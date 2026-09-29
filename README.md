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
the store's files, `nixremote-server` holds its metadata, and a second
export holds a binary cache. The VMs reach them at `10.0.2.2`, which is
where QEMU's user-mode network puts the host's loopback. Each client
mounts the store's export at `/shared` and the cache at `/cache`, and
uses the store `local?root=/shared&state=/var/lib/nixremote`. Then:

- one client copies busybox in, and every client sees it as valid;
- all three build the same derivation at the same time. Its output lock
  is a file on NFS, so exactly one builds it, and the others wait and
  then find it valid;
- one client builds a derivation over every client's output without
  rebuilding any of them;
- every client agrees on the closure and verifies the store's contents;
- client1 crashes partway through a build, and again partway through
  registering a path, both before and after its commit reaches the
  service (see below);
- client1 is cut off from the host partway through a build, while
  another client builds or substitutes the same output (see below).

### Delegations: set `nfsv4.delegation_watermark=0` on every host

By default, reading what another host just wrote costs about 100ms per
file. nfsd gives the writer a write delegation on every file it creates.
The writer's Linux client keeps them, up to `delegation_watermark` (5000)
of them. Another host's OPEN of such a file gets NFS4ERR_DELAY while nfsd
recalls the delegation. The writer returns it within milliseconds, but
the reader's client waits 100ms before retrying (`NFS4_POLL_RETRY_MIN`,
fixed in the kernel). nfsd's OPEN doesn't wait for the recall, although
its SETATTR, RENAME, and UNLINK wait up to 30ms. The first client to
check busybox's roughly 900 files after client1 copied it in spent 95
seconds on this.

The hosts in the test set this, which they load as an `nfsv4` module
option, not `nfs`:

```
options nfsv4 delegation_watermark=0
```

A client then returns each delegation when the file is last closed. For
Nix that is right after writing it, before any other host reads it. The
same check took 2.4 seconds, and nfsd recalled 2 delegations instead of
904. The cost is a DELEGRETURN per file on the writer. The server keeps
its defaults.

nfsd has no per-export or write-only switch for delegations. The one
server-side alternative is `sysctl fs.leases-enable=0`, which stops
delegations of every kind for the whole host. It also took 2.5 seconds,
and suits a server that does nothing else. One of the test's subtests fails
if any client's failed OPENs reach 100, which is how a writer keeping its
delegations shows up. The trace step shows the details: NFS4ERR_DELAY and
recalls per connection, and each client's delegations sampled once a
second.

### Where a build writes

A sandboxed build's scratch space is local, and its outputs are on NFS
from the start. In Nix 2.35:

| In the sandbox | On the host | On NFS? |
|---|---|---|
| `/build`: `TMPDIR`, the working directory | `<state>/builds/nix-*/build`, so `/var/lib/nixremote/builds` | no |
| each output, `/nix/store/<out>` | `/shared/nix/store/<drv>.chroot/root/nix/store/<out>` | yes |
| the chroot's `/tmp` and `/etc` | also in `<drv>.chroot/root` | yes |
| inputs | bind-mounted (directories) or hard-linked from the store | yes, read |

The build directory is `build-dir`, which defaults to `builds` in the
state directory, and the store URL's `state=` puts that on local disk.
Unpacking and compiling never touch NFS, unless a builder writes to
`/tmp` and ignores `TMPDIR`. Each output is written over NFS once, while
it's being built, and then renamed into place on the same export. Nix
puts the chroot next to the derivation so that this move is a rename;
moving the chroot elsewhere would make it a copy.

### A host that crashes

The other hosts carry on correctly, but anything the dead host was
writing is stuck for about 105 seconds. The test crashes client1 three
times (QEMU quits without syncing), and boots it again after each:

- **Mid-build.** client1 leaves half an output in `<drv>.chroot` on the
  export (see above), nothing at the output path, and nothing
  registered. Its build directory stays on its own disk, where the test
  doesn't look. client2 and client3 then build the same derivation. One
  of them builds it, deleting the old chroot first, and the other finds
  it valid. That took 125 seconds, 20 of them building.
- **Files copied, commit never arrived.** The service holds client1's
  commit, and drops it after the crash (`--test-hooks`). The files stay
  on the export, unregistered. client2 copies the same path 104 seconds
  later: Nix takes the path's lock, finds the path invalid, deletes the
  files, and copies it again.
- **Commit arrived, client1 never heard back.** The service applies it
  after the crash. The path's contents verify on every host: Nix closes
  every file before registering the path, and an NFS client writes a file
  back when it's closed.

The wait is nfsd's lease. The dead host held its Nix lock file open, and
with it a write delegation, which `delegation_watermark=0` returns only
on close. Every other host's OPEN of that lock file gets NFS4ERR_DELAY
while nfsd tries to recall the delegation from a host that can't answer.
The retries back off to one every 15 seconds (`NFS4_POLL_RETRY_MAX`).
After 90 seconds (the lease), nfsd drops the dead host's state, lock
included, and the next retry succeeds.

Two things follow:

- Files a dead host left behind are cleaned up only when another host
  builds or adds the same path. Nothing else deletes them, since hosts
  can't delete (`deletes=deny`). `test/ci-host.sh verify` fails on any it
  finds.
- A shorter lease (`lease-time` in `/etc/nfs.conf`, 10 seconds at least)
  shortens the wait. It also means a host cut off from the server for
  longer than that loses its locks while it may still be building, which
  goes wrong in the ways below.

### A host that's cut off

A host that loses the network doesn't crash, and it keeps building. Its
NFS mount is `hard`, so anything that touches NFS waits for the network
to come back, but its build directory is local. After the lease, nfsd
gives its locks to the next host that asks. When the network comes back,
its NFS client reopens by file handle the files that still exist, and
marks the lock lost (`recover_lost_locks` is off). Nix never touches its
lock file during a build, so it never learns that the lock is gone.

The test cuts client1 off (iptables drops everything to and from the
host) while it builds a derivation that waits for a local file partway
through, and lets each build carry on in turn. Every build of these
writes a random last line, so it's plain whose output ended up where.

- **Another host builds the same derivation.** client2 gets the lock
  after 106 seconds and deletes client1's chroot to make its own. When
  client1 comes back, its builder fails (`Stale file handle`). Cleaning
  up, client1 deletes `<drv>.chroot` by its path, which is client2's
  chroot now, so client2's builder fails the same way. client3 then
  builds it. Two builds are lost, and nothing is corrupted.
- **Another host substitutes the output.** client2 gets the path from the
  binary cache after 104 seconds; substituting needs no chroot, so
  client1's survives. When client1 comes back, its build finishes. Nix
  goes to register the output, finds it valid, which it expects only of
  CA derivations, and aborts on `assert(newInfo.ca)`
  (`derivation-builder.cc`). That assertion is all that stops it moving
  its own output over the one client2 substituted. The abort skips
  cleanup, so client1's chroot stays on the export for good: the path is
  valid, so no one will build it again. The test deletes it.
- **Another host substitutes the output, and hasn't registered it yet.**
  As above, but the service holds client2's commit, so client1 comes
  back while client2's files are in place and the path is invalid.
  client1's build finishes, and it deletes client2's files, moves its
  own in, and registers them; the NFS client logs `lost 1 locks`, and
  Nix ignores `cannot close lock file`. Then client2's commit gets a 409,
  and on the retry Nix finds the path valid and goes to update its row
  with client2's hash. The service refuses that (422, below), so client2's
  substitution fails, and the path holds client1's output with client1's
  hash. Without that check, both would succeed and the store would be
  corrupted: client1's files with the cache's hash, failing
  `--verify-path` on every host.

The service refuses any commit that changes a registered path's hash,
except the all-zero one Nix registers when it doesn't know a path's
hash. That makes the third case safe, but not every ordering of it. If
client2's commit lands after client1 has found the path invalid but
before it moves its output in, client1's retry is the one refused, with
its files already in place, and the path is corrupted anyway. The
service can't tell whether a host still holds the path's lock, and the
files move before any commit. The check also refuses `--repair` of a
derivation that isn't reproducible, which gives the path a new hash.

The test is a Nix build that requires the `kvm` feature, and it fails
unless every VM reports KVM (`systemd-detect-virt`), so it never falls
back to emulation. To see the host's servers it sets `__noChroot`, which
needs `sandbox = relaxed`. That is why it lives in `legacyPackages` rather
than `checks`.

`.github/workflows/nfs-cluster.yml` runs it on `ubuntu-latest`.
`test/ci-host.sh start` sets up the NFS export and the service on an
Ubuntu host, and starts recording NFS traffic. After the test,
`test/ci-host.sh verify` checks that the service's paths and the export's
files match, and that each one's contents have the hash the service
holds, and `test/ci-host.sh nfs-trace` summarizes the recording. The
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
  locks across hosts, reading what another host wrote, with
  `delegation_watermark=0` on the hosts, and carrying on after a host
  crashes (see above). A host that's cut off can still overwrite a path
  another host has just registered (see above), and nothing stops it:
  the service can't tell whether a host still holds the path's lock. Either
  server restarting is still ahead.
