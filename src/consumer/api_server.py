#!/usr/bin/env python3
"""
ASH REST API Server — Search, analytics, and real-time streaming.
Provides JWT-based authentication and RBAC.
"""

import hmac
import logging
import os
import time
import uuid
from datetime import datetime, timedelta, timezone
from functools import wraps
from typing import Optional

import jwt
import psycopg2
from flask import Flask, Response, g, jsonify, request
from flask_limiter import Limiter
from flask_limiter.util import get_remote_address
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    CollectorRegistry,
    Counter,
    Gauge,
    Histogram,
    generate_latest,
    multiprocess,
)
from psycopg2.extras import RealDictCursor
from werkzeug.exceptions import BadRequest

from ash_observability import (
    FALSE_VALUES,
    LOG_LEVELS,
    TRUE_VALUES,
    configure_logging,
    log_extra,
    new_request_id,
    sanitize_request_id,
)


def _env_flag(name: str, default: bool = False) -> bool:
    """Read a strict boolean environment variable.

    Domain: unset -> ``default``; otherwise one of ``1/true/yes/on`` or
    ``0/false/no/off`` (case-insensitive).  Any other value raises
    ``RuntimeError`` naming the variable, so a typo cannot silently disable
    metrics or change another safety-relevant flag.
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


_LOG_LEVEL = os.environ.get("ASH_LOG_LEVEL", "INFO").strip().upper()
if _LOG_LEVEL not in LOG_LEVELS:
    raise RuntimeError(f"ASH_LOG_LEVEL must be one of {LOG_LEVELS}, got {_LOG_LEVEL!r}")

# The API's file log is per gunicorn worker: rotating one shared file from
# four processes is not safe (one worker can rotate the file another still
# has open).  Operators get JSON on stdout by default; setting ASH_LOG_DIR
# additionally writes bounded api-<pid>.log files.
_ash_log_dir = os.environ.get("ASH_LOG_DIR") or None
logger = configure_logging(
    "ash-api",
    level=_LOG_LEVEL,
    log_dir=_ash_log_dir,
    log_name=f"api-{os.getpid()}.log",
)

# Validate the metrics flag at import so a typo prevents startup instead of
# silently leaving the endpoint disabled.
_env_flag("ASH_METRICS_ENABLED", False)


def _require_env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(
            f"{name} is not set. Refusing to start with an insecure "
            "built-in default -- see deployments/docker/.env.example, or "
            "scripts/install.sh's generate_api_secrets for how to "
            "generate one. A previous fixed, publicly-known default here "
            '(the literal string "change-me-in-production") let anyone '
            "who had read this file forge a valid admin JWT."
        )
    return value


app = Flask(__name__)
app.config["JWT_SECRET"] = _require_env("ASH_JWT_SECRET")
app.config["JWT_EXPIRY_HOURS"] = int(os.environ.get("ASH_JWT_EXPIRY_HOURS", "24"))
DATABASE_URL = _require_env("ASH_DATABASE_URL")

# ─── API Metrics ─────────────────────────────────────────────────────────────
# route is the Flask rule (for example "/api/v1/events/<event_id>"), not the
# raw path, so an event UUID cannot create unbounded label cardinality.
API_REQUESTS = Counter(
    "ash_api_requests_total",
    "Total HTTP requests handled by the ASH API",
    ["method", "route", "status"],
)
API_REQUEST_DURATION = Histogram(
    "ash_api_request_duration_seconds",
    "ASH API request duration",
    ["method", "route"],
    buckets=[0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0],
)
API_INFLIGHT = Gauge(
    "ash_api_inflight_requests",
    "HTTP requests currently being handled by this API process",
    multiprocess_mode="livesum",
)
API_DATABASE_AVAILABLE = Gauge(
    "ash_api_database_available",
    "1 when the last readiness check opened a PostgreSQL connection, 0 otherwise",
    multiprocess_mode="max",
)

# In gunicorn with multiple workers, prometheus_client must aggregate the
# per-worker mmap files.  The directory is created by the image/unit and is
# only used when explicitly configured; single-process runs use the default
# registry.  See src/consumer/gunicorn.conf.py for worker cleanup.
if os.environ.get("PROMETHEUS_MULTIPROC_DIR"):
    os.makedirs(os.environ["PROMETHEUS_MULTIPROC_DIR"], exist_ok=True)


def _metrics_enabled() -> bool:
    """Return whether ``/metrics`` is served.

    Domain: ``ASH_METRICS_ENABLED`` is unset/false (default, endpoint
    returns 404) or one of ``1/true/yes/on``.  Disabled by default because
    the API port is commonly published to users.
    """
    return _env_flag("ASH_METRICS_ENABLED", False)


def _metrics_token() -> str:
    """Return the bearer token required for ``/metrics``, or ``""``.

    Domain: ``ASH_METRICS_TOKEN`` must be a non-empty secret when metrics
    are enabled.  An empty value makes every metrics request fail closed
    rather than exposing process data unauthenticated.
    """
    return os.environ.get("ASH_METRICS_TOKEN", "")


def _metrics_authorized() -> bool:
    """Compare the request's bearer token in constant time."""
    token = _metrics_token()
    if not token:
        return False
    supplied = request.headers.get("Authorization", "")
    return hmac.compare_digest(supplied, f"Bearer {token}")


if _metrics_enabled() and not _metrics_token():
    logger.error(
        "ASH_METRICS_ENABLED is true but ASH_METRICS_TOKEN is empty; "
        "/metrics will reject every request"
    )

# In-memory storage: correct for a single process, but under gunicorn's
# multiple sync workers (see Dockerfile.api's --workers 4) each worker
# tracks its own count, so the effective limit is roughly workers x the
# configured rate, not an exact bound. A precise limit across all workers
# needs a shared backend (e.g. Redis), which isn't part of this stack today
# -- this is still a large improvement over no rate limiting at all.
limiter = Limiter(app=app, key_func=get_remote_address)

# ─── RBAC ─────────────────────────────────────────────────────────────────────
ROLE_PERMISSIONS = {
    "admin": ["read", "write", "delete", "manage_users", "verify_integrity", "export"],
    "analyst": ["read", "search", "export", "verify_integrity"],
    "readonly": ["read", "search"],
}

# Real credentials per role, from the environment only -- there is no user
# store (see create_token()). ASH_ADMIN_USER/ASH_ADMIN_PASS are required:
# refusing to start with an insecure "admin"/"admin" default, the same
# reasoning as ASH_JWT_SECRET/ASH_DATABASE_URL above. analyst/readonly
# credentials are optional -- if not configured, that role simply cannot
# log in, which is the safe failure mode (nobody gets a token for it),
# unlike the previous behavior of handing a valid readonly token to any
# request with a non-empty username and no real credential check at all.
ROLE_CREDENTIALS = {
    "admin": (_require_env("ASH_ADMIN_USER"), _require_env("ASH_ADMIN_PASS"))
}
if os.environ.get("ASH_ANALYST_USER") and os.environ.get("ASH_ANALYST_PASS"):
    ROLE_CREDENTIALS["analyst"] = (
        os.environ["ASH_ANALYST_USER"],
        os.environ["ASH_ANALYST_PASS"],
    )
if os.environ.get("ASH_READONLY_USER") and os.environ.get("ASH_READONLY_PASS"):
    ROLE_CREDENTIALS["readonly"] = (
        os.environ["ASH_READONLY_USER"],
        os.environ["ASH_READONLY_PASS"],
    )


def get_db():
    return psycopg2.connect(DATABASE_URL, connect_timeout=10)


# ─── Request Correlation and Access Logging ─────────────────────────────────
_HEALTH_ROUTES = ("/health", "/health/live", "/health/ready")


@app.before_request
def _start_request_observation():
    """Assign a request ID and start the duration/in-flight measurements.

    Domain: an inbound ``X-Request-ID`` is accepted only if it matches
    1-128 characters from ``[A-Za-z0-9._:-]``; otherwise a new UUID replaces
    it.  This prevents log/header injection and keeps IDs bounded.
    """
    g.request_id = (
        sanitize_request_id(request.headers.get("X-Request-ID")) or new_request_id()
    )
    g.request_started = time.monotonic()
    g.inflight_counted = True
    API_INFLIGHT.inc()


@app.teardown_request
def _finish_request_observation(_error):
    """Release the in-flight gauge exactly once per request."""
    if getattr(g, "inflight_counted", False):
        API_INFLIGHT.dec()
        g.inflight_counted = False


@app.after_request
def _log_request(response):
    """Emit one structured access log and the request metrics.

    The query string, headers, and body are deliberately absent: a search
    query or authorization header can contain credentials or sensitive
    command text.  ``request.path`` plus the matched route is enough to
    operate the service.
    """
    request_id = getattr(g, "request_id", None) or new_request_id()
    response.headers["X-Request-ID"] = request_id

    started = getattr(g, "request_started", None)
    duration = max(0.0, time.monotonic() - started) if started else 0.0
    route = request.url_rule.rule if request.url_rule is not None else "unmatched"

    try:
        API_REQUESTS.labels(
            method=request.method,
            route=route,
            status=str(response.status_code),
        ).inc()
        API_REQUEST_DURATION.labels(
            method=request.method,
            route=route,
        ).observe(duration)
    except Exception:
        # Metrics must never turn a successful API response into a 500.
        pass

    try:
        if route in _HEALTH_ROUTES:
            level = logging.DEBUG
        elif response.status_code >= 500:
            level = logging.ERROR
        elif response.status_code >= 400:
            level = logging.WARNING
        else:
            level = logging.INFO
        logger.log(
            level,
            "request completed",
            extra=log_extra(
                request_id=request_id,
                method=request.method,
                path=request.path,
                route=route,
                status_code=response.status_code,
                duration_ms=round(duration * 1000, 3),
                remote_addr=request.remote_addr,
            ),
        )
    except Exception:
        # Same rule as metrics: observability must not break the response.
        pass

    return response


@app.errorhandler(429)
def rate_limit_exceeded(_e):
    return jsonify({"error": "Too many requests, try again later"}), 429


@app.errorhandler(BadRequest)
def invalid_request(error):
    # Query-string and path validation raises BadRequest; keep the response
    # JSON so API clients never have to parse Flask's default HTML error page.
    return jsonify({"error": error.description}), 400


@app.errorhandler(psycopg2.OperationalError)
def database_unavailable(error):
    # Connection loss is an expected runtime condition, not a bug. Without
    # this handler Flask returned its default HTML 500 page, which breaks
    # JSON clients and hides the retryable nature of the failure. Log only
    # the exception type: psycopg2's message can include the server address
    # and username, and neither belongs in a central log by default.
    logger.error(
        "Database unavailable",
        extra=log_extra(error_type=type(error).__name__),
    )
    return jsonify({"error": "database unavailable"}), 503


@app.errorhandler(psycopg2.Error)
def database_error(error):
    logger.error(
        "Database error",
        extra=log_extra(error_type=type(error).__name__),
    )
    return jsonify({"error": "database error"}), 500


def _int_arg(name, default, maximum=None, minimum=0):
    """Parse a non-negative integer query parameter.

    int() on arbitrary query-string input (and negative LIMIT/OFFSET values)
    previously reached PostgreSQL and surfaced as a 500. Invalid input is a
    client error, so reject it before touching the database.
    """
    raw = request.args.get(name)
    if raw is None or raw == "":
        value = default
    else:
        try:
            value = int(raw)
        except (TypeError, ValueError):
            raise BadRequest(f"{name} must be an integer")
    if value < minimum:
        raise BadRequest(f"{name} must be >= {minimum}")
    if maximum is not None:
        value = min(value, maximum)
    return value


def _uuid_arg(value, name):
    try:
        return str(uuid.UUID(value))
    except (TypeError, ValueError, AttributeError):
        raise BadRequest(f"{name} must be a UUID")


def _timestamp_arg(name):
    raw = request.args.get(name)
    if not raw:
        return None
    try:
        parsed = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        raise BadRequest(f"{name} must be an ISO-8601 timestamp")
    # command_logs.log_timestamp is TIMESTAMP (without time zone), so pass a
    # naive UTC value rather than relying on an implicit cast.
    if parsed.tzinfo is not None:
        parsed = parsed.astimezone(timezone.utc).replace(tzinfo=None)
    return parsed


def require_role(*roles):
    def decorator(f):
        @wraps(f)
        def decorated(*args, **kwargs):
            token = request.headers.get("Authorization", "").replace("Bearer ", "")
            if not token:
                return jsonify({"error": "Authentication required"}), 401
            try:
                payload = jwt.decode(
                    token, app.config["JWT_SECRET"], algorithms=["HS256"]
                )
                user_role = payload.get("role", "readonly")
                if user_role not in roles:
                    return jsonify({"error": "Insufficient permissions"}), 403
                request.current_user = payload
            except jwt.ExpiredSignatureError:
                return jsonify({"error": "Token expired"}), 401
            except jwt.InvalidTokenError:
                return jsonify({"error": "Invalid token"}), 401
            return f(*args, **kwargs)

        return decorated

    return decorator


# ─── Auth Endpoints ──────────────────────────────────────────────────────────
@app.route("/api/v1/auth/token", methods=["POST"])
@limiter.limit("5 per minute")
def create_token():
    """Generate a JWT for a role, if the request's credentials match that
    role's configured username/password exactly. There is no user store
    (see ROLE_CREDENTIALS above): every role that isn't configured simply
    has no valid credentials, and every mismatch -- including a request
    with no matching role at all -- is rejected the same way. Previously,
    any request with a non-empty username that *didn't* match the admin
    credentials was issued a valid "readonly" token anyway, with no
    credential check for that role at all.
    """
    data = request.get_json(silent=True) or {}
    username = data.get("username", "")
    password = data.get("password", "")

    if not username or not password:
        return jsonify({"error": "username and password required"}), 400

    role = None
    for candidate_role, (cred_user, cred_pass) in ROLE_CREDENTIALS.items():
        # hmac.compare_digest: constant-time, so a wrong password can't be
        # guessed character-by-character via response-time differences the
        # way a plain `==` comparison could.
        if hmac.compare_digest(username, cred_user) and hmac.compare_digest(
            password, cred_pass
        ):
            role = candidate_role
            break

    if role is None:
        return jsonify({"error": "Invalid credentials"}), 401

    now = datetime.now(timezone.utc)
    payload = {
        "sub": username,
        "role": role,
        "iat": now,
        "exp": now + timedelta(hours=app.config["JWT_EXPIRY_HOURS"]),
    }
    token = jwt.encode(payload, app.config["JWT_SECRET"], algorithm="HS256")
    return jsonify(
        {"token": token, "expires_in": app.config["JWT_EXPIRY_HOURS"] * 3600}
    )


# ─── Event Endpoints ─────────────────────────────────────────────────────────
@app.route("/api/v1/events", methods=["GET"])
@require_role("admin", "analyst", "readonly")
def search_events():
    """Search events with filters."""
    hostname = request.args.get("hostname")
    user = request.args.get("user")
    command = request.args.get("command")
    event_type = request.args.get("event_type")
    source = request.args.get("source")
    session_id = request.args.get("session_id")
    if session_id:
        session_id = _uuid_arg(session_id, "session_id")
    start_time = _timestamp_arg("start_time")
    end_time = _timestamp_arg("end_time")
    limit = _int_arg("limit", 100, maximum=1000)
    offset = _int_arg("offset", 0)

    query = "SELECT event_id, hostname, source, event_type, username, command, cwd, exit_code, log_timestamp, session_id, risk_score FROM command_logs WHERE 1=1"
    params = []

    if hostname:
        query += " AND hostname = %s"
        params.append(hostname)
    if user:
        query += " AND username = %s"
        params.append(user)
    if command:
        query += " AND command ILIKE %s"
        params.append(f"%{command}%")
    if event_type:
        query += " AND event_type = %s"
        params.append(event_type)
    if source:
        query += " AND source = %s"
        params.append(source)
    if session_id:
        query += " AND session_id = %s"
        params.append(session_id)
    if start_time:
        query += " AND log_timestamp >= %s"
        params.append(start_time)
    if end_time:
        query += " AND log_timestamp <= %s"
        params.append(end_time)

    query += " ORDER BY log_timestamp DESC LIMIT %s OFFSET %s"
    params.extend([limit, offset])

    conn = get_db()
    try:
        with conn.cursor(cursor_factory=RealDictCursor) as cursor:
            cursor.execute(query, params)
            results = cursor.fetchall()
            # Get total count. Drop the trailing ORDER BY/LIMIT/OFFSET:
            # PostgreSQL rejects ORDER BY on a plain COUNT(*) aggregate
            # (column must appear in GROUP BY), and LIMIT/OFFSET do not
            # belong in a total. params[:-2] already drops limit/offset.
            count_query = query.replace(
                "SELECT event_id, hostname, source, event_type, username, command, cwd, exit_code, log_timestamp, session_id, risk_score",
                "SELECT COUNT(*)",
            ).split(" ORDER BY ", 1)[0]
            cursor.execute(count_query, params[:-2])
            total = cursor.fetchone()["count"]
    finally:
        conn.close()

    return jsonify(
        {
            "events": [dict(r) for r in results],
            "total": total,
            "limit": limit,
            "offset": offset,
        }
    )


@app.route("/api/v1/events/<event_id>", methods=["GET"])
@require_role("admin", "analyst", "readonly")
def get_event(event_id):
    """Get a single event by ID with full details."""
    event_id = _uuid_arg(event_id, "event_id")
    conn = get_db()
    try:
        with conn.cursor(cursor_factory=RealDictCursor) as cursor:
            cursor.execute(
                "SELECT * FROM command_logs WHERE event_id = %s", (event_id,)
            )
            result = cursor.fetchone()
    finally:
        conn.close()

    if not result:
        return jsonify({"error": "Event not found"}), 404
    return jsonify(dict(result))


# ─── Session Endpoints ───────────────────────────────────────────────────────
@app.route("/api/v1/sessions", methods=["GET"])
@require_role("admin", "analyst", "readonly")
def list_sessions():
    """List sessions with optional filters."""
    hostname = request.args.get("hostname")
    user = request.args.get("user")
    limit = _int_arg("limit", 50, maximum=200)

    query = "SELECT * FROM sessions WHERE 1=1"
    params = []

    if hostname:
        query += " AND hostname = %s"
        params.append(hostname)
    if user:
        query += " AND username = %s"
        params.append(user)

    query += " ORDER BY start_time DESC LIMIT %s"
    params.append(limit)

    conn = get_db()
    try:
        with conn.cursor(cursor_factory=RealDictCursor) as cursor:
            cursor.execute(query, params)
            results = cursor.fetchall()
    finally:
        conn.close()

    return jsonify({"sessions": [dict(r) for r in results]})


@app.route("/api/v1/sessions/<session_id>", methods=["GET"])
@require_role("admin", "analyst", "readonly")
def get_session(session_id):
    """Get session details with all events (session replay)."""
    session_id = _uuid_arg(session_id, "session_id")
    conn = get_db()
    try:
        with conn.cursor(cursor_factory=RealDictCursor) as cursor:
            cursor.execute(
                "SELECT * FROM sessions WHERE session_id = %s", (session_id,)
            )
            session = cursor.fetchone()
            if not session:
                return jsonify({"error": "Session not found"}), 404

            cursor.execute(
                "SELECT * FROM command_logs WHERE session_id = %s ORDER BY log_timestamp",
                (session_id,),
            )
            events = cursor.fetchall()
    finally:
        conn.close()

    return jsonify(
        {
            "session": dict(session),
            "events": [dict(e) for e in events],
            "event_count": len(events),
        }
    )


# ─── Host Endpoints ──────────────────────────────────────────────────────────
@app.route("/api/v1/hosts", methods=["GET"])
@require_role("admin", "analyst", "readonly")
def list_hosts():
    """List all monitored hosts with stats."""
    conn = get_db()
    try:
        with conn.cursor(cursor_factory=RealDictCursor) as cursor:
            cursor.execute("""
                SELECT hostname,
                       COUNT(*) as total_events,
                       MAX(log_timestamp) as last_seen,
                       COUNT(DISTINCT session_id) as total_sessions,
                       COUNT(DISTINCT username) as unique_users
                FROM command_logs
                WHERE log_timestamp > NOW() - INTERVAL '24 hours'
                GROUP BY hostname
                ORDER BY total_events DESC
            """)
            results = cursor.fetchall()
    finally:
        conn.close()

    return jsonify({"hosts": [dict(r) for r in results]})


# ─── Analytics Endpoints ─────────────────────────────────────────────────────
@app.route("/api/v1/stats/top-commands", methods=["GET"])
@require_role("admin", "analyst")
def top_commands():
    """Most frequent commands in the last 24h."""
    limit = _int_arg("limit", 20, maximum=100)
    hours = _int_arg("hours", 24, maximum=720, minimum=1)

    conn = get_db()
    try:
        with conn.cursor(cursor_factory=RealDictCursor) as cursor:
            cursor.execute(
                """
                SELECT command, COUNT(*) as count,
                       COUNT(DISTINCT hostname) as hosts,
                       COUNT(DISTINCT username) as users
                FROM command_logs
                WHERE log_timestamp > NOW() - INTERVAL '%s hours'
                  AND event_type = 'command_start'
                  AND command IS NOT NULL AND command != ''
                GROUP BY command
                ORDER BY count DESC
                LIMIT %s
            """,
                (hours, limit),
            )
            results = cursor.fetchall()
    finally:
        conn.close()

    return jsonify({"top_commands": [dict(r) for r in results], "period_hours": hours})


@app.route("/api/v1/stats/timeline", methods=["GET"])
@require_role("admin", "analyst")
def event_timeline():
    """Event frequency over time (bucketed)."""
    hours = _int_arg("hours", 24, maximum=720, minimum=1)

    conn = get_db()
    try:
        with conn.cursor(cursor_factory=RealDictCursor) as cursor:
            cursor.execute(
                """
                SELECT date_trunc('hour', log_timestamp) as bucket,
                       COUNT(*) as event_count,
                       COUNT(DISTINCT hostname) as active_hosts
                FROM command_logs
                WHERE log_timestamp > NOW() - INTERVAL '%s hours'
                GROUP BY bucket
                ORDER BY bucket
            """,
                (hours,),
            )
            results = cursor.fetchall()
    finally:
        conn.close()

    return jsonify({"timeline": [dict(r) for r in results]})


@app.route("/api/v1/stats/risky", methods=["GET"])
@require_role("admin", "analyst")
def risky_events():
    """Highest risk score events."""
    limit = _int_arg("limit", 50, maximum=200)

    conn = get_db()
    try:
        with conn.cursor(cursor_factory=RealDictCursor) as cursor:
            cursor.execute(
                """
                SELECT event_id, hostname, username, command, event_type,
                       risk_score, log_timestamp
                FROM command_logs
                WHERE risk_score > 0
                ORDER BY risk_score DESC, log_timestamp DESC
                LIMIT %s
            """,
                (limit,),
            )
            results = cursor.fetchall()
    finally:
        conn.close()

    return jsonify({"risky_events": [dict(r) for r in results]})


# ─── Alert Endpoints ─────────────────────────────────────────────────────────
@app.route("/api/v1/alerts", methods=["GET"])
@require_role("admin", "analyst")
def list_alerts():
    """List triggered alerts."""
    severity = request.args.get("severity")
    limit = _int_arg("limit", 50, maximum=200)

    conn = get_db()
    try:
        with conn.cursor(cursor_factory=RealDictCursor) as cursor:
            query = "SELECT * FROM alerts WHERE 1=1"
            params = []
            if severity:
                query += " AND severity = %s"
                params.append(severity)
            query += " ORDER BY triggered_at DESC LIMIT %s"
            params.append(limit)
            cursor.execute(query, params)
            results = cursor.fetchall()
    finally:
        conn.close()

    return jsonify({"alerts": [dict(r) for r in results]})


# ─── Integrity Endpoint ──────────────────────────────────────────────────────
@app.route("/api/v1/integrity/verify", methods=["POST"])
@require_role("admin")
def verify_integrity():
    """Verify hash chain integrity for a host's event log."""
    data = request.get_json() or {}
    hostname = data.get("hostname")
    if not hostname:
        return jsonify({"error": "hostname required"}), 400

    conn = get_db()
    try:
        with conn.cursor(cursor_factory=RealDictCursor) as cursor:
            cursor.execute(
                """
                SELECT event_hash, prev_hash, raw_event
                FROM command_logs
                WHERE hostname = %s AND event_hash IS NOT NULL
                -- Chain order is insert order, not wall-clock order: an
                -- event can arrive late with an earlier timestamp. Ordering
                -- by log_timestamp reported a false FAIL for such a host.
                ORDER BY id
            """,
                (hostname,),
            )
            rows = cursor.fetchall()
    finally:
        conn.close()

    errors = 0
    prev_hash = "0" * 64
    for i, row in enumerate(rows):
        if row["prev_hash"] != prev_hash:
            errors += 1
        prev_hash = row["event_hash"] or prev_hash

    status = "PASS" if errors == 0 else "FAIL"
    return jsonify(
        {
            "status": status,
            "hostname": hostname,
            "events_checked": len(rows),
            "integrity_errors": errors,
        }
    )


# ─── Health and Metrics Endpoints ───────────────────────────────────────────
_last_database_health: Optional[bool] = None


def _database_available() -> bool:
    """Return whether a PostgreSQL connection can be opened.

    The exception text is intentionally not returned to the caller or put in
    the access log.  It can contain the database host, user, and (for some
    drivers) connection parameters.  Log only state transitions: Docker
    probes readiness every 10 seconds, and repeating the same failure line
    would bury the first occurrence.
    """
    global _last_database_health
    try:
        conn = get_db()
        conn.close()
    except Exception as error:
        API_DATABASE_AVAILABLE.set(0)
        if _last_database_health is not False:
            logger.warning(
                "Database health check failed",
                extra=log_extra(error_type=type(error).__name__),
            )
        _last_database_health = False
        return False

    API_DATABASE_AVAILABLE.set(1)
    if _last_database_health is False:
        logger.info("Database health check recovered")
    _last_database_health = True
    return True


@app.route("/health/live", methods=["GET"])
def health_live():
    """Liveness: the API process can answer HTTP.

    Domain: always HTTP 200 while the process is running.  Do not use this
    for traffic routing; a process with a dead database is still live.
    """
    return jsonify({"status": "alive"}), 200


@app.route("/health/ready", methods=["GET"])
def health_ready():
    """Readiness: the API can serve requests that need PostgreSQL.

    Domain: HTTP 200 and ``status=ready`` when the database connection
    succeeds; HTTP 503 and ``status=degraded`` otherwise.
    """
    database = _database_available()
    status = "ready" if database else "degraded"
    return (
        jsonify(
            {
                "status": status,
                "checks": {
                    "database": "connected" if database else "disconnected",
                },
            }
        ),
        200 if database else 503,
    )


@app.route("/health", methods=["GET"])
def health():
    """Legacy health endpoint; same readiness decision as /health/ready.

    The response body is kept byte-for-byte compatible with the existing
    contract: ``{"status": "healthy", "database": "connected"}``.
    """
    database = _database_available()
    checks = {
        "status": "healthy" if database else "degraded",
        "database": "connected" if database else "disconnected",
    }
    return jsonify(checks), 200 if database else 503


@app.route("/metrics", methods=["GET"])
def metrics():
    """Expose Prometheus metrics when explicitly enabled and authenticated.

    Domain: ``ASH_METRICS_ENABLED`` false/unset -> 404.  When enabled,
    ``ASH_METRICS_TOKEN`` is required as ``Authorization: Bearer <token>``;
    a missing token fails closed with 401.  The API port is often published,
    so this endpoint is not unauthenticated by default.
    """
    if not _metrics_enabled():
        return jsonify({"error": "not found"}), 404

    if not _metrics_authorized():
        response = jsonify({"error": "Authentication required"})
        response.status_code = 401
        response.headers["WWW-Authenticate"] = 'Bearer realm="metrics"'
        return response

    if os.environ.get("PROMETHEUS_MULTIPROC_DIR"):
        registry = CollectorRegistry()
        multiprocess.MultiProcessCollector(registry)
        payload = generate_latest(registry)
    else:
        payload = generate_latest()
    return Response(payload, content_type=CONTENT_TYPE_LATEST)


if __name__ == "__main__":
    port = int(os.environ.get("ASH_API_PORT", "8080"))
    debug = os.environ.get("ASH_DEBUG", "false").lower() == "true"
    host = os.environ.get("ASH_API_HOST", "127.0.0.1")
    app.run(host=host, port=port, debug=debug)
