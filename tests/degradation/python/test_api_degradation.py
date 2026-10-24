"""Degradation tests for the API's health and database-failure paths."""

import psycopg2


def test_database_outage_on_an_endpoint_returns_json_503(
    api_client, api_module, monkeypatch
):
    token = api_client.post(
        "/api/v1/auth/token",
        json={"username": "test-admin", "password": "test-password"},
    ).get_json()["token"]

    def unavailable():
        raise psycopg2.OperationalError("server closed the connection")

    monkeypatch.setattr(api_module, "get_db", unavailable)

    response = api_client.get(
        "/api/v1/events", headers={"Authorization": f"Bearer {token}"}
    )

    assert response.status_code == 503
    assert response.is_json
    assert response.get_json() == {"error": "database unavailable"}
    assert "server closed" not in response.get_data(as_text=True)


def test_health_reports_degraded_when_the_database_is_down(
    api_client, api_module, monkeypatch
):
    def unavailable():
        raise RuntimeError("database is down")

    monkeypatch.setattr(api_module, "get_db", unavailable)

    response = api_client.get("/health")

    assert response.status_code == 503
    assert response.get_json() == {"status": "degraded", "database": "disconnected"}
    assert api_module.API_DATABASE_AVAILABLE._value.get() == 0
