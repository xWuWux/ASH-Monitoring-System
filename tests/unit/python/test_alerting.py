"""Security and behavior tests for the alert engine's webhook/logging paths."""

import json
import logging

import requests

from ash_alerting import ASHAlertEngine, AlertRule

SECRET = "WEBHOOK_PATH_SECRET_9c1f"


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


def test_webhook_failure_logs_redacted_host_only(tmp_path, monkeypatch):
    engine = ASHAlertEngine(
        config_path=str(tmp_path / "rules.json"),
        alert_log_path=str(tmp_path / "alerts.jsonl"),
    )
    engine.webhooks = [f"https://hooks.slack.com/services/{SECRET}"]
    logger, handler, records = _capture_alert_logs()
    try:

        def fail(*_args, **_kwargs):
            raise requests.ConnectionError(
                f"failed while posting to https://hooks.slack.com/services/{SECRET}"
            )

        monkeypatch.setattr(requests, "post", fail)
        engine._send_webhook(_rule(), {"hostname": "host-a"})
    finally:
        logger.removeHandler(handler)

    assert records
    record = records[-1]
    assert record.webhook_host == "https://hooks.slack.com"
    assert record.error_type == "ConnectionError"
    assert SECRET not in str(record.__dict__)


def test_non_2xx_webhook_response_is_not_treated_as_success(tmp_path, monkeypatch):
    engine = ASHAlertEngine(
        config_path=str(tmp_path / "rules.json"),
        alert_log_path=str(tmp_path / "alerts.jsonl"),
    )
    engine.webhooks = [f"https://hooks.slack.com/services/{SECRET}"]
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
    assert records[-1].webhook_host == "https://hooks.slack.com"
    assert SECRET not in str(records[-1].__dict__)


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
