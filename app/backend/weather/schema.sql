-- Idempotent schema. Run by the migrate job before the app starts.
-- Additive changes only (ADD COLUMN IF NOT EXISTS, nullable): old and new app versions can run side by side during a rollout.
CREATE TABLE IF NOT EXISTS weather_observations (
    location        text             NOT NULL,
    observed_at     timestamptz      NOT NULL,
    latitude        double precision NOT NULL,
    longitude       double precision NOT NULL,
    temperature_c   real             NOT NULL,
    wind_speed_kmh  real             NOT NULL,
    weather_code    smallint         NOT NULL,
    collected_at    timestamptz      NOT NULL DEFAULT now(),
    -- PK index also serves both read queries (latest per location, history by time range).
    PRIMARY KEY (location, observed_at)
);

ALTER TABLE weather_observations
    ADD COLUMN IF NOT EXISTS apparent_temperature_c real,
    ADD COLUMN IF NOT EXISTS humidity_pct           smallint,
    ADD COLUMN IF NOT EXISTS wind_direction_deg     smallint,
    ADD COLUMN IF NOT EXISTS is_day                 boolean,
    ADD COLUMN IF NOT EXISTS utc_offset_seconds     integer;
