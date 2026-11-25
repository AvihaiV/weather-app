"""Database access. All SQL is parameterized; no string formatting of user input."""
import os
from pathlib import Path

import psycopg
from psycopg.rows import dict_row

SCHEMA_FILE = Path(__file__).with_name("schema.sql")


def _password() -> str:
    # In AWS the pod gets a 15-minute IAM auth token via EKS Pod Identity: no stored DB password.
    if os.environ.get("DB_IAM_AUTH") == "true":
        import boto3

        return boto3.client("rds").generate_db_auth_token(
            DBHostname=os.environ["DB_HOST"],
            Port=int(os.environ.get("DB_PORT", "5432")),
            DBUsername=os.environ["DB_USER"],
        )
    return os.environ["DB_PASSWORD"]  # local docker compose only


def connect() -> psycopg.Connection:
    # shortcut: new connection per call, no pool. Fine at this traffic; add psycopg_pool if QPS grows.
    return psycopg.connect(
        host=os.environ["DB_HOST"],
        port=int(os.environ.get("DB_PORT", "5432")),
        dbname=os.environ.get("DB_NAME", "weather"),
        user=os.environ["DB_USER"],
        password=_password(),
        sslmode=os.environ.get("DB_SSLMODE", "verify-full"),
        sslrootcert=os.environ.get("DB_SSLROOTCERT"),
        connect_timeout=5,
        row_factory=dict_row,
    )


def migrate() -> None:
    with connect() as conn:
        conn.execute(SCHEMA_FILE.read_text())


def ping() -> None:
    with connect() as conn:
        conn.execute("SELECT 1")


def latest() -> list[dict]:
    with connect() as conn:
        return conn.execute(
            """WITH latest AS (
                   SELECT DISTINCT ON (location) * FROM weather_observations
                   ORDER BY location, observed_at DESC),
               day_range AS (
                   SELECT location, max(temperature_c) AS high_c, min(temperature_c) AS low_c
                   FROM weather_observations
                   WHERE observed_at > now() - interval '24 hours'
                   GROUP BY location)
               SELECT l.location, l.observed_at, l.temperature_c, l.apparent_temperature_c, l.humidity_pct,
                      l.wind_speed_kmh, l.wind_direction_deg, l.weather_code, l.is_day, l.utc_offset_seconds,
                      r.high_c, r.low_c
               FROM latest l LEFT JOIN day_range r USING (location)
               ORDER BY l.location"""
        ).fetchall()


def history(location: str, hours: int) -> list[dict]:
    with connect() as conn:
        return conn.execute(
            """SELECT observed_at, temperature_c, wind_speed_kmh, weather_code
               FROM weather_observations
               WHERE location = %s AND observed_at > now() - make_interval(hours => %s)
               ORDER BY observed_at""",
            (location, hours),
        ).fetchall()


def insert_observations(rows: list[dict], retention_days: int) -> int:
    with connect() as conn:
        with conn.cursor() as cur:
            # Idempotent: a retried run cannot create duplicates (PK = location, observed_at).
            cur.executemany(
                """INSERT INTO weather_observations
                   (location, observed_at, latitude, longitude, temperature_c, wind_speed_kmh, weather_code,
                    apparent_temperature_c, humidity_pct, wind_direction_deg, is_day, utc_offset_seconds)
                   VALUES (%(location)s, %(observed_at)s, %(latitude)s, %(longitude)s,
                           %(temperature_c)s, %(wind_speed_kmh)s, %(weather_code)s,
                           %(apparent_temperature_c)s, %(humidity_pct)s, %(wind_direction_deg)s,
                           %(is_day)s, %(utc_offset_seconds)s)
                   ON CONFLICT DO NOTHING""",
                rows,
            )
            cur.execute(
                "DELETE FROM weather_observations WHERE observed_at < now() - make_interval(days => %s)",
                (retention_days,),
            )
    return len(rows)
