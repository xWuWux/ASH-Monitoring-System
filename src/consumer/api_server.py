#!/usr/bin/env python3
"""
ASH REST API Server — Search, analytics, and real-time streaming.
Provides JWT-based authentication and RBAC.
"""

import hmac
import os
from datetime import datetime, timedelta
from functools import wraps

import jwt
import psycopg2
from flask import Flask, jsonify, request
from flask_limiter import Limiter
from flask_limiter.util import get_remote_address
from psycopg2.extras import RealDictCursor


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


@app.errorhandler(429)
def rate_limit_exceeded(_e):
    return jsonify({"error": "Too many requests, try again later"}), 429


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

    payload = {
        "sub": username,
        "role": role,
        "iat": datetime.utcnow(),
        "exp": datetime.utcnow() + timedelta(hours=app.config["JWT_EXPIRY_HOURS"]),
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
    start_time = request.args.get("start_time")
    end_time = request.args.get("end_time")
    limit = min(int(request.args.get("limit", 100)), 1000)
    offset = int(request.args.get("offset", 0))

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
            # Get total count
            count_query = query.replace(
                "SELECT event_id, hostname, source, event_type, username, command, cwd, exit_code, log_timestamp, session_id, risk_score",
                "SELECT COUNT(*)",
            ).rsplit("LIMIT", 1)[0]
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
    limit = min(int(request.args.get("limit", 50)), 200)

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
    limit = min(int(request.args.get("limit", 20)), 100)
    hours = min(int(request.args.get("hours", 24)), 720)

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
    hours = min(int(request.args.get("hours", 24)), 720)

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
    limit = min(int(request.args.get("limit", 50)), 200)

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
    limit = min(int(request.args.get("limit", 50)), 200)

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
                ORDER BY log_timestamp
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


# ─── Health Endpoint ─────────────────────────────────────────────────────────
@app.route("/health", methods=["GET"])
def health():
    """Health check endpoint."""
    checks = {"status": "healthy"}
    try:
        conn = get_db()
        conn.close()
        checks["database"] = "connected"
    except Exception:
        checks["database"] = "disconnected"
        checks["status"] = "degraded"

    return jsonify(checks), 200 if checks["status"] == "healthy" else 503


if __name__ == "__main__":
    port = int(os.environ.get("ASH_API_PORT", "8080"))
    debug = os.environ.get("ASH_DEBUG", "false").lower() == "true"
    host = os.environ.get("ASH_API_HOST", "127.0.0.1")
    app.run(host=host, port=port, debug=debug)
