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
    `ValidPaths` writes.
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

## Not yet

- No caching. Every lookup is a round trip, and SQLite resolves Nix's
  references join one row at a time: `nix path-info -r` on 3 paths makes
  12 requests.
- The service stores its tables in SQLite, not Postgres.
- CA derivations (`BuildTraceV3`) are unsupported. With `ca-derivations`
  enabled, Nix fails to open the store rather than keep that table locally
  on one host.
- Nothing about NFS yet: locking, client caching, and write ordering are
  still ahead.
