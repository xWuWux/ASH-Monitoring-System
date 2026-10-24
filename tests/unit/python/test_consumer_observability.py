"""Unit tests for the consumer's health, readiness, and env overrides."""

import json
import urllib.request

import pytest


def _configured_consumer(consumer_module, tmp_path, monkeypatch, **config):
    """Build a real consumer without opening Kafka, DB, or sockets."""
    log_dir = tmp_path / "log"
    config_path = tmp_path / "consumer.conf"
    payload = {
        "log_dir": str(log_dir),
        "database_enabled": False,
        "alerting_enabled": False,
        **config,
    }
    config_path.write_text(json.dumps(payload), encoding="utf-8")

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
    return consumer_module.ASHConsumer(str(config_path))


def test_environment_overrides_take_precedence(consumer_module, tmp_path, monkeypatch):
    monkeypatch.setenv("ASH_KAFKA_BROKERS", "broker-a:9092, broker-b:9093")
    monkeypatch.setenv("ASH_KAFKA_TOPIC", "env-topic")
    monkeypatch.setenv("ASH_KAFKA_GROUP_ID", "env-group")
    monkeypatch.setenv("ASH_DATABASE_URL", "postgresql://env/db")
    monkeypatch.setenv("ASH_METRICS_PORT", "19090")
    monkeypatch.setenv("ASH_LOG_LEVEL", "debug")
    monkeypatch.setenv("ASH_LOG_MAX_BYTES", "1024")
    monkeypatch.setenv("ASH_LOG_BACKUP_COUNT", "1")

    consumer = _configured_consumer(
        consumer_module,
        tmp_path,
        monkeypatch,
        kafka_brokers=["file-broker:9092"],
        kafka_topic="file-topic",
        kafka_group_id="file-group",
        database_url="postgresql://file/db",
        metrics_port=9090,
    )

    assert consumer.config["kafka_brokers"] == ["broker-a:9092", "broker-b:9093"]
    assert consumer.config["kafka_topic"] == "env-topic"
    assert consumer.config["kafka_group_id"] == "env-group"
    assert consumer.config["database_url"] == "postgresql://env/db"
    assert consumer.config["metrics_port"] == 19090
    assert consumer.config["log_level"] == "DEBUG"
    assert consumer.config["log_max_bytes"] == 1024
    assert consumer.config["log_backup_count"] == 1


@pytest.mark.parametrize(
    "name,value",
    [
        ("ASH_METRICS_PORT", "70000"),
        ("ASH_METRICS_PORT", "not-a-port"),
        ("ASH_LOG_LEVEL", "verbose"),
        ("ASH_DATABASE_ENABLED", "maybe"),
        ("ASH_KAFKA_BROKERS", " , "),
        ("ASH_BATCH_SIZE", "0"),
        ("ASH_BATCH_TIMEOUT", "nan"),
    ],
)
def test_invalid_environment_values_fail_fast(
    consumer_module, tmp_path, monkeypatch, name, value
):
    monkeypatch.setenv(name, value)

    with pytest.raises(ValueError, match=name):
        _configured_consumer(consumer_module, tmp_path, monkeypatch)


def test_readiness_reports_database_and_flush_state(consumer_factory, consumer_module):
    consumer = consumer_factory()
    consumer.running = True
    consumer._last_flush_error = None
    consumer_module.DB_AVAILABLE.set(1)

    status, body = consumer.health_readiness()
    assert status.value == 200
    assert body["status"] == "ready"
    assert body["checks"] == {
        "consumer": "running",
        "database": "disabled",
        "flush": "ok",
    }

    consumer._last_flush_error = "OperationalError"
    status, body = consumer.health_readiness()
    assert status.value == 503
    assert body["status"] == "degraded"
    assert body["checks"]["flush"] == "failing"


def test_readiness_is_false_when_postgres_is_unavailable(
    consumer_factory, consumer_module
):
    consumer = consumer_factory(database_enabled=True)
    consumer.running = True
    consumer._last_flush_error = None
    consumer_module.DB_AVAILABLE.set(0)

    status, body = consumer.health_readiness()

    assert status.value == 503
    assert body["checks"]["database"] == "unavailable"
    assert "postgres" not in json.dumps(body).lower()


def test_liveness_ignores_database_and_flush_state(consumer_factory, consumer_module):
    consumer = consumer_factory(database_enabled=True)
    consumer.running = True
    consumer._last_flush_error = "OperationalError"
    consumer_module.DB_AVAILABLE.set(0)

    status, body = consumer.health_liveness()

    assert status.value == 200
    assert body == {"status": "alive"}


def test_successful_flush_restores_readiness(
    consumer_factory, event_factory, consumer_module
):
    consumer = consumer_factory()
    consumer.running = True
    consumer._last_flush_error = "OperationalError"
    consumer.batch_buffer = [event_factory()]
    consumer.batch_raw_texts = [None]

    consumer._flush_batch()

    assert consumer._last_flush_error is None
    assert consumer.health_readiness()[0].value == 200


def test_observability_server_serves_health_and_metrics(
    consumer_factory, consumer_module
):
    consumer = consumer_factory(
        metrics_host="127.0.0.1", metrics_port=0, database_enabled=False
    )
    consumer.running = True
    consumer._last_flush_error = None
    consumer_module.DB_AVAILABLE.set(1)

    consumer._start_observability_server()
    server = consumer._observability_server
    assert server is not None
    port = server.server_address[1]
    try:
        with urllib.request.urlopen(
            f"http://127.0.0.1:{port}/health/ready", timeout=2
        ) as response:
            body = json.load(response)
        assert response.status == 200
        assert body["status"] == "ready"

        with urllib.request.urlopen(
            f"http://127.0.0.1:{port}/health/live", timeout=2
        ) as response:
            assert json.load(response) == {"status": "alive"}

        with urllib.request.urlopen(
            f"http://127.0.0.1:{port}/metrics", timeout=2
        ) as response:
            metrics = response.read().decode("utf-8")
        assert "ash_consumer_ready 1.0" in metrics
    finally:
        server.shutdown()
        server.server_close()
        consumer._observability_server = None


def test_kafka_lag_metric_documents_its_limitation(consumer_module):
    assert "not committed-offset lag" in consumer_module.KAFKA_LAG._documentation


def test_installed_shared_module_path_is_added_once(
    consumer_module, tmp_path, monkeypatch
):
    """The installed executable lives in bin/ while its modules are in lib/."""
    monkeypatch.setattr(consumer_module.sys, "path", list(consumer_module.sys.path))

    consumer_module._ensure_shared_module_path(str(tmp_path))
    consumer_module._ensure_shared_module_path(str(tmp_path))

    assert consumer_module.sys.path.count(str(tmp_path)) == 1


def test_missing_shared_module_path_is_ignored(consumer_module, tmp_path, monkeypatch):
    missing = tmp_path / "does-not-exist"
    monkeypatch.setattr(consumer_module.sys, "path", list(consumer_module.sys.path))

    consumer_module._ensure_shared_module_path(str(missing))

    assert str(missing) not in consumer_module.sys.path
