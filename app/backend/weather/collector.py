"""Collector: runs as a K8s CronJob. Fetches current weather for all locations and stores it.

Open-Meteo needs no API key, so this service has no third-party secret to protect.
"""
import json
import logging
import math
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

from weather import db
from weather.config import Location, load_locations

API_URL = "https://api.open-meteo.com/v1/forecast"
RETRYABLE = {429, 500, 502, 503, 504}
MAX_ATTEMPTS = 4
log = logging.getLogger("collector")


def _get_json(url: str):
    """GET with retries: rate limits (429) and server errors are usually temporary.

    Exponential backoff (2s, 4s, 8s), honouring Retry-After but capped at 30s so the whole run
    stays inside the Job's activeDeadlineSeconds (120s). Client errors (4xx) fail immediately.
    """
    for attempt in range(1, MAX_ATTEMPTS + 1):
        try:
            with urllib.request.urlopen(url, timeout=10) as resp:
                return json.load(resp)
        except urllib.error.HTTPError as e:
            if e.code not in RETRYABLE or attempt == MAX_ATTEMPTS:
                raise
            retry_after = e.headers.get("Retry-After") if e.headers else None
            delay = min(float(retry_after) if retry_after and retry_after.isdigit() else 2 ** attempt, 30)
            log.warning("weather API returned %s, retry %d/%d in %.0fs", e.code, attempt, MAX_ATTEMPTS - 1, delay)
        except (urllib.error.URLError, TimeoutError) as e:
            if attempt == MAX_ATTEMPTS:
                raise
            delay = 2 ** attempt
            log.warning("weather API unreachable (%s), retry %d/%d in %ds", e, attempt, MAX_ATTEMPTS - 1, delay)
        time.sleep(delay)


FIELDS = "temperature_2m,apparent_temperature,relative_humidity_2m,wind_speed_10m,wind_direction_10m,weather_code,is_day"


def fetch(locations: tuple[Location, ...], section: str = "current", **extra) -> list[dict]:
    """One batched request for all locations. section="current" (collector) or "hourly" (backfill)."""
    query = urllib.parse.urlencode({
        "latitude": ",".join(str(l.lat) for l in locations),
        "longitude": ",".join(str(l.lon) for l in locations),
        section: FIELDS,
        "timezone": "auto",  # gives each city's UTC offset, so the UI can show local time
        **extra,
    })
    payload = _get_json(f"{API_URL}?{query}")
    # Open-Meteo returns a list for several locations, a single object for one.
    return payload if isinstance(payload, list) else [payload]


def _num(value, low: float, high: float, name: str) -> float:
    v = float(value)
    if not (math.isfinite(v) and low <= v <= high):
        raise ValueError(f"{name} out of range: {v}")
    return v


def utc_offset(payload: dict) -> int:
    return int(_num(payload["utc_offset_seconds"], -14 * 3600, 14 * 3600, "utc offset"))


def parse(location: Location, payload: dict) -> dict:
    """Validate the external response (a trust boundary) before it reaches the database."""
    return row(location, utc_offset(payload), payload["current"])


def row(location: Location, offset: int, cur: dict) -> dict:
    """Validate one observation (current or one hourly sample) and build a DB row."""
    # With timezone=auto, "time" is the city's local time: convert to UTC.
    observed_at = (datetime.fromisoformat(cur["time"]) - timedelta(seconds=offset)).replace(tzinfo=timezone.utc)
    return {
        "location": location.name,
        "observed_at": observed_at,
        "latitude": location.lat,
        "longitude": location.lon,
        "temperature_c": _num(cur["temperature_2m"], -100, 70, "temperature"),
        "apparent_temperature_c": _num(cur["apparent_temperature"], -120, 80, "apparent temperature"),
        "humidity_pct": int(_num(cur["relative_humidity_2m"], 0, 100, "humidity")),
        "wind_speed_kmh": _num(cur["wind_speed_10m"], 0, 500, "wind speed"),
        "wind_direction_deg": int(_num(cur["wind_direction_10m"], 0, 360, "wind direction")),
        "weather_code": int(_num(cur["weather_code"], 0, 99, "weather code")),
        "is_day": bool(_num(cur["is_day"], 0, 1, "is_day")),
        "utc_offset_seconds": offset,
    }


def main() -> int:
    logging.basicConfig(level=logging.INFO, format='{"level":"%(levelname)s","msg":"%(message)s"}')
    locations = load_locations()
    payloads = fetch(locations)
    if len(payloads) != len(locations):
        log.error("expected %d results, got %d", len(locations), len(payloads))
        return 1
    rows, failed = [], 0
    for loc, payload in zip(locations, payloads):
        try:
            rows.append(parse(loc, payload))
        except (KeyError, ValueError, TypeError) as e:
            failed += 1
            log.error("bad data for %s: %s", loc.name, e)
    stored = db.insert_observations(rows, int(os.environ.get("RETENTION_DAYS", "90")))
    log.info("stored %d observations, %d failed", stored, failed)
    return 1 if failed else 0  # non-zero marks the Job failed, which alerting picks up


if __name__ == "__main__":
    sys.exit(main())
