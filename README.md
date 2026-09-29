# sqlite-virtual-table-experiment
A cache-coherent virtual table for use as a Nix file store DB

The goal: many hosts mount one read/write `/nix/store` over NFS. The files
are fine on NFS; Nix's SQLite database (`/nix/var/nix/db/db.sqlite`) is
not. So each host keeps a local, constant `db.sqlite` whose `ValidPaths`,
`Refs`, and `DerivationOutputs` tables are SQLite virtual tables, and every
read and write goes to one metadata service that provides consistency.

## Pieces

- `src/vtab.c`: the `nixremote` virtual table module. It serves the
  handful of statements Nix issues (see `src/libstore/local-store.cc`),
  maps SQLite transactions onto one backend transaction per connection
  (committed in `xSync`), and refuses deletes unless the host is allowed
  to garbage collect.
- `src/backend.h`: the interface a backend implements. The URI scheme
  picks one of these:
  - `src/backend_http.c` (`http://`, `https://`) is the client for the
    metadata service. It holds a transaction's writes and sends them as one
    atomic commit. Reads inside the transaction see that transaction's own
    `ValidPaths` writes. It caches only what stays true while a path is
    valid (see below).
  - `src/backend_sqlite.c` (`file:`) opens a shared SQLite file directly,
    for experiments.
- `server/nixremote-server`: a reference implementation of the metadata
  service, written in Python (standard library only) over SQLite. The
  protocol, documented at the top of `src/backend_http.c`, is the contract;
  a Postgres-backed service can replace this one.
- `src/plugin.c`: a Nix plugin (`plugin-files`) that registers the module
  through `sqlite3_auto_extension` in the libsqlite3 Nix already has
  loaded. The library doesn't link libsqlite3 itself, so the same file
  also works with the sqlite3 shell's `.load`.
- `scripts/nixremote-mkstate`: creates a state directory whose `db.sqlite`
  points at a backend.

`ValidPaths.id` comes from the store path's hash part, not from
autoincrement. Every host computes the same id without asking anyone, and
Nix can get a new path's id immediately, even though the commit is
buffered. When a transaction conflicts with another host's changes, the
service answers 409. The host turns that into `SQLITE_BUSY`, Nix retries
the transaction, and on the retry it re-checks what it relied on.

## Caching

A host caches a path's row, its references, and its derivation outputs,
because those don't change while the path is valid. It never caches
absence, referrers, or derivers: another host can add to those at any
moment, and Nix re-checks validity after taking a lock, expecting a fresh
answer. A lookup that misses the cache also brings back (prefetches) the
path's closure, up to 500 paths breadth first, so walking a closure costs
about one request.

The cache is dropped when:

- a response carries a new epoch, which the service bumps whenever a
  commit deletes or changes a path;
- a commit conflicts;
- a single entry is older than 60 seconds;
- the database connection closes, which happens at the end of every Nix
  process and every daemon session.

So a cached answer can be stale, but only until the host's next request
that the cache can't answer. Staleness also can't cause a bad write,
because the service checks every commit against its current state.

Both settings are URL parameters, for example
`http://host:port?cache_ttl=60&prefetch=500`. `cache_ttl=0` turns the cache
off.

## Try it

```sh
nix develop
make
server/nixremote-server --db /tmp/remote.sqlite --listen 127.0.0.1:8080 &
NIXREMOTE_LIB=$PWD/libnixremote.dylib scripts/nixremote-mkstate /tmp/state http://127.0.0.1:8080
NIX_CONFIG="plugin-files = $PWD/libnixremote.dylib" \
  nix copy --to 'local?root=/tmp/root&state=/tmp/state' nixpkgs#hello
```

`NIX_DEBUG_SQLITE_TRACES=1` makes Nix print every statement it runs, and
`nixremote-server -v` logs every request.

`test/smoke.sh [http|sqlite]` runs the whole thing against the `nix` on
`PATH`. Two simulated hosts share one store directory and one backend, and
every query is compared with a plain store. With `http`, it also injects a
commit conflict (`--test-hooks`) and checks that Nix retries through it.
`test/cache.py` then checks the cache's request counts and invalidation
from a single long-lived connection.

## A cluster over NFS

`test/nfs-cluster.nix` is a NixOS test with three client VMs. The servers
run outside the VMs, on the machine running the test: an NFS export holds
the store's files and `nixremote-server` holds its metadata. The VMs reach
both at `10.0.2.2`, which is where QEMU's user-mode network puts the
host's loopback. Each client mounts the export at `/shared` and uses the
store `local?root=/shared&state=/var/lib/nixremote`. Then:

- one client copies busybox in, and every client sees it as valid;
- all three build the same derivation at the same time. Its output lock
  is a file on NFS, so exactly one builds it, and the others wait and
  then find it valid;
- one client builds a derivation over every client's output without
  rebuilding any of them;
- every client agrees on the closure and verifies the store's contents.

The test found that reading what another host just wrote is slow, about
100ms per file. nfsd gives the writer a write delegation on every file it
creates, and the writer keeps them. A reader's OPEN of such a file gets
NFS4ERR_DELAY while nfsd recalls the delegation. The writer returns it
within milliseconds, but the reader's Linux client waits about 100ms
before retrying. The first client to check busybox's roughly 900 files
after client1 copied it in spent 95 seconds on this, against 2.5 seconds
with delegations turned off (`fs.leases-enable=0` on the server). The
trace step shows it: counts of NFS4ERR_DELAY per connection, the
recalls, and each client's delegations sampled once a second.

The test is a Nix build that requires the `kvm` feature, and it fails
unless every VM reports KVM (`systemd-detect-virt`), so it never falls
back to emulation. To see the host's servers it sets `__noChroot`, which
needs `sandbox = relaxed`. That is why it lives in `legacyPackages` rather
than `checks`.

`.github/workflows/nfs-cluster.yml` runs it on `ubuntu-latest`.
`test/ci-host.sh start` sets up the NFS export and the service on an
Ubuntu host, and starts recording NFS traffic. After the test,
`test/ci-host.sh verify` checks that the service's paths and the export's
files match, and `test/ci-host.sh nfs-trace` summarizes the recording. The
workflow uploads the full capture as the `nfs-trace` artifact. To run it by hand on such a
host, with `sandbox = relaxed` and `kvm` in `system-features` in
`nix.conf`:

```sh
test/ci-host.sh start
nix build -L .#legacyPackages.x86_64-linux.nfs-cluster-test
test/ci-host.sh verify
```

## Not yet

- Registering paths still costs a few round trips per path, mostly Nix
  asking whether each path is valid yet. Those answers can't be cached.
- The service stores its tables in SQLite, not Postgres.
- CA derivations (`BuildTraceV3`) are unsupported. With `ca-derivations`
  enabled, Nix fails to open the store rather than keep that table locally
  on one host.
- On NFS, only what the cluster test exercises is known to work: build
  locks across hosts and reading what another host wrote. Reading what
  another host wrote costs about 100ms per file while nfsd hands out
  write delegations (see above). Client caching and write ordering under
  failures are still ahead.
