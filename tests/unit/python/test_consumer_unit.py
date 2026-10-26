"""Unit tests for the Kafka consumer's processing and local-write logic."""

import json
import time

import psycopg2
import pytest


def test_constructor_creates_log_dir_before_configuring_logging(
    consumer_module, tmp_path, monkeypatch
):
    """Regression: _setup_logging() used self.log_dir before it was set.

    Every real ``ASHConsumer(...)`` startup raised AttributeError, but the
    other tests bypass __init__ via object.__new__, so nothing caught it.
    """
    log_dir = tmp_path / "log"
    config_path = tmp_path / "consumer.conf"
    config_path.write_text(
        json.dumps(
            {
                "log_dir": str(log_dir),
                "database_enabled": False,
                "alerting_enabled": False,
            }
        ),
        encoding="utf-8",
    )

    # Keep the constructor hermetic: no broker, metrics server, timers, or
    # process-wide signal handler changes.
    monkeypatch.setattr(
        consumer_module.ASHConsumer, "_setup_kafka_consumer", lambda self: None
    )
    monkeypatch.setattr(
        consumer_module.ASHConsumer, "_start_flush_timer", lambda self: None
    )
    monkeypatch.setattr(
        consumer_module.ASHConsumer, "_start_retention_timer", lambda self: None
    )
    monkeypatch.setattr(
        consumer_module.ASHConsumer, "_start_observability_server", lambda self: None
    )
    monkeypatch.setattr(
        consumer_module.ASHConsumer, "_start_watchdog", lambda self: None
    )
    monkeypatch.setattr(consumer_module.signal, "signal", lambda *_args: None)

    consumer = consumer_module.ASHConsumer(str(config_path))

    assert consumer.log_dir == log_dir
    assert log_dir.is_dir()
    assert consumer.logger.name == "ash-consumer"


def test_process_message_buffers_a_valid_event(consumer_factory, event_factory):
    consumer = consumer_factory()
    event = event_factory()

    consumer.process_message(event)

    assert consumer.batch_buffer == [event]
    assert not consumer._commit_pending.is_set()


def test_invalid_event_is_written_to_the_dead_letter_queue(
    consumer_factory, event_factory
):
    consumer = consumer_factory()
    event = event_factory()
    del event["hostname"]

    consumer.process_message(event)

    assert consumer.batch_buffer == []
    assert consumer.dlq_path.exists()
    record = json.loads(consumer.dlq_path.read_text().strip())
    assert record["reason"] == "missing_field"
    assert record["event"]["event_id"] == event["event_id"]


def test_duplicate_event_is_processed_once(consumer_factory, event_factory):
    consumer = consumer_factory()
    event = event_factory()

    consumer.process_message(event)
    consumer.process_message(event)

    assert consumer.batch_buffer == [event]


def test_flush_writes_one_jsonl_file_per_hostname(consumer_factory, event_factory):
    consumer = consumer_factory()
    consumer.batch_buffer = [
        event_factory(
            hostname="host-a", event_id="11111111-1111-1111-1111-111111111111"
        ),
        event_factory(
            hostname="host-b", event_id="22222222-2222-2222-2222-222222222222"
        ),
        event_factory(
            hostname="host-a", event_id="33333333-3333-3333-3333-333333333333"
        ),
    ]

    consumer._flush_batch()

    host_a = consumer.log_dir / "ash-history-host-a.jsonl"
    host_b = consumer.log_dir / "ash-history-host-b.jsonl"
    assert len(host_a.read_text().splitlines()) == 2
    assert len(host_b.read_text().splitlines()) == 1
    assert consumer.batch_buffer == []
    assert consumer._commit_pending.is_set()


def test_batch_size_triggers_an_automatic_flush(consumer_factory, event_factory):
    consumer = consumer_factory(batch_size=1)

    consumer.process_message(event_factory())

    assert consumer.batch_buffer == []
    assert consumer._commit_pending.is_set()
    written = consumer.log_dir / "ash-history-smoke-host.jsonl"
    assert written.exists()
    assert len(written.read_text().splitlines()) == 1


def test_flush_keeps_the_batch_when_the_local_write_fails(
    consumer_factory, event_factory, monkeypatch
):
    consumer = consumer_factory()
    event = event_factory()
    consumer.batch_buffer = [event]

    def fail_write(_events):
        raise OSError("disk full")

    monkeypatch.setattr(consumer, "_write_file_batch", fail_write)
    consumer._flush_batch()

    assert consumer.batch_buffer == [event]
    assert not consumer._commit_pending.is_set()


def test_flush_without_a_database_is_file_only(consumer_factory, event_factory):
    consumer = consumer_factory()
    consumer.db_conn = None
    consumer.batch_buffer = [event_factory()]

    consumer._flush_batch()

    written = consumer.log_dir / "ash-history-smoke-host.jsonl"
    assert written.exists()
    assert consumer._commit_pending.is_set()


def test_retention_vacuums_with_autocommit_and_restores_it(consumer_factory):
    """VACUUM cannot run in a transaction; it used to fail every run."""

    class FakeCursor:
        rowcount = 1

        def __init__(self, conn):
            self.conn = conn

        def __enter__(self):
            return self

        def __exit__(self, *_exc):
            return False

        def execute(self, sql, _params=None):
            self.conn.log.append((sql, self.conn.autocommit))

        def fetchall(self):
            return []

    class FakeConnection:
        def __init__(self):
            self.autocommit = False
            self.log = []

        def cursor(self, **_kwargs):
            return FakeCursor(self)

        def commit(self):
            self.log.append(("COMMIT", self.autocommit))

    consumer = consumer_factory()
    consumer.archive_days = 30
    consumer.retention_days = 90
    connection = FakeConnection()
    consumer.db_conn = connection

    consumer._run_retention()

    vacuum_entries = [
        (sql, autocommit)
        for sql, autocommit in connection.log
        if isinstance(sql, str) and sql.startswith("VACUUM")
    ]
    assert vacuum_entries == [
        ("VACUUM ANALYZE command_logs", True),
        ("VACUUM ANALYZE file_changes", True),
    ]
    # The connection must go back to manual-commit mode for normal writes.
    assert connection.autocommit is False


def test_dedup_cache_evicts_oldest_entries(consumer_factory):
    consumer = consumer_factory(max_dedup_cache=4)

    for index in range(6):
        assert consumer._deduplicate(f"event-{index}") is False

    # Once the cache exceeds its limit, the oldest half is dropped.
    assert len(consumer.seen_event_ids) <= 4
    assert consumer._deduplicate("event-5") is True

    evicted = next(
        event_id
        for event_id in (f"event-{index}" for index in range(6))
        if event_id not in consumer.seen_event_ids
    )
    assert consumer._deduplicate(evicted) is False


# ─── Strict event validation ─────────────────────────────────────────────────


def test_validation_accepts_a_complete_event(consumer_factory, event_factory):
    consumer = consumer_factory()

    assert consumer._validate_event(event_factory()) == (True, "")


@pytest.mark.parametrize(
    "field,value,reason",
    [
        ("event_id", "not-a-uuid", "invalid_uuid"),
        ("session_id", "not-a-uuid", "invalid_uuid"),
        ("timestamp", "yesterday", "invalid_timestamp"),
        ("event_type", "not_an_event", "invalid_event_type"),
        ("source", "not-a-source", "invalid_source"),
        ("hostname", "", "missing_field"),
    ],
)
def test_validation_classifies_malformed_fields(
    consumer_factory, event_factory, field, value, reason
):
    consumer = consumer_factory()
    event = event_factory(**{field: value})

    assert consumer._validate_event(event) == (False, reason)


def test_validation_rejects_non_objects_and_wrong_types(
    consumer_factory, event_factory
):
    consumer = consumer_factory()

    assert consumer._validate_event(["not", "an", "object"]) == (
        False,
        "not_an_object",
    )
    assert consumer._validate_event(event_factory(uid="1000")) == (
        False,
        "invalid_type",
    )
    assert consumer._validate_event(event_factory(duration_ms="soon")) == (
        False,
        "invalid_type",
    )


def test_validation_rejects_values_wider_than_the_column(
    consumer_factory, event_factory, consumer_module, monkeypatch
):
    consumer = consumer_factory()
    monkeypatch.setitem(consumer_module.MAX_FIELD_LENGTHS, "hostname", 4)

    assert consumer._validate_event(event_factory(hostname="too-long")) == (
        False,
        "field_too_long",
    )


def test_invalid_event_records_its_specific_reason(consumer_factory, event_factory):
    consumer = consumer_factory()
    event = event_factory(event_type="not_an_event")

    consumer.process_message(event)

    record = json.loads(consumer.dlq_path.read_text().strip())
    assert record["reason"] == "invalid_event_type"
    assert record["event"]["event_id"] == event["event_id"]
    assert consumer.batch_buffer == []


# ─── Raw Kafka payload handling ──────────────────────────────────────────────


def test_process_message_keeps_the_exact_raw_text(consumer_factory, event_factory):
    consumer = consumer_factory()
    event = event_factory()
    raw_text = json.dumps(event)

    consumer.process_message(event, raw_event_text=raw_text)

    assert consumer.batch_raw_texts == [raw_text]


@pytest.mark.parametrize(
    "value,reason,raw_prefix",
    [
        (b"{not json", "invalid_json", "{not json"),
        (b"[]", "not_an_object", "[]"),
        (b"\xff\xfe", "invalid_utf8", "\ufffd"),
        (123, "unsupported_payload", None),
    ],
)
def test_decode_message_rejects_poison_payloads(
    consumer_factory, value, reason, raw_prefix
):
    consumer = consumer_factory()

    raw_text, event, error = consumer._decode_message(value)

    assert event is None
    assert error == reason
    if raw_prefix is None:
        assert raw_text is None
    else:
        assert raw_text.startswith(raw_prefix)


def test_decode_message_rejects_oversized_payloads(
    consumer_factory, consumer_module, monkeypatch
):
    consumer = consumer_factory()
    monkeypatch.setattr(consumer_module, "MAX_RAW_EVENT_LENGTH", 10)

    raw_text, event, error = consumer._decode_message(b'{"a": 1, "b": 2}')

    assert event is None
    assert error == "raw_too_long"
    assert raw_text == '{"a": 1, "'


def test_flush_pads_missing_raw_texts(consumer_factory, event_factory, monkeypatch):
    consumer = consumer_factory()
    consumer.config["database_enabled"] = True
    consumer.batch_buffer = [event_factory()]
    consumer.batch_raw_texts = []
    captured = {}

    def capture(_batch, raw_texts):
        captured["raw_texts"] = raw_texts
        return True

    monkeypatch.setattr(consumer, "_write_database_batch", capture)
    consumer._flush_batch()

    assert captured["raw_texts"] == [None]


# ─── PostgreSQL persistence and per-row fallback ─────────────────────────────


class _RecordingCursor:
    def __init__(self, connection):
        self.connection = connection

    def __enter__(self):
        return self

    def __exit__(self, *_exc):
        return False


class _RecordingConnection:
    def __init__(self):
        self.autocommit = False
        self.commits = 0
        self.rollbacks = 0
        self.executed = []

    def cursor(self, **_kwargs):
        return _RecordingCursor(self)

    def commit(self):
        self.commits += 1

    def rollback(self):
        self.rollbacks += 1

    def close(self):
        pass


def test_database_batch_stores_the_exact_raw_text(
    consumer_factory, event_factory, consumer_module, monkeypatch
):
    consumer = consumer_factory()
    consumer.config["database_enabled"] = True
    connection = _RecordingConnection()
    consumer.db_conn = connection
    event = event_factory(
        trace_id="a" * 32,
        span_id="b" * 16,
        parent_span_id="c" * 16,
    )
    raw_text = json.dumps(event, separators=(",", ":"))

    def record_command_rows(cursor, sql, values, template=None):
        if "INSERT INTO command_logs" in sql:
            cursor.connection.executed.extend(values)

    monkeypatch.setattr(consumer_module, "execute_values", record_command_rows)

    consumer._write_database_batch([event], [raw_text])

    assert connection.executed[0][22:25] == ("a" * 32, "b" * 16, "c" * 16)
    assert connection.executed[0][28] == raw_text
    assert connection.executed[0][27] == json.dumps(event, default=str)
    assert connection.commits == 1
    assert consumer_module.DB_AVAILABLE._value.get() == 1


def test_database_batch_stores_null_for_invalid_trace_context(
    consumer_factory, event_factory, consumer_module, monkeypatch
):
    """A malformed trace context must not reject the event or store garbage."""
    consumer = consumer_factory()
    consumer.config["database_enabled"] = True
    connection = _RecordingConnection()
    consumer.db_conn = connection
    event = event_factory(
        trace_id="not-a-trace", span_id="short", parent_span_id="0" * 16
    )

    def record_command_rows(cursor, sql, values, template=None):
        if "INSERT INTO command_logs" in sql:
            cursor.connection.executed.extend(values)

    monkeypatch.setattr(consumer_module, "execute_values", record_command_rows)

    consumer._write_database_batch([event], [None])

    assert connection.executed[0][22:25] == (None, None, None)
    assert connection.commits == 1


def test_failed_batch_retries_rows_and_dlqs_only_the_bad_row(
    consumer_factory, event_factory, consumer_module, monkeypatch
):
    consumer = consumer_factory()
    consumer.config["database_enabled"] = True
    connection = _RecordingConnection()
    consumer.db_conn = connection
    good = event_factory()
    bad = event_factory()

    def reject_bad_row(cursor, sql, values, template=None):
        if "INSERT INTO command_logs" not in sql:
            return
        if len(values) > 1 or values[0][0] == bad["event_id"]:
            raise psycopg2.DataError("invalid input syntax")
        cursor.connection.executed.extend(values)

    monkeypatch.setattr(consumer_module, "execute_values", reject_bad_row)

    assert consumer._write_database_batch([good, bad], ["good", "bad"]) is True

    assert [row[0] for row in connection.executed] == [good["event_id"]]
    records = [json.loads(line) for line in consumer.dlq_path.read_text().splitlines()]
    assert [record["reason"] for record in records] == ["db_row_error"]
    assert records[0]["event"]["event_id"] == bad["event_id"]
    assert consumer_module.DB_AVAILABLE._value.get() == 1


def test_database_outage_marks_the_gauge_unavailable(
    consumer_factory, event_factory, consumer_module
):
    consumer = consumer_factory()
    consumer.config["database_enabled"] = True
    consumer.db_conn = _RecordingConnection()

    def fail_cursor(**_kwargs):
        raise ValueError("unexpected failure")

    consumer.db_conn.cursor = fail_cursor

    with pytest.raises(consumer_module.DatabaseWriteError):
        consumer._write_database_batch([event_factory()], ["raw"])

    assert consumer_module.DB_AVAILABLE._value.get() == 0
    assert consumer.db_conn.rollbacks == 1


# ─── Consume loop ────────────────────────────────────────────────────────────


class _Message:
    def __init__(self, value):
        self.value = value


class _FakeKafkaConsumer:
    def __init__(self, messages, failure=None):
        self._messages = iter(messages)
        self._failure = failure
        self.commits = 0
        self.closed = False

    def __iter__(self):
        return self

    def __next__(self):
        if self._failure is not None:
            raise self._failure
        return next(self._messages)

    def metrics(self):
        return {"records-lag-max": 7.0}

    def commit(self):
        self.commits += 1

    def close(self):
        self.closed = True


def test_run_dead_letters_poison_payloads_and_keeps_consuming(
    consumer_factory, event_factory, consumer_module
):
    consumer = consumer_factory(batch_size=1)
    raw_text = json.dumps(event_factory())
    fake = _FakeKafkaConsumer([_Message(b"{not json"), _Message(raw_text.encode())])
    consumer.consumer = fake

    consumer.run()

    records = [json.loads(line) for line in consumer.dlq_path.read_text().splitlines()]
    assert [record["reason"] for record in records] == ["invalid_json"]
    written = consumer.log_dir / "ash-history-smoke-host.jsonl"
    assert len(written.read_text().splitlines()) == 1
    assert fake.commits == 1
    assert fake.closed is True
    assert consumer_module.KAFKA_LAG._value.get() == 7.0


def test_run_raises_on_a_fatal_loop_error(consumer_factory):
    consumer = consumer_factory()
    fake = _FakeKafkaConsumer([], failure=RuntimeError("broker broke"))
    consumer.consumer = fake

    with pytest.raises(RuntimeError, match="broker broke"):
        consumer.run()

    assert fake.closed is True


def test_flush_timer_flushes_under_the_processing_lock(
    consumer_factory, event_factory, consumer_module, monkeypatch
):
    consumer = consumer_factory()
    consumer.batch_buffer = [event_factory()]
    consumer.batch_raw_texts = [None]
    consumer.last_flush = time.time() - 10
    consumer.batch_timeout = 0
    flushed = []

    def fake_flush():
        flushed.append(consumer._processing_lock.locked())
        consumer.running = False

    class _ImmediateThread:
        def __init__(self, target, daemon=None):
            self._target = target

        def start(self):
            self._target()

    monkeypatch.setattr(consumer, "_flush_batch", fake_flush)
    monkeypatch.setattr(consumer_module.time, "sleep", lambda _seconds: None)
    monkeypatch.setattr(consumer_module.threading, "Thread", _ImmediateThread)

    consumer._start_flush_timer()

    assert flushed == [True]
