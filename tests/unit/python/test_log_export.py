"""Unit tests for best-effort OTLP log export."""

import logging

import pytest
from opentelemetry.sdk._logs.export import InMemoryLogRecordExporter
from opentelemetry.sdk.trace.export.in_memory_span_exporter import (
    InMemorySpanExporter,
)

import ash_log_export
from ash_log_export import LogExport, configure_log_export, shutdown_log_export
from ash_tracing import Tracing

TRACE_ID = "0123456789abcdef0123456789abcdef"
SPAN_ID = "0011223344556677"
ENDPOINT = "http://127.0.0.1:4318/v1/logs"


@pytest.fixture(autouse=True)
def _isolate_log_export(monkeypatch):
    """Keep env, global state, and the root log level out of other tests."""
    for name in ("ASH_LOG_OTLP_ENABLED", "ASH_OTLP_LOGS_ENDPOINT"):
        monkeypatch.delenv(name, raising=False)
    root = logging.getLogger()
    old_level = root.level
    root.setLevel(logging.DEBUG)
    shutdown_log_export()
    yield
    shutdown_log_export()
    root.setLevel(old_level)


@pytest.fixture
def export_factory():
    created = []

    def factory(component="ash-test", enabled=True, endpoint=ENDPOINT):
        exporter = InMemoryLogRecordExporter()
        export = LogExport(
            component,
            enabled=enabled,
            endpoint=endpoint,
            log_exporter=exporter,
        )
        created.append(export)
        return export, exporter

    yield factory
    for export in created:
        export.shutdown()


def _emit(message="hello", **extra):
    logging.getLogger("ash-test").info(message, extra=extra)


def test_disabled_export_does_not_attach_a_handler(export_factory):
    export, _exporter = export_factory(enabled=False)

    assert export.enabled is False
    assert export._handler is None
    assert export._provider is None
    assert export.force_flush() is None
    assert export.shutdown() is None


def test_disabled_export_is_the_default_without_importing_the_sdk(monkeypatch):
    export = configure_log_export("ash-test")

    assert export.enabled is False
    assert export._provider is None


@pytest.mark.parametrize("value", ["maybe", "", "2"])
def test_enabled_flag_rejects_unknown_values(monkeypatch, value):
    monkeypatch.setenv("ASH_LOG_OTLP_ENABLED", value)
    with pytest.raises(RuntimeError, match="ASH_LOG_OTLP_ENABLED"):
        configure_log_export("ash-test")


def test_enabled_export_requires_an_endpoint(monkeypatch):
    monkeypatch.setenv("ASH_LOG_OTLP_ENABLED", "true")
    with pytest.raises(RuntimeError, match="ASH_OTLP_LOGS_ENDPOINT"):
        configure_log_export("ash-test")


@pytest.mark.parametrize(
    "endpoint",
    [
        "127.0.0.1:4318/v1/logs",
        "ftp://127.0.0.1/v1/logs",
        "http:///v1/logs",
        "https://user:secret@collector/v1/logs",
    ],
)
def test_export_rejects_unsafe_endpoints(monkeypatch, endpoint):
    monkeypatch.setenv("ASH_LOG_OTLP_ENABLED", "true")
    monkeypatch.setenv("ASH_OTLP_LOGS_ENDPOINT", endpoint)
    with pytest.raises(RuntimeError):
        configure_log_export("ash-test")


def test_exported_record_uses_the_allow_listed_schema(export_factory):
    _export, exporter = export_factory()

    _emit(
        "request completed",
        request_id="9f0c",
        method="GET",
        path="/api/v1/events",
        status_code=200,
        password="hunter2",
        arbitrary_field="not exported",
    )

    records = exporter.get_finished_logs()
    assert len(records) == 1
    record = records[0]
    assert record.log_record.body == "request completed"
    assert record.resource.attributes["service.name"] == "ash-test"
    assert record.log_record.attributes["component"] == "ash-test"
    assert record.log_record.attributes["logger"] == "ash-test"
    assert record.log_record.attributes["request_id"] == "9f0c"
    assert record.log_record.attributes["method"] == "GET"
    assert record.log_record.attributes["path"] == "/api/v1/events"
    assert record.log_record.attributes["status_code"] == 200
    assert "password" not in record.log_record.attributes
    assert "arbitrary_field" not in record.log_record.attributes
    assert "code.filepath" not in record.log_record.attributes
    assert "code.lineno" not in record.log_record.attributes


def test_message_is_redacted_before_it_reaches_the_exporter(export_factory):
    _export, exporter = export_factory()

    _emit("connecting to postgresql://user:secret@db/ash_logs token=abc123")

    body = exporter.get_finished_logs()[0].log_record.body
    assert "secret" not in body
    assert "abc123" not in body
    assert "[redacted]" in body


def test_exception_message_and_traceback_are_never_exported(export_factory):
    _export, exporter = export_factory()

    try:
        raise RuntimeError("password=hunter2")
    except RuntimeError:
        logging.getLogger("ash-test").exception("request failed")

    record = exporter.get_finished_logs()[0]
    assert record.log_record.attributes["exception.type"] == "RuntimeError"
    assert "hunter2" not in record.log_record.body
    assert "hunter2" not in str(record.log_record.attributes)
    assert "exception.message" not in record.log_record.attributes
    assert "exception.stacktrace" not in record.log_record.attributes


def test_explicit_trace_context_wins_over_the_ambient_span(export_factory):
    _export, exporter = export_factory()
    tracing = Tracing(
        "ash-test",
        enabled=True,
        endpoint="http://127.0.0.1:4318/v1/traces",
        span_exporter=InMemorySpanExporter(),
    )
    span = tracing.start_root_span("ambient")
    span.attach()
    try:
        _emit("event", trace_id=TRACE_ID, span_id=SPAN_ID)
    finally:
        span.finish()
        span.detach()
        tracing.shutdown()

    record = exporter.get_finished_logs()[0]
    assert f"{record.log_record.trace_id:032x}" == TRACE_ID
    assert f"{record.log_record.span_id:016x}" == SPAN_ID
    assert record.log_record.trace_flags.sampled is True


def test_ambient_span_is_used_when_no_explicit_context_is_set(export_factory):
    _export, exporter = export_factory()
    tracing = Tracing(
        "ash-test",
        enabled=True,
        endpoint="http://127.0.0.1:4318/v1/traces",
        span_exporter=InMemorySpanExporter(),
    )
    span = tracing.start_root_span("ambient")
    span.attach()
    try:
        _emit("event")
    finally:
        span.finish()
        span.detach()
        tracing.shutdown()

    record = exporter.get_finished_logs()[0]
    assert record.log_record.trace_id != 0
    assert record.log_record.span_id != 0


def test_partial_explicit_context_is_ignored(export_factory):
    _export, exporter = export_factory()

    _emit("event", trace_id=TRACE_ID)

    record = exporter.get_finished_logs()[0]
    assert record.log_record.trace_id == 0
    assert record.log_record.span_id == 0


def test_shutdown_flushes_and_stops_export(export_factory):
    export, exporter = export_factory()
    _emit("before")
    export.force_flush()
    assert len(exporter.get_finished_logs()) == 1

    export.shutdown()
    _emit("after")

    assert len(exporter.get_finished_logs()) == 1
    assert export.shutdown() is None


def test_configure_caches_an_equivalent_configuration(monkeypatch):
    monkeypatch.setenv("ASH_LOG_OTLP_ENABLED", "true")
    monkeypatch.setenv("ASH_OTLP_LOGS_ENDPOINT", ENDPOINT)

    first = configure_log_export("ash-test")
    second = configure_log_export("ash-test")

    assert first is second
    assert first.enabled is True


def test_configure_replaces_a_changed_configuration(monkeypatch):
    monkeypatch.setenv("ASH_LOG_OTLP_ENABLED", "true")
    monkeypatch.setenv("ASH_OTLP_LOGS_ENDPOINT", ENDPOINT)
    first = configure_log_export("ash-test")

    monkeypatch.setenv("ASH_OTLP_LOGS_ENDPOINT", "http://127.0.0.1:4318/v1/other")
    second = configure_log_export("ash-test")

    assert first is not second
    assert second.endpoint.endswith("/v1/other")


def test_component_must_be_non_empty():
    with pytest.raises(RuntimeError, match="component"):
        configure_log_export("")


def test_shutdown_log_export_is_idempotent():
    assert ash_log_export.shutdown_log_export() is None
    assert ash_log_export.shutdown_log_export() is None
