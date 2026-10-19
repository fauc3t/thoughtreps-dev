#!/usr/bin/env python3
"""Pass check for a sync scenario: the two devices' status snapshots must show the same end state.

    python3 -I scripts/sync-pass-check.py <status-a.json> <status-b.json>

Each snapshot is the file the app writes after every sync cycle (SyncDebugSession.StatusSnapshot). Exits 0 when both show an
empty outbox, nothing parked or held, no stop reason and no error, and the same thought count and content digest; otherwise
prints what differs and exits 1. Reads only; never prints more than counts and a digest prefix.
"""
import json
import sys


def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError) as e:
        return {"unreadable": str(e)}


def problems(name, status):
    if "unreadable" in status:
        return ["%s: no status snapshot (%s)" % (name, status["unreadable"])]
    found = []
    for key in ("thoughts", "digest", "parked", "held"):
        if key not in status:
            found.append("%s: the snapshot has no %s (no cycle finished after the last change?)" % (name, key))
    if status.get("outbox") != 0:
        found.append("%s: outbox is %s, not 0" % (name, status.get("outbox")))
    for key in ("parked", "held"):
        if status.get(key, 0) != 0:
            found.append("%s: %s is %s, not 0" % (name, key, status.get(key)))
    for key in ("attention", "lastError"):
        if status.get(key):
            found.append("%s: %s is set: %s" % (name, key, status.get(key)))
    return found


def main(argv):
    if len(argv) != 3:
        sys.exit("usage: sync-pass-check.py <status-a.json> <status-b.json>")
    a, b = load(argv[1]), load(argv[2])
    found = problems("device A", a) + problems("device B", b)
    if not found:
        if a["thoughts"] != b["thoughts"]:
            found.append("thought counts differ: A %s, B %s" % (a["thoughts"], b["thoughts"]))
        if a["digest"] != b["digest"]:
            found.append("content digests differ: A %s, B %s" % (a["digest"][:12], b["digest"][:12]))
    for line in found:
        print(line)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
