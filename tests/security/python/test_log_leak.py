"""Security regression tests: the API must not echo credentials or tokens."""

PASSWORD_CANARY = "API_PASSWORD_CANARY_7e3a"
TOKEN_CANARY = "API_TOKEN_CANARY_4b8c"
DATABASE_CANARY = "API_DB_CANARY_9d1f"


def test_token_endpoint_does_not_echo_the_password(api_client):
    response = api_client.post(
        "/api/v1/auth/token",
        json={"username": "test-admin", "password": PASSWORD_CANARY},
    )

    assert response.status_code == 401
    assert PASSWORD_CANARY not in response.get_data(as_text=True)


def test_invalid_bearer_token_is_not_echoed(api_client):
    response = api_client.get(
        "/api/v1/events",
        headers={"Authorization": f"Bearer {TOKEN_CANARY}"},
    )

    assert response.status_code == 401
    assert TOKEN_CANARY not in response.get_data(as_text=True)


def test_health_failure_does_not_leak_the_database_url(
    api_client, api_module, monkeypatch
):
    def unavailable():
        raise RuntimeError(
            f"could not connect: postgresql://ash:{DATABASE_CANARY}@db.internal/ash"
        )

    monkeypatch.setattr(api_module, "get_db", unavailable)

    response = api_client.get("/health")

    assert response.status_code == 503
    body = response.get_data(as_text=True)
    assert DATABASE_CANARY not in body
    assert "postgresql://" not in body
    assert response.get_json() == {
        "status": "degraded",
        "database": "disconnected",
    }
