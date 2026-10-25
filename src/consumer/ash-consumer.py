#!/usr/bin/env python3
"""
ASH Kafka Consumer v2.2 — Centralized Log Processing
Production-grade consumer with batch processing, deduplication,
retry logic, structured event validation, and Prometheus metrics.
"""

import gzip
import json
import os
import signal
import sys
import time
import threading
import uuid
from datetime import datetime, timedelta, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple
from urllib.parse import urlsplit

import psycopg2
from psycopg2.extras import RealDictCursor, execute_values
from kafka import KafkaConsumer

# kafka-python 3.0 removed NoBrokersAvailableError: a broker-unreachable
# KafkaConsumer(...) construction now raises KafkaTimeoutError instead. See
# https://kafka-python.readthedocs.io/en/3.0.1/upgrade_to_3_0.html
from kafka.errors import KafkaTimeoutError
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    Counter,
    Gauge,
    Histogram,
    generate_latest,
)


def _ensure_shared_module_path(lib_dir: str = "/usr/local/lib/ash") -> None:
    """Make installed sibling modules importable from the bin launcher.

    ``scripts/install.sh`` puts the executable at ``/usr/local/bin`` and the
    shared modules (``ash_observability``, ``ash_alerting``) in
    ``/usr/local/lib/ash``.  Python puts only the script's own directory on
    ``sys.path``, so without this the installed consumer fails at import
    with ``ModuleNotFoundError``.  Source checkouts and the container keep
    the modules beside this file, where the directory already exists on
    ``sys.path`` and this is a no-op.

    Domain: ``lib_dir`` is an absolute directory path.  A missing directory
    is ignored; this function never raises.
    """
    if os.path.isdir(lib_dir) and lib_dir not in sys.path:
        sys.path.insert(0, lib_dir)


_ensure_shared_module_path()

from ash_observability import (  # noqa: E402
    FALSE_VALUES,
    LOG_LEVELS,
    TRUE_VALUES,
    configure_logging,
    log_extra,
    sd_notify,
)

# ─── Prometheus Metrics ──────────────────────────────────────────────────────
EVENTS_RECEIVED = Counter(
    "ash_consumer_events_received_total",
    "Total events received from Kafka",
    ["source", "event_type"],
)
EVENTS_PROCESSED = Counter(
    "ash_consumer_events_processed_total", "Total events successfully processed"
)
EVENTS_FAILED = Counter(
    "ash_consumer_events_failed_total",
    "Total events that failed processing",
    ["reason"],
)
EVENTS_DEDUPLICATED = Counter(
    "ash_consumer_events_deduplicated_total", "Total duplicate events skipped"
)
EVENTS_DEAD_LETTERED = Counter(
    "ash_consumer_events_dead_lettered_total",
    "Total events written to the dead-letter queue instead of being processed",
    ["reason"],
)
BATCH_FLUSH_LATENCY = Histogram(
    "ash_consumer_batch_flush_seconds",
    "Batch flush latency",
    buckets=[0.01, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0],
)
DB_WRITE_LATENCY = Histogram(
    "ash_consumer_db_write_seconds",
    "Database write latency",
    buckets=[0.01, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0],
)
# This is kafka-python's records-lag-max: an estimate from the consumer's
# last fetched position, not committed-offset lag.  It is still useful for
# "is the consumer keeping up?", but a DB stall is better detected by the
# last-successful-flush timestamp and the ready gauge below.
KAFKA_LAG = Gauge(
    "ash_consumer_kafka_lag",
    "Estimated records behind the consumer's last fetched position "
    "(not committed-offset lag)",
)
KAFKA_ASSIGNED_PARTITIONS = Gauge(
    "ash_consumer_kafka_assigned_partitions",
    "Number of Kafka partitions currently assigned to this consumer",
)
LAST_MESSAGE_TIMESTAMP = Gauge(
    "ash_consumer_last_message_timestamp_seconds",
    "Unix timestamp of the last Kafka message received",
)
LAST_FLUSH_SUCCESS_TIMESTAMP = Gauge(
    "ash_consumer_last_flush_success_timestamp_seconds",
    "Unix timestamp of the last batch persisted to all enabled stores",
)
FLUSH_FAILURES = Counter(
    "ash_consumer_flush_failures_total",
    "Total batch flushes that left data undurable and pending retry",
)
READY = Gauge(
    "ash_consumer_ready",
    "1 when the consumer is running, storage is available, and no flush is failing",
)
BATCH_SIZE_GAUGE = Gauge("ash_consumer_batch_buffer_size", "Current batch buffer size")
DB_AVAILABLE = Gauge(
    "ash_consumer_database_available",
    "1 when the last database write succeeded, 0 while it is failing",
)


# ─── Event Schema Validation ─────────────────────────────────────────────────
REQUIRED_FIELDS = ["event_id", "timestamp", "hostname", "source", "event_type"]
VALID_SOURCES = [
    "bash-debug",
    "bash-session",
    "bash-diff",
    "auditd",
    "inotify",
    "fanotify",
    "docker-events",
    "k8s-audit",
    "process-accounting",
]
VALID_EVENT_TYPES = [
    "command_start",
    "command_end",
    "file_modify",
    "file_create",
    "file_delete",
    "file_move",
    "file_attrib",
    "session_start",
    "session_end",
    "privilege_escalation",
    "alert",
    "container_start",
    "container_stop",
    "container_exec",
    "container_die",
    "container_create",
    "container_destroy",
]

# These mirror the varchar widths in command_logs. A value that is too long
# would otherwise abort the whole INSERT batch with a database error, so it is
# rejected at the validation boundary and routed to the DLQ instead.
MAX_TEXT_LENGTH = 1_048_576
MAX_RAW_EVENT_LENGTH = 2_097_152
MAX_FIELD_LENGTHS = {
    "schema_version": 10,
    "hostname": 100,
    "source": 50,
    "event_type": 50,
    "user": 100,
    "username": 100,
    "tty": 50,
    "ssh_connection": 200,
    "container_id": 100,
    "container_name": 200,
    "command": MAX_TEXT_LENGTH,
    "cwd": MAX_TEXT_LENGTH,
    "stdout": MAX_TEXT_LENGTH,
    "stderr": MAX_TEXT_LENGTH,
    "file_path": MAX_TEXT_LENGTH,
    "diff_content": MAX_TEXT_LENGTH,
}
INTEGER_FIELDS = ("uid", "pid", "ppid", "exit_code")


class DatabaseWriteError(RuntimeError):
    """The batch is not durable in PostgreSQL; Kafka offsets must not move."""


def _connect_db(database_url: str):
    # connect_timeout bounds the initial TCP/auth handshake; statement_timeout
    # (a libpq connection option, applied server-side for every query on this
    # connection) bounds how long any single query can run once connected.
    # Without both, an unresponsive Postgres (network partition, overload, a
    # runaway query) can make a query block indefinitely. _flush_batch() no
    # longer holds batch_lock across _write_database_batch() (see
    # _flush_batch() itself), so a hung query no longer freezes the whole
    # consumer -- but it would still stall that one flush indefinitely
    # without these timeouts.
    return psycopg2.connect(
        database_url, connect_timeout=10, options="-c statement_timeout=30000"
    )


# Maps an AlertRule's severity to the 0-10 risk_score range defined in
# src/common/schema/event-v1.json. Feeds matched-rule severity back onto the
# event before it is batched, so risk_score (indexed, and the sole filter on
# GET /api/v1/stats/risky) is actually populated -- previously nothing ever
# assigned it, so every row stayed at its schema DEFAULT 0 and that endpoint
# always returned empty.
SEVERITY_RISK_SCORE = {
    "critical": 10,
    "high": 7,
    "medium": 4,
    "low": 2,
}

_VALID_LOG_LEVELS = LOG_LEVELS
_TRUE_VALUES = TRUE_VALUES
_FALSE_VALUES = FALSE_VALUES


def _env_bool(name: str, current: bool) -> bool:
    """Read a boolean environment override.

    Domain: unset -> ``current``; otherwise one of ``1/true/yes/on`` or
    ``0/false/no/off`` (case-insensitive).  Anything else raises ``ValueError``
    so a typo cannot silently disable a safety check.
    """
    raw = os.environ.get(name)
    if raw is None:
        return current
    value = raw.strip().lower()
    if value in _TRUE_VALUES:
        return True
    if value in _FALSE_VALUES:
        return False
    raise ValueError(f"{name} must be one of {_TRUE_VALUES + _FALSE_VALUES}")


def _env_int(
    name: str,
    current: int,
    minimum: Optional[int] = None,
    maximum: Optional[int] = None,
) -> int:
    """Read an integer environment override.

    Domain: unset -> ``current``; otherwise a base-10 integer within
    ``[minimum, maximum]`` when those bounds are set.  Invalid input raises
    ``ValueError`` with the variable name.
    """
    raw = os.environ.get(name)
    if raw is None:
        return current
    try:
        value = int(raw)
    except ValueError as exc:
        raise ValueError(f"{name} must be an integer, got {raw!r}") from exc
    if minimum is not None and value < minimum:
        raise ValueError(f"{name} must be >= {minimum}, got {value}")
    if maximum is not None and value > maximum:
        raise ValueError(f"{name} must be <= {maximum}, got {value}")
    return value


def _env_float(name: str, current: float, minimum: Optional[float] = None) -> float:
    """Read a floating-point environment override.

    Domain: unset -> ``current``; otherwise a finite number >= ``minimum``
    when set.  NaN and infinity are rejected because they make batch timing
    and readiness comparisons meaningless.
    """
    raw = os.environ.get(name)
    if raw is None:
        return current
    try:
        value = float(raw)
    except ValueError as exc:
        raise ValueError(f"{name} must be a number, got {raw!r}") from exc
    if value != value or value in (float("inf"), float("-inf")):
        raise ValueError(f"{name} must be finite, got {raw!r}")
    if minimum is not None and value < minimum:
        raise ValueError(f"{name} must be >= {minimum}, got {value}")
    return value


def _env_string(name: str, current: str) -> str:
    """Read a non-empty string environment override.

    Domain: unset -> ``current``; otherwise a non-empty value after stripping
    surrounding whitespace.  Empty values raise ``ValueError`` rather than
    quietly leaving a service pointed at the wrong broker or directory.
    """
    raw = os.environ.get(name)
    if raw is None:
        return current
    value = raw.strip()
    if not value:
        raise ValueError(f"{name} must not be empty")
    return value


class _ObservabilityHandler(BaseHTTPRequestHandler):
    """Serve metrics and health over one small, dependency-free HTTP server.

    The query string is ignored, request paths are not logged, and responses
    never include exception text or configuration values.  The Prometheus
    metrics endpoint keeps the conventional ``/metrics`` path so a later
    scrape configuration does not need a special case.
    """

    server_version = "ASHObservability/1.0"
    sys_version = ""

    def do_GET(self):  # noqa: N802 - BaseHTTPRequestHandler API
        path = urlsplit(self.path).path
        consumer = self.server.consumer  # type: ignore[attr-defined]

        if path == "/metrics":
            self._send(
                HTTPStatus.OK,
                generate_latest(),
                CONTENT_TYPE_LATEST,
            )
            return

        if path == "/health/live":
            status, payload = consumer.health_liveness()
        elif path in ("/health", "/health/ready"):
            status, payload = consumer.health_readiness()
        else:
            self._send_json(
                HTTPStatus.NOT_FOUND,
                {"error": "not found"},
                no_store=True,
            )
            return

        self._send_json(status, payload, no_store=True)

    def _send_json(self, status: HTTPStatus, payload: Dict[str, Any], no_store=False):
        body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self._send(
            status,
            body,
            "application/json; charset=utf-8",
            no_store=no_store,
        )

    def _send(
        self,
        status: HTTPStatus,
        body: bytes,
        content_type: str,
        no_store: bool = False,
    ):
        self.send_response(int(status))
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Content-Type-Options", "nosniff")
        if no_store:
            self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format, *_args):
        # The default handler writes request lines to stderr without any
        # redaction or correlation.  Startup/health transitions are logged by
        # the consumer's structured logger instead.
        return


class ASHConsumer:
    """Production-grade ASH event consumer with resilience patterns."""

    def __init__(self, config_path: str = "/etc/ash/consumer.conf"):
        self.config = self._load_config(config_path)

        # _setup_logging() attaches a FileHandler under self.log_dir, so the
        # directory must exist and the attribute must be set first. It used
        # to be assigned further down, which made every real startup crash
        # with AttributeError before the consumer could connect to anything.
        self.log_dir = Path(self.config.get("log_dir", "/var/log/ash"))
        self.log_dir.mkdir(parents=True, exist_ok=True)

        self._setup_logging()
        self.running = True
        self._stopping = False
        self.started_at: float = time.time()
        self._last_flush_error: Optional[str] = None
        self._last_flush_success: Optional[float] = None
        self._last_message_at: Optional[float] = None
        self._observability_server: Optional[ThreadingHTTPServer] = None
        self._observability_thread: Optional[threading.Thread] = None
        self._watchdog_thread: Optional[threading.Thread] = None

        # Deduplication
        self.seen_event_ids: set = set()
        self.max_seen_ids: int = self.config.get("max_dedup_cache", 100000)

        # Batch processing. batch_raw_texts is kept parallel to
        # batch_buffer: it holds the exact bytes Kafka delivered (decoded as
        # UTF-8) so command_logs.raw_event_text can be hashed later. None
        # means the event did not arrive through the Kafka loop (tests).
        self.batch_buffer: List[Dict] = []
        self.batch_raw_texts: List[Optional[str]] = []
        self.batch_size: int = self.config.get("batch_size", 100)
        self.batch_timeout: float = self.config.get("batch_timeout", 5.0)
        self.last_flush: float = time.time()
        self.batch_lock = threading.Lock()

        # Serializes "process one message + commit its offset" against the
        # background flush timer. Without it, the timer can snapshot a batch
        # before the message currently being processed is appended, set
        # _commit_pending, and let run() commit an offset whose event is
        # still only in memory.
        self._processing_lock = threading.Lock()

        # Set by _flush_batch() (which can run on the main consume-loop
        # thread or the background flush-timer thread) whenever it durably
        # writes a batch; only ever read and cleared on the main
        # consumer-loop thread, which is the only thread allowed to call
        # self.consumer.commit() -- KafkaConsumer is not thread-safe.
        self._commit_pending = threading.Event()

        # Storage (log_dir was created before logging was configured)
        # Dead-letter queue: events that fail schema validation were
        # previously logged at WARNING and silently discarded. Route them
        # here instead so nothing is lost without a trace and an operator
        # can inspect/replay them.
        self.dlq_path = self.log_dir / "dead_letter.jsonl"

        # Database
        self.db_conn: Optional[psycopg2.extensions.connection] = None
        if self.config.get("database_enabled", False):
            self._setup_database()

        # Kafka
        self._setup_kafka_consumer()

        # Alerting
        self.alert_engine: Optional["ASHAlertEngine"] = None
        if self.config.get("alerting_enabled", False):
            from ash_alerting import ASHAlertEngine

            self.alert_engine = ASHAlertEngine(
                self.config.get("alert_rules_path", "/etc/ash/alert_rules.json"),
                alert_log_path=str(self.log_dir / "alerts.jsonl"),
            )

        # Retention
        self.retention_days: int = self.config.get("retention_days", 90)
        self.archive_days: int = self.config.get("archive_days", 30)
        self.archive_path = Path(self.config.get("archive_path", "/var/archive/ash"))

        # Metrics + health endpoint.  Binding is deliberately separate from
        # Kafka/DB startup: an operator can still see "not ready, DB down"
        # instead of a connection refused on the health port.
        self._start_observability_server()

        # Signal handlers
        signal.signal(signal.SIGTERM, self._signal_handler)
        signal.signal(signal.SIGINT, self._signal_handler)

        # Start background flush timer
        self._start_flush_timer()

        # Start retention maintenance (daily)
        self._start_retention_timer()

        self._refresh_readiness()
        sd_notify("READY=1")
        self._start_watchdog()

    def _start_observability_server(self):
        """Start the combined Prometheus/health HTTP server.

        Domain: ``metrics_host`` is a hostname or IP address (default
        ``127.0.0.1``); ``metrics_port`` is an integer in 1-65535.  Docker
        sets the host to ``0.0.0.0`` for an internal-only scrape network;
        systemd keeps the default loopback bind.

        A bind failure is logged and the consumer keeps processing events.
        That is intentional: losing observability must not lose data, and
        the container health check will correctly report the service
        unhealthy.  The exception text is not included because it can echo
        the configured address.
        """
        host = self.config.get("metrics_host", "127.0.0.1")
        port = int(self.config.get("metrics_port", 9090))
        try:
            server = ThreadingHTTPServer((host, port), _ObservabilityHandler)
            server.consumer = self  # type: ignore[attr-defined]
            thread = threading.Thread(
                target=server.serve_forever,
                name="ash-observability",
                daemon=True,
            )
            thread.start()
            self._observability_server = server
            self._observability_thread = thread
            self.logger.info(
                "Observability HTTP server started",
                extra=log_extra(channel="observability"),
            )
        except OSError as exc:
            self.logger.error(
                "Could not start observability HTTP server",
                extra=log_extra(error_type=type(exc).__name__),
            )

    def _start_watchdog(self):
        """Send systemd watchdog heartbeats while the process is running.

        Domain: active only when ``NOTIFY_SOCKET`` is set by systemd; the
        interval is fixed at 10 seconds, below the unit's 60-second
        ``WatchdogSec``.  This is process liveness, not proof that a Kafka
        message arrived: an idle consumer is healthy.
        """
        if not os.environ.get("NOTIFY_SOCKET"):
            return

        def heartbeat():
            while self.running:
                sd_notify("WATCHDOG=1")
                time.sleep(10)

        thread = threading.Thread(
            target=heartbeat, name="ash-systemd-watchdog", daemon=True
        )
        thread.start()
        self._watchdog_thread = thread

    def _is_ready(self) -> bool:
        """Return whether this consumer can durably accept more events.

        Readiness deliberately does not require recent traffic: an idle
        consumer whose database and last flush are healthy is ready.  It
        does require that the last flush did not leave data pending and, if
        PostgreSQL is enabled, that the database gauge is 1.
        """
        if not getattr(self, "running", False):
            return False
        if getattr(self, "_last_flush_error", None):
            return False
        if self.config.get("database_enabled", False):
            if DB_AVAILABLE._value.get() != 1:
                return False
        return True

    def _refresh_readiness(self):
        """Publish the readiness decision to the Prometheus gauge."""
        READY.set(1 if self._is_ready() else 0)

    def health_liveness(self) -> Tuple[HTTPStatus, Dict[str, Any]]:
        """Return ``(status, body)`` for the liveness endpoint.

        Liveness answers "is this process still running?" and intentionally
        does not check PostgreSQL or Kafka.  A DB outage must not cause an
        orchestrator to kill and restart a consumer that is correctly
        holding its batch.
        """
        alive = bool(getattr(self, "running", False)) and not getattr(
            self, "_stopping", False
        )
        status = HTTPStatus.OK if alive else HTTPStatus.SERVICE_UNAVAILABLE
        return status, {"status": "alive" if alive else "stopping"}

    def health_readiness(self) -> Tuple[HTTPStatus, Dict[str, Any]]:
        """Return ``(status, body)`` for the readiness endpoint.

        The body is a stable, secret-free summary.  Database error strings,
        connection URLs, and Kafka broker lists are never included; those
        belong in the structured logs.
        """
        ready = self._is_ready()
        if self.config.get("database_enabled", False):
            database = "connected" if DB_AVAILABLE._value.get() == 1 else "unavailable"
        else:
            database = "disabled"
        flush = "ok" if not getattr(self, "_last_flush_error", None) else "failing"
        last_message = getattr(self, "_last_message_at", None)
        last_flush = getattr(self, "_last_flush_success", None)
        started_at = getattr(self, "started_at", time.time())
        payload = {
            "status": "ready" if ready else "degraded",
            "checks": {
                "consumer": "running" if self.running else "stopping",
                "database": database,
                "flush": flush,
            },
            "last_message_at": (
                datetime.fromtimestamp(last_message, tz=timezone.utc).isoformat()
                if last_message
                else None
            ),
            "last_flush_success_at": (
                datetime.fromtimestamp(last_flush, tz=timezone.utc).isoformat()
                if last_flush
                else None
            ),
            "uptime_seconds": round(time.time() - started_at, 3),
        }
        status = HTTPStatus.OK if ready else HTTPStatus.SERVICE_UNAVAILABLE
        return status, payload

    def _load_config(self, config_path: str) -> Dict[str, Any]:
        default_config = {
            "kafka_brokers": ["localhost:9092"],
            "kafka_topic": "ash-logs",
            "kafka_group_id": "ash-consumer-group",
            "log_dir": "/var/log/ash",
            "log_level": "INFO",
            "log_name": "consumer.log",
            "log_max_bytes": 10 * 1024 * 1024,
            "log_backup_count": 5,
            "database_enabled": False,
            "database_url": "postgresql://ash:password@localhost/ash_logs",
            "batch_size": 100,
            "batch_timeout": 5.0,
            "retention_days": 90,
            "archive_days": 30,
            "archive_path": "/var/archive/ash",
            "metrics_host": "127.0.0.1",
            "metrics_port": 9090,
            "alerting_enabled": False,
            "alert_rules_path": "/etc/ash/alert_rules.json",
            "max_dedup_cache": 100000,
        }

        if os.path.exists(config_path):
            with open(config_path, "r") as f:
                config = json.load(f)
                default_config.update(config)

        self._apply_environment(default_config)
        return default_config

    def _apply_environment(self, config: Dict[str, Any]) -> None:
        """Apply documented ``ASH_*`` environment overrides in place.

        Docker sets connection details in the environment while the image
        also ships a JSON config file.  Without this step the JSON file's
        localhost defaults silently won: the consumer never used the
        ``ASH_DATABASE_URL``/``ASH_KAFKA_BROKERS`` values passed by Compose.

        Every variable is optional.  Values are validated here and a bad
        value raises ``ValueError`` before any connection is attempted, so a
        typo cannot start a consumer that silently writes to the wrong place.
        See ``docs/OBSERVABILITY.md`` for the full domain table.
        """
        if "ASH_KAFKA_BROKERS" in os.environ:
            raw = _env_string("ASH_KAFKA_BROKERS", "")
            brokers = [item.strip() for item in raw.split(",") if item.strip()]
            if not brokers:
                raise ValueError(
                    "ASH_KAFKA_BROKERS must contain at least one host:port"
                )
            config["kafka_brokers"] = brokers

        config["kafka_topic"] = _env_string("ASH_KAFKA_TOPIC", config["kafka_topic"])
        config["kafka_group_id"] = _env_string(
            "ASH_KAFKA_GROUP_ID", config["kafka_group_id"]
        )
        config["database_url"] = _env_string("ASH_DATABASE_URL", config["database_url"])
        config["database_enabled"] = _env_bool(
            "ASH_DATABASE_ENABLED", config["database_enabled"]
        )
        config["alerting_enabled"] = _env_bool(
            "ASH_ALERTING_ENABLED", config["alerting_enabled"]
        )
        config["log_dir"] = _env_string("ASH_LOG_DIR", config["log_dir"])
        config["log_level"] = _env_string("ASH_LOG_LEVEL", config["log_level"]).upper()
        if config["log_level"] not in _VALID_LOG_LEVELS:
            raise ValueError(
                f"ASH_LOG_LEVEL must be one of {_VALID_LOG_LEVELS}, "
                f"got {config['log_level']!r}"
            )
        config["log_max_bytes"] = _env_int(
            "ASH_LOG_MAX_BYTES", config["log_max_bytes"], minimum=0
        )
        config["log_backup_count"] = _env_int(
            "ASH_LOG_BACKUP_COUNT", config["log_backup_count"], minimum=0
        )
        config["metrics_host"] = _env_string("ASH_METRICS_HOST", config["metrics_host"])
        config["metrics_port"] = _env_int(
            "ASH_METRICS_PORT",
            config["metrics_port"],
            minimum=1,
            maximum=65535,
        )
        config["batch_size"] = _env_int(
            "ASH_BATCH_SIZE", config["batch_size"], minimum=1
        )
        config["batch_timeout"] = _env_float(
            "ASH_BATCH_TIMEOUT", config["batch_timeout"], minimum=0.001
        )

    def _setup_logging(self):
        self.logger = configure_logging(
            "ash-consumer",
            level=self.config.get("log_level", "INFO"),
            log_dir=str(self.log_dir),
            log_name=self.config.get("log_name", "consumer.log"),
            max_bytes=self.config.get("log_max_bytes", 10 * 1024 * 1024),
            backup_count=self.config.get("log_backup_count", 5),
        )

    def _setup_database(self):
        max_retries = 3
        for attempt in range(max_retries):
            try:
                self.db_conn = _connect_db(self.config["database_url"])
                self.db_conn.autocommit = False
                self._create_tables()
                DB_AVAILABLE.set(1)
                self._refresh_readiness()
                self.logger.info("Database connection established")
                return
            except Exception as e:
                DB_AVAILABLE.set(0)
                self._refresh_readiness()
                self.logger.error(
                    f"Database setup attempt {attempt+1} failed: {e}",
                    extra=log_extra(error_type=type(e).__name__),
                )
                time.sleep(2**attempt)

        self.logger.error("Database setup failed after all retries")
        self.db_conn = None
        DB_AVAILABLE.set(0)
        self._refresh_readiness()

    def _create_tables(self):
        with self.db_conn.cursor() as cursor:
            cursor.execute("""
                CREATE TABLE IF NOT EXISTS command_logs (
                    id SERIAL PRIMARY KEY,
                    event_id UUID UNIQUE NOT NULL,
                    schema_version VARCHAR(10) DEFAULT '1.0',
                    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    server_ip VARCHAR(50),
                    hostname VARCHAR(100) NOT NULL,
                    source VARCHAR(50) NOT NULL,
                    event_type VARCHAR(50) NOT NULL,
                    username VARCHAR(100),
                    uid INTEGER,
                    session_id UUID,
                    pid INTEGER,
                    ppid INTEGER,
                    tty VARCHAR(50),
                    command TEXT,
                    cwd TEXT,
                    exit_code INTEGER,
                    duration_ms REAL,
                    stdout TEXT,
                    stderr TEXT,
                    output_truncated BOOLEAN DEFAULT FALSE,
                    file_path TEXT,
                    diff_content TEXT,
                    ssh_connection VARCHAR(200),
                    container_id VARCHAR(100),
                    container_name VARCHAR(200),
                    risk_score INTEGER DEFAULT 0,
                    risk_flags TEXT[],
                    prev_hash VARCHAR(64),
                    event_hash VARCHAR(64),
                    raw_event JSONB,
                    raw_event_text TEXT,
                    log_timestamp TIMESTAMP,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                );

                -- Existing deployments predate raw_event_text. Keep the
                -- exact signed line so the API can later recompute
                -- sha256(prev_hash || unsigned_json); raw_event JSONB does
                -- not preserve the bytes that were signed.
                ALTER TABLE command_logs
                    ADD COLUMN IF NOT EXISTS raw_event_text TEXT;

                CREATE INDEX IF NOT EXISTS idx_cmd_logs_hostname_time
                    ON command_logs (hostname, log_timestamp);
                CREATE INDEX IF NOT EXISTS idx_cmd_logs_session
                    ON command_logs (session_id, log_timestamp);
                CREATE INDEX IF NOT EXISTS idx_cmd_logs_user_time
                    ON command_logs (username, log_timestamp);
                CREATE INDEX IF NOT EXISTS idx_cmd_logs_event_type
                    ON command_logs (event_type, log_timestamp);
                CREATE INDEX IF NOT EXISTS idx_cmd_logs_source
                    ON command_logs (source);
                CREATE INDEX IF NOT EXISTS idx_cmd_logs_command_gin
                    ON command_logs USING gin (to_tsvector('english', coalesce(command, '')));
                CREATE INDEX IF NOT EXISTS idx_cmd_logs_event_id
                    ON command_logs (event_id);

                CREATE TABLE IF NOT EXISTS file_changes (
                    id SERIAL PRIMARY KEY,
                    event_id UUID UNIQUE NOT NULL,
                    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    hostname VARCHAR(100) NOT NULL,
                    username VARCHAR(100),
                    session_id UUID,
                    file_path TEXT NOT NULL,
                    change_type VARCHAR(30),
                    diff_content TEXT,
                    command TEXT,
                    source VARCHAR(50),
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                );

                CREATE INDEX IF NOT EXISTS idx_file_changes_host_time
                    ON file_changes (hostname, timestamp);
                CREATE INDEX IF NOT EXISTS idx_file_changes_path
                    ON file_changes (file_path, timestamp);
                CREATE INDEX IF NOT EXISTS idx_file_changes_session
                    ON file_changes (session_id);

                CREATE TABLE IF NOT EXISTS sessions (
                    id SERIAL PRIMARY KEY,
                    session_id UUID UNIQUE NOT NULL,
                    hostname VARCHAR(100) NOT NULL,
                    username VARCHAR(100),
                    start_time TIMESTAMP,
                    end_time TIMESTAMP,
                    ssh_connection VARCHAR(200),
                    tty VARCHAR(50),
                    shell VARCHAR(50),
                    event_count INTEGER DEFAULT 0,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                );

                CREATE INDEX IF NOT EXISTS idx_sessions_host
                    ON sessions (hostname, start_time);
                CREATE INDEX IF NOT EXISTS idx_sessions_user
                    ON sessions (username, start_time);

                CREATE TABLE IF NOT EXISTS alerts (
                    id SERIAL PRIMARY KEY,
                    event_id UUID REFERENCES command_logs(event_id),
                    rule_name VARCHAR(200) NOT NULL,
                    severity VARCHAR(20) NOT NULL,
                    description TEXT,
                    hostname VARCHAR(100),
                    username VARCHAR(100),
                    command TEXT,
                    triggered_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    acknowledged BOOLEAN DEFAULT FALSE,
                    acknowledged_by VARCHAR(100),
                    acknowledged_at TIMESTAMP
                );

                CREATE INDEX IF NOT EXISTS idx_alerts_severity
                    ON alerts (severity, triggered_at);
                CREATE INDEX IF NOT EXISTS idx_alerts_host
                    ON alerts (hostname, triggered_at);
            """)
            self.db_conn.commit()

    def _setup_kafka_consumer(self):
        max_retries = 5
        for attempt in range(max_retries):
            try:
                self.consumer = KafkaConsumer(
                    self.config["kafka_topic"],
                    bootstrap_servers=self.config["kafka_brokers"],
                    group_id=self.config["kafka_group_id"],
                    # Keep the raw bytes: run() decodes and parses them so
                    # command_logs.raw_event_text holds the exact signed
                    # line. A deserializer that parsed here would discard
                    # the bytes (and raise inside the iterator on poison
                    # messages, restarting the consumer at the same offset).
                    value_deserializer=lambda x: x,
                    auto_offset_reset="latest",
                    # Was True: offsets were committed on a fixed
                    # background timer regardless of whether the consumed
                    # events had actually been flushed to file/DB yet. A
                    # crash between poll and flush silently lost up to
                    # batch_size - 1 events, since Kafka never redelivers
                    # an already-committed offset. Commits are now issued
                    # explicitly, only after a flush succeeds (see run()).
                    enable_auto_commit=False,
                    max_poll_interval_ms=300000,
                    session_timeout_ms=30000,
                    heartbeat_interval_ms=10000,
                )
                self.logger.info("Kafka consumer initialized")
                return
            except KafkaTimeoutError:
                self.logger.warning(
                    f"Kafka not available, attempt {attempt+1}/{max_retries}"
                )
                time.sleep(5 * (attempt + 1))
            except Exception as e:
                self.logger.error(f"Kafka setup error: {e}")
                time.sleep(5)

        self.logger.error("Kafka connection failed after all retries")
        sys.exit(1)

    def _validate_event(self, event: Dict[str, Any]) -> Tuple[bool, str]:
        """Validate an event before it can poison a database batch.

        Presence-only checks were not enough: a non-UUID session_id, an
        unparseable timestamp, or a value wider than its varchar column made
        the whole batch fail in PostgreSQL. Return the reason so the caller
        can put the event in the DLQ and keep consuming.
        """
        if not isinstance(event, dict):
            return False, "not_an_object"

        for field in REQUIRED_FIELDS:
            value = event.get(field)
            if value is None or (isinstance(value, str) and not value.strip()):
                return False, "missing_field"

        for field in ("event_id", "session_id"):
            value = event.get(field)
            if value is None:
                continue
            try:
                uuid.UUID(str(value))
            except (ValueError, TypeError, AttributeError):
                return False, "invalid_uuid"

        timestamp = event.get("timestamp")
        if not isinstance(timestamp, str) or "T" not in timestamp:
            return False, "invalid_timestamp"
        try:
            datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
        except ValueError:
            return False, "invalid_timestamp"

        if event.get("event_type") not in VALID_EVENT_TYPES:
            return False, "invalid_event_type"
        if event.get("source") not in VALID_SOURCES:
            return False, "invalid_source"

        for field, max_length in MAX_FIELD_LENGTHS.items():
            value = event.get(field)
            if value is None:
                continue
            if not isinstance(value, str):
                return False, "invalid_type"
            if len(value) > max_length:
                return False, "field_too_long"

        for field in INTEGER_FIELDS:
            value = event.get(field)
            if value is not None and (
                isinstance(value, bool) or not isinstance(value, int)
            ):
                return False, "invalid_type"

        duration = event.get("duration_ms")
        if duration is not None and (
            isinstance(duration, bool) or not isinstance(duration, (int, float))
        ):
            return False, "invalid_type"

        return True, ""

    def _append_dead_letter_record(self, record: Dict[str, Any]) -> bool:
        """Append one JSON line to the DLQ.

        Returns False if it was not persisted so the caller can surface the
        loss (the per-row fallback refuses to commit in that case)."""
        try:
            with open(self.dlq_path, "a", encoding="utf-8") as f:
                f.write(json.dumps(record, default=str) + "\n")
            return True
        except Exception as e:
            self.logger.error(f"Failed to write dead-letter record: {e}")
            return False

    def _write_dead_letter(self, event: Dict[str, Any], reason: str) -> bool:
        """Persist an event that could not be processed instead of silently
        dropping it, so it can be inspected/replayed later."""
        EVENTS_DEAD_LETTERED.labels(reason=reason).inc()
        return self._append_dead_letter_record(
            {
                "dlq_timestamp": datetime.now(timezone.utc).isoformat(),
                "reason": reason,
                "event": event,
            }
        )

    def _write_dead_letter_raw(self, raw_text: Optional[str], reason: str) -> bool:
        """DLQ a payload that could not even be parsed as a JSON object."""
        EVENTS_DEAD_LETTERED.labels(reason=reason).inc()
        return self._append_dead_letter_record(
            {
                "dlq_timestamp": datetime.now(timezone.utc).isoformat(),
                "reason": reason,
                "raw_event_text": raw_text,
            }
        )

    def _decode_message(
        self, value: Any
    ) -> Tuple[Optional[str], Optional[Dict[str, Any]], Optional[str]]:
        """Return (raw_text, event, error_reason) for one Kafka value.

        Parsing here, not in the deserializer, is what makes a poison
        message a DLQ entry instead of an exception inside the consumer
        iterator (which restarted the process at the same offset forever).
        """
        if isinstance(value, bytes):
            try:
                raw_text = value.decode("utf-8")
            except UnicodeDecodeError:
                return value.decode("utf-8", errors="replace"), None, "invalid_utf8"
        elif isinstance(value, str):
            raw_text = value
        elif isinstance(value, dict):
            raw_text = json.dumps(value, separators=(",", ":"), default=str)
        else:
            return None, None, "unsupported_payload"

        if len(raw_text) > MAX_RAW_EVENT_LENGTH:
            return raw_text[:MAX_RAW_EVENT_LENGTH], None, "raw_too_long"

        try:
            event = json.loads(raw_text)
        except (json.JSONDecodeError, RecursionError):
            return raw_text, None, "invalid_json"

        if not isinstance(event, dict):
            return raw_text, None, "not_an_object"
        return raw_text, event, None

    def _deduplicate(self, event_id: str) -> bool:
        if event_id in self.seen_event_ids:
            EVENTS_DEDUPLICATED.inc()
            return True
        self.seen_event_ids.add(event_id)
        if len(self.seen_event_ids) > self.max_seen_ids:
            # Evict oldest half
            ids_list = list(self.seen_event_ids)
            self.seen_event_ids = set(ids_list[self.max_seen_ids // 2 :])
        return False

    def process_message(
        self, log_data: Dict[str, Any], raw_event_text: Optional[str] = None
    ):
        """Process a single incoming event with validation and deduplication."""
        try:
            is_valid, reason = self._validate_event(log_data)
            if not is_valid:
                self.logger.warning(
                    "Invalid event dead-lettered",
                    extra=log_extra(
                        event_id=log_data.get("event_id"),
                        session_id=log_data.get("session_id"),
                        error_type=reason,
                    ),
                )
                self._write_dead_letter(log_data, reason)
                return

            event_id = log_data.get("event_id", "")
            if self._deduplicate(event_id):
                self.logger.debug(
                    "Duplicate event skipped", extra=log_extra(event_id=event_id)
                )
                return

            source = log_data.get("source", "unknown")
            event_type = log_data.get("event_type", "unknown")
            EVENTS_RECEIVED.labels(source=source, event_type=event_type).inc()

            # Alerting -- feed matched-rule severity back into risk_score
            # (see SEVERITY_RISK_SCORE) so it's actually non-zero for
            # anything the alert engine flagged.
            if self.alert_engine:
                matched_rules = self.alert_engine.check_event(log_data)
                if matched_rules:
                    log_data["risk_score"] = max(
                        SEVERITY_RISK_SCORE.get(rule.severity, 0)
                        for rule in matched_rules
                    )

            # Add to batch buffer. _flush_batch() manages batch_lock itself
            # and does the actual (potentially slow) file/DB writes outside
            # the lock -- it must not be called from within another
            # `with self.batch_lock:` block, or the lock it takes internally
            # would block forever waiting for a lock this same thread is
            # still holding.
            with self.batch_lock:
                self.batch_buffer.append(log_data)
                self.batch_raw_texts.append(raw_event_text)
                BATCH_SIZE_GAUGE.set(len(self.batch_buffer))
                should_flush = len(self.batch_buffer) >= self.batch_size

            if should_flush:
                self._flush_batch()

        except Exception as e:
            self.logger.error(
                "Error processing message",
                exc_info=True,
                extra=log_extra(
                    event_id=(
                        log_data.get("event_id") if isinstance(log_data, dict) else None
                    ),
                    error_type=type(e).__name__,
                ),
            )
            EVENTS_FAILED.labels(reason="processing_error").inc()

    def _flush_batch(self):
        """Flush the current batch to storage.

        Takes batch_lock only to snapshot-and-clear the buffer (and, on
        failure, to put it back) -- never while writing to disk or the
        database. _write_database_batch() can block for a while even with
        _connect_db()'s timeouts (up to connect_timeout to reconnect, plus
        statement_timeout per retry, times its own retry loop); holding
        batch_lock for that whole duration would block process_message()
        for every other incoming Kafka message, and the periodic flush_loop
        timer thread, until it finished -- effectively freezing the whole
        consumer any time a write is slow, not just this one flush.
        """
        with self.batch_lock:
            if not self.batch_buffer:
                return
            batch = self.batch_buffer[:]
            raw_texts = self.batch_raw_texts[:]
            # Tests and older callers can populate batch_buffer directly.
            # Keep the two lists aligned rather than dropping raw text.
            if len(raw_texts) < len(batch):
                raw_texts.extend([None] * (len(batch) - len(raw_texts)))
            elif len(raw_texts) > len(batch):
                raw_texts = raw_texts[: len(batch)]
            self.batch_buffer = []
            self.batch_raw_texts = []
            BATCH_SIZE_GAUGE.set(0)

        start_time = time.time()
        try:
            # PostgreSQL first. If it is unavailable, the batch stays in
            # memory and its Kafka offset is not committed; the broker will
            # replay it after a crash. Writing the local JSONL first would
            # duplicate lines on every retry while the database is down.
            if self.config.get("database_enabled", False):
                self._write_database_batch(batch, raw_texts)

            self._write_file_batch(batch)

            now = time.time()
            self.last_flush = now
            self._last_flush_success = now
            self._last_flush_error = None
            LAST_FLUSH_SUCCESS_TIMESTAMP.set(now)
            EVENTS_PROCESSED.inc(len(batch))
            self._refresh_readiness()
            # Signal the main consumer-loop thread that it's now safe to
            # advance committed Kafka offsets past these events (they are
            # durably in the DB and on disk). Set here so this covers both
            # a size-triggered flush (main thread) and a timeout-triggered
            # flush (background flush-timer thread) -- threading.Event is
            # itself thread-safe, so this needs no lock.
            self._commit_pending.set()

        except Exception as e:
            self._last_flush_error = type(e).__name__
            FLUSH_FAILURES.inc()
            self.logger.error(
                "Batch flush failed; batch remains pending",
                exc_info=True,
                extra=log_extra(
                    batch_size=len(batch),
                    error_type=type(e).__name__,
                ),
            )
            # Re-add failed batch for retry. Its offset is deliberately
            # left uncommitted, so PostgreSQL failure blocks progress
            # instead of creating a permanent gap in the API's data.
            with self.batch_lock:
                self.batch_buffer = batch + self.batch_buffer
                self.batch_raw_texts = raw_texts + self.batch_raw_texts
                BATCH_SIZE_GAUGE.set(len(self.batch_buffer))
            EVENTS_FAILED.labels(reason="flush_error").inc()
            self._refresh_readiness()

        BATCH_FLUSH_LATENCY.observe(time.time() - start_time)

    def _write_file_batch(self, events: List[Dict]):
        """Write batch of events to JSONL files grouped by hostname."""
        files: Dict[str, list] = {}
        for event in events:
            hostname = event.get("hostname", "unknown")
            if hostname not in files:
                files[hostname] = []
            files[hostname].append(event)

        for hostname, host_events in files.items():
            log_file = self.log_dir / f"ash-history-{hostname}.jsonl"
            with open(log_file, "a", encoding="utf-8") as f:
                for event in host_events:
                    f.write(json.dumps(event, default=str) + "\n")

    def _write_database_batch(
        self, events: List[Dict], raw_texts: List[Optional[str]]
    ) -> bool:
        """Write a batch to PostgreSQL, raising if it is not durable.

        The caller uses the exception to keep the batch in memory and leave
        its Kafka offset uncommitted. A data error (one bad row) is isolated
        by retrying rows individually and DLQing only the rejected ones.
        """
        max_retries = 3
        for attempt in range(max_retries):
            try:
                start_time = time.time()
                if self.db_conn is None:
                    try:
                        self.db_conn = _connect_db(self.config["database_url"])
                        self.db_conn.autocommit = False
                    except Exception as e:
                        DB_AVAILABLE.set(0)
                        self.logger.warning(
                            "DB reconnect failed "
                            f"(attempt {attempt + 1}/{max_retries}): {e}"
                        )
                        if attempt == max_retries - 1:
                            raise DatabaseWriteError(str(e)) from e
                        time.sleep(2**attempt)
                        continue
                with self.db_conn.cursor() as cursor:
                    self._insert_database_rows(cursor, events, raw_texts)
                self.db_conn.commit()
                DB_AVAILABLE.set(1)
                DB_WRITE_LATENCY.observe(time.time() - start_time)
                return True

            except psycopg2.OperationalError as e:
                DB_AVAILABLE.set(0)
                self.logger.warning(
                    f"DB connection lost (attempt {attempt + 1}/{max_retries}): {e}"
                )
                if self.db_conn:
                    try:
                        self.db_conn.rollback()
                    except Exception:
                        pass
                time.sleep(2**attempt)
                try:
                    self.db_conn = _connect_db(self.config["database_url"])
                    self.db_conn.autocommit = False
                except Exception:
                    self.db_conn = None

            except psycopg2.Error as e:
                DB_AVAILABLE.set(0)
                self.logger.error(f"Database write error: {e}", exc_info=True)
                if self.db_conn:
                    self.db_conn.rollback()
                # A single bad row (for example a value PostgreSQL rejects
                # despite validation) must not poison every other event in
                # the batch. Retry one row per transaction; only the row
                # that still fails goes to the DLQ.
                return self._write_database_rows_individually(events, raw_texts)

            except Exception as e:
                DB_AVAILABLE.set(0)
                self.logger.error(
                    f"Unexpected database write error: {e}", exc_info=True
                )
                if self.db_conn:
                    self.db_conn.rollback()
                raise DatabaseWriteError(str(e)) from e

        DB_AVAILABLE.set(0)
        raise DatabaseWriteError(
            f"database write failed after {max_retries} connection attempts"
        )

    def _write_database_rows_individually(
        self, events: List[Dict], raw_texts: List[Optional[str]]
    ) -> bool:
        """Retry a failed batch one row at a time, DLQing only bad rows."""
        for event, raw_text in zip(events, raw_texts):
            try:
                with self.db_conn.cursor() as cursor:
                    self._insert_database_rows(cursor, [event], [raw_text])
                self.db_conn.commit()
            except psycopg2.OperationalError as e:
                DB_AVAILABLE.set(0)
                if self.db_conn:
                    self.db_conn.rollback()
                raise DatabaseWriteError(str(e)) from e
            except psycopg2.Error as e:
                if self.db_conn:
                    self.db_conn.rollback()
                event_id = event.get("event_id", "unknown")
                self.logger.error(f"Database rejected event {event_id}: {e}")
                EVENTS_FAILED.labels(reason="db_row_error").inc()
                if not self._write_dead_letter(event, "db_row_error"):
                    DB_AVAILABLE.set(0)
                    raise DatabaseWriteError(
                        f"could not DLQ database-rejected event {event_id}"
                    ) from e
            except Exception as e:
                DB_AVAILABLE.set(0)
                if self.db_conn:
                    self.db_conn.rollback()
                raise DatabaseWriteError(str(e)) from e

        DB_AVAILABLE.set(1)
        return True

    def _insert_database_rows(
        self,
        cursor,
        events: List[Dict],
        raw_texts: List[Optional[str]],
    ):
        """Insert command, file-change, and session rows on one cursor."""
        if len(raw_texts) < len(events):
            raw_texts = list(raw_texts) + [None] * (len(events) - len(raw_texts))

        command_events = []
        file_events = []
        session_events = []

        for event, raw_text in zip(events, raw_texts):
            event_type = event.get("event_type", "")

            if event_type in ("session_start", "session_end"):
                session_events.append(event)
            elif event_type.startswith("file_"):
                file_events.append(event)

            # All events go to command_logs
            command_events.append((event, raw_text))

        # Bulk insert command events
        if command_events:
            values = [
                (
                    e.get("event_id"),
                    e.get("schema_version", "1.0"),
                    e.get("hostname", "unknown"),
                    e.get("source", "unknown"),
                    e.get("event_type", "unknown"),
                    e.get("user", e.get("username", "")),
                    e.get("uid"),
                    e.get("session_id"),
                    e.get("pid"),
                    e.get("ppid"),
                    e.get("tty"),
                    e.get("command", ""),
                    e.get("cwd"),
                    e.get("exit_code"),
                    e.get("duration_ms"),
                    e.get("stdout", e.get("output", "")),
                    e.get("file_path"),
                    e.get("diff_content"),
                    e.get("ssh_connection"),
                    e.get("container_id"),
                    e.get("container_name"),
                    e.get("risk_score", 0),
                    e.get("prev_hash"),
                    e.get("event_hash"),
                    json.dumps(e, default=str),
                    raw_text,
                    e.get("timestamp"),
                )
                for e, raw_text in command_events
            ]
            execute_values(
                cursor,
                """INSERT INTO command_logs
                (event_id, schema_version, hostname, source, event_type,
                 username, uid, session_id, pid, ppid, tty, command, cwd,
                 exit_code, duration_ms, stdout, file_path, diff_content,
                 ssh_connection, container_id, container_name, risk_score,
                 prev_hash, event_hash, raw_event, raw_event_text,
                 log_timestamp)
                VALUES %s
                ON CONFLICT (event_id) DO NOTHING""",
                values,
                template="""(%s, %s, %s, %s, %s, %s, %s, %s::uuid, %s, %s,
                             %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s,
                             %s, %s, %s, %s::jsonb, %s, %s::timestamp)""",
            )

        # Bulk insert file-change events. file_events was already classified
        # above and then never used -- nothing was ever inserted into
        # file_changes, so "file change tracking + diffs" (this project's
        # headline differentiator per docs/PROJECT_REPORT.md) was completely
        # unqueryable via the DB or the API.
        if file_events:
            file_values = [
                (
                    e.get("event_id"),
                    e.get("hostname", "unknown"),
                    e.get("user", e.get("username", "")),
                    e.get("session_id"),
                    e.get("file_path"),
                    e.get("event_type"),
                    e.get("diff_content"),
                    e.get("command", ""),
                    e.get("source", "unknown"),
                    e.get("timestamp"),
                )
                for e in file_events
            ]
            execute_values(
                cursor,
                """INSERT INTO file_changes
                (event_id, hostname, username, session_id, file_path,
                 change_type, diff_content, command, source, timestamp)
                VALUES %s
                ON CONFLICT (event_id) DO NOTHING""",
                file_values,
                template="""(%s, %s, %s, %s::uuid, %s, %s, %s, %s, %s,
                             %s::timestamp)""",
            )

        # Handle sessions
        for se in session_events:
            if se.get("event_type") == "session_start":
                cursor.execute(
                    """
                    INSERT INTO sessions
                    (session_id, hostname, username, start_time, ssh_connection, tty, shell)
                    VALUES (%s, %s, %s, %s, %s, %s, %s)
                    ON CONFLICT (session_id) DO NOTHING
                """,
                    (
                        se.get("session_id"),
                        se.get("hostname"),
                        se.get("user", se.get("username")),
                        se.get("timestamp"),
                        se.get("ssh_connection"),
                        se.get("tty"),
                        se.get("shell"),
                    ),
                )
            elif se.get("event_type") == "session_end":
                cursor.execute(
                    """
                    UPDATE sessions
                    SET end_time = %s, event_count = %s
                    WHERE session_id = %s
                """,
                    (
                        se.get("timestamp"),
                        se.get("events_in_session", 0),
                        se.get("session_id"),
                    ),
                )

    def _start_flush_timer(self):
        """Periodic flush timer for batch timeout."""

        def flush_loop():
            while self.running:
                time.sleep(1.0)
                # _processing_lock closes the race between "consumer yields
                # a message" and "process_message appends it": without it,
                # this timer could flush an earlier prefix, set
                # _commit_pending, and let run() commit past a message that
                # is still only in memory.
                with self._processing_lock:
                    with self.batch_lock:
                        should_flush = (
                            self.batch_buffer
                            and (time.time() - self.last_flush) >= self.batch_timeout
                        )
                    if should_flush:
                        self._flush_batch()

        thread = threading.Thread(target=flush_loop, daemon=True)
        thread.start()

    def _start_retention_timer(self):
        """Run retention maintenance daily."""

        def retention_loop():
            while self.running:
                time.sleep(86400)  # 24 hours
                try:
                    self._run_retention()
                except Exception as e:
                    self.logger.error(f"Retention maintenance failed: {e}")

        thread = threading.Thread(target=retention_loop, daemon=True)
        thread.start()

    def _run_retention(self):
        """Archive old records and delete expired ones."""
        if not self.db_conn:
            return

        self.logger.info("Running retention maintenance...")
        self.archive_path.mkdir(parents=True, exist_ok=True)

        # Archive records older than archive_days
        archive_cutoff = datetime.now() - timedelta(days=self.archive_days)
        with self.db_conn.cursor(cursor_factory=RealDictCursor) as cursor:
            cursor.execute(
                "SELECT * FROM command_logs WHERE log_timestamp < %s ORDER BY log_timestamp LIMIT 10000",
                (archive_cutoff,),
            )
            rows = cursor.fetchall()

            if rows:
                archive_file = (
                    self.archive_path
                    / f"commands_{archive_cutoff.strftime('%Y%m%d')}.jsonl.gz"
                )
                with gzip.open(archive_file, "at", encoding="utf-8") as f:
                    for row in rows:
                        f.write(json.dumps(dict(row), default=str) + "\n")

                self.logger.info(f"Archived {len(rows)} records to {archive_file}")

        # Delete records older than retention_days
        retention_cutoff = datetime.now() - timedelta(days=self.retention_days)
        with self.db_conn.cursor() as cursor:
            cursor.execute(
                "DELETE FROM command_logs WHERE log_timestamp < %s", (retention_cutoff,)
            )
            deleted = cursor.rowcount
            cursor.execute(
                "DELETE FROM file_changes WHERE timestamp < %s", (retention_cutoff,)
            )
            self.db_conn.commit()

        if deleted > 0:
            self.logger.info(f"Deleted {deleted} expired records")
            # VACUUM cannot run inside a transaction block. The connection
            # is in manual-commit mode, so a plain execute() here starts a
            # new transaction and PostgreSQL rejects it -- the old code
            # logged deletion, then failed VACUUM on every retention run.
            previous_autocommit = self.db_conn.autocommit
            self.db_conn.autocommit = True
            try:
                with self.db_conn.cursor() as vacuum_cursor:
                    vacuum_cursor.execute("VACUUM ANALYZE command_logs")
                    vacuum_cursor.execute("VACUUM ANALYZE file_changes")
            finally:
                self.db_conn.autocommit = previous_autocommit

    def _update_lag(self):
        """Publish Kafka position/lag and assignment.

        ``records-lag-max`` is kafka-python's estimate from the consumer's
        last fetched position, not committed-offset lag.  It is still a
        useful "keeping up?" signal, but it can look healthy during a DB
        stall; readiness therefore depends on the last flush outcome, not on
        this gauge.  Metrics are observability only and must never fail a
        consume cycle.
        """
        try:
            assignment = self.consumer.assignment()
            KAFKA_ASSIGNED_PARTITIONS.set(len(assignment) if assignment else 0)
        except Exception:
            pass
        try:
            lag = self.consumer.metrics().get("records-lag-max")
            if lag is not None:
                KAFKA_LAG.set(float(lag))
        except Exception:
            pass

    def run(self):
        """Main consumer loop."""
        self.logger.info(
            f"ASH Consumer v2.2 started (topic: {self.config['kafka_topic']})",
            extra=log_extra(channel="kafka"),
        )

        try:
            for message in self.consumer:
                if not self.running:
                    break

                now = time.time()
                self._last_message_at = now
                LAST_MESSAGE_TIMESTAMP.set(now)
                raw_text, event, error = self._decode_message(message.value)
                with self._processing_lock:
                    if error:
                        self.logger.warning(
                            f"Dead-lettering malformed Kafka payload: {error}"
                        )
                        self._write_dead_letter_raw(raw_text, error)
                    else:
                        self.process_message(event, raw_event_text=raw_text)

                    self._update_lag()

                    # Commit only from this thread (KafkaConsumer.commit()
                    # is not thread-safe) and only once a flush has
                    # actually persisted data -- see enable_auto_commit=False
                    # and the _commit_pending.set() call in _flush_batch().
                    if self._commit_pending.is_set():
                        try:
                            self.consumer.commit()
                            self._commit_pending.clear()
                        except Exception as e:
                            self.logger.error(f"Offset commit failed: {e}")

        except KeyboardInterrupt:
            self.logger.info("Consumer interrupted by user")
        except Exception as e:
            self.logger.error(f"Consumer loop error: {e}", exc_info=True)
            # Exit non-zero so on-failure supervisors restart the process.
            # Returning normally made a fatal loop error look like a clean
            # shutdown to Kubernetes and systemd's on-failure policy.
            raise
        finally:
            self._cleanup()

    def _signal_handler(self, signum, frame):
        self.logger.info(f"Received signal {signum}, shutting down...")
        self._stopping = True
        self.running = False
        self._refresh_readiness()
        sd_notify("STOPPING=1")

    def _cleanup(self):
        # Take the same lock the flush timer uses: _flush_batch() takes
        # batch_lock itself, but the timer could otherwise be mid-flush
        # while this final flush runs.
        with self._processing_lock:
            self._flush_batch()

            # Commit the final flush's offsets before closing -- same thread
            # as run()'s loop (called from its `finally`), so this is safe.
            if hasattr(self, "consumer") and self._commit_pending.is_set():
                try:
                    self.consumer.commit()
                    self._commit_pending.clear()
                except Exception as e:
                    self.logger.error(f"Final offset commit failed: {e}")

        observability_server = getattr(self, "_observability_server", None)
        if observability_server is not None:
            observability_server.shutdown()
            observability_server.server_close()
            self._observability_server = None

        if hasattr(self, "consumer"):
            self.consumer.close()
        if self.db_conn:
            self.db_conn.close()

        self.logger.info("ASH Consumer stopped")


if __name__ == "__main__":
    config_path = sys.argv[1] if len(sys.argv) > 1 else "/etc/ash/consumer.conf"
    consumer = ASHConsumer(config_path)
    consumer.run()
