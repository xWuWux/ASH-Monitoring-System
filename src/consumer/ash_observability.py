#!/usr/bin/env python3
"""Shared structured logging, correlation, and service-notify helpers.

The goal is intentionally small: emit one JSON object per log record, keep
the same fields across the consumer and API, and never put a credential into
a URL that is written to a log.  Tracing fields are accepted here so a later
change can add them without changing the log schema again.
"""

from __future__ import annotations

import json
import logging
import os
import re
import socket
import sys
import uuid
from datetime import datetime, timezone
from logging.handlers import RotatingFileHandler
from pathlib import Path
from typing import Any, Mapping, Optional
from urllib.parse import urlsplit

# Only these extra logging fields are copied into a JSON record.  Copying
# every record attribute would leak arbitrary objects and internal logging
# state; an allow-list also keeps the emitted schema stable.
LOG_EXTRA_FIELDS = (
    "component",
    "hostname",
    "event_id",
    "session_id",
    "request_id",
    "trace_id",
    "span_id",
    "method",
    "path",
    "route",
    "status_code",
    "duration_ms",
    "remote_addr",
    "batch_size",
    "channel",
    "webhook_host",
    "error_type",
)

# Logger names that belong to a known ASH component.  The filter maps these
# even when more than one component has configured logging in the same
# process (unit tests do exactly that).
_COMPONENT_PREFIXES = (
    ("ash-alerting", "ash-alerting"),
    ("ash-consumer", "ash-consumer"),
    ("ash_api_server", "ash-api"),
    ("ash-api", "ash-api"),
    ("gunicorn", "ash-api"),
    ("werkzeug", "ash-api"),
)

# Third-party libraries are useful at DEBUG while diagnosing a problem, but
# at INFO they can duplicate request lines or log full URLs.  Keep them quiet
# unless the operator explicitly asks for DEBUG.
_NOISY_LOGGERS = ("kafka", "urllib3", "werkzeug", "gunicorn.error", "gunicorn.access")

# Shared environment domains.  Keeping one definition prevents the consumer
# and API from drifting on what counts as a valid level or boolean.
LOG_LEVELS = ("DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL")
TRUE_VALUES = ("1", "true", "yes", "on")
FALSE_VALUES = ("0", "false", "no", "off")

_REQUEST_ID_RE = re.compile(r"^[A-Za-z0-9._:-]{1,128}$")
_JSON_HANDLER_MARKER = "_ash_json_handler"

# Exception text from PostgreSQL/Kafka can echo a DSN.  Redact URL userinfo
# and common secret assignments before a message or traceback is formatted.
_URL_USERINFO_RE = re.compile(r"(?P<scheme>[A-Za-z][A-Za-z0-9+.-]*://)[^/\s@]+@")
_SECRET_ASSIGNMENT_RE = re.compile(
    r"(?i)\b(password|passwd|pwd|token|secret|api[_-]?key)\b" r"(\s*[:=]\s*)([^\s,;&]+)"
)


def redact_text(value: Any) -> str:
    """Return a string safe to place in a log message or traceback.

    Domain: any value; the result is ``str(value)`` with URL userinfo
    (``scheme://user:pass@host``) and assignments such as ``password=...``
    or ``token: ...`` replaced by ``[redacted]``.  This is a safety net for
    exception text, not a replacement for not logging a secret in the first
    place.  It intentionally leaves host, port, and path intact so an
    operator can still identify the failing endpoint.
    """
    text = str(value)
    text = _URL_USERINFO_RE.sub(r"\g<scheme>[redacted]@", text)
    return _SECRET_ASSIGNMENT_RE.sub(r"\1\2[redacted]", text)


def utc_timestamp() -> str:
    """Return the current time as an ISO-8601 UTC string with milliseconds."""
    return (
        datetime.now(timezone.utc)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z")
    )


def new_request_id() -> str:
    """Return a new opaque request identifier.

    Domain: a 36-character lowercase UUID string.
    """
    return str(uuid.uuid4())


def sanitize_request_id(value: Optional[str]) -> Optional[str]:
    """Return a safe client-supplied request ID, or ``None``.

    Domain: ``None`` for missing/unsafe input; otherwise a string of 1-128
    characters from ``[A-Za-z0-9._:-]``.  Rejecting other characters keeps
    a caller from injecting newlines into logs or response headers.
    """
    if not isinstance(value, str):
        return None
    value = value.strip()
    if not value or not _REQUEST_ID_RE.fullmatch(value):
        return None
    return value


def safe_url_for_log(url: str) -> str:
    """Return only scheme and host for a URL written to a log.

    Webhook URLs (Slack, Discord, and most custom integrations) carry their
    credential in the path or query string.  Logging ``urlsplit(url).netloc``
    alone would still expose a userinfo component, so build the result from
    the hostname and port explicitly.

    Domain: a non-empty URL string; return value is ``scheme://host[:port]``
    with no path, query, fragment, userinfo, or secret.  Invalid or
    host-less input returns ``<invalid-url>``.
    """
    try:
        parsed = urlsplit(url)
        port = parsed.port
    except ValueError:
        return "<invalid-url>"

    host = parsed.hostname
    if not host:
        return "<invalid-url>"
    if ":" in host:
        host = f"[{host}]"
    scheme = parsed.scheme or "http"
    if port is None:
        return f"{scheme}://{host}"
    return f"{scheme}://{host}:{port}"


def _component_name(logger_name: str, default_component: str) -> str:
    for prefix, component in _COMPONENT_PREFIXES:
        if logger_name == prefix or logger_name.startswith(f"{prefix}."):
            return component
    return default_component


class _ComponentFilter(logging.Filter):
    """Attach a stable component name to records that do not set one."""

    def __init__(self, default_component: str):
        super().__init__()
        self.default_component = default_component

    def filter(self, record: logging.LogRecord) -> bool:
        if not getattr(record, "component", None):
            record.component = _component_name(record.name, self.default_component)
        return True


class JsonFormatter(logging.Formatter):
    """Format a log record as one JSON object.

    Domain: ``record`` is a Python LogRecord; output is a JSON object with
    ``timestamp``, ``severity``, ``component``, ``logger``, ``message``, and
    ``pid`` plus allow-listed correlation fields.  Values in the allow-list
    are omitted when they are ``None``.
    """

    def __init__(self, component: str):
        super().__init__()
        self.component = component

    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, Any] = {
            "timestamp": datetime.fromtimestamp(record.created, tz=timezone.utc)
            .isoformat(timespec="milliseconds")
            .replace("+00:00", "Z"),
            "severity": record.levelname,
            "component": getattr(record, "component", None)
            or _component_name(record.name, self.component),
            "logger": record.name,
            "message": redact_text(record.getMessage()),
            "pid": record.process,
        }

        for field in LOG_EXTRA_FIELDS:
            value = getattr(record, field, None)
            if value is not None:
                payload[field] = value

        if record.exc_info:
            payload["exception"] = redact_text(self.formatException(record.exc_info))

        return json.dumps(payload, default=str, separators=(",", ":"))


def _remove_owned_handlers(logger: logging.Logger) -> None:
    for handler in list(logger.handlers):
        if getattr(handler, _JSON_HANDLER_MARKER, False):
            logger.removeHandler(handler)
            handler.close()


def configure_logging(
    component: str,
    level: str = "INFO",
    log_dir: Optional[str] = None,
    log_name: Optional[str] = None,
    max_bytes: int = 10 * 1024 * 1024,
    backup_count: int = 5,
    stream: Optional[Any] = None,
) -> logging.Logger:
    """Configure root logging with JSON output.

    ``stdout`` is always configured because systemd/journald and Docker both
    capture it.  When ``log_dir`` is set, a rotating JSON file is also
    configured for compatibility with the existing file-based deployment.

    Domain:
      * ``component``: non-empty service name (``ash-consumer``/``ash-api``)
      * ``level``: ``DEBUG``, ``INFO``, ``WARNING``, ``ERROR``, ``CRITICAL``
      * ``log_dir``: existing/creatable directory or ``None``
      * ``log_name``: file name inside ``log_dir`` or ``None`` for
        ``<component>.log``
      * ``max_bytes``: integer >= 0 (0 disables file rotation)
      * ``backup_count``: integer >= 0
      * ``stream``: writable text stream or ``None`` for ``sys.stdout``

    Returns the logger named after ``component``.  Calling this function more
    than once replaces only handlers created by this module, so tests and
    gunicorn's import path do not accumulate duplicate handlers.

    A file-handler failure (for example, a read-only log directory) is
    reported on stderr and is not fatal: stdout logging still works, which is
    what systemd and Docker consume.
    """
    numeric_level = getattr(logging, str(level).upper(), None)
    if not isinstance(numeric_level, int):
        numeric_level = logging.INFO

    root = logging.getLogger()
    root.setLevel(numeric_level)
    _remove_owned_handlers(root)

    formatter = JsonFormatter(component)
    component_filter = _ComponentFilter(component)

    stream_handler = logging.StreamHandler(stream or sys.stdout)
    stream_handler.setFormatter(formatter)
    stream_handler.addFilter(component_filter)
    setattr(stream_handler, _JSON_HANDLER_MARKER, True)
    root.addHandler(stream_handler)

    if log_dir:
        path = Path(log_dir)
        filename = path / (log_name or f"{component}.log")
        try:
            path.mkdir(parents=True, exist_ok=True)
            file_handler = RotatingFileHandler(
                str(filename),
                maxBytes=max(0, int(max_bytes)),
                backupCount=max(0, int(backup_count)),
                encoding="utf-8",
            )
            file_handler.setFormatter(formatter)
            file_handler.addFilter(component_filter)
            setattr(file_handler, _JSON_HANDLER_MARKER, True)
            root.addHandler(file_handler)
            try:
                os.chmod(filename, 0o640)
            except OSError:
                # A service may run without write permission to an existing
                # file owned by another user; logging still works via stdout.
                pass
        except OSError as exc:
            print(
                f"warning: cannot open log file {filename}: "
                f"{type(exc).__name__}; continuing with stdout only",
                file=sys.stderr,
            )

    for logger_name in _NOISY_LOGGERS:
        logging.getLogger(logger_name).setLevel(logging.WARNING)

    return logging.getLogger(component)


def sd_notify(message: str) -> bool:
    """Send one systemd notification datagram.

    Domain: ``message`` is a non-empty string such as ``READY=1``,
    ``WATCHDOG=1``, or ``STOPPING=1``.  Returns ``True`` only when a
    ``NOTIFY_SOCKET`` was configured and the datagram was sent.  This is a
    no-op outside systemd, so callers must treat ``False`` as normal.
    """
    address = os.environ.get("NOTIFY_SOCKET")
    if not address or not message:
        return False
    # systemd uses an abstract Unix socket when the path starts with '@'.
    if address.startswith("@"):
        address = "\0" + address[1:]
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as sock:
            sock.settimeout(0.5)
            sock.sendto(message.encode("utf-8"), address)
        return True
    except OSError:
        return False


def log_extra(**values: Any) -> Mapping[str, Any]:
    """Return an ``extra=`` mapping containing only allow-listed fields.

    Domain: keyword arguments matching ``LOG_EXTRA_FIELDS``.  Unknown keys
    are ignored rather than passed to ``logging`` (which raises on keys such
    as ``message`` or ``args``).
    """
    return {key: value for key, value in values.items() if key in LOG_EXTRA_FIELDS}
