"""Fixtures for the API contract suite.

These tests run the real Flask app against a real PostgreSQL database and
assert the response contract (field names, JSON types, status codes, and
pagination/filter behavior). They are deliberately not mocked: the unit
tests already cover request construction, and mocking the database is what
let the COUNT(*) + ORDER BY bug reach a release.
"""

import logging
import os
import uuid
from datetime import datetime, timedelta, timezone

import psycopg2
import pytest

# Deterministic, well-formed hashes so /integrity/verify can check links.
GENESIS_HASH = "0" * 64
FIRST_HASH = "a" * 64
SECOND_HASH = "b" * 64


def _naive_utc_now():
    return datetime.now(timezone.utc).replace(tzinfo=None)


@pytest.fixture(scope="session")
def database_url():
    return os.environ["ASH_DATABASE_URL"]


@pytest.fixture(scope="session")
def contract_schema(database_url, consumer_module):
    """Create the ASH schema exactly the way the consumer does."""
    consumer = object.__new__(consumer_module.ASHConsumer)
    consumer.config = {"database_url": database_url}
    consumer.logger = logging.getLogger("ash-contract-schema")
    consumer._setup_database()

    if consumer.db_conn is None:
        pytest.fail(f"could not create schema in {database_url}")
    consumer.db_conn.close()


@pytest.fixture(scope="session")
def admin_token(api_module, contract_schema):
    client = api_module.app.test_client()
    response = client.post(
        "/api/v1/auth/token",
        json={
            "username": os.environ["ASH_ADMIN_USER"],
            "password": os.environ["ASH_ADMIN_PASS"],
        },
    )
    assert response.status_code == 200, response.get_data(as_text=True)
    return response.get_json()["token"]


@pytest.fixture
def admin_headers(admin_token):
    return {"Authorization": f"Bearer {admin_token}"}


@pytest.fixture
def contract_data(database_url, contract_schema):
    """Seed one host/session with two events and one alert, then clean up."""
    tag = uuid.uuid4().hex[:12]
    hostname = f"contract-host-{tag}"
    session_id = uuid.uuid4()
    first_event = uuid.uuid4()
    second_event = uuid.uuid4()
    first_time = _naive_utc_now() - timedelta(hours=2)
    second_time = first_time + timedelta(minutes=5)
    command = f"contract-command-{tag}"
    trace_id = "1" * 32
    first_span = "1" * 16
    second_span = "2" * 16

    data = {
        "tag": tag,
        "hostname": hostname,
        "username": f"contract-user-{tag}",
        "session_id": str(session_id),
        "first_event": str(first_event),
        "second_event": str(second_event),
        "command": command,
        "rule_name": f"contract-rule-{tag}",
        "first_time": first_time,
        "second_time": second_time,
        "trace_id": trace_id,
        "first_span": first_span,
        "second_span": second_span,
    }

    conn = psycopg2.connect(database_url)
    try:
        with conn.cursor() as cursor:
            cursor.execute(
                """
                INSERT INTO sessions
                    (session_id, hostname, username, start_time, end_time,
                     ssh_connection, tty, shell, event_count)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
                """,
                (
                    str(session_id),
                    hostname,
                    data["username"],
                    first_time,
                    second_time,
                    "203.0.113.10 51000 198.51.100.5 22",
                    "/dev/pts/7",
                    "/bin/bash",
                    2,
                ),
            )
            cursor.execute(
                """
                INSERT INTO command_logs
                    (event_id, schema_version, hostname, source, event_type,
                     username, session_id, command, cwd, exit_code,
                     log_timestamp, risk_score, prev_hash, event_hash,
                     trace_id, span_id)
                VALUES (%s, '1.0', %s, 'bash-debug', 'command_start', %s, %s,
                        %s, '/srv/app', 0, %s, 95, %s, %s, %s, %s)
                """,
                (
                    str(first_event),
                    hostname,
                    data["username"],
                    str(session_id),
                    f"{command} alpha",
                    first_time,
                    GENESIS_HASH,
                    FIRST_HASH,
                    trace_id,
                    first_span,
                ),
            )
            cursor.execute(
                """
                INSERT INTO command_logs
                    (event_id, schema_version, hostname, source, event_type,
                     username, session_id, command, cwd, exit_code,
                     log_timestamp, risk_score, prev_hash, event_hash,
                     trace_id, span_id, parent_span_id)
                VALUES (%s, '1.0', %s, 'bash-debug', 'command_end', %s, %s,
                        %s, '/srv/app', 0, %s, 0, %s, %s, %s, %s, %s)
                """,
                (
                    str(second_event),
                    hostname,
                    data["username"],
                    str(session_id),
                    f"{command} beta",
                    second_time,
                    FIRST_HASH,
                    SECOND_HASH,
                    trace_id,
                    second_span,
                    first_span,
                ),
            )
            cursor.execute(
                """
                INSERT INTO alerts
                    (event_id, rule_name, severity, description, hostname,
                     username, command, triggered_at)
                VALUES (%s, %s, 'high', 'contract alert', %s, %s, %s, %s)
                """,
                (
                    str(first_event),
                    data["rule_name"],
                    hostname,
                    data["username"],
                    f"{command} alpha",
                    second_time,
                ),
            )
        conn.commit()
    finally:
        conn.close()

    try:
        yield data
    finally:
        conn = psycopg2.connect(database_url)
        try:
            with conn.cursor() as cursor:
                cursor.execute(
                    "DELETE FROM alerts WHERE rule_name = %s", (data["rule_name"],)
                )
                cursor.execute(
                    "DELETE FROM file_changes WHERE hostname = %s", (hostname,)
                )
                cursor.execute(
                    "DELETE FROM command_logs WHERE hostname = %s", (hostname,)
                )
                cursor.execute("DELETE FROM sessions WHERE hostname = %s", (hostname,))
            conn.commit()
        finally:
            conn.close()
