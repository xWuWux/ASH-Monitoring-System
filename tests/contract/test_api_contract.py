"""API response-contract tests against a real PostgreSQL database.

The goal is to catch the class of bug that only appears when SQL really
runs: wrong/renamed JSON fields, invalid pagination values reaching the
database, SQL type errors, and status codes that drift from the documented
behavior. There is no OpenAPI document in this repository yet, so these
assertions are the contract until one is generated.
"""

import os
from datetime import datetime, timedelta, timezone
from uuid import uuid4

import jwt
import pytest

EVENT_SEARCH_KEYS = {
    "event_id",
    "hostname",
    "source",
    "event_type",
    "username",
    "command",
    "cwd",
    "exit_code",
    "log_timestamp",
    "session_id",
    "risk_score",
    "trace_id",
    "span_id",
    "parent_span_id",
}

SESSION_KEYS = {
    "id",
    "session_id",
    "hostname",
    "username",
    "start_time",
    "end_time",
    "ssh_connection",
    "tty",
    "shell",
    "event_count",
    "created_at",
}

ALERT_KEYS = {
    "id",
    "event_id",
    "rule_name",
    "severity",
    "description",
    "hostname",
    "username",
    "command",
    "triggered_at",
    "acknowledged",
    "acknowledged_by",
    "acknowledged_at",
}


def body(response, status=200):
    assert response.status_code == status, response.get_data(as_text=True)
    assert response.is_json, response.get_data(as_text=True)
    return response.get_json()


def make_token(api_module, role, **overrides):
    payload = {
        "sub": f"contract-{role}",
        "role": role,
        "iat": datetime.now(timezone.utc),
        "exp": datetime.now(timezone.utc) + timedelta(hours=1),
    }
    payload.update(overrides)
    return jwt.encode(payload, api_module.app.config["JWT_SECRET"], algorithm="HS256")


# ─── Health & auth ───────────────────────────────────────────────────────────


def test_health_contract(api_client, contract_schema):
    data = body(api_client.get("/health"))
    assert data == {"status": "healthy", "database": "connected"}


def test_token_contract(api_client, contract_schema):
    data = body(
        api_client.post(
            "/api/v1/auth/token",
            json={
                "username": os.environ["ASH_ADMIN_USER"],
                "password": os.environ["ASH_ADMIN_PASS"],
            },
        )
    )
    assert set(data) == {"token", "expires_in"}
    assert isinstance(data["token"], str) and data["token"]
    assert isinstance(data["expires_in"], int)
    assert data["expires_in"] > 0


def test_auth_error_contract(api_client):
    data = body(
        api_client.post(
            "/api/v1/auth/token",
            json={"username": "test-admin", "password": "wrong"},
        ),
        401,
    )
    assert data == {"error": "Invalid credentials"}

    data = body(api_client.post("/api/v1/auth/token", json={}), 400)
    assert data == {"error": "username and password required"}


@pytest.mark.parametrize(
    "headers,status,error",
    [
        ({}, 401, "Authentication required"),
        ({"Authorization": "Bearer not-a-jwt"}, 401, "Invalid token"),
    ],
)
def test_protected_endpoint_auth_contract(api_client, headers, status, error):
    data = body(api_client.get("/api/v1/events", headers=headers), status)
    assert data == {"error": error}


def test_expired_token_is_rejected(api_client, api_module):
    token = make_token(
        api_module,
        "admin",
        exp=datetime.now(timezone.utc) - timedelta(minutes=1),
    )
    data = body(
        api_client.get("/api/v1/events", headers={"Authorization": f"Bearer {token}"}),
        401,
    )
    assert data == {"error": "Token expired"}


def test_role_permissions_are_enforced(api_client, api_module, contract_schema):
    readonly = {"Authorization": f"Bearer {make_token(api_module, 'readonly')}"}
    analyst = {"Authorization": f"Bearer {make_token(api_module, 'analyst')}"}

    body(api_client.get("/api/v1/events", headers=readonly))

    data = body(api_client.get("/api/v1/stats/timeline", headers=readonly), 403)
    assert data == {"error": "Insufficient permissions"}

    body(api_client.get("/api/v1/stats/timeline", headers=analyst))

    data = body(
        api_client.post(
            "/api/v1/integrity/verify",
            json={"hostname": "any"},
            headers=analyst,
        ),
        403,
    )
    assert data == {"error": "Insufficient permissions"}


# ─── Events ──────────────────────────────────────────────────────────────────


def test_event_search_contract(api_client, admin_headers, contract_data):
    data = body(
        api_client.get(
            "/api/v1/events",
            query_string={"hostname": contract_data["hostname"]},
            headers=admin_headers,
        )
    )

    assert set(data) == {"events", "total", "limit", "offset"}
    assert data["total"] == 2
    assert data["limit"] == 100
    assert data["offset"] == 0
    assert isinstance(data["events"], list)
    assert len(data["events"]) == 2
    for event in data["events"]:
        assert set(event) == EVENT_SEARCH_KEYS
        assert event["hostname"] == contract_data["hostname"]
        assert event["username"] == contract_data["username"]
        assert event["session_id"] == contract_data["session_id"]
        assert isinstance(event["risk_score"], int)
        assert isinstance(event["log_timestamp"], str)
    # Ordered newest first.
    assert data["events"][0]["event_id"] == contract_data["second_event"]
    assert data["events"][1]["event_id"] == contract_data["first_event"]
    assert data["events"][0]["trace_id"] == contract_data["trace_id"]
    assert data["events"][0]["span_id"] == contract_data["second_span"]
    assert data["events"][0]["parent_span_id"] == contract_data["first_span"]
    assert data["events"][1]["trace_id"] == contract_data["trace_id"]
    assert data["events"][1]["span_id"] == contract_data["first_span"]
    assert data["events"][1]["parent_span_id"] is None


def test_event_search_filters_contract(api_client, admin_headers, contract_data):
    common = {
        "hostname": contract_data["hostname"],
        "user": contract_data["username"],
        "source": "bash-debug",
        "session_id": contract_data["session_id"],
    }

    data = body(
        api_client.get(
            "/api/v1/events",
            query_string={**common, "command": "alpha"},
            headers=admin_headers,
        )
    )
    assert data["total"] == 1
    assert data["events"][0]["event_id"] == contract_data["first_event"]

    data = body(
        api_client.get(
            "/api/v1/events",
            query_string={**common, "event_type": "command_end"},
            headers=admin_headers,
        )
    )
    assert data["total"] == 1
    assert data["events"][0]["event_id"] == contract_data["second_event"]


def test_event_search_time_window_contract(api_client, admin_headers, contract_data):
    before = (contract_data["first_time"] - timedelta(minutes=1)).isoformat() + "Z"

    data = body(
        api_client.get(
            "/api/v1/events",
            query_string={
                "hostname": contract_data["hostname"],
                "start_time": before,
            },
            headers=admin_headers,
        )
    )
    assert data["total"] == 2

    data = body(
        api_client.get(
            "/api/v1/events",
            query_string={
                "hostname": contract_data["hostname"],
                "end_time": (
                    contract_data["first_time"] + timedelta(minutes=1)
                ).isoformat()
                + "Z",
            },
            headers=admin_headers,
        )
    )
    assert data["total"] == 1
    assert data["events"][0]["event_id"] == contract_data["first_event"]


def test_event_search_pagination_contract(api_client, admin_headers, contract_data):
    query = {"hostname": contract_data["hostname"]}

    first = body(
        api_client.get(
            "/api/v1/events",
            query_string={**query, "limit": 1, "offset": 0},
            headers=admin_headers,
        )
    )
    second = body(
        api_client.get(
            "/api/v1/events",
            query_string={**query, "limit": 1, "offset": 1},
            headers=admin_headers,
        )
    )

    assert first["limit"] == 1 and second["limit"] == 1
    assert first["total"] == second["total"] == 2
    assert first["events"][0]["event_id"] != second["events"][0]["event_id"]

    capped = body(
        api_client.get(
            "/api/v1/events",
            query_string={"limit": 99999},
            headers=admin_headers,
        )
    )
    assert capped["limit"] == 1000

    empty = body(
        api_client.get(
            "/api/v1/events",
            query_string={**query, "limit": 0},
            headers=admin_headers,
        )
    )
    assert empty["events"] == []
    assert empty["total"] == 2


@pytest.mark.parametrize(
    "query_string,message",
    [
        ({"limit": "abc"}, "limit must be an integer"),
        ({"limit": -1}, "limit must be >= 0"),
        ({"offset": "abc"}, "offset must be an integer"),
        ({"offset": -1}, "offset must be >= 0"),
        ({"session_id": "not-a-uuid"}, "session_id must be a UUID"),
        ({"start_time": "not-a-date"}, "start_time must be an ISO-8601 timestamp"),
        ({"end_time": "2026-99-99"}, "end_time must be an ISO-8601 timestamp"),
    ],
)
def test_event_search_rejects_invalid_parameters(
    api_client, admin_headers, query_string, message
):
    data = body(
        api_client.get(
            "/api/v1/events",
            query_string=query_string,
            headers=admin_headers,
        ),
        400,
    )
    assert data == {"error": message}


def test_get_event_contract(api_client, admin_headers, contract_data):
    data = body(
        api_client.get(
            f"/api/v1/events/{contract_data['first_event']}", headers=admin_headers
        )
    )
    assert data["event_id"] == contract_data["first_event"]
    assert data["hostname"] == contract_data["hostname"]
    assert data["command"] == f"{contract_data['command']} alpha"


def test_get_event_not_found_and_bad_uuid(api_client, admin_headers):
    data = body(api_client.get(f"/api/v1/events/{uuid4()}", headers=admin_headers), 404)
    assert data == {"error": "Event not found"}

    data = body(api_client.get("/api/v1/events/not-a-uuid", headers=admin_headers), 400)
    assert data == {"error": "event_id must be a UUID"}


# ─── Sessions ────────────────────────────────────────────────────────────────


def test_session_list_contract(api_client, admin_headers, contract_data):
    data = body(
        api_client.get(
            "/api/v1/sessions",
            query_string={
                "hostname": contract_data["hostname"],
                "user": contract_data["username"],
            },
            headers=admin_headers,
        )
    )
    assert set(data) == {"sessions"}
    assert len(data["sessions"]) == 1
    session = data["sessions"][0]
    assert set(session) == SESSION_KEYS
    assert session["session_id"] == contract_data["session_id"]
    assert session["event_count"] == 2


def test_session_list_rejects_invalid_limit(api_client, admin_headers):
    data = body(
        api_client.get("/api/v1/sessions?limit=nope", headers=admin_headers), 400
    )
    assert data == {"error": "limit must be an integer"}


def test_session_detail_contract(api_client, admin_headers, contract_data):
    data = body(
        api_client.get(
            f"/api/v1/sessions/{contract_data['session_id']}", headers=admin_headers
        )
    )
    assert set(data) == {"session", "events", "event_count"}
    assert data["session"]["session_id"] == contract_data["session_id"]
    assert data["event_count"] == 2
    assert {event["event_id"] for event in data["events"]} == {
        contract_data["first_event"],
        contract_data["second_event"],
    }


def test_session_detail_not_found_and_bad_uuid(api_client, admin_headers):
    data = body(
        api_client.get(f"/api/v1/sessions/{uuid4()}", headers=admin_headers), 404
    )
    assert data == {"error": "Session not found"}

    data = body(
        api_client.get("/api/v1/sessions/not-a-uuid", headers=admin_headers), 400
    )
    assert data == {"error": "session_id must be a UUID"}


# ─── Hosts & analytics ───────────────────────────────────────────────────────


def test_hosts_contract(api_client, admin_headers, contract_data):
    data = body(api_client.get("/api/v1/hosts", headers=admin_headers))
    assert set(data) == {"hosts"}

    host = next(
        (h for h in data["hosts"] if h["hostname"] == contract_data["hostname"]),
        None,
    )
    assert host is not None
    assert set(host) == {
        "hostname",
        "total_events",
        "last_seen",
        "total_sessions",
        "unique_users",
    }
    assert host["total_events"] == 2
    assert host["total_sessions"] == 1
    assert host["unique_users"] == 1
    assert isinstance(host["last_seen"], str)


def test_top_commands_contract(api_client, admin_headers, contract_data):
    data = body(
        api_client.get(
            "/api/v1/stats/top-commands",
            query_string={"hours": 24, "limit": 100},
            headers=admin_headers,
        )
    )
    assert set(data) == {"top_commands", "period_hours"}
    assert data["period_hours"] == 24
    assert isinstance(data["top_commands"], list)

    for item in data["top_commands"]:
        assert set(item) == {"command", "count", "hosts", "users"}
        assert isinstance(item["command"], str)
        assert isinstance(item["count"], int)
        assert isinstance(item["hosts"], int)
        assert isinstance(item["users"], int)

    commands = [item["command"] for item in data["top_commands"]]
    assert any(command.startswith(contract_data["command"]) for command in commands)


@pytest.mark.parametrize(
    "query_string,message",
    [
        ({"limit": "abc"}, "limit must be an integer"),
        ({"hours": "abc"}, "hours must be an integer"),
        ({"hours": 0}, "hours must be >= 1"),
        ({"limit": -5}, "limit must be >= 0"),
    ],
)
def test_top_commands_rejects_invalid_parameters(
    api_client, admin_headers, query_string, message
):
    data = body(
        api_client.get(
            "/api/v1/stats/top-commands",
            query_string=query_string,
            headers=admin_headers,
        ),
        400,
    )
    assert data == {"error": message}


def test_timeline_contract(api_client, admin_headers, contract_data):
    data = body(
        api_client.get(
            "/api/v1/stats/timeline",
            query_string={"hours": 24},
            headers=admin_headers,
        )
    )
    assert set(data) == {"timeline"}
    assert isinstance(data["timeline"], list)

    for bucket in data["timeline"]:
        assert set(bucket) == {"bucket", "event_count", "active_hosts"}
        assert isinstance(bucket["bucket"], str)
        assert isinstance(bucket["event_count"], int)
        assert isinstance(bucket["active_hosts"], int)

    data = body(
        api_client.get("/api/v1/stats/timeline?hours=abc", headers=admin_headers),
        400,
    )
    assert data == {"error": "hours must be an integer"}


def test_risky_events_contract(api_client, admin_headers, contract_data):
    data = body(
        api_client.get(
            "/api/v1/stats/risky",
            query_string={"limit": 200},
            headers=admin_headers,
        )
    )
    assert set(data) == {"risky_events"}
    assert isinstance(data["risky_events"], list)

    for event in data["risky_events"]:
        assert set(event) == {
            "event_id",
            "hostname",
            "username",
            "command",
            "event_type",
            "risk_score",
            "log_timestamp",
        }
        assert event["risk_score"] > 0

    scores = [event["risk_score"] for event in data["risky_events"]]
    assert scores == sorted(scores, reverse=True)
    assert contract_data["first_event"] in {
        event["event_id"] for event in data["risky_events"]
    }

    data = body(
        api_client.get("/api/v1/stats/risky?limit=nope", headers=admin_headers), 400
    )
    assert data == {"error": "limit must be an integer"}


def test_alerts_contract(api_client, admin_headers, contract_data):
    data = body(
        api_client.get(
            "/api/v1/alerts",
            query_string={"severity": "high", "limit": 200},
            headers=admin_headers,
        )
    )
    assert set(data) == {"alerts"}
    alert = next(
        (a for a in data["alerts"] if a["rule_name"] == contract_data["rule_name"]),
        None,
    )
    assert alert is not None
    assert set(alert) == ALERT_KEYS
    assert alert["event_id"] == contract_data["first_event"]
    assert alert["hostname"] == contract_data["hostname"]
    assert alert["severity"] == "high"

    data = body(api_client.get("/api/v1/alerts?limit=nope", headers=admin_headers), 400)
    assert data == {"error": "limit must be an integer"}


# ─── Integrity ───────────────────────────────────────────────────────────────


def test_integrity_verify_contract(api_client, admin_headers, contract_data):
    data = body(
        api_client.post(
            "/api/v1/integrity/verify",
            json={"hostname": contract_data["hostname"]},
            headers=admin_headers,
        )
    )
    assert data == {
        "status": "PASS",
        "hostname": contract_data["hostname"],
        "events_checked": 2,
        "integrity_errors": 0,
    }

    data = body(
        api_client.post("/api/v1/integrity/verify", json={}, headers=admin_headers),
        400,
    )
    assert data == {"error": "hostname required"}

    data = body(
        api_client.post(
            "/api/v1/integrity/verify",
            json={"hostname": "no-such-host"},
            headers=admin_headers,
        )
    )
    assert data["status"] == "PASS"
    assert data["events_checked"] == 0


def test_integrity_verify_uses_insert_order_not_timestamps(
    api_client, admin_headers, database_url
):
    """A late event can carry an earlier timestamp than its predecessor.

    The chain is built in arrival/insert order, so verifying ORDER BY
    log_timestamp would see the late event first and report a false FAIL.
    """
    import psycopg2

    tag = uuid4().hex[:12]
    hostname = f"contract-order-{tag}"
    session_id = str(uuid4())
    first_event = str(uuid4())
    second_event = str(uuid4())
    later = datetime.now(timezone.utc).replace(tzinfo=None)
    earlier = later - timedelta(hours=1)

    conn = psycopg2.connect(database_url)
    try:
        with conn.cursor() as cursor:
            cursor.execute(
                """
                INSERT INTO command_logs
                    (event_id, schema_version, hostname, source, event_type,
                     username, session_id, command, cwd, exit_code,
                     log_timestamp, risk_score, prev_hash, event_hash)
                VALUES (%s, '1.0', %s, 'bash-debug', 'command_start', 'u',
                        %s, 'late-arrival', '/srv/app', 0, %s, 0, %s, %s),
                       (%s, '1.0', %s, 'bash-debug', 'command_end', 'u',
                        %s, 'early-timestamp', '/srv/app', 0, %s, 0, %s, %s)
                """,
                (
                    first_event,
                    hostname,
                    session_id,
                    later,
                    "0" * 64,
                    "a" * 64,
                    second_event,
                    hostname,
                    session_id,
                    earlier,
                    "a" * 64,
                    "b" * 64,
                ),
            )
        conn.commit()
    finally:
        conn.close()

    try:
        data = body(
            api_client.post(
                "/api/v1/integrity/verify",
                json={"hostname": hostname},
                headers=admin_headers,
            )
        )
        assert data == {
            "status": "PASS",
            "hostname": hostname,
            "events_checked": 2,
            "integrity_errors": 0,
        }
    finally:
        conn = psycopg2.connect(database_url)
        try:
            with conn.cursor() as cursor:
                cursor.execute(
                    "DELETE FROM command_logs WHERE hostname = %s", (hostname,)
                )
            conn.commit()
        finally:
            conn.close()
