#!/usr/bin/env python3
"""Best-effort OTLP/HTTP log export for the ASH consumer and API.

stdout remains the authoritative local log stream.  This module adds an
optional second destination for the monitoring stack: the OpenTelemetry
Collector receives OTLP logs and forwards them to Loki.  No Alloy/Promtail,
Docker-socket access, or file tailing is involved.

Environment domains:

* ``ASH_LOG_OTLP_ENABLED``: ``1/true/yes/on`` or ``0/false/no/off``;
  unset means disabled.  Independent of tracing so logs can be centralized
  without exporting spans.
* ``ASH_OTLP_LOGS_ENDPOINT``: full OTLP/HTTP logs URL (``http`` or
  ``https`` with a host and no userinfo), for example
  ``http://127.0.0.1:4318/v1/logs``.  Required when export is enabled.

Export is asynchronous and best-effort.  Construction errors fail startup
(an enabled exporter that cannot be built is a configuration error), but
runtime export failures are logged by type and swallowed: telemetry can
never fail, delay, drop, or duplicate an event or an HTTP response.

New functions and classes document their own domains below.
"""

from __future__ import annotations

import logging
import os
from typing import Any, Optional

from ash_observability import LOG_EXTRA_FIELDS, redact_text
from ash_tracing import _env_bool, _validate_endpoint, trace_context_strings

logger = logging.getLogger("ash-log-export")

_SERVICE_NAME = "service.name"
_HANDLER_MARKER = "_ash_otlp_log_handler"
_EXPORT_TIMEOUT_MILLIS = 5000
_SCHEDULE_DELAY_MILLIS = 5000
_MAX_QUEUE_SIZE = 2048
_MAX_EXPORT_BATCH_SIZE = 512


def _build_handler(component: str, provider: Any) -> logging.Handler:
    """Build the OTel logging handler with ASH's allow-listed schema.

    Domain: ``component`` is the non-empty service name; ``provider`` is a
    configured ``opentelemetry.sdk._logs.LoggerProvider``.  Imports the SDK
    here so disabled export does not require OpenTelemetry at import time.
    The returned handler is not attached to any logger.
    """
    from opentelemetry.sdk._logs import LoggingHandler
    from opentelemetry.trace import TraceFlags

    class _ASHLoggingHandler(LoggingHandler):
        """OTLP handler that mirrors the JSON log allow-list.

        Only fields in ``LOG_EXTRA_FIELDS`` plus ``component``, ``logger``,
        and ``pid`` become attributes.  Exception messages and tracebacks are
        deliberately absent; only the exception class name is recorded, which
        matches the trace-span convention.  The body is the redacted log
        message, not the JSON line, so Loki does not store a JSON string
        inside an OTLP body.
        """

        def _get_attributes(self, record: logging.LogRecord) -> dict:
            attributes = {}
            for field in LOG_EXTRA_FIELDS:
                value = getattr(record, field, None)
                if value is not None:
                    attributes[field] = value
            # The exporter is per-process, so its own component is
            # authoritative.  A root JSON handler may have set a different
            # component for a foreign logger in a shared test process; that
            # must not relabel this service's OTLP records.
            attributes["component"] = component
            attributes.setdefault("logger", record.name)
            attributes.setdefault("pid", record.process)
            if record.exc_info and record.exc_info[0] is not None:
                attributes["exception.type"] = record.exc_info[0].__name__
            return attributes

        def _translate(self, record: logging.LogRecord) -> Any:
            translated = super()._translate(record)
            translated.body = redact_text(record.getMessage())
            # An explicit event trace/span ID wins over the ambient span, the
            # same precedence the JSON formatter uses.  Accept only a complete
            # pair: a trace ID with an unrelated span ID is worse than none.
            context = trace_context_strings(
                {
                    "trace_id": getattr(record, "trace_id", None),
                    "span_id": getattr(record, "span_id", None),
                }
            )
            if context is not None:
                trace_id, span_id, _parent = context
                translated.trace_id = int(trace_id, 16)
                translated.span_id = int(span_id, 16)
                translated.trace_flags = TraceFlags(TraceFlags.SAMPLED)
            return translated

    return _ASHLoggingHandler(logger_provider=provider)


class LogExport:
    """Per-process OTLP log export facade.

    Domain: ``component`` is ``ash-consumer`` or ``ash-api``; ``enabled``
    controls whether a real SDK provider exists; ``endpoint`` is the OTLP
    logs URL when enabled; ``log_exporter`` is an optional OpenTelemetry log
    exporter used instead of the OTLP exporter (tests and in-process
    integration only, ``None`` in production).  Methods are no-ops when
    export is disabled.
    """

    def __init__(
        self,
        component: str,
        enabled: bool,
        endpoint: str,
        log_exporter: Optional[Any] = None,
    ):
        self.component = component
        self.enabled = enabled
        self.endpoint = endpoint
        self._provider: Optional[Any] = None
        self._handler: Optional[logging.Handler] = None

        if not enabled:
            return

        from opentelemetry.sdk._logs import LoggerProvider
        from opentelemetry.sdk._logs.export import (
            BatchLogRecordProcessor,
            SimpleLogRecordProcessor,
        )
        from opentelemetry.sdk.resources import Resource

        try:
            self._provider = LoggerProvider(
                resource=Resource.create({_SERVICE_NAME: component}),
                shutdown_on_exit=False,
            )
            if log_exporter is not None:
                processor = SimpleLogRecordProcessor(log_exporter)
            else:
                from opentelemetry.exporter.otlp.proto.http._log_exporter import (
                    OTLPLogExporter,
                )

                processor = BatchLogRecordProcessor(
                    OTLPLogExporter(endpoint=endpoint, timeout=5),
                    schedule_delay_millis=_SCHEDULE_DELAY_MILLIS,
                    max_queue_size=_MAX_QUEUE_SIZE,
                    max_export_batch_size=_MAX_EXPORT_BATCH_SIZE,
                    export_timeout_millis=_EXPORT_TIMEOUT_MILLIS,
                )
            self._provider.add_log_record_processor(processor)
            self._handler = _build_handler(component, self._provider)
            setattr(self._handler, _HANDLER_MARKER, True)
            logging.getLogger().addHandler(self._handler)
        except Exception:
            # A half-built provider must not outlive a failed configuration.
            if self._provider is not None:
                try:
                    self._provider.shutdown()
                except Exception:  # noqa: BLE001 - telemetry is best-effort
                    pass
            self._provider = None
            raise

    def force_flush(self) -> None:
        """Flush queued log records without shutting the exporter down.

        Domain: no input.  Failures are logged by type and swallowed; this is
        a diagnostic/test helper, not a durability guarantee.
        """
        if self._provider is None:
            return
        try:
            self._provider.force_flush(timeout_millis=_EXPORT_TIMEOUT_MILLIS)
        except Exception as exc:  # noqa: BLE001 - telemetry is best-effort
            logger.warning("OTLP log export flush failed: %s", type(exc).__name__)

    def shutdown(self) -> None:
        """Flush queued records and stop the exporter.  Idempotent.

        Domain: no input.  The handler is detached before the provider is
        shut down so shutdown diagnostics cannot recurse through the handler
        being closed.  Failures are logged by type and swallowed.
        """
        handler, self._handler = self._handler, None
        if handler is not None:
            try:
                logging.getLogger().removeHandler(handler)
            except Exception:  # noqa: BLE001 - telemetry is best-effort
                pass
            try:
                handler.close()
            except Exception:  # noqa: BLE001 - telemetry is best-effort
                pass

        provider, self._provider = self._provider, None
        if provider is not None:
            try:
                provider.shutdown()
            except Exception as exc:  # noqa: BLE001 - telemetry is best-effort
                logger.warning(
                    "OTLP log export shutdown failed: %s", type(exc).__name__
                )


_active_log_export: Optional[LogExport] = None


def configure_log_export(
    component: str,
    log_exporter: Optional[Any] = None,
) -> LogExport:
    """Create (or return) the process OTLP log export facade.

    Domain: ``component`` is a non-empty service name.  Settings come from
    ``ASH_LOG_OTLP_ENABLED`` and ``ASH_OTLP_LOGS_ENDPOINT`` as documented at
    module level.  Enabling export without an endpoint, with an invalid URL,
    or without the SDK raises ``RuntimeError``; disabled export never imports
    the SDK or requires a collector.  The production object is cached for the
    process so repeated imports do not install duplicate handlers.
    ``log_exporter`` is for tests only and bypasses the cache.
    """
    global _active_log_export

    if not component or not isinstance(component, str):
        raise RuntimeError("log export component must be a non-empty string")

    enabled = _env_bool("ASH_LOG_OTLP_ENABLED", False)
    endpoint = (os.environ.get("ASH_OTLP_LOGS_ENDPOINT") or "").strip()

    if enabled:
        if not endpoint:
            raise RuntimeError(
                "ASH_LOG_OTLP_ENABLED is true but ASH_OTLP_LOGS_ENDPOINT is empty"
            )
        endpoint = _validate_endpoint(endpoint, "ASH_OTLP_LOGS_ENDPOINT")

    if (
        log_exporter is None
        and _active_log_export is not None
        and _active_log_export.component == component
        and _active_log_export.enabled == enabled
        and _active_log_export.endpoint == endpoint
    ):
        return _active_log_export

    if _active_log_export is not None:
        _active_log_export.shutdown()
        _active_log_export = None

    try:
        _active_log_export = LogExport(
            component=component,
            enabled=enabled,
            endpoint=endpoint,
            log_exporter=log_exporter,
        )
    except ImportError as exc:
        raise RuntimeError(
            "ASH_LOG_OTLP_ENABLED requires the OpenTelemetry SDK and OTLP/HTTP "
            "exporter to be installed"
        ) from exc
    except Exception as exc:
        raise RuntimeError(
            f"could not configure OTLP log export: {type(exc).__name__}"
        ) from exc
    return _active_log_export


def shutdown_log_export() -> None:
    """Flush and stop the active exporter.  Domain: no input; idempotent."""
    global _active_log_export
    if _active_log_export is not None:
        _active_log_export.shutdown()
        _active_log_export = None
