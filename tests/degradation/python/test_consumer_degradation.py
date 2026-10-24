"""Degradation tests for the consumer's startup and storage failure paths."""

import json

import psycopg2
from kafka.errors import KafkaTimeoutError


class _BrokenConnection:
    def __init__(self):
        self.rolled_back = False

    def cursor(self):
        raise psycopg2.OperationalError("server closed the connection")

    def rollback(self):
        self.rolled_back = True


class _BadWriteConnection:
    def __init__(self):
        self.rolled_back = False

    def cursor(self):
        raise ValueError("unexpected database error")

    def rollback(self):
        self.rolled_back = True


def test_database_setup_gives_up_after_retries(consumer_module, monkeypatch):
    consumer = object.__new__(consumer_module.ASHConsumer)
    consumer.config = {"database_url": "postgresql://unreachable"}
    consumer.logger = consumer_module.logging.getLogger("db-retry-test")

    attempts = []

    def fail_connect(_url):
        attempts.append(_url)
        raise RuntimeError("connection refused")

    monkeypatch.setattr(consumer_module, "_connect_db", fail_connect)
    monkeypatch.setattr(consumer_module.time, "sleep", lambda _seconds: None)

    consumer._setup_database()

    assert len(attempts) == 3
    assert consumer.db_conn is None


def test_kafka_setup_exits_after_all_attempts(consumer_module, monkeypatch):
    consumer = object.__new__(consumer_module.ASHConsumer)
    consumer.config = {
        "kafka_topic": "ash-logs",
        "kafka_brokers": ["unreachable:9092"],
        "kafka_group_id": "test-group",
    }
    consumer.logger = consumer_module.logging.getLogger("kafka-retry-test")

    attempts = []

    def fail_consumer(*_args, **_kwargs):
        attempts.append(1)
        raise KafkaTimeoutError("no brokers available")

    monkeypatch.setattr(consumer_module, "KafkaConsumer", fail_consumer)
    monkeypatch.setattr(consumer_module.time, "sleep", lambda _seconds: None)

    try:
        consumer._setup_kafka_consumer()
    except SystemExit as exc:
        assert exc.code == 1
    else:
        raise AssertionError("consumer should exit when Kafka is unavailable")

    assert len(attempts) == 5


def test_flush_survives_a_lost_database_connection(
    consumer_factory, event_factory, consumer_module, monkeypatch
):
    consumer = consumer_factory()
    consumer.db_conn = _BrokenConnection()
    consumer.batch_buffer = [event_factory()]

    reconnect_attempts = []

    def fail_reconnect(_url):
        reconnect_attempts.append(1)
        raise RuntimeError("still down")

    monkeypatch.setattr(consumer_module, "_connect_db", fail_reconnect)
    monkeypatch.setattr(consumer_module.time, "sleep", lambda _seconds: None)

    consumer._flush_batch()

    # The local file is the durable fallback while Postgres is unavailable.
    written = consumer.log_dir / "ash-history-smoke-host.jsonl"
    assert written.exists()
    assert len(reconnect_attempts) == 3
    assert consumer.batch_buffer == []
    assert consumer._commit_pending.is_set()


def test_flush_rolls_back_on_an_unexpected_database_error(
    consumer_factory, event_factory, consumer_module, monkeypatch
):
    consumer = consumer_factory()
    connection = _BadWriteConnection()
    consumer.db_conn = connection
    consumer.batch_buffer = [event_factory()]
    monkeypatch.setattr(consumer_module.time, "sleep", lambda _seconds: None)

    consumer._flush_batch()

    assert connection.rolled_back is True
    assert (consumer.log_dir / "ash-history-smoke-host.jsonl").exists()
    assert consumer._commit_pending.is_set()


def test_invalid_event_does_not_stop_following_events(consumer_factory, event_factory):
    consumer = consumer_factory()
    invalid = event_factory()
    del invalid["source"]
    valid = event_factory()

    consumer.process_message(invalid)
    consumer.process_message(valid)

    assert consumer.batch_buffer == [valid]
    records = [json.loads(line) for line in consumer.dlq_path.read_text().splitlines()]
    assert len(records) == 1
    assert records[0]["event"]["event_id"] == invalid["event_id"]


def test_dead_letter_path_failure_does_not_crash_processing(
    consumer_factory, event_factory, monkeypatch
):
    consumer = consumer_factory()
    consumer.dlq_path = consumer.log_dir  # a directory, so open() fails
    invalid = event_factory()
    del invalid["timestamp"]

    consumer.process_message(invalid)

    assert consumer.batch_buffer == []
    valid = event_factory()
    consumer.process_message(valid)
    assert consumer.batch_buffer == [valid]
