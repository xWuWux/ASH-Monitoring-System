"""Degradation tests for the API's health endpoint."""


def test_health_reports_degraded_when_the_database_is_down(
    api_client, api_module, monkeypatch
):
    def unavailable():
        raise RuntimeError("database is down")

    monkeypatch.setattr(api_module, "get_db", unavailable)

    response = api_client.get("/health")

    assert response.status_code == 503
    assert response.get_json() == {"status": "degraded", "database": "disconnected"}
