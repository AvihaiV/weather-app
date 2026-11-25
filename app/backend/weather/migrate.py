"""Applies schema.sql. Runs as a one-shot Job before the API rolls out."""
from weather import db

if __name__ == "__main__":
    db.migrate()
    print("schema applied")
