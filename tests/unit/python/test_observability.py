"""Unit tests for the shared structured-logging and notify helpers."""

import io
import json
import logging
import socket

import pytest

from ash_observability import (
    JsonFormatter,
    configure_logging,
    log_extra,
    new_request_id,
    redact_text,
    safe_url_for_log,
    sanitize_request_id,
    sd_notify,
    utc_timestamp,
)


@pytest.fixture(autouse=True)
def _restore_root_logging():
    """Keep configure_logging() from leaking handlers between tests."""
    root = logging.getLogger()
    original_handlers = list(root.handlers)
    original_level = root.level
    yield
    for handler in list(root.handlers):
        if handler not in original_handlers:
            root.removeHandler(handler)
            handler.close()
    for handler in original_handlers:
        if handler not in root.handlers:
            root.addHandler(handler)
    root.setLevel(original_level)


def test_utc_timestamp_is_iso_utc_with_milliseconds():
    value = utc_timestamp()

    assert value.endswith("Z")
    assert "T" in value
    assert len(value.split(".")[1]) == 4  # milliseconds + trailing Z


def test_new_request_id_is_a_uuid_string():
    value = new_request_id()

    assert len(value) == 36
    assert value == str(__import__("uuid").UUID(value))


@pytest.mark.parametrize(
    "value,expected",
    [
        ("abc-123", "abc-123"),
        ("a" * 128, "a" * 128),
        (" a.b:c_d ", "a.b:c_d"),
        (None, None),
        ("", None),
        ("a" * 129, None),
        ("line\nbreak", None),
        ("semi;colon", None),
    ],
)
def test_sanitize_request_id_enforces_domain(value, expected):
    assert sanitize_request_id(value) == expected


@pytest.mark.parametrize(
    "url,expected",
    [
        ("https://hooks.slack.com/services/SECRET", "https://hooks.slack.com"),
        (
            "https://hooks.slack.com:8443/services/SECRET?x=1",
            "https://hooks.slack.com:8443",
        ),
        ("https://user:pass@example.test/path", "https://example.test"),
        ("http://[2001:db8::1]:8080/path", "http://[2001:db8::1]:8080"),
        ("not-a-url", "<invalid-url>"),
        ("https://example.test:bad/path", "<invalid-url>"),
    ],
)
def test_safe_url_for_log_strips_credentials_and_path(url, expected):
    assert safe_url_for_log(url) == expected


def test_configure_logging_emits_one_json_object_per_record():
    stream = io.StringIO()
    logger = configure_logging("test-component", stream=stream)

    logger.info(
        "hello",
        extra=log_extra(request_id="req-1", path="/api/v1/events"),
    )

    record = json.loads(stream.getvalue())
    assert record["severity"] == "INFO"
    assert record["component"] == "test-component"
    assert record["logger"] == "test-component"
    assert record["message"] == "hello"
    assert record["request_id"] == "req-1"
    assert record["path"] == "/api/v1/events"
    assert "status_code" not in record


def test_configure_logging_is_idempotent():
    stream = io.StringIO()
    first = configure_logging("first-component", stream=stream)
    root = logging.getLogger()
    handler_count = len(root.handlers)

    second = configure_logging("second-component", stream=stream)

    assert first.name == "first-component"
    assert second.name == "second-component"
    assert len(root.handlers) == handler_count


def test_configure_logging_rotates_bounded_files(tmp_path):
    log_dir = tmp_path / "logs"
    logger = configure_logging(
        "rotation-test",
        log_dir=str(log_dir),
        log_name="service.log",
        max_bytes=200,
        backup_count=2,
        stream=io.StringIO(),
    )

    for index in range(50):
        logger.info("line %s", index)

    files = sorted(log_dir.glob("service.log*"))
    assert 1 <= len(files) <= 3
    assert all(path.stat().st_size <= 400 for path in files)
    for path in files:
        for line in path.read_text().splitlines():
            json.loads(line)


def test_json_formatter_includes_exception_text():
    formatter = JsonFormatter("test-component")
    record = logging.LogRecord(
        "ash-consumer",
        logging.ERROR,
        __file__,
        1,
        "failed",
        (),
        None,
    )
    try:
        raise RuntimeError("boom")
    except RuntimeError:
        record.exc_info = __import__("sys").exc_info()

    payload = json.loads(formatter.format(record))

    assert payload["component"] == "ash-consumer"
    assert "RuntimeError: boom" in payload["exception"]


@pytest.mark.parametrize(
    "value,expected",
    [
        (
            "postgresql://ash:DB_CANARY@db.internal/ash_logs",
            "postgresql://[redacted]@db.internal/ash_logs",
        ),
        (
            "connect failed: password=DB_CANARY host=db",
            "connect failed: password=[redacted] host=db",
        ),
        ("token: TOKEN_CANARY", "token: [redacted]"),
        ("api_key = KEY_CANARY", "api_key = [redacted]"),
        (
            "https://hooks.slack.com/services/path",
            "https://hooks.slack.com/services/path",
        ),
    ],
)
def test_redact_text_removes_url_userinfo_and_secret_assignments(value, expected):
    assert redact_text(value) == expected


def test_json_formatter_redacts_message_and_exception_text():
    formatter = JsonFormatter("test-component")
    record = logging.LogRecord(
        "ash-consumer",
        logging.ERROR,
        __file__,
        1,
        "failed to connect to postgresql://ash:DB_CANARY@db/ash_logs",
        (),
        None,
    )
    try:
        raise RuntimeError("password=DB_CANARY")
    except RuntimeError:
        record.exc_info = __import__("sys").exc_info()

    payload = json.loads(formatter.format(record))

    assert "DB_CANARY" not in payload["message"]
    assert "DB_CANARY" not in payload["exception"]
    assert "postgresql://[redacted]@db/ash_logs" in payload["message"]


def test_log_extra_drops_unknown_and_reserved_keys():
    assert log_extra(request_id="r", message="not allowed", nonsense=1) == {
        "request_id": "r"
    }


def test_sd_notify_sends_a_datagram_when_notify_socket_is_set(tmp_path, monkeypatch):
    socket_path = tmp_path / "notify.sock"
    receiver = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    receiver.bind(str(socket_path))
    receiver.settimeout(1.0)
    try:
        monkeypatch.setenv("NOTIFY_SOCKET", str(socket_path))
        assert sd_notify("READY=1") is True
        assert receiver.recv(64) == b"READY=1"
    finally:
        receiver.close()


def test_sd_notify_is_a_noop_without_notify_socket(monkeypatch):
    monkeypatch.delenv("NOTIFY_SOCKET", raising=False)

    assert sd_notify("READY=1") is False
