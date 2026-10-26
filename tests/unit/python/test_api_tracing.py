"""API request-span and access-log correlation tests."""

import json
import logging

from opentelemetry.sdk.trace.export.in_memory_span_exporter import (
    InMemorySpanExporter,
)
from opentelemetry.trace import SpanKind

from ash_observability import JsonFormatter
from ash_tracing import Tracing

TRACE_ID = "0123456789abcdef0123456789abcdef"
PARENT_SPAN_ID = "fedcba9876543210"


def _install_tracing(api_module, monkeypatch):
    exporter = InMemorySpanExporter()
    tracing = Tracing(
        "ash-api",
        enabled=True,
        endpoint="http://127.0.0.1:4318/v1/traces",
        span_exporter=exporter,
    )
    monkeypatch.setattr(api_module, "_TRACING", tracing)
    return tracing, exporter


class _CaptureHandler(logging.Handler):
    def __init__(self):
        super().__init__()
        self.lines = []
        self.setFormatter(JsonFormatter("ash-api"))

    def emit(self, record):
        self.lines.append(self.format(record))


def test_api_span_continues_traceparent_and_access_log_carries_it(
    api_client, api_module, monkeypatch
):
    tracing, exporter = _install_tracing(api_module, monkeypatch)
    handler = _CaptureHandler()
    api_module.logger.addHandler(handler)
    api_module.logger.setLevel(logging.INFO)
    try:
        response = api_client.get(
            "/api/v1/events",
            headers={"traceparent": f"00-{TRACE_ID}-{PARENT_SPAN_ID}-01"},
        )
    finally:
        api_module.logger.removeHandler(handler)
        tracing.shutdown()

    assert response.status_code == 401
    span = exporter.get_finished_spans()[-1]
    assert span.name == "ash.api.request"
    assert span.kind is SpanKind.SERVER
    assert f"{span.context.trace_id:032x}" == TRACE_ID
    assert f"{span.parent.span_id:016x}" == PARENT_SPAN_ID
    assert span.attributes["http.request.method"] == "GET"
    assert span.attributes["http.route"] == "/api/v1/events"
    assert span.attributes["http.response.status_code"] == 401

    access = [
        json.loads(line)
        for line in handler.lines
        if json.loads(line)["message"] == "request completed"
    ]
    assert access
    assert access[-1]["trace_id"] == TRACE_ID
    assert access[-1]["span_id"] == f"{span.context.span_id:016x}"


def test_api_span_ignores_a_malformed_traceparent(api_client, api_module, monkeypatch):
    tracing, exporter = _install_tracing(api_module, monkeypatch)
    try:
        response = api_client.get(
            "/api/v1/events",
            headers={"traceparent": "00-not-a-trace-not-a-span-01"},
        )
    finally:
        tracing.shutdown()

    assert response.status_code == 401
    span = exporter.get_finished_spans()[-1]
    assert span.parent is None
    assert f"{span.context.trace_id:032x}" != TRACE_ID
