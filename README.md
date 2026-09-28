# sqlite-virtual-table-experiment
A cache-coherent virtual table for use as a Nix file store DB

The goal: many hosts mount one read/write `/nix/store` over NFS. The files
are fine on NFS; Nix's SQLite database (`/nix/var/nix/db/db.sqlite`) is
not. So each host keeps a local, constant `db.sqlite` whose `ValidPaths`,
`Refs`, and `DerivationOutputs` tables are SQLite virtual tables, and every
read and write goes to one shared backend that provides consistency.

## Pieces

- `src/vtab.c`: the `nixremote` virtual table module. It serves the
  handful of statements Nix issues (see `src/libstore/local-store.cc`),
  maps SQLite transactions onto one backend transaction per connection
  (committed in `xSync`), and refuses deletes unless the host is allowed
  to garbage collect.
- `src/backend.h`: the boundary a web service client will implement.
  `src/backend_sqlite.c` is a stand-in that uses another SQLite file.
- `src/plugin.c`: a Nix plugin (`plugin-files`) that registers the module
  through `sqlite3_auto_extension` in the libsqlite3 Nix already has
  loaded. The library doesn't link libsqlite3 itself, so the same file
  also works with the sqlite3 shell's `.load`.
- `scripts/nixremote-mkstate`: creates a state directory whose `db.sqlite`
  points at a backend.

`ValidPaths.id` comes from the store path's hash part, not from
autoincrement, so every host computes the same id without asking the
backend. If another host registers a path between Nix's validity check and
its insert, the insert fails with `SQLITE_BUSY`. Nix then retries the
transaction and finds the path already valid.

## Try it

```sh
nix develop
make
scripts/nixremote-mkstate /tmp/state file:/tmp/remote.sqlite   # NIXREMOTE_LIB=$PWD/libnixremote.dylib
NIX_CONFIG="plugin-files = $PWD/libnixremote.dylib" \
  nix copy --to 'local?root=/tmp/root&state=/tmp/state' nixpkgs#hello
```

`NIX_DEBUG_SQLITE_TRACES=1` makes Nix print every statement it runs.

`test/smoke.sh` runs the whole thing against the `nix` on `PATH`. Two
simulated hosts share one store directory and one backend, and every query
is compared with a plain store.

## Not yet

- The backend is a local SQLite file, not a service.
- No caching, so every lookup goes to the backend.
- CA derivations (`BuildTraceV3`) are unsupported. With `ca-derivations`
  enabled, Nix fails to open the store rather than keep that table locally
  on one host.
- Nothing about NFS yet: locking, client caching, and write ordering are
  still ahead.
