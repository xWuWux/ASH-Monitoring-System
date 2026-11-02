#!/usr/bin/env python3
"""W3C tracing support shared by the ASH consumer and API.

The agent does not run an OpenTelemetry SDK.  It emits a trace-id and
span-id with every event, and the consumer reconstructs the agent span from
those IDs.  This module is the only place that talks to the OpenTelemetry
SDK, so tracing can stay disabled without making the rest of ASH depend on
the exporter.

Environment domains:

* ``ASH_TRACING_ENABLED``: ``1/true/yes/on`` or ``0/false/no/off``;
  unset means disabled.
* ``ASH_OTLP_ENDPOINT``: full OTLP/HTTP traces URL (``http`` or ``https``
  with a host), for example ``http://127.0.0.1:4318/v1/traces``.  Required
  when tracing is enabled.
* ``ASH_TRACING_SAMPLE_RATIO``: finite number in ``[0.0, 1.0]``; default
  ``1.0``.  A remote parent's sampled flag takes precedence.

New functions and classes document their own domains below.
"""

from __future__ import annotations

import logging
import os
import random
import re
import socket
import threading
from typing import Any, Dict, Iterable, Mapping, Optional, Sequence, Tuple
from urllib.parse import urlsplit

from ash_observability import FALSE_VALUES, TRUE_VALUES

logger = logging.getLogger("ash-tracing")

_TRACE_ID_RE = re.compile(r"^[a-f0-9]{32}$")
_SPAN_ID_RE = re.compile(r"^[a-f0-9]{16}$")
_ZERO_TRACE_ID = "0" * 32
_ZERO_SPAN_ID = "0" * 16

# Resource attribute keys from the OpenTelemetry semantic conventions.  They
# are copied rather than imported so a disabled tracing module does not need
# the SDK at import time.
_SERVICE_NAME = "service.name"
_SERVICE_INSTANCE_ID = "service.instance.id"


def _env_bool(name: str, default: bool = False) -> bool:
    """Read a strict boolean environment variable.

    Domain: unset -> ``default``; otherwise one of ``1/true/yes/on`` or
    ``0/false/no/off`` (case-insensitive).  Any other value raises
    ``RuntimeError`` naming the variable.
    """
    raw = os.environ.get(name)
    if raw is None:
        return default
    value = raw.strip().lower()
    if value in TRUE_VALUES:
        return True
    if value in FALSE_VALUES:
        return False
    raise RuntimeError(
        f"{name} must be one of {TRUE_VALUES + FALSE_VALUES}, got {raw!r}"
    )


def _env_ratio(name: str, default: float = 1.0) -> float:
    """Read a sampling ratio.

    Domain: unset -> ``default``; otherwise a finite number in ``[0.0, 1.0]``.
    NaN, infinities, and out-of-range values raise ``RuntimeError``.
    """
    raw = os.environ.get(name)
    if raw is None:
        return default
    try:
        value = float(raw)
    except ValueError as exc:
        raise RuntimeError(f"{name} must be a number, got {raw!r}") from exc
    if value != value or value in (float("inf"), float("-inf")):
        raise RuntimeError(f"{name} must be finite, got {raw!r}")
    if not 0.0 <= value <= 1.0:
        raise RuntimeError(f"{name} must be between 0 and 1, got {value}")
    return value


def _valid_trace_id(value: Any) -> Optional[str]:
    """Return a normalized W3C trace-id or ``None``.

    Domain: any value; accepted values are 32 lowercase hex characters and
    are not all zero.  Uppercase is normalized to lowercase.  Invalid input
    is ignored so an old agent or a malformed event still gets processed.
    """
    if not isinstance(value, str):
        return None
    candidate = value.strip().lower()
    if not _TRACE_ID_RE.fullmatch(candidate) or candidate == _ZERO_TRACE_ID:
        return None
    return candidate


def _valid_span_id(value: Any) -> Optional[str]:
    """Return a normalized W3C span-id or ``None``.

    Domain: any value; accepted values are 16 lowercase hex characters and
    are not all zero.  Uppercase is normalized to lowercase.
    """
    if not isinstance(value, str):
        return None
    candidate = value.strip().lower()
    if not _SPAN_ID_RE.fullmatch(candidate) or candidate == _ZERO_SPAN_ID:
        return None
    return candidate


def trace_context_strings(
    event: Mapping[str, Any],
) -> Optional[Tuple[str, str, Optional[str]]]:
    """Extract ``(trace_id, span_id, parent_span_id)`` from an event.

    Domain: ``event`` is any mapping (normally a decoded ASH event).  A
    context is returned only when both trace_id and span_id are valid W3C
    IDs; ``parent_span_id`` is optional.  Invalid or missing context returns
    ``None`` so the caller can start a new trace instead of dropping the
    event.  This function performs no I/O.
    """
    trace_id = _valid_trace_id(event.get("trace_id"))
    span_id = _valid_span_id(event.get("span_id"))
    if trace_id is None or span_id is None:
        return None
    parent_span_id = _valid_span_id(event.get("parent_span_id"))
    return trace_id, span_id, parent_span_id


def trace_columns(event: Mapping[str, Any]) -> Dict[str, Optional[str]]:
    """Return validated trace columns for storage.

    Domain: ``event`` is any mapping (normally a decoded ASH event).  The
    result always has keys ``trace_id``, ``span_id``, and ``parent_span_id``;
    each value is a normalized W3C ID or ``None`` when that field is missing
    or invalid.  Storage must not reject the event just because its trace
    context is malformed, so invalid values become NULL instead.
    """
    if not isinstance(event, Mapping):
        return {"trace_id": None, "span_id": None, "parent_span_id": None}
    return {
        "trace_id": _valid_trace_id(event.get("trace_id")),
        "span_id": _valid_span_id(event.get("span_id")),
        "parent_span_id": _valid_span_id(event.get("parent_span_id")),
    }


def current_trace_fields() -> Dict[str, str]:
    """Return the active span's log fields.

    Domain: no input; returns ``{"trace_id": 32-hex, "span_id": 16-hex}``
    when a valid span is current, otherwise an empty dict.  This is safe to
    call when the OpenTelemetry SDK is not installed.
    """
    try:
        from opentelemetry import trace
    except ImportError:  # tracing disabled installations do not need the SDK
        return {}

    context = trace.get_current_span().get_span_context()
    if not context.is_valid:
        return {}
    trace_id = f"{context.trace_id:032x}"
    span_id = f"{context.span_id:016x}"
    if trace_id == _ZERO_TRACE_ID or span_id == _ZERO_SPAN_ID:
        return {}
    return {"trace_id": trace_id, "span_id": span_id}


def _new_trace_id() -> str:
    """Return a random non-zero 128-bit trace-id as 32 lowercase hex chars."""
    value = random.getrandbits(128)
    while value == 0:
        value = random.getrandbits(128)
    return f"{value:032x}"


def _new_span_id() -> str:
    """Return a random non-zero 64-bit span-id as 16 lowercase hex chars."""
    value = random.getrandbits(64)
    while value == 0:
        value = random.getrandbits(64)
    return f"{value:016x}"


class SpanHandle:
    """A context-manager wrapper around one OpenTelemetry span.

    Domain: ``span`` is a recording SDK span or ``None`` for a disabled
    tracer.  ``attach``/``detach`` manage the current-context token; the
    context manager always ends the span and detaches exactly once.  Exceptions
    are recorded without their text so a database URL or secret in an
    exception message cannot reach the tracing backend.
    """

    def __init__(self, span: Any = None):
        self._span = span
        self._token: Any = None
        self._ended = False

    def attach(self) -> Any:
        """Make this span current for log correlation; return the token.

        Domain: no input; returns an OpenTelemetry context token or ``None``.
        Failure is logged and ignored so correlation cannot break the
        request or event being processed.
        """
        if self._span is None or self._token is not None:
            return self._token
        try:
            from opentelemetry import context as otel_context
            from opentelemetry import trace

            self._token = otel_context.attach(trace.set_span_in_context(self._span))
        except Exception as exc:  # noqa: BLE001 - telemetry is best-effort
            logger.warning(
                "Failed to attach trace context",
                extra={"error_type": type(exc).__name__},
            )
        return self._token

    def detach(self) -> None:
        """Detach a previously attached context.  Safe to call twice."""
        if self._token is None:
            return
        try:
            from opentelemetry import context as otel_context

            otel_context.detach(self._token)
        except Exception as exc:  # noqa: BLE001 - telemetry is best-effort
            logger.warning(
                "Failed to detach trace context",
                extra={"error_type": type(exc).__name__},
            )
        self._token = None

    def set_attribute(self, key: str, value: Any) -> None:
        """Set one attribute.  Domain: key string, any scalar/list value."""
        if self._span is not None:
            try:
                self._span.set_attribute(key, value)
            except Exception:  # noqa: BLE001 - telemetry is best-effort
                pass

    def add_event(self, name: str, attributes: Optional[Dict[str, Any]] = None) -> None:
        """Add a timestamped event.  Domain: non-empty name, scalar attrs."""
        if self._span is not None:
            try:
                self._span.add_event(name, attributes=attributes or {})
            except Exception:  # noqa: BLE001 - telemetry is best-effort
                pass

    def record_exception(self, error: BaseException) -> None:
        """Record only the exception type, never its message.

        Domain: any exception instance.  Exception text from PostgreSQL or
        Kafka can contain a DSN or credential, so the tracing backend gets
        the type name and an error status, not ``str(error)`` or a
        traceback that ends in that text.
        """
        if self._span is None:
            return
        self.add_event(
            "exception",
            attributes={
                "exception.type": type(error).__name__,
                "exception.escaped": "false",
            },
        )
        self.mark_error()

    def mark_error(self) -> None:
        """Set the span status to ERROR without recording exception text.

        Domain: no input; used when the failure is known only as a status
        code (for example an HTTP 5xx handled by Flask) and there is no
        exception object to inspect.
        """
        if self._span is None:
            return
        try:
            from opentelemetry.trace import Status, StatusCode

            self._span.set_status(Status(StatusCode.ERROR))
        except Exception:  # noqa: BLE001 - telemetry is best-effort
            pass

    def end(self) -> None:
        """End the span once.  Safe to call after the context manager.

        Domain: no input; idempotent.  A failure is logged and swallowed so
        telemetry cannot turn a successful flush or response into an error.
        """
        if self._span is None or self._ended:
            return
        self._ended = True
        try:
            self._span.end()
        except Exception as exc:  # noqa: BLE001 - telemetry is best-effort
            logger.warning(
                "Failed to end trace span",
                extra={"error_type": type(exc).__name__},
            )

    def finish(self) -> None:
        """Detach, then end; used by the API's request teardown."""
        self.detach()
        self.end()

    def __enter__(self) -> "SpanHandle":
        self.attach()
        return self

    def __exit__(self, exc_type, exc, _traceback) -> bool:
        if exc is not None:
            self.record_exception(exc)
        self.finish()
        return False


class _ForcedIdGenerator:
    """An ID generator that can emit an agent's exact W3C IDs once.

    Domain: the force values are 32-hex trace-ids and 16-hex span-ids.  The
    forced values are thread-local, so the API's worker threads and the
    consumer's flush thread cannot borrow each other's context.  After the
    first span is started the values are cleared; all child spans receive
    random IDs.
    """

    def __init__(self):
        self._local = threading.local()

    def force(self, trace_id: int, span_id: int) -> None:
        self._local.trace_id = trace_id
        self._local.span_id = span_id

    def clear(self) -> None:
        self._local.trace_id = None
        self._local.span_id = None

    def generate_trace_id(self) -> int:
        forced = getattr(self._local, "trace_id", None)
        if forced is not None:
            return forced
        trace_id = random.getrandbits(128)
        while trace_id == 0:
            trace_id = random.getrandbits(128)
        return trace_id

    def generate_span_id(self) -> int:
        forced = getattr(self._local, "span_id", None)
        if forced is not None:
            self._local.span_id = None
            return forced
        span_id = random.getrandbits(64)
        while span_id == 0:
            span_id = random.getrandbits(64)
        return span_id

    def is_trace_id_random(self) -> bool:
        """Report whether the next trace ID is locally random.

        Domain: no input.  ``False`` while an agent's exact trace ID is
        forced (the ID came from the event, so the W3C ``random-trace-id``
        flag must not be set); ``True`` for locally generated trace IDs.
        """
        return getattr(self._local, "trace_id", None) is None


def _span_processor(span_exporter: Any, endpoint: str) -> Any:
    """Return the span processor for a provider.

    Domain: ``span_exporter`` is ``None`` (production: export OTLP/HTTP in
    batches to ``endpoint``) or an OpenTelemetry exporter instance (tests:
    export synchronously so assertions see finished spans immediately).
    """
    if span_exporter is not None:
        from opentelemetry.sdk.trace.export import SimpleSpanProcessor

        return SimpleSpanProcessor(span_exporter)

    from opentelemetry.exporter.otlp.proto.http.trace_exporter import (
        OTLPSpanExporter,
    )
    from opentelemetry.sdk.trace.export import BatchSpanProcessor

    return BatchSpanProcessor(
        OTLPSpanExporter(endpoint=endpoint, timeout=5),
        max_queue_size=2048,
        schedule_delay_millis=5000,
        max_export_batch_size=512,
    )


class Tracing:
    """Per-process tracing facade.

    Domain: ``component`` is ``ash-consumer`` or ``ash-api``; ``enabled``
    controls whether a real SDK provider exists; ``endpoint`` is the OTLP
    traces URL when enabled; ``sample_ratio`` is 0.0-1.0; ``span_exporter``
    is an optional OpenTelemetry span exporter used instead of the OTLP
    exporter (tests and in-process integration only, ``None`` in production).
    Methods are no-ops when tracing is disabled.
    """

    def __init__(
        self,
        component: str,
        enabled: bool = False,
        endpoint: str = "",
        sample_ratio: float = 1.0,
        span_exporter: Any = None,
    ):
        self.component = component
        self.enabled = enabled
        self.endpoint = endpoint
        self.sample_ratio = sample_ratio
        self._provider: Any = None
        self._tracer: Any = None
        self._id_generator: Optional[_ForcedIdGenerator] = None
        self._ratio_sampler: Any = None

        if not enabled:
            return

        if not endpoint:
            raise RuntimeError("tracing requires a non-empty OTLP endpoint")
        endpoint = _validate_endpoint(endpoint)

        from opentelemetry.sdk.resources import Resource
        from opentelemetry.sdk.trace import TracerProvider
        from opentelemetry.sdk.trace.sampling import (
            ParentBased,
            TraceIdRatioBased,
        )

        instance_id = f"{socket.gethostname()}:{os.getpid()}"
        resource = Resource.create(
            {
                _SERVICE_NAME: component,
                _SERVICE_INSTANCE_ID: instance_id,
            }
        )
        # Agent events carry no sampling flag, so the consumer must derive one
        # from the trace ID.  Keeping this sampler lets a child event make the
        # same decision as its command_start root instead of being forced
        # sampled (which would produce orphan spans at a partial ratio).
        ratio_sampler = TraceIdRatioBased(sample_ratio)
        self._ratio_sampler = ratio_sampler
        self._id_generator = _ForcedIdGenerator()
        self._provider = TracerProvider(
            resource=resource,
            sampler=ParentBased(ratio_sampler),
            id_generator=self._id_generator,
        )
        self._provider.add_span_processor(_span_processor(span_exporter, endpoint))
        self._tracer = self._provider.get_tracer(component)

    def _empty_context(self) -> Any:
        from opentelemetry import context as otel_context

        return otel_context.Context()

    def _safe_span(self, name: str, **kwargs: Any) -> SpanHandle:
        """Start an SDK span, returning a no-op handle if tracing fails.

        Domain: ``name`` is a stable operation name; ``kwargs`` are passed to
        ``Tracer.start_span``.  Telemetry must never be able to abort event
        processing, so any SDK failure is logged and swallowed.
        """
        if not self.enabled or self._tracer is None:
            return SpanHandle()
        try:
            return SpanHandle(self._tracer.start_span(name, **kwargs))
        except Exception as exc:  # noqa: BLE001 - telemetry is best-effort
            logger.warning(
                "Failed to start trace span",
                extra={"error_type": type(exc).__name__},
            )
            return SpanHandle()

    def start_span(
        self,
        name: str,
        *,
        parent_context: Any = None,
        kind: Any = None,
        attributes: Optional[Dict[str, Any]] = None,
        links: Optional[Sequence[Any]] = None,
        start_time: Optional[int] = None,
    ) -> SpanHandle:
        """Start a child span.

        Domain: ``name`` is a stable operation name; ``parent_context`` is
        ``None`` (use the current context), an OpenTelemetry context, or a
        remote ``SpanContext``.  ``kind`` is an OpenTelemetry ``SpanKind`` or
        ``None`` for the default.  Attributes must not contain command text or
        credentials.
        """
        if not self.enabled or self._tracer is None:
            return SpanHandle()
        kwargs: Dict[str, Any] = {}
        if parent_context is not None:
            kwargs["context"] = parent_context
        if kind is not None:
            kwargs["kind"] = kind
        if attributes:
            kwargs["attributes"] = attributes
        if links:
            kwargs["links"] = links
        if start_time is not None:
            kwargs["start_time"] = start_time
        return self._safe_span(name, **kwargs)

    def start_root_span(
        self,
        name: str,
        *,
        kind: Any = None,
        attributes: Optional[Dict[str, Any]] = None,
        links: Optional[Sequence[Any]] = None,
    ) -> SpanHandle:
        """Start a span with no parent; used for batch and synthetic roots."""
        return self.start_span(
            name,
            parent_context=self._empty_context() if self.enabled else None,
            kind=kind,
            attributes=attributes,
            links=links,
        )

    def start_agent_span(self, event: Mapping[str, Any]) -> SpanHandle:
        """Reconstruct an agent event span from its emitted trace context.

        Domain: ``event`` is a decoded ASH event.  When its trace_id/span_id
        are valid, the returned span uses those exact W3C IDs and the event's
        parent_span_id (if valid) as its parent.  Otherwise a new trace is
        started.  The span records event metadata but never the command text.
        """
        if not self.enabled or self._tracer is None:
            return SpanHandle()
        if self._id_generator is None or self._ratio_sampler is None:
            return SpanHandle()

        if not isinstance(event, Mapping):
            event = {}

        try:
            from opentelemetry import trace
            from opentelemetry.trace import SpanContext, SpanKind, TraceFlags

            context = trace_context_strings(event)
            if context is None:
                trace_id = _new_trace_id()
                span_id = _new_span_id()
                parent_span_id = None
                source = "generated"
            else:
                trace_id, span_id, parent_span_id = context
                source = "agent"

            parent_context = self._empty_context()
            if parent_span_id is not None:
                # Derive the parent's sampled flag from the same trace-ID
                # ratio decision the root span used.  Always claiming
                # SAMPLED here would export a child whose root was dropped.
                sampled = self._ratio_sampler.should_sample(
                    None,
                    int(trace_id, 16),
                    "ash.agent",
                    SpanKind.INTERNAL,
                    {},
                ).decision.is_sampled()
                parent_context = trace.set_span_in_context(
                    trace.NonRecordingSpan(
                        SpanContext(
                            trace_id=int(trace_id, 16),
                            span_id=int(parent_span_id, 16),
                            is_remote=True,
                            trace_flags=TraceFlags(
                                TraceFlags.SAMPLED if sampled else 0
                            ),
                        )
                    )
                )

            assert self._id_generator is not None
            self._id_generator.force(int(trace_id, 16), int(span_id, 16))
            try:
                attributes = {
                    "ash.event_id": str(event.get("event_id", "")),
                    "ash.event_type": str(event.get("event_type", "unknown")),
                    "ash.source": str(event.get("source", "unknown")),
                    "ash.hostname": str(event.get("hostname", "")),
                    "ash.session_id": str(event.get("session_id", "")),
                    "ash.trace_context_source": source,
                }
                if event.get("user") is not None:
                    attributes["ash.user"] = str(event["user"])
                if isinstance(event.get("exit_code"), int):
                    attributes["ash.exit_code"] = event["exit_code"]
                if isinstance(event.get("risk_score"), int):
                    attributes["ash.risk_score"] = event["risk_score"]
                return self._safe_span(
                    f"ash.agent.{event.get('event_type', 'event')}",
                    context=parent_context,
                    kind=SpanKind.INTERNAL,
                    attributes=attributes,
                )
            finally:
                self._id_generator.clear()
        except Exception as exc:  # noqa: BLE001 - telemetry is best-effort
            logger.warning(
                "Failed to reconstruct agent span",
                extra={"error_type": type(exc).__name__},
            )
            if self._id_generator is not None:
                self._id_generator.clear()
            return SpanHandle()

    def start_server_span(
        self,
        name: str,
        carrier: Mapping[str, Any],
        attributes: Optional[Dict[str, Any]] = None,
    ) -> SpanHandle:
        """Start an HTTP server span, continuing a W3C traceparent if valid.

        Domain: ``carrier`` is a case-insensitive header mapping.  A missing
        or invalid traceparent starts a new trace rather than rejecting the
        request.  ``attributes`` must not contain headers, query strings, or
        credentials.
        """
        if not self.enabled or self._tracer is None:
            return SpanHandle()

        try:
            from opentelemetry.trace import SpanKind

            parent_context = extract_remote_context(carrier) or self._empty_context()
            return self._safe_span(
                name,
                context=parent_context,
                kind=SpanKind.SERVER,
                attributes=attributes or {},
            )
        except Exception as exc:  # noqa: BLE001 - telemetry is best-effort
            logger.warning(
                "Failed to start server span",
                extra={"error_type": type(exc).__name__},
            )
            return SpanHandle()

    def links_for_events(self, events: Iterable[Mapping[str, Any]]) -> Sequence[Any]:
        """Build span links for a batch of events.

        Domain: an iterable of decoded events.  Returns an empty sequence
        when tracing is disabled or no event has valid context.  Links are
        used instead of a fake parent so one batch can belong to many traces.
        """
        if not self.enabled:
            return []
        try:
            from opentelemetry.trace import Link, SpanContext, SpanKind, TraceFlags

            links = []
            for event in events:
                if not isinstance(event, Mapping):
                    continue
                context = trace_context_strings(event)
                if context is None:
                    continue
                trace_id, span_id, _parent = context
                # The agent does not emit a sampled flag.  Report the link as
                # sampled only when the same trace-ID ratio decision that
                # governs the reconstructed agent span would keep it, so a
                # tail sampler or span-metrics connector is not told that a
                # dropped trace was sampled.
                sampled = True
                if self._ratio_sampler is not None:
                    sampled = self._ratio_sampler.should_sample(
                        None,
                        int(trace_id, 16),
                        "ash.agent",
                        SpanKind.INTERNAL,
                        {},
                    ).decision.is_sampled()
                links.append(
                    Link(
                        SpanContext(
                            trace_id=int(trace_id, 16),
                            span_id=int(span_id, 16),
                            is_remote=True,
                            trace_flags=TraceFlags(
                                TraceFlags.SAMPLED if sampled else 0
                            ),
                        )
                    )
                )
            return links
        except Exception as exc:  # noqa: BLE001 - telemetry is best-effort
            logger.warning(
                "Failed to build span links",
                extra={"error_type": type(exc).__name__},
            )
            return []

    def shutdown(self) -> None:
        """Flush queued spans and stop the exporter.  Idempotent.

        Domain: no input.  Exporter/shutdown failures are logged and
        swallowed so process shutdown still succeeds.
        """
        if self._provider is not None:
            try:
                self._provider.shutdown()
            except Exception as exc:  # noqa: BLE001 - telemetry is best-effort
                logger.warning(
                    "Failed to shut down tracing",
                    extra={"error_type": type(exc).__name__},
                )
            self._provider = None
            self._tracer = None
            self._id_generator = None
            self._ratio_sampler = None


_active_tracing: Optional[Tracing] = None


def _validate_endpoint(endpoint: str, name: str = "ASH_OTLP_ENDPOINT") -> str:
    """Validate an OTLP/HTTP endpoint.

    Domain: non-empty absolute ``http``/``https`` URL with a host.  Path and
    query are preserved.  Userinfo is rejected because it would put a
    credential in configuration/logs.  ``name`` is the environment variable
    named in the error, so the logs exporter can reuse the same checks.
    Raises ``RuntimeError`` on failure.
    """
    parsed = urlsplit(endpoint)
    if parsed.scheme not in ("http", "https") or not parsed.hostname:
        raise RuntimeError(
            f"{name} must be an http(s) URL with a host, "
            "for example http://127.0.0.1:4318/v1/traces"
        )
    if parsed.username or parsed.password:
        raise RuntimeError(f"{name} must not contain credentials")
    return endpoint


def configure_tracing(component: str) -> Tracing:
    """Create (or return) the process tracing facade.

    Domain: ``component`` is a non-empty service name.  Settings come from
    ``ASH_TRACING_ENABLED``, ``ASH_OTLP_ENDPOINT``, and
    ``ASH_TRACING_SAMPLE_RATIO`` as documented at module level.  Enabling
    tracing without an endpoint, or with invalid values, raises
    ``RuntimeError``; disabled tracing never imports the SDK or requires a
    collector.  The returned object is cached for the process.
    """
    global _active_tracing

    enabled = _env_bool("ASH_TRACING_ENABLED", False)
    endpoint = (os.environ.get("ASH_OTLP_ENDPOINT") or "").strip()
    ratio = _env_ratio("ASH_TRACING_SAMPLE_RATIO", 1.0)

    if enabled:
        if not endpoint:
            raise RuntimeError(
                "ASH_TRACING_ENABLED is true but ASH_OTLP_ENDPOINT is empty"
            )
        endpoint = _validate_endpoint(endpoint)

    if (
        _active_tracing is not None
        and _active_tracing.component == component
        and _active_tracing.enabled == enabled
        and _active_tracing.endpoint == endpoint
        and _active_tracing.sample_ratio == ratio
    ):
        return _active_tracing

    if _active_tracing is not None:
        _active_tracing.shutdown()
        _active_tracing = None

    _active_tracing = Tracing(
        component=component,
        enabled=enabled,
        endpoint=endpoint,
        sample_ratio=ratio,
    )
    return _active_tracing


def shutdown_tracing() -> None:
    """Flush and stop the active provider.  Domain: no input; idempotent."""
    global _active_tracing
    if _active_tracing is not None:
        _active_tracing.shutdown()
        _active_tracing = None


def extract_remote_context(carrier: Mapping[str, Any]) -> Any:
    """Extract a W3C trace context from request headers/event metadata.

    Domain: any case-insensitive mapping such as Flask's request headers.
    Returns an OpenTelemetry context for a valid ``traceparent``, otherwise
    ``None``.  Never raises for malformed headers.
    """
    try:
        from opentelemetry import trace
        from opentelemetry.trace.propagation.tracecontext import (
            TraceContextTextMapPropagator,
        )
    except ImportError:
        return None

    try:
        context = TraceContextTextMapPropagator().extract(carrier=carrier)
        span_context = trace.get_current_span(context).get_span_context()
    except Exception:
        return None
    return context if span_context.is_valid else None
