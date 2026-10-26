"""Unit tests for W3C tracing, agent span reconstruction, and export."""

import threading

import pytest
from opentelemetry.trace import SpanKind, StatusCode
from opentelemetry.sdk.trace.export.in_memory_span_exporter import (
    InMemorySpanExporter,
)

import ash_tracing
from ash_tracing import (
    Tracing,
    _env_bool,
    _env_ratio,
    _valid_span_id,
    _valid_trace_id,
    configure_tracing,
    current_trace_fields,
    extract_remote_context,
    shutdown_tracing,
    trace_columns,
    trace_context_strings,
)

TRACE_ID = "0123456789abcdef0123456789abcdef"
PARENT_SPAN_ID = "fedcba9876543210"
SPAN_ID = "0011223344556677"


@pytest.fixture(autouse=True)
def _isolate_tracing(monkeypatch):
    """Keep env-driven configuration and the process cache out of other tests."""
    for name in (
        "ASH_TRACING_ENABLED",
        "ASH_OTLP_ENDPOINT",
        "ASH_TRACING_SAMPLE_RATIO",
    ):
        monkeypatch.delenv(name, raising=False)
    shutdown_tracing()
    yield
    shutdown_tracing()


@pytest.fixture
def tracing_factory():
    created = []

    def factory(sample_ratio=1.0):
        exporter = InMemorySpanExporter()
        tracing = Tracing(
            "test-service",
            enabled=True,
            endpoint="http://127.0.0.1:4318/v1/traces",
            sample_ratio=sample_ratio,
            span_exporter=exporter,
        )
        created.append(tracing)
        return tracing, exporter

    yield factory
    for tracing in created:
        tracing.shutdown()


@pytest.mark.parametrize("value", ["1", "true", "YES", "on"])
def test_env_bool_accepts_true_values(monkeypatch, value):
    monkeypatch.setenv("ASH_TRACING_ENABLED", value)
    assert _env_bool("ASH_TRACING_ENABLED") is True


@pytest.mark.parametrize("value", ["0", "false", "NO", "off"])
def test_env_bool_accepts_false_values(monkeypatch, value):
    monkeypatch.setenv("ASH_TRACING_ENABLED", value)
    assert _env_bool("ASH_TRACING_ENABLED") is False


@pytest.mark.parametrize("value", ["maybe", "", "2"])
def test_env_bool_rejects_other_values(monkeypatch, value):
    monkeypatch.setenv("ASH_TRACING_ENABLED", value)
    with pytest.raises(RuntimeError, match="ASH_TRACING_ENABLED"):
        _env_bool("ASH_TRACING_ENABLED")


@pytest.mark.parametrize("value", ["0", "0.25", "1", "1.0"])
def test_env_ratio_accepts_unit_interval(monkeypatch, value):
    monkeypatch.setenv("ASH_TRACING_SAMPLE_RATIO", value)
    assert 0.0 <= _env_ratio("ASH_TRACING_SAMPLE_RATIO") <= 1.0


@pytest.mark.parametrize("value", ["-0.1", "1.1", "nan", "inf", "-inf", "not-a-number"])
def test_env_ratio_rejects_invalid_values(monkeypatch, value):
    monkeypatch.setenv("ASH_TRACING_SAMPLE_RATIO", value)
    with pytest.raises(RuntimeError, match="ASH_TRACING_SAMPLE_RATIO"):
        _env_ratio("ASH_TRACING_SAMPLE_RATIO")


@pytest.mark.parametrize(
    "value,expected",
    [
        (TRACE_ID, TRACE_ID),
        (TRACE_ID.upper(), TRACE_ID),
        ("0" * 32, None),
        ("0" * 31, None),
        ("g" * 32, None),
        (None, None),
        (123, None),
    ],
)
def test_valid_trace_id_normalizes_and_rejects(value, expected):
    assert _valid_trace_id(value) == expected


@pytest.mark.parametrize(
    "value,expected",
    [
        (SPAN_ID, SPAN_ID),
        (SPAN_ID.upper(), SPAN_ID),
        ("0" * 16, None),
        ("0" * 15, None),
        (None, None),
        (b"0011223344556677", None),
    ],
)
def test_valid_span_id_normalizes_and_rejects(value, expected):
    assert _valid_span_id(value) == expected


def test_trace_context_requires_trace_and_span_but_not_parent():
    event = {"trace_id": TRACE_ID, "span_id": SPAN_ID}
    assert trace_context_strings(event) == (TRACE_ID, SPAN_ID, None)

    event["parent_span_id"] = "not-a-span"
    assert trace_context_strings(event) == (TRACE_ID, SPAN_ID, None)

    event["span_id"] = ""
    assert trace_context_strings(event) is None


def test_trace_columns_distinguish_missing_from_invalid():
    assert trace_columns({"trace_id": TRACE_ID, "span_id": SPAN_ID}) == {
        "trace_id": TRACE_ID,
        "span_id": SPAN_ID,
        "parent_span_id": None,
    }
    assert trace_columns({"trace_id": "bad", "span_id": SPAN_ID}) == {
        "trace_id": None,
        "span_id": SPAN_ID,
        "parent_span_id": None,
    }
    assert trace_columns("not-a-mapping") == {
        "trace_id": None,
        "span_id": None,
        "parent_span_id": None,
    }


def test_configure_tracing_is_disabled_by_default():
    tracing = configure_tracing("ash-consumer")
    assert tracing.enabled is False
    assert tracing.shutdown() is None


def test_configure_tracing_requires_an_endpoint(monkeypatch):
    monkeypatch.setenv("ASH_TRACING_ENABLED", "true")
    with pytest.raises(RuntimeError, match="ASH_OTLP_ENDPOINT"):
        configure_tracing("ash-consumer")


@pytest.mark.parametrize(
    "endpoint",
    [
        "127.0.0.1:4318/v1/traces",
        "ftp://127.0.0.1/v1/traces",
        "http:///v1/traces",
        "https://user:secret@collector/v1/traces",
    ],
)
def test_configure_tracing_rejects_unsafe_endpoints(monkeypatch, endpoint):
    monkeypatch.setenv("ASH_TRACING_ENABLED", "true")
    monkeypatch.setenv("ASH_OTLP_ENDPOINT", endpoint)
    with pytest.raises(RuntimeError):
        configure_tracing("ash-consumer")


def test_configure_tracing_caches_an_equivalent_configuration(monkeypatch):
    monkeypatch.setenv("ASH_TRACING_ENABLED", "true")
    monkeypatch.setenv("ASH_OTLP_ENDPOINT", "http://127.0.0.1:4318/v1/traces")

    first = configure_tracing("ash-consumer")
    second = configure_tracing("ash-consumer")

    assert first is second
    assert first.enabled is True


def test_agent_span_reuses_the_exact_emitted_ids(tracing_factory):
    tracing, exporter = tracing_factory()
    event = {
        "event_id": "e-1",
        "event_type": "command_start",
        "source": "bash-debug",
        "hostname": "host-a",
        "session_id": "s-1",
        "user": "tester",
        "exit_code": 0,
        "trace_id": TRACE_ID,
        "span_id": SPAN_ID,
        "parent_span_id": PARENT_SPAN_ID,
        "command": "curl -H 'Authorization: Bearer SUPER_SECRET'",
    }

    with tracing.start_agent_span(event) as agent_span:
        with tracing.start_span("ash.consumer.process_event"):
            pass
        assert current_trace_fields() == {
            "trace_id": TRACE_ID,
            "span_id": SPAN_ID,
        }
        agent_span.set_attribute("ash.outcome", "ok")

    spans = exporter.get_finished_spans()
    agent = next(span for span in spans if span.name == "ash.agent.command_start")
    child = next(span for span in spans if span.name == "ash.consumer.process_event")

    assert f"{agent.context.trace_id:032x}" == TRACE_ID
    assert f"{agent.context.span_id:016x}" == SPAN_ID
    assert f"{agent.parent.span_id:016x}" == PARENT_SPAN_ID
    assert agent.attributes["ash.trace_context_source"] == "agent"
    assert f"{child.parent.span_id:016x}" == SPAN_ID
    # Trace attributes must never carry the command text or its credentials.
    assert "SUPER_SECRET" not in str(agent.attributes)
    assert "command" not in agent.attributes


def test_invalid_event_context_starts_a_new_trace(tracing_factory):
    tracing, exporter = tracing_factory()
    event = {
        "event_type": "command_start",
        "source": "bash-debug",
        "trace_id": "not-a-trace-id",
        "span_id": "not-a-span-id",
    }

    with tracing.start_agent_span(event):
        pass

    agent = exporter.get_finished_spans()[0]
    assert agent.attributes["ash.trace_context_source"] == "generated"
    assert f"{agent.context.trace_id:032x}" != "0" * 32
    assert f"{agent.context.span_id:016x}" != "0" * 16
    assert agent.parent is None


def test_agent_span_answers_a_non_mapping_event(tracing_factory):
    tracing, exporter = tracing_factory()

    with tracing.start_agent_span("not-a-mapping"):
        pass

    agent = exporter.get_finished_spans()[0]
    assert agent.attributes["ash.trace_context_source"] == "generated"


def test_agent_child_is_dropped_when_its_root_is_dropped(tracing_factory):
    """A partial ratio must not export an orphan command_end span."""
    tracing, exporter = tracing_factory(sample_ratio=0.0)
    root = {"event_type": "command_start", "trace_id": TRACE_ID, "span_id": SPAN_ID}
    child = {
        "event_type": "command_end",
        "trace_id": TRACE_ID,
        "span_id": PARENT_SPAN_ID,
        "parent_span_id": SPAN_ID,
    }

    with tracing.start_agent_span(root):
        pass
    with tracing.start_agent_span(child):
        pass

    assert not exporter.get_finished_spans()


def test_agent_child_matches_its_root_for_a_partial_ratio(tracing_factory):
    tracing, exporter = tracing_factory(sample_ratio=0.5)
    sampled_trace = "0" * 31 + "1"
    dropped_trace = "f" * 32

    for trace_id in (sampled_trace, dropped_trace):
        root = {"event_type": "command_start", "trace_id": trace_id, "span_id": SPAN_ID}
        child = {
            "event_type": "command_end",
            "trace_id": trace_id,
            "span_id": PARENT_SPAN_ID,
            "parent_span_id": SPAN_ID,
        }
        with tracing.start_agent_span(root):
            pass
        with tracing.start_agent_span(child):
            pass

    exported = {
        (f"{span.context.trace_id:032x}", span.name)
        for span in exporter.get_finished_spans()
    }
    assert exported == {
        (sampled_trace, "ash.agent.command_start"),
        (sampled_trace, "ash.agent.command_end"),
    }


def test_server_span_continues_a_valid_traceparent(tracing_factory):
    tracing, exporter = tracing_factory()
    carrier = {"traceparent": f"00-{TRACE_ID}-{PARENT_SPAN_ID}-01"}

    with tracing.start_server_span(
        "ash.api.request",
        carrier,
        attributes={"http.request.method": "GET"},
    ):
        fields = current_trace_fields()
        assert fields["trace_id"] == TRACE_ID

    span = exporter.get_finished_spans()[0]
    assert span.kind is SpanKind.SERVER
    assert f"{span.context.trace_id:032x}" == TRACE_ID
    assert f"{span.parent.span_id:016x}" == PARENT_SPAN_ID
    assert f"{span.context.span_id:016x}" != PARENT_SPAN_ID


def test_server_span_ignores_a_malformed_traceparent(tracing_factory):
    tracing, exporter = tracing_factory()
    carrier = {"traceparent": f"00-not-a-trace-{PARENT_SPAN_ID}-01"}

    with tracing.start_server_span("ash.api.request", carrier):
        pass

    span = exporter.get_finished_spans()[0]
    assert span.parent is None
    assert f"{span.context.trace_id:032x}" != TRACE_ID


def test_sampled_remote_parent_wins_over_zero_local_ratio(tracing_factory):
    tracing, exporter = tracing_factory(sample_ratio=0.0)
    sampled = {"traceparent": f"00-{TRACE_ID}-{PARENT_SPAN_ID}-01"}
    unsampled = {"traceparent": f"00-{TRACE_ID}-{PARENT_SPAN_ID}-00"}

    with tracing.start_server_span("sampled", sampled):
        pass
    with tracing.start_server_span("unsampled", unsampled):
        pass

    names = [span.name for span in exporter.get_finished_spans()]
    assert names == ["sampled"]


def test_root_span_is_dropped_when_the_local_ratio_is_zero(tracing_factory):
    tracing, exporter = tracing_factory(sample_ratio=0.0)

    with tracing.start_root_span("root"):
        pass

    assert not exporter.get_finished_spans()


def test_links_use_the_events_exact_span_ids(tracing_factory):
    tracing, _exporter = tracing_factory()
    events = [
        {"trace_id": TRACE_ID, "span_id": SPAN_ID},
        {"trace_id": "invalid", "span_id": SPAN_ID},
        {"trace_id": TRACE_ID, "span_id": PARENT_SPAN_ID},
    ]

    links = tracing.links_for_events(events)

    assert len(links) == 2
    assert f"{links[0].context.trace_id:032x}" == TRACE_ID
    assert f"{links[0].context.span_id:016x}" == SPAN_ID
    assert f"{links[1].context.span_id:016x}" == PARENT_SPAN_ID


def test_links_report_the_same_sampling_decision_as_the_agent_span(tracing_factory):
    """A dropped agent trace must not be advertised as sampled by its link."""
    tracing, _exporter = tracing_factory(sample_ratio=0.5)
    sampled_trace = "0" * 31 + "1"
    dropped_trace = "f" * 32

    links = tracing.links_for_events(
        [
            {"trace_id": sampled_trace, "span_id": SPAN_ID},
            {"trace_id": dropped_trace, "span_id": PARENT_SPAN_ID},
        ]
    )

    flags = {
        f"{link.context.trace_id:032x}": link.context.trace_flags.sampled
        for link in links
    }
    assert flags[sampled_trace] is True
    assert flags[dropped_trace] is False


def test_record_exception_never_records_the_message(tracing_factory):
    tracing, exporter = tracing_factory()

    with tracing.start_span("work") as span:
        try:
            raise RuntimeError("password=hunter2")
        except RuntimeError as error:
            span.record_exception(error)

    finished = exporter.get_finished_spans()[0]
    assert finished.status.status_code is StatusCode.ERROR
    assert "hunter2" not in str(finished.events)
    assert finished.events[0].attributes["exception.type"] == "RuntimeError"


def test_current_trace_fields_is_empty_without_a_span(tracing_factory):
    tracing, _exporter = tracing_factory()
    shutdown_tracing()
    assert current_trace_fields() == {}


def test_disabled_tracing_is_a_safe_no_op():
    tracing = Tracing("disabled-service")

    with tracing.start_agent_span({"event_type": "command_start"}):
        with tracing.start_span("child"):
            tracing.start_server_span("server", {})
            assert current_trace_fields() == {}
    assert tracing.links_for_events([{"trace_id": TRACE_ID, "span_id": SPAN_ID}]) == []
    assert tracing.shutdown() is None
    assert tracing.shutdown() is None


def test_forced_id_generator_is_thread_local():
    generator = ash_tracing._ForcedIdGenerator()
    generator.force(int(TRACE_ID, 16), int(SPAN_ID, 16))
    observed = {}

    def other_thread():
        observed["trace"] = generator.generate_trace_id()
        observed["span"] = generator.generate_span_id()
        observed["random"] = generator.is_trace_id_random()

    thread = threading.Thread(target=other_thread)
    thread.start()
    thread.join()

    assert generator.generate_trace_id() == int(TRACE_ID, 16)
    assert generator.generate_span_id() == int(SPAN_ID, 16)
    assert observed["trace"] != int(TRACE_ID, 16)
    assert observed["span"] != int(SPAN_ID, 16)
    assert observed["random"] is True


def test_forced_id_generator_reports_forced_ids_as_not_random():
    """An agent trace ID is external, so it must not be flagged random."""
    generator = ash_tracing._ForcedIdGenerator()
    assert generator.is_trace_id_random() is True

    generator.force(int(TRACE_ID, 16), int(SPAN_ID, 16))
    assert generator.is_trace_id_random() is False

    generator.clear()
    assert generator.is_trace_id_random() is True


def test_forced_id_generator_skips_zero_ids(monkeypatch):
    """Zero is the W3C invalid ID, so the generator must retry."""
    generator = ash_tracing._ForcedIdGenerator()
    values = iter([0, int(TRACE_ID, 16), 0, int(SPAN_ID, 16)])
    monkeypatch.setattr(ash_tracing.random, "getrandbits", lambda _bits: next(values))

    assert generator.generate_trace_id() == int(TRACE_ID, 16)
    assert generator.generate_span_id() == int(SPAN_ID, 16)


def test_extract_remote_context_rejects_invalid_headers():
    assert extract_remote_context({"traceparent": "garbage"}) is None
    assert extract_remote_context({}) is None
    context = extract_remote_context(
        {"traceparent": f"00-{TRACE_ID}-{PARENT_SPAN_ID}-01"}
    )
    assert context is not None
