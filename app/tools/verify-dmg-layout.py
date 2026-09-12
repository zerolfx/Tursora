#!/usr/bin/env python3
"""Check the read-only DMG's drag-install layout using the pinned ds_store reader."""

from pathlib import Path
import sys

from ds_store import DSStore

mount = Path(sys.argv[1])
with DSStore.open(str(mount / ".DS_Store"), "r") as store:
    for name, position in (("Tursora.app", (140, 120)), ("Applications", (500, 120))):
        if store[name]["Iloc"] != position:
            raise SystemExit(f"DMG icon position is incorrect for {name}.")
    window = store["."]["bwsp"]
    if window["WindowBounds"] != "{{100, 100}, {640, 280}}":
        raise SystemExit("DMG window bounds are incorrect.")
    view = store["."]["icvp"]
    if view["iconSize"] != 128 or view["backgroundType"] != 2:
        raise SystemExit("DMG icon size or arrow background is missing.")
print("DMG layout verified: application left, Applications right, arrow background.")
