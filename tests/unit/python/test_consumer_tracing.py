"""Consumer integration tests for reconstructed agent spans and batch links."""

import json

import pytest
from opentelemetry.sdk.trace.export.in_memory_span_exporter import (
    InMemorySpanExporter,
)
from opentelemetry.trace import StatusCode

from ash_tracing import Tracing

TRACE_ID = "0123456789abcdef0123456789abcdef"
SPAN_ID = "0011223344556677"


@pytest.fixture
def consumer_tracing():
    exporter = InMemorySpanExporter()
    tracing = Tracing(
        "ash-consumer",
        enabled=True,
        endpoint="http://127.0.0.1:4318/v1/traces",
        span_exporter=exporter,
    )
    yield tracing, exporter
    tracing.shutdown()


def _finished(exporter, name):
    spans = [span for span in exporter.get_finished_spans() if span.name == name]
    assert spans, f"missing {name} in {[s.name for s in exporter.get_finished_spans()]}"
    return spans[-1]


def test_process_message_reconstructs_the_agent_span(
    consumer_factory, event_factory, consumer_tracing
):
    tracing, exporter = consumer_tracing
    consumer = consumer_factory()
    consumer.tracing = tracing
    event = event_factory(trace_id=TRACE_ID, span_id=SPAN_ID)
    raw_text = json.dumps(event, separators=(",", ":"))

    consumer.process_message(event, raw_event_text=raw_text)

    agent = _finished(exporter, "ash.agent.command_start")
    process = _finished(exporter, "ash.consumer.process_event")
    assert f"{agent.context.trace_id:032x}" == TRACE_ID
    assert f"{agent.context.span_id:016x}" == SPAN_ID
    assert f"{process.parent.span_id:016x}" == SPAN_ID
    assert consumer.batch_buffer == [event]
    assert consumer.batch_raw_texts == [raw_text]


def test_process_message_still_stores_an_event_without_trace_context(
    consumer_factory, event_factory, consumer_tracing
):
    tracing, exporter = consumer_tracing
    consumer = consumer_factory()
    consumer.tracing = tracing
    event = event_factory()

    consumer.process_message(event, raw_event_text=None)

    agent = _finished(exporter, "ash.agent.command_start")
    assert agent.attributes["ash.trace_context_source"] == "generated"
    assert consumer.batch_buffer == [event]


def test_a_broken_tracer_never_drops_an_event(
    consumer_factory, event_factory, consumer_tracing, monkeypatch
):
    tracing, _exporter = consumer_tracing
    consumer = consumer_factory()
    consumer.tracing = tracing

    def explode(*_args, **_kwargs):
        raise RuntimeError("exporter is misconfigured")

    monkeypatch.setattr(tracing._tracer, "start_span", explode)
    event = event_factory(trace_id=TRACE_ID, span_id=SPAN_ID)

    consumer.process_message(event, raw_event_text="{}")

    assert consumer.batch_buffer == [event]


def test_flush_span_links_every_event_and_has_no_database_child(
    consumer_factory, event_factory, consumer_tracing
):
    tracing, exporter = consumer_tracing
    consumer = consumer_factory()
    consumer.tracing = tracing
    first = event_factory(trace_id=TRACE_ID, span_id=SPAN_ID)
    second = event_factory(trace_id="f" * 32, span_id="a" * 16)
    consumer.batch_buffer = [first, second]
    consumer.batch_raw_texts = [None, None]

    consumer._flush_batch()

    flush = _finished(exporter, "ash.consumer.flush_batch")
    assert flush.parent is None
    assert flush.attributes["ash.batch_size"] == 2
    assert flush.attributes["ash.database_enabled"] is False
    assert flush.attributes["ash.flush.outcome"] == "ok"
    linked = {
        (f"{link.context.trace_id:032x}", f"{link.context.span_id:016x}")
        for link in flush.links
    }
    assert linked == {(TRACE_ID, SPAN_ID), ("f" * 32, "a" * 16)}
    assert not [
        span
        for span in exporter.get_finished_spans()
        if span.name == "ash.db.insert_events"
    ]


def test_flush_span_contains_a_database_child(
    consumer_factory, event_factory, consumer_tracing, monkeypatch
):
    tracing, exporter = consumer_tracing
    consumer = consumer_factory(database_enabled=True)
    consumer.tracing = tracing
    consumer.batch_buffer = [event_factory(trace_id=TRACE_ID, span_id=SPAN_ID)]
    consumer.batch_raw_texts = [None]
    monkeypatch.setattr(
        consumer, "_write_database_batch", lambda _events, _raw_texts: True
    )

    consumer._flush_batch()

    flush = _finished(exporter, "ash.consumer.flush_batch")
    db_span = _finished(exporter, "ash.db.insert_events")
    assert f"{db_span.parent.span_id:016x}" == f"{flush.context.span_id:016x}"


def test_flush_failure_marks_the_span_and_keeps_the_batch(
    consumer_factory, event_factory, consumer_tracing, monkeypatch
):
    tracing, exporter = consumer_tracing
    consumer = consumer_factory()
    consumer.tracing = tracing
    event = event_factory()
    consumer.batch_buffer = [event]
    consumer.batch_raw_texts = [None]

    def fail(_events):
        raise OSError("disk full")

    monkeypatch.setattr(consumer, "_write_file_batch", fail)

    consumer._flush_batch()

    flush = _finished(exporter, "ash.consumer.flush_batch")
    assert flush.status.status_code is StatusCode.ERROR
    assert flush.attributes["ash.flush.outcome"] == "error"
    assert consumer.batch_buffer == [event]
    assert consumer._last_flush_error == "OSError"
