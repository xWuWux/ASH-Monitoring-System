"""Security and behavior tests for the alert engine's webhook/logging paths."""

import json
import logging

import requests

from ash_alerting import ASHAlertEngine, AlertRule
from ash_observability import JsonFormatter

CANARY = "WEBHOOK_PATH_CANARY_9c1f"


def _rule():
    return AlertRule(
        name="test rule",
        pattern=r"rm\s+-rf",
        severity="critical",
        description="test",
        actions=["webhook", "log"],
    )


def _capture_alert_logs():
    records = []

    class Capture(logging.Handler):
        def emit(self, record):
            records.append(record)

    logger = logging.getLogger("ash-alerting")
    handler = Capture()
    logger.addHandler(handler)
    return logger, handler, records


def test_webhook_failure_logs_only_the_webhook_index(tmp_path, monkeypatch):
    engine = ASHAlertEngine(
        config_path=str(tmp_path / "rules.json"),
        alert_log_path=str(tmp_path / "alerts.jsonl"),
    )
    engine.webhooks = [f"https://hooks.slack.com/services/{CANARY}"]
    logger, handler, records = _capture_alert_logs()
    try:

        def fail(*_args, **_kwargs):
            raise requests.ConnectionError(
                f"failed while posting to https://hooks.slack.com/services/{CANARY}"
            )

        monkeypatch.setattr(requests, "post", fail)
        engine._send_webhook(_rule(), {"hostname": "host-a"})
    finally:
        logger.removeHandler(handler)

    assert records
    record = records[-1]
    assert record.webhook_index == 0
    assert record.error_type == "ConnectionError"
    assert CANARY not in str(record.__dict__)
    formatted = JsonFormatter("ash-consumer").format(record)
    assert CANARY not in formatted
    assert "hooks.slack.com" not in formatted


def test_webhook_index_identifies_the_configured_position(tmp_path, monkeypatch):
    engine = ASHAlertEngine(
        config_path=str(tmp_path / "rules.json"),
        alert_log_path=str(tmp_path / "alerts.jsonl"),
    )
    engine.webhooks = [
        f"https://first.example/services/{CANARY}",
        f"https://second.example/services/{CANARY}",
    ]
    logger, handler, records = _capture_alert_logs()
    try:

        class RejectedResponse:
            ok = False
            status_code = 503

        monkeypatch.setattr(requests, "post", lambda *_a, **_k: RejectedResponse())
        engine._send_webhook(_rule(), {"hostname": "host-a"})
    finally:
        logger.removeHandler(handler)

    assert [record.webhook_index for record in records] == [0, 1]
    for record in records:
        formatted = JsonFormatter("ash-consumer").format(record)
        assert CANARY not in formatted
        assert "first.example" not in formatted
        assert "second.example" not in formatted


def test_non_2xx_webhook_response_is_not_treated_as_success(tmp_path, monkeypatch):
    engine = ASHAlertEngine(
        config_path=str(tmp_path / "rules.json"),
        alert_log_path=str(tmp_path / "alerts.jsonl"),
    )
    engine.webhooks = [f"https://hooks.slack.com/services/{CANARY}"]
    logger, handler, records = _capture_alert_logs()
    try:

        class RejectedResponse:
            ok = False
            status_code = 403

        monkeypatch.setattr(requests, "post", lambda *_a, **_k: RejectedResponse())
        engine._send_webhook(_rule(), {"hostname": "host-a"})
    finally:
        logger.removeHandler(handler)

    assert records
    assert records[-1].status_code == 403
    assert records[-1].webhook_index == 0
    assert CANARY not in str(records[-1].__dict__)


def test_alert_log_writes_json_to_the_configured_path(tmp_path):
    alert_path = tmp_path / "nested" / "alerts.jsonl"
    engine = ASHAlertEngine(
        config_path=str(tmp_path / "rules.json"),
        alert_log_path=str(alert_path),
    )

    engine._log_alert(_rule(), {"hostname": "host-a", "command": "rm -rf /tmp/x"})

    record = json.loads(alert_path.read_text().strip())
    assert record["rule_name"] == "test rule"
    assert record["timestamp"].endswith("Z")
    assert record["hostname"] == "host-a"


def test_alert_log_failure_does_not_raise(tmp_path):
    engine = ASHAlertEngine(
        config_path=str(tmp_path / "rules.json"),
        alert_log_path=str(tmp_path),  # a directory, so open() fails
    )

    engine._log_alert(_rule(), {"hostname": "host-a"})
