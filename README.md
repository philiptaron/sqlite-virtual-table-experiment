# sqlite-virtual-table-experiment
A cache-coherent virtual table for use as a Nix file store DB

The goal: many hosts mount one read/write `/nix/store` over NFS. The files
are fine on NFS; Nix's SQLite database (`/nix/var/nix/db/db.sqlite`) is
not. So each host keeps a local, constant `db.sqlite` whose `ValidPaths`,
`Refs`, and `DerivationOutputs` tables, and for CA derivations
`BuildTraceV3`, are SQLite virtual tables, and every read and write goes
to one metadata service that provides consistency.

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
- `src/lock.c`: keeps a Nix process from acting on a store path after
  another host may have taken its lock: a watchdog that kills a process
  once its NFS server has been silent for too long, and a check that the
  process still holds a path's lock (see "A host that's cut off" below).
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

## CA derivations

With `ca-derivations`, Nix records what each derivation output was built
as in a fourth table, `BuildTraceV3`, and looks there to decide whether an
output needs building. `nixremote-mkstate` makes it a virtual table like
the others, and lists its schema migration, so that Nix doesn't try to
create it locally. Its ids aren't from a store path. The backend numbers
them, as Nix's schema does, and the HTTP backend makes up the id it hands
Nix for a new row, which Nix never reads.

Nix's schema has only an index on `(drvPath, outputName)`. The service
makes it unique, since a second row for the same output is what two hosts
racing to register it would make. The second host gets a 409, and Nix,
retrying, finds the first host's row. It then adds its signatures if it
built the same path, and fails if it built another. The service also
refuses to change a row's output path. Nothing caches the table.

Hosts don't build the same floating CA derivation twice, even though its
output path isn't known until it's built. Nix locks `<drv>.<output>` for
it instead, and that lock file is on NFS, next to the derivation.

The cluster test builds a floating CA derivation on every client at once.
Its output is a random UUID, so each build would get a path of its own.
Exactly one client built it. The others waited on the lock and then found
its row, and all three agree on the row. Then a client that didn't build
it builds a derivation that depends on it, without building it again.

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
off. A third, `retry=60`, is how many seconds a host keeps sending a
request whose connection failed (see "Either server restarting" below).

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
- all three build the same floating CA derivation at the same time, with
  the same outcome (see "CA derivations" above);
- one client builds a derivation over every client's output without
  rebuilding any of them;
- every client agrees on the closure and verifies the store's contents;
- client1 crashes partway through a build, and again partway through
  registering a path, both before and after its commit reaches the
  service (see below);
- client1 is cut off from the host partway through a build, while
  another client builds or substitutes the same output (see below);
- the metadata service is killed, and nfsd restarted, while clients are
  using them (see below).

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
  shortens the wait. The hosts' `lease=` has to shrink with it, so that
  one cut off from the server stops sooner too (see below).

### A host that's cut off

A host that loses the network doesn't crash, and it keeps building. Its
NFS mount is `hard`, so anything that touches NFS waits for the network
to come back, but its build directory is local. After the lease, nfsd
gives its locks to the next host that asks. When the network comes back,
its NFS client reopens by file handle the files that still exist, and
marks the lock lost (`recover_lost_locks` is off). Nix never touches its
lock file during a build, so it never learns that the lock is gone.

So the plugin stops it first (`src/lock.c`). Every request a host sends
the server renews its lease, for at least a lease from when it was sent.
In each Nix process that holds a lock on NFS, one thread asks the server
for `statfs` of each locked file every two seconds, and another kills the
process with SIGKILL once none of those has been answered for two thirds
of the lease: 60 seconds of nfsd's 90. The process is gone half a minute
before the server could give its locks away, and it does nothing once
the network is back, much as if the host had crashed (see above). It's
SIGKILL because cleaning up is exactly what the process mustn't do. The
lease is the `lease=` module argument, which `nixremote-mkstate --lease`
sets, 90 by default; it must be no longer than the server's `lease-time`.
`--lease 0` turns the watchdog off.

The test cuts client1 off (iptables drops everything to and from the
host) while it builds a derivation that waits for a local file partway
through, and lets each build carry on in turn. Every build of these
writes a random last line, so it's plain whose output ended up where.

- **For less than the deadline.** Cut off for 20 seconds, client1 carries
  on, and its build finishes.
- **Another host builds the same derivation.** The watchdog kills
  client1's nix-build 60 seconds in, and its builder dies with it. client2
  gets the lock after 105 seconds, deletes client1's chroot to make its
  own, and builds it.

  The killed process may not be gone yet. Exiting closes the lock file,
  which unlocks it, and the unlock is an NFS request. The thread doing it
  waits in the kernel for an answer that can't come until the network is
  back:

  ```
  rpc_wait_bit_killable < nfs4_proc_lock < locks_remove_flock
    < locks_remove_file < __fput < task_work_run < do_exit
  ```

  It's past running anything of Nix's by then, and the unlock reaches a
  server that has already dropped the host's state. It happened in about
  half of the runs; in the others, presumably, the host held a delegation
  for the lock file, which makes the unlock local.
- **Another host substitutes the output.** The same, except that client2
  gets the path from the binary cache. client1's chroot stays on the
  export for good, as a crashed host's would: the path is valid, so no
  one will build it again. The test deletes it.

Before the watchdog, client1 carried on once it was back, and:

- **building the same derivation**, found its chroot gone, so its builder
  failed (`Stale file handle`). Cleaning up, client1 deleted
  `<drv>.chroot` by its path, which was client2's chroot by then, so
  client2's builder failed the same way. Two builds were lost.
- **substituting**, finished its build, and went to register its output.
  Nix found it valid, which it expects only of CA derivations, and
  aborted on `assert(newInfo.ca)` (`derivation-builder.cc`). That
  assertion was all that stopped it moving its own output over the one
  client2 substituted.
- **whose build fails**, would move its half-built output out of the
  chroot to the store path, for debugging, over whatever another host put
  there, without asking whether the path is valid. The test can't show
  it: Nix looks for the output at the chroot plus the store's real path,
  `<drv>.chroot/root/shared/nix/store/...`, while the builder wrote it at
  `<drv>.chroot/root/nix/store/...`, so with the test's store at
  `/shared` it finds nothing to move. A host that mounts the store at
  `/nix/store` would move it.

### Without the watchdog

The plugin also checks that its process still holds a path's lock before
it answers that the path is invalid, and before it registers or changes
the path (see below). That covers what the watchdog can't: a host frozen
for longer than the lease (see below), a process stopped while its host
was cut off, or a `lease=` longer than the server's. The test checks it
from a second state directory on
client1, made with `nixremote-mkstate --lease 0`, so the watchdog is off:

- **Another host substitutes the output, and hasn't registered it yet.**
  The service holds client2's commit, so client1 comes back while
  client2's files are in place and the path is invalid. client1's build
  finishes, and it asks whether the path is valid, to decide whether to
  delete what's there and move its own output in. The plugin finds that
  client1 lost its lock and fails the query, so client1's build fails,
  and client2's files stay. client2's commit then goes through.
- **Another host registers the output just after this one finds it
  invalid.** The same, except that the service also holds its answer
  to client1 until client2's commit has landed. The plugin gets that the
  path is invalid, finds that client1 lost its lock, and fails the query.
  The outcome is the same.

Without the check, both corrupt the store. client1 deletes client2's
files and moves its own in, and the path ends up with client1's files
and the cache's hash. In the first case, that's because client2's commit
gets a 409, and on the retry Nix finds the path valid and updates the row
with its own hash. In the second, client2's commit was the one that
landed.

The service refuses any commit that changes a registered path's hash,
except the all-zero one Nix registers when it doesn't know a path's hash.
That's enough to make the first case safe without the plugin's check,
but not the second: there the files move before any commit, and the
service can't tell whether a host still holds the path's lock. It also
refuses `--repair` of a derivation that isn't reproducible, which gives
the path a new hash.

The check doesn't cover a failed build's move (above), a host cut off
between the check and its move, or a chroot deleted by its path.

### How a host tells it lost its lock

Only by asking the server. The test has a probe (`test/lockprobe.py`)
take a lock on the export like Nix's, on client1 and then on client2 once
client1 is cut off. Each tries what a process can check on its own
descriptor. On Linux 6.18:

| Check | client2, holding the lock | client1, having lost it |
|---|---|---|
| `fstat`, `pread`, `pwrite` of nothing | ok | ok |
| `pread` with `O_DIRECT` | ok | EIO |
| its line in `/proc/locks` | there | still there |
| `F_SETLK` again | ok | EAGAIN, since client2 holds it |

An NFS client that marks a lock lost fails reads and writes under it
with EIO, but the lock file is empty, so an ordinary read never reaches
the server. `O_DIRECT` makes it, and it fails as soon as client1 is
back. Taking the lock again isn't a check: with no one else holding it,
it may succeed. Closing another descriptor for the lock file is out too,
since that drops all of the process's locks on it.

So the plugin (`src/lock.c`) looks for a path's lock file among its
process's descriptors in `/proc/self/fd`, and reads each one on NFS with
`O_DIRECT`. If a read fails with EIO, or with ESTALE because another
host has deleted the lock file since, as Nix does once the path is
valid, the query or write fails with `SQLITE_IOERR`, which Nix doesn't
retry. It also fails if the watchdog has found the server silent past
its deadline and not yet killed the process. That costs a scan of
`/proc/self/fd` for each lookup that finds no path and each write of
one, plus a READ for each lock file it finds.

The watchdog finds a process's locks in `/proc/self/fdinfo`, which lists
a descriptor's locks only while they're held. It costs each process that
holds a lock a `statfs` to the server every two seconds. Both work only
on Linux.

### A host that's frozen

What the watchdog and the check leave open is a host frozen for longer
than the lease in the moment between the check and the move. A process
that's merely stopped (SIGSTOP, a debugger, a cgroup freezer) isn't a
risk: the lease is the host kernel's, which renews it all along, so the
process keeps its locks, and other hosts only wait. The risk is the
whole kernel stopping, as when a VM is paused or migrated, or a machine
suspended:

1. Nix asks whether its output is valid. The plugin's O_DIRECT read of
   the lock file succeeds, and the answer is that it isn't.
2. The host freezes before Nix's `deletePath(dest); movePath(chroot, dest)`,
   microseconds later.
3. It stays frozen for longer than the lease. nfsd drops its state, and
   another host takes the lock and substitutes or builds the path.
4. The host resumes. A paused VM's clock (kvmclock) typically doesn't show
   the pause, so the watchdog sees no silence and kills nothing.
5. Nix's REMOVE and RENAME go out on the old NFS session, and get
   `BADSESSION`. The kernel recovers without telling anyone: it sets up a
   new client, marks the lock lost, and sends them again. Namespace
   operations don't depend on locks, so they succeed, and the other
   host's files are replaced.

A host frozen anywhere else is caught when it resumes: the next check's
read fails with EIO. Closing the gap needs the moves to depend on
something the next holder of the lock destroys. Nix could stage each
output in a directory that every writer of the path deletes once it holds
the lock, and move both the old files out and its own in relative to
that directory's handle. A late move by a stale host would then fail
with ESTALE, which the kernel doesn't retry. That's a change to Nix's
`registerOutputs` and `addToStore`.

Meanwhile the plugin reports it. After the move, Nix asks again whether
the path is valid, and then registers it, and the check refuses both. It
can't tell whether the process has moved anything yet, so whenever the
check refuses, the plugin reports the path to the service (`/v1/suspect`)
before failing. The service lists what's been reported, with the hash
each is registered with (`/v1/suspects`), for someone to verify with
`nix-store --verify-path` and repair, and forgets a path once told to
(`{"clear": [...]}`). In the test, the two cut-off subtests without the
watchdog report their paths; both hold the other host's files and verify,
and `test/ci-host.sh verify` lists them. A report is best effort: a host
that can't reach the service fails without it.

### Either server restarting

**The metadata service.** A host sends a request again when its
connection fails, for up to `retry=` seconds (60 by default), backing off
from 0.1 to 2 seconds: when the service isn't there, or goes away before
answering. It doesn't for a timeout, or for an answer, even an error. A
commit may have been applied by a service that died before answering, so
each commit carries a random id, from `/dev/urandom` rather than SQLite's
generator, which the processes a Nix daemon forks would share. The
service records the ids it applies, in the same transaction, for an hour,
and answers a commit whose id it has seen as if it had just applied it.

The test has the host kill the service with SIGKILL (`test/host-control`)
and start it again 15 seconds later. First the service applies a commit
from client1, which is copying a path in, and holds its answer (the
`hold-replies` test hook), so client1 never hears it. Meanwhile, client2
looks a path up. Both wait for the service: client2's lookup took the 15
seconds, and client1's commit arrived again, and was counted as applied
already rather than applied twice. Without the id, it would have got a
409, since the path was registered already, and Nix would have retried
the whole transaction.

**nfsd.** Restarting it drops every client's opens and locks. With
`nfsdcld` tracking which clients it had, as on Ubuntu, it then starts a
90-second grace period in which only those clients' reclaims are
allowed, and ends it once they've all reclaimed. The test restarts it
while client1 builds a derivation that client2 is waiting to build.
client1 reclaimed its lock, and grace ended 43 or 44 seconds after the
restart.
Its build finished 59 seconds after the restart, and client2 went on
waiting, then found the output valid. The test doesn't cover a server
that can't tell which clients it had. That server would refuse their
reclaims, and a Nix process that held a lock would carry on without it,
with only the lock check to stop it (see above): the watchdog hears from
the server all along.

The test is a Nix build that requires the `kvm` feature, and it fails
unless every VM reports KVM (`systemd-detect-virt`), so it never falls
back to emulation. To see the host's servers it sets `__noChroot`, which
needs `sandbox = relaxed`. That is why it lives in `legacyPackages` rather
than `checks`.

`.github/workflows/nfs-cluster.yml` runs it on `ubuntu-latest`.
`test/ci-host.sh start` sets up the NFS export and the service on an
Ubuntu host, and starts recording NFS traffic. `test/host-control`, run as
root, runs the service and lets the test kill it or restart nfsd. After the test,
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
- The service stores its tables in SQLite, not Postgres, in one process.
- A host frozen for longer than the NFS lease, between the lock check and
  moving its output in, could still overwrite another host's files. The
  plugin reports the path for someone to verify, but can't prevent it
  (see "A host that's frozen").
- Nothing cleans up what a crashed or killed host leaves on the export:
  a chroot, or files it never registered. They go only when some host
  builds or adds the same path again, and a chroot whose output is valid
  never goes. Hosts can't garbage collect (`deletes=deny`), and nothing
  yet does it centrally.
- On NFS, only what the cluster test exercises is known to work: build
  locks across hosts, reading what another host wrote, with
  `delegation_watermark=0` on the hosts, and carrying on after a host
  crashes (see above), and a host that's cut off, which kills its Nix
  processes before another host can take their locks, on Linux (see
  above), and either server restarting.
