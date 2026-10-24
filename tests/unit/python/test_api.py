"""Unit tests for the REST API's health and authentication behavior."""

import jwt


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
