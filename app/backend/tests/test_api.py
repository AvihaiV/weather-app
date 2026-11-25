from datetime import datetime, timezone

import pytest
from fastapi.testclient import TestClient

from weather import api

client = TestClient(api.app)
ROW = {"location": "London", "observed_at": datetime(2026, 11, 25, tzinfo=timezone.utc),
       "temperature_c": 8.5, "wind_speed_kmh": 20.0, "weather_code": 3}


@pytest.fixture(autouse=True)
def locations_file(monkeypatch):
    monkeypatch.setenv("LOCATIONS_FILE", "locations.json")


def test_current(monkeypatch):
    monkeypatch.setattr(api.db, "latest", lambda: [ROW])
    r = client.get("/api/weather/current")
    assert r.status_code == 200
    assert r.json()[0]["location"] == "London"


def test_current_uses_configured_order(monkeypatch):
    rows = [dict(ROW, location=n) for n in ("Sydney", "London", "Tel Aviv")]
    monkeypatch.setattr(api.db, "latest", lambda: rows)
    assert [r["location"] for r in client.get("/api/weather/current").json()] == ["Tel Aviv", "London", "Sydney"]


def test_history_known_location(monkeypatch):
    seen = {}
    monkeypatch.setattr(api.db, "history", lambda loc, hours: seen.update(loc=loc, hours=hours) or [])
    assert client.get("/api/weather/history", params={"location": "London", "hours": 5}).status_code == 200
    assert seen == {"loc": "London", "hours": 5}


def test_history_unknown_location_is_404(monkeypatch):
    monkeypatch.setattr(api.db, "history", lambda *a: pytest.fail("db must not be called"))
    assert client.get("/api/weather/history", params={"location": "'; DROP TABLE x;--"}).status_code == 404


@pytest.mark.parametrize("hours", [0, -1, 100000])
def test_history_hours_bounds(hours):
    assert client.get("/api/weather/history", params={"location": "London", "hours": hours}).status_code == 422


def test_db_error_returns_503_without_details(monkeypatch):
    def boom():
        raise RuntimeError("password=secret host=internal")
    monkeypatch.setattr(api.db, "latest", boom)
    r = client.get("/api/weather/current")
    assert r.status_code == 503
    assert "secret" not in r.text


def test_docs_disabled():
    assert client.get("/docs").status_code == 404


def test_metrics_exposed():
    client.get("/healthz")
    assert "http_requests_total" in client.get("/metrics").text
