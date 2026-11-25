"""Backfill: load the last N days of hourly history from Open-Meteo into the database.

Runs once after install (Helm post-install hook). Why: a fresh environment (CI, demo, disaster recovery,
a new region) would otherwise start with an empty history. Real data from the provider, not synthetic.
Idempotent: ON CONFLICT DO NOTHING never overwrites rows the collector already stored.
"""
import logging
import os
import sys
from datetime import datetime, timezone

from weather import db
from weather.collector import fetch, row, utc_offset
from weather.config import load_locations

log = logging.getLogger("backfill")


def hourly_rows(location, payload: dict, now: datetime) -> tuple[list[dict], int]:
    """Turn Open-Meteo's column arrays into validated rows; skip future hours and bad samples."""
    offset = utc_offset(payload)
    hourly = payload["hourly"]
    rows, bad = [], 0
    for i in range(len(hourly["time"])):
        sample = {k: v[i] for k, v in hourly.items()}
        try:
            r = row(location, offset, sample)
        except (KeyError, ValueError, TypeError):
            bad += 1   # e.g. a null value for a not-yet-final hour
            continue
        if r["observed_at"] <= now:
            rows.append(r)
    return rows, bad


def main() -> int:
    logging.basicConfig(level=logging.INFO, format='{"level":"%(levelname)s","msg":"%(message)s"}')
    days = int(os.environ.get("BACKFILL_DAYS", "7"))
    locations = load_locations()
    try:
        payloads = fetch(locations, section="hourly", past_days=days, forecast_days=1)
    except Exception as e:  # upstream down / rate-limited after retries
        # Never fail a deploy because a third party is busy: the 15-min collector keeps filling history.
        log.warning("backfill skipped, weather API unavailable: %s", e)
        return 0
    now = datetime.now(timezone.utc)
    total = 0
    for loc, payload in zip(locations, payloads):
        rows, bad = hourly_rows(loc, payload, now)
        total += db.insert_observations(rows, int(os.environ.get("RETENTION_DAYS", "90")))
        log.info("%s: %d hourly rows (%d skipped)", loc.name, len(rows), bad)
    log.info("backfill done: %d rows for %d days", total, days)
    return 0


if __name__ == "__main__":
    sys.exit(main())
