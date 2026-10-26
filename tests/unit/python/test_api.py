"""Unit tests for the REST API's health and authentication behavior."""

import logging
import uuid

import jwt
import pytest


class _HealthyConnection:
    def close(self):
        pass


def test_health_is_healthy_when_the_database_connects(
    api_client, api_module, monkeypatch
):
    monkeypatch.setattr(api_module, "get_db", lambda: _HealthyConnection())

    response = api_client.get("/health")

    assert response.status_code == 200
    assert response.get_json() == {"status": "healthy", "database": "connected"}


def test_liveness_is_independent_of_the_database(api_client):
    response = api_client.get("/health/live")

    assert response.status_code == 200
    assert response.get_json() == {"status": "alive"}


def test_readiness_reports_ready_when_the_database_connects(
    api_client, api_module, monkeypatch
):
    monkeypatch.setattr(api_module, "get_db", lambda: _HealthyConnection())

    response = api_client.get("/health/ready")

    assert response.status_code == 200
    assert response.get_json() == {
        "status": "ready",
        "checks": {"database": "connected"},
    }
    assert api_module.API_DATABASE_AVAILABLE._value.get() == 1


@pytest.mark.parametrize(
    "raw,expected",
    [
        ("1", True),
        ("TRUE", True),
        ("yes", True),
        ("on", True),
        ("0", False),
        ("FALSE", False),
        ("no", False),
        ("off", False),
    ],
)
def test_env_flag_accepts_the_documented_boolean_domain(
    api_module, monkeypatch, raw, expected
):
    monkeypatch.setenv("ASH_TEST_FLAG", raw)

    assert api_module._env_flag("ASH_TEST_FLAG") is expected


def test_env_flag_rejects_invalid_values(api_module, monkeypatch):
    monkeypatch.setenv("ASH_TEST_FLAG", "ture")

    with pytest.raises(RuntimeError, match="ASH_TEST_FLAG"):
        api_module._env_flag("ASH_TEST_FLAG")


def test_generated_request_id_is_returned(api_client):
    response = api_client.get("/health/live")

    request_id = response.headers["X-Request-ID"]
    assert str(uuid.UUID(request_id)) == request_id


def test_safe_client_request_id_is_preserved(api_client):
    response = api_client.get(
        "/health/live", headers={"X-Request-ID": "client-request-123"}
    )

    assert response.headers["X-Request-ID"] == "client-request-123"


def test_unsafe_client_request_id_is_replaced(api_client):
    # Werkzeug itself rejects a newline before the app sees it, so use a
    # value it accepts but the ASH sanitizer rejects (spaces/semicolon).
    unsafe = "bad id;with spaces"
    response = api_client.get("/health/live", headers={"X-Request-ID": unsafe})

    request_id = response.headers["X-Request-ID"]
    assert request_id != unsafe
    assert str(uuid.UUID(request_id)) == request_id


def test_access_log_omits_query_string_and_authorization(api_client, api_module):
    records = []

    class Capture(logging.Handler):
        def emit(self, record):
            records.append(record)

    handler = Capture()
    api_module.logger.addHandler(handler)
    previous_level = api_module.logger.level
    api_module.logger.setLevel(logging.INFO)
    try:
        response = api_client.get(
            "/api/v1/events?command=SEARCH_SECRET",
            headers={"Authorization": "Bearer TOKEN_SECRET"},
        )
    finally:
        api_module.logger.removeHandler(handler)
        api_module.logger.setLevel(previous_level)

    assert response.status_code == 401
    access = [r for r in records if r.getMessage() == "request completed"]
    assert access
    record = access[-1]
    assert record.path == "/api/v1/events"
    assert record.method == "GET"
    assert record.status_code == 401
    assert record.request_id
    assert "SEARCH_SECRET" not in str(record.__dict__)
    assert "TOKEN_SECRET" not in str(record.__dict__)
    assert "Authorization" not in record.__dict__


def test_metrics_are_disabled_by_default(api_client, monkeypatch):
    monkeypatch.delenv("ASH_METRICS_ENABLED", raising=False)

    response = api_client.get("/metrics")

    assert response.status_code == 404


def test_metrics_fail_closed_without_a_token(api_client, monkeypatch):
    monkeypatch.setenv("ASH_METRICS_ENABLED", "true")
    monkeypatch.delenv("ASH_METRICS_TOKEN", raising=False)

    response = api_client.get("/metrics")

    assert response.status_code == 401
    assert response.headers["WWW-Authenticate"].startswith("Bearer")


def test_metrics_require_the_configured_token(api_client, monkeypatch):
    monkeypatch.setenv("ASH_METRICS_ENABLED", "true")
    monkeypatch.setenv("ASH_METRICS_TOKEN", "metrics-secret")
    monkeypatch.delenv("PROMETHEUS_MULTIPROC_DIR", raising=False)

    unauthorized = api_client.get("/metrics")
    authorized = api_client.get(
        "/metrics", headers={"Authorization": "Bearer metrics-secret"}
    )

    assert unauthorized.status_code == 401
    assert authorized.status_code == 200
    assert authorized.content_type.startswith("text/plain")
    assert b"ash_api_requests_total" in authorized.data


def test_admin_credentials_return_a_usable_token(api_client):
    response = api_client.post(
        "/api/v1/auth/token",
        json={"username": "test-admin", "password": "test-password"},
    )

    assert response.status_code == 200
    body = response.get_json()
    assert body["expires_in"] > 0
    payload = jwt.decode(
        body["token"],
        "test-only-jwt-secret-not-for-production",
        algorithms=["HS256"],
    )
    assert payload["role"] == "admin"
    assert payload["sub"] == "test-admin"


def test_bad_credentials_are_rejected(api_client):
    response = api_client.post(
        "/api/v1/auth/token",
        json={"username": "test-admin", "password": "wrong-password"},
    )

    assert response.status_code == 401
    assert response.get_json() == {"error": "Invalid credentials"}


def test_missing_credentials_are_rejected(api_client):
    response = api_client.post("/api/v1/auth/token", json={"username": "test-admin"})

    assert response.status_code == 400


def test_protected_endpoint_requires_a_token(api_client):
    response = api_client.get("/api/v1/events")

    assert response.status_code == 401
    assert response.get_json() == {"error": "Authentication required"}


def test_protected_endpoint_rejects_an_invalid_token(api_client):
    response = api_client.get(
        "/api/v1/events", headers={"Authorization": "Bearer not-a-real-token"}
    )

    assert response.status_code == 401
    assert response.get_json() == {"error": "Invalid token"}


class _SearchCursor:
    def __init__(self, queries):
        self.queries = queries

    def __enter__(self):
        return self

    def __exit__(self, *_exc_info):
        return False

    def execute(self, query, params):
        self.queries.append((query, params))

    def fetchall(self):
        return []

    def fetchone(self):
        return {"count": 0}


class _SearchConnection:
    def __init__(self, queries):
        self.queries = queries

    def cursor(self, *_args, **_kwargs):
        return _SearchCursor(self.queries)

    def close(self):
        pass


def test_event_search_count_query_does_not_keep_order_by(
    api_client, api_module, monkeypatch
):
    queries = []
    monkeypatch.setattr(api_module, "get_db", lambda: _SearchConnection(queries))
    token = jwt.encode(
        {"sub": "test-admin", "role": "admin"},
        "test-only-jwt-secret-not-for-production",
        algorithm="HS256",
    )

    response = api_client.get(
        "/api/v1/events?hostname=host-a&limit=1",
        headers={"Authorization": f"Bearer {token}"},
    )

    assert response.status_code == 200
    count_queries = [query for query, _params in queries if "COUNT(*)" in query]
    assert len(count_queries) == 1
    assert "ORDER BY" not in count_queries[0]
    assert "LIMIT" not in count_queries[0]


def test_event_search_returns_trace_context_columns(
    api_client, api_module, monkeypatch
):
    queries = []
    monkeypatch.setattr(api_module, "get_db", lambda: _SearchConnection(queries))
    token = jwt.encode(
        {"sub": "test-admin", "role": "admin"},
        "test-only-jwt-secret-not-for-production",
        algorithm="HS256",
    )

    response = api_client.get(
        "/api/v1/events?hostname=host-a",
        headers={"Authorization": f"Bearer {token}"},
    )

    assert response.status_code == 200
    select_query = next(
        query for query, _params in queries if "FROM command_logs" in query
    )
    for column in ("trace_id", "span_id", "parent_span_id"):
        assert column in select_query
    # The count query must remain a valid aggregate: it replaces the whole
    # select list instead of appending columns to COUNT(*).
    count_query = next(query for query, _params in queries if "COUNT(*)" in query)
    assert "trace_id" not in count_query


def test_api_registers_a_tracing_flush_on_normal_exit(api_module, monkeypatch):
    registered = []
    monkeypatch.setattr(api_module.atexit, "register", registered.append)

    api_module._register_tracing_shutdown()

    assert registered == [api_module.shutdown_tracing]
