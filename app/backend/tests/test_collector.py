import json

import pytest

from weather.collector import parse
from weather.config import Location, load_locations

LOC = Location("Tel Aviv", 32.08, 34.78)


def payload(**over):
    cur = {"time": "2026-11-25T12:15", "temperature_2m": 21.4, "apparent_temperature": 20.1,
           "relative_humidity_2m": 55, "wind_speed_10m": 12.0, "wind_direction_10m": 310,
           "weather_code": 2, "is_day": 1}
    cur.update(over)
    return {"utc_offset_seconds": 7200, "current": cur}


def test_parse_valid():
    row = parse(LOC, payload())
    assert row["location"] == "Tel Aviv"
    assert row["temperature_c"] == 21.4
    assert row["observed_at"].isoformat() == "2026-11-25T10:15:00+00:00"  # local 12:15 at UTC+2
    assert row["is_day"] is True and row["humidity_pct"] == 55


@pytest.mark.parametrize("bad", [
    {"temperature_2m": 999},
    {"temperature_2m": float("nan")},
    {"wind_speed_10m": -1},
    {"weather_code": 500},
    {"temperature_2m": "DROP TABLE"},
    {"relative_humidity_2m": 150},
    {"wind_direction_10m": 720},
    {"is_day": 5},
])
def test_parse_rejects_bad_data(bad):
    with pytest.raises((ValueError, TypeError)):
        parse(LOC, payload(**bad))


def test_parse_rejects_missing_field():
    with pytest.raises(KeyError):
        parse(LOC, {"current": {"time": "2026-11-25T10:15"}})


def test_shipped_locations_file_is_valid():
    assert len(load_locations("locations.json")) >= 2


def test_locations_reject_bad_coordinates(tmp_path):
    f = tmp_path / "l.json"
    f.write_text(json.dumps([{"name": "X", "lat": 200, "lon": 0}]))
    with pytest.raises(ValueError):
        load_locations(str(f))
