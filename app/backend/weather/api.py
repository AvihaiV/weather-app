"""Read-only HTTP API. Only /api/* is reachable from outside (via the frontend proxy)."""
import logging
import time

from fastapi import FastAPI, HTTPException, Query, Request
from fastapi.responses import PlainTextResponse
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest

from weather import db
from weather.config import load_locations

log = logging.getLogger("api")

# Interactive docs disabled: no need to publish the API surface to the internet.
app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)

REQUESTS = Counter("http_requests_total", "HTTP requests", ["route", "status"])
LATENCY = Histogram("http_request_duration_seconds", "HTTP latency", ["route"])


@app.middleware("http")
async def metrics(request: Request, call_next):
    start = time.perf_counter()
    response = await call_next(request)
    # Route template, not raw path: keeps metric cardinality bounded.
    route = getattr(request.scope.get("route"), "path", "unmatched")
    REQUESTS.labels(route, str(response.status_code)).inc()
    LATENCY.labels(route).observe(time.perf_counter() - start)
    return response


@app.get("/healthz")
def healthz():
    return {"status": "ok"}  # liveness: process is up; must not depend on the DB


@app.get("/readyz")
def readyz():
    try:
        db.ping()
    except Exception:
        log.exception("readiness check failed")
        raise HTTPException(503, "database unavailable")
    return {"status": "ready"}


@app.get("/metrics")
def metrics_endpoint():
    return PlainTextResponse(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.get("/api/weather/current")
def current():
    try:
        return db.latest()
    except Exception:
        log.exception("query failed")
        raise HTTPException(503, "temporarily unavailable")


@app.get("/api/weather/history")
def history(location: str = Query(max_length=64), hours: int = Query(24, ge=1, le=24 * 90)):
    # Allow-list: only configured locations can be queried.
    if location not in {l.name for l in load_locations()}:
        raise HTTPException(404, "unknown location")
    try:
        return db.history(location, hours)
    except Exception:
        log.exception("query failed")
        raise HTTPException(503, "temporarily unavailable")
