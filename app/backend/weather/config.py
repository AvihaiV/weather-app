"""Configuration loaded from environment and the locations file (a ConfigMap in K8s)."""
import json
import os
from dataclasses import dataclass
from functools import cache


@dataclass(frozen=True)
class Location:
    name: str
    lat: float
    lon: float


@cache
def load_locations(path: str | None = None) -> tuple[Location, ...]:
    path = path or os.environ.get("LOCATIONS_FILE", "locations.json")
    with open(path, encoding="utf-8") as f:
        raw = json.load(f)
    locations = tuple(Location(str(r["name"]), float(r["lat"]), float(r["lon"])) for r in raw)
    for loc in locations:
        # Fail fast on a bad config instead of sending garbage to the weather API.
        if not loc.name or len(loc.name) > 64:
            raise ValueError(f"invalid location name: {loc.name!r}")
        if not (-90 <= loc.lat <= 90 and -180 <= loc.lon <= 180):
            raise ValueError(f"invalid coordinates for {loc.name}")
    if len({loc.name for loc in locations}) != len(locations):
        raise ValueError("duplicate location names")
    return locations
