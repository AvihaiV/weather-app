-- One-time RDS bootstrap, run by an admin with the master credentials from Secrets Manager
-- (e.g. from a short-lived psql pod in the cluster). The app never uses the master user.
-- rds_iam = these users can only log in with IAM auth tokens; they have no password.
CREATE ROLE weather_migrate LOGIN;
CREATE ROLE weather_api LOGIN;
CREATE ROLE weather_collector LOGIN;
GRANT rds_iam TO weather_migrate, weather_api, weather_collector;

ALTER DATABASE weather OWNER TO weather_migrate;
\c weather
ALTER SCHEMA public OWNER TO weather_migrate;   -- migrate owns the schema; table grants are in app schema.sql
