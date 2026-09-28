"""
Cache behaviour of the HTTP backend, seen from one long-lived connection
(like a nix-daemon session) on host a while host b changes the store.
Run by test/smoke.sh:

  cache.py LIB FRONT_DB SERVER_URL STORE_B TOP REFERENCE...

where TOP is a registered path whose references are the REFERENCEs, TOP
has no referrers, and the server runs with --test-hooks.
"""

import json
import os
import sqlite3
import subprocess
import sys
import urllib.request

lib, front_db, server, store_b, top, *references = sys.argv[1:]
missing = "/nix/store/00000000000000000000000000000000-nixremote-missing"
failures = 0


def check(name, ok, detail=""):
    global failures
    print(f"{'ok  ' if ok else 'FAIL'} {name}" + ("" if ok else f": {detail}"))
    failures += not ok


def queries():
    req = urllib.request.Request(f"{server}/v1/test/stats", data=b"{}", headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req) as resp:
        return json.load(resp)["requests"].get("/v1/query", 0)


def host_b(*args):
    env = dict(os.environ, NIX_CONFIG=f"plugin-files = {lib}")
    subprocess.run(["nix", *args, "--store", store_b], env=env, check=True, capture_output=True)


conn = sqlite3.connect(front_db, isolation_level=None)
conn.enable_load_extension(True)
conn.load_extension(lib, entrypoint="sqlite3_nixremote_init")


def valid(path):
    # Nix's QueryPathInfo
    return conn.execute(
        "select id, hash, registrationTime, deriver, narSize, ultimate, sigs, ca from ValidPaths where path = ?",
        (path,),
    ).fetchone() is not None


def refs(path):
    # Nix's QueryReferences
    (id_,) = conn.execute("select id from ValidPaths where path = ?", (path,)).fetchone()
    return {r for (r,) in conn.execute("select path from Refs join ValidPaths on reference = id where referrer = ?", (id_,))}


def referrers(path):
    # Nix's QueryReferrers
    return {r for (r,) in conn.execute(
        "select path from Refs join ValidPaths on referrer = id where reference = (select id from ValidPaths where path = ?)",
        (path,),
    )}


def costs(name, expected, fn):
    """Run fn, checking it makes `expected` queries; return its result."""
    before = queries()
    result = fn()
    made = queries() - before
    check(f"{name} ({expected} {'query' if expected == 1 else 'queries'})", made == expected, f"made {made}")
    return result


costs("first lookup of a path prefetches its closure", 1, lambda: valid(top))
costs("second lookup is a cache hit", 0, lambda: valid(top))
got = costs("its references come from the cache", 0, lambda: refs(top))
check("references are right", got == set(references), f"{got} != {set(references)}")
costs("its references' rows are prefetched too", 0, lambda: all(valid(r) for r in references))
costs("referrers are never cached", 2, lambda: (referrers(references[0]), referrers(references[0])))
costs("absence is never cached", 2, lambda: (valid(missing), valid(missing)))

host_b("store", "delete", top)
check("a hit can be stale until the next response", costs("  ...which is a hit", 0, lambda: valid(top)))
costs("the next miss brings the new epoch", 1, lambda: valid(missing))
check("which drops the cache", not costs("  ...so the lookup goes to the server", 1, lambda: valid(top)))

host_b("copy", "--no-check-sigs", "--from", "daemon", top)
check("a path registered elsewhere shows up at once", costs("  ...as absence wasn't cached", 1, lambda: valid(top)))

# A commit that conflicts drops the cache, so that Nix's retry sees fresh data.
valid(top)
host_b("store", "delete", top)
conn.execute("begin")
try:
    conn.execute("update ValidPaths set sigs = 'test:sig' where path = ?", (top,))
    conn.execute("commit")
    check("updating a path deleted elsewhere conflicts", False, "commit succeeded")
except sqlite3.OperationalError as e:
    conn.execute("rollback")
    check("updating a path deleted elsewhere conflicts", "no longer registered" in str(e), str(e))
check("the conflict drops the cache", not costs("  ...so the retry's lookup goes to the server", 1, lambda: valid(top)))
host_b("copy", "--no-check-sigs", "--from", "daemon", top)

sys.exit(1 if failures else 0)
