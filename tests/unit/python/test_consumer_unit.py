"""Unit tests for the Kafka consumer's processing and local-write logic."""

import json


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
    monkeypatch.setattr(consumer_module, "start_http_server", lambda _port: None)
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
