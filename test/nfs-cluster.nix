# Several NixOS VMs sharing one Nix store: the files on NFS, the metadata
# in nixremote-server, and a binary cache on another NFS export. Both servers run on the machine running the test,
# outside the VMs (test/ci-host.sh starts them); the VMs reach it at
# 10.0.2.2, QEMU's user-mode network address for the host's loopback.
#
# The test runs as a Nix build that needs the kvm system feature, but it
# has to see the host's network, so it sets __noChroot and needs
# `sandbox = relaxed`. It fails unless every VM runs under KVM.
{ pkgs, nixremote }:
let
  host = "10.0.2.2";
  backend = "http://${host}:8080";
  # The shared store: files at /shared/nix/store (the NFS mount), and a
  # local state directory whose db.sqlite points at the backend.
  store = "local?root=/shared&state=/var/lib/nixremote";
  clients = [
    "client1"
    "client2"
    "client3"
  ];
  # Store paths without references for a client to copy in and crash while
  # committing: 20 files of about 1MB each.
  payload =
    name:
    pkgs.runCommand "nixremote-${name}" { } ''
      mkdir $out
      for i in $(seq 20); do seq -f "${name} $i %06g" 60000 > $out/$i; done
    '';
  dropped = payload "dropped";
  applied = payload "applied";
  # For a client to copy in while the metadata service restarts.
  replayed = payload "replayed";

  client =
    { config, pkgs, ... }:
    let
      nix = config.nix.package;
      # cluster-build ROUND ARGS...: nix-build test/cluster-builds.nix in the
      # shared store, or in $STORE, leaving /tmp/ROUND.{out,err,rc}.
      clusterBuild = pkgs.writeShellScriptBin "cluster-build" ''
        round=$1
        shift
        rc=0
        ${nix}/bin/nix-build --store "''${STORE:-${store}}" ${./cluster-builds.nix} --no-out-link \
          --argstr busybox ${pkgs.busybox} \
          --argstr client ${config.networking.hostName} \
          --arg clients '[ ${toString (map (c: ''"${c}"'') clients)} ]' \
          "$@" >/tmp/"$round".out 2>/tmp/"$round".err || rc=$?
        echo $rc >/tmp/"$round".rc
      '';
      lockProbe = pkgs.writeShellScriptBin "lockprobe" ''exec ${pkgs.python3}/bin/python3 ${./lockprobe.py} "$@"'';
      # logged ROUND COMMAND...: run COMMAND, leaving /tmp/ROUND.{out,err,rc}.
      logged = pkgs.writeShellScriptBin "logged" ''
        round=$1
        shift
        rc=0
        "$@" >/tmp/"$round".out 2>/tmp/"$round".err || rc=$?
        echo $rc >/tmp/"$round".rc
      '';
    in
    {
      virtualisation.memorySize = 1536;
      boot.supportedFilesystems = [ "nfs" ];
      # Return each delegation when the file is last closed, rather than
      # keeping up to 5000 of them. Otherwise a host that wrote a store path
      # holds a write delegation on every file in it, and each other host's
      # first open of each file waits for a recall: NFS4ERR_DELAY, then a
      # retry 100ms later.
      boot.extraModprobeConfig = "options nfsv4 delegation_watermark=0";
      # QEMU's user-mode network. Each VM has its own, so they can all be
      # 10.0.2.15.
      networking.useDHCP = false;
      networking.interfaces.eth0.ipv4.addresses = [
        {
          address = "10.0.2.15";
          prefixLength = 24;
        }
      ];

      # The version whose schema migrations nixremote-mkstate lists.
      nix.package = pkgs.nixVersions.nix_2_35;
      nix.settings = {
        experimental-features = [ "nix-command" ];
        plugin-files = [ "${nixremote}/lib/libnixremote.so" ];
      };

      environment.systemPackages = [
        nixremote
        clusterBuild
        lockProbe
        logged
        pkgs.curl
        pkgs.iptables
        pkgs.sqlite
      ];
      virtualisation.additionalPaths = [
        dropped
        applied
        replayed
      ];
    };
in
(pkgs.testers.runNixOSTest {
  name = "nixremote-nfs-cluster";

  nodes = pkgs.lib.genAttrs clients (_: client);

  testScript = ''
    import json
    import re
    import time

    store = "${store}"
    # client1 also has a state directory whose watchdog is off, for the
    # subtests of what happens without it.
    guarded = "/var/lib/nixremote"
    unguarded = "/var/lib/nixremote-unguarded"
    busybox = "${pkgs.busybox}"
    dropped = "${dropped}"
    applied = "${applied}"
    replayed = "${replayed}"
    clients = [${toString (map (c: "${c},") clients)}]

    def build_everywhere(round, args, machines=clients):
        """Start the same build on every client at once, wait for all of
        them, and return each one's (output paths, stderr)."""
        for m in machines:
            m.succeed(f"systemd-run --unit={round} --collect /run/current-system/sw/bin/cluster-build {round} {args}")
        return {m.name: finished(m, round) for m in machines}

    def outcome(m, round):
        """Wait for a cluster-build round to end, and return its exit code
        and stderr."""
        m.wait_until_succeeds(f"test -e /tmp/{round}.rc", timeout=900)
        return m.succeed(f"cat /tmp/{round}.rc").strip(), m.succeed(f"cat /tmp/{round}.err")

    def finished(m, round):
        rc, err = outcome(m, round)
        assert rc == "0", f"{m.name}: nix-build exited {rc}:\n{err}"
        return m.succeed(f"cat /tmp/{round}.out").split(), err

    def let_build_finish(m, round, state=guarded):
        """Once m is running a build that waits for go (see
        cluster-builds.nix), let it carry on; then wait for the round to
        end, and return its exit code and stderr."""
        builds = f"{state}/builds/nix-*/build"
        m.wait_until_succeeds(f"test -e /tmp/{round}.rc || ls -d {builds}", timeout=900)
        m.execute(f"for d in {builds}; do touch $d/go; done")
        return outcome(m, round)

    def report(m, round, rc, err):
        tail = "\n".join(err.strip().splitlines()[-8:])
        print(f"{m.name}'s {round} exited {rc}:\n{tail}")

    def built(err):
        """The names of the derivations a nix-build actually built."""
        return re.findall(r"^building '/nix/store/[a-z0-9]+-([^']+)\.drv'", err, re.M)

    def mount_shared(m):
        m.succeed("mkdir -p /shared /cache")
        m.succeed("mount -t nfs4 -o vers=4.2 ${host}:/srv/nixremote /shared")
        m.succeed("mount -t nfs4 -o vers=4.2 ${host}:/srv/nixremote-cache /cache")

    def cut_off(m):
        """Drop everything between m and the host, both ways. m doesn't
        crash: its NFS mount (hard) and the service just stop answering."""
        m.succeed("iptables -w -I OUTPUT -d ${host} -j DROP && iptables -w -I INPUT -s ${host} -j DROP")

    def reconnect(m):
        m.succeed("iptables -w -D OUTPUT -d ${host} -j DROP && iptables -w -D INPUT -s ${host} -j DROP")

    def cut_off_mid_build(m, name, state=guarded):
        """Have m build name (see cluster-builds.nix), and cut it off once
        its output is half written. Return when it was cut off."""
        m.succeed(
            f"systemd-run --unit={name} --collect '--setenv=STORE=local?root=/shared&state={state}' "
            f"/run/current-system/sw/bin/cluster-build {name} -A {name}"
        )
        m.wait_until_succeeds(f"grep -qx started /shared/nix/store/*-nixremote-{name}.drv.chroot/root/nix/store/*-nixremote-{name}", timeout=120)
        cut_off(m)
        return time.monotonic()

    # A shell test that each thread of every nix-build has exited, or is in
    # the kernel on its way out. No single quotes, to go inside sh -c '...'.
    exiting = ("for p in $(pgrep -x nix-build); do for t in /proc/$p/task/*; do "
               "read -r _ _ st _ <$t/stat; [ $st = Z ] || grep -q do_exit $t/stack || exit 1; done; done")

    def killed(m, round, since, state=guarded):
        """Wait for the watchdog to kill m's nix-build while m is cut off,
        and clear away what it left on m's own disk: its build directory,
        and its builder if that outlived it.

        Exiting closes the lock file, which unlocks it: an NFS request, and
        the thread doing that waits for the answer, which can't come until
        m is back. (Unless m holds a delegation for the file, when the
        unlock is local.) So the process may not be gone yet, only past the
        point where it could run anything of Nix's."""
        m.wait_until_succeeds(f"grep -q 'no answer from the NFS server' /tmp/{round}.err", timeout=100)
        print(f"{m.name}'s nix-build was killed {time.monotonic() - since:.0f}s after it was cut off")
        if m.execute(f"timeout 20 sh -c 'until [ -e /tmp/{round}.rc ] || ({exiting}); do sleep 1; done'")[0] != 0:
            print(m.execute("timeout 10 ps -eLo pid,tid,stat,wchan:32,etimes,args | grep -v ' \\['")[1])
            print(m.execute("for p in $(pgrep -x nix-build); do for t in /proc/$p/task/*; do echo \"== $t: $(cat $t/comm)\"; timeout 5 cat $t/stack; done; done")[1])
            raise AssertionError(f"{m.name}'s nix-build should have been exiting by now")
        waiting = m.execute(f"test -e /tmp/{round}.rc")[0] != 0
        print(f"{m.name}'s nix-build {'is waiting to unlock its lock file' if waiting else 'has exited'}")
        survivors = m.execute("pgrep -af '[s]leep 0.2'")[1].strip()
        print(f"{m.name}'s builder {'outlived it: ' + survivors if survivors else 'died with it'}")
        m.execute(f"pkill -f '[s]leep 0.2'; rm -rf {state}/builds/nix-*")

    def reaped(m, round):
        """Once m is back, check that its nix-build was killed."""
        rc, err = outcome(m, round)
        report(m, round, rc, err)
        assert rc == "137", f"the watchdog should have killed {m.name}'s nix-build, not let it exit {rc}"

    def fill_cache(name):
        """Build name in a store of client3's own, and copy it to the binary
        cache. Return its path and contents."""
        fill = "/var/lib/cachefill"
        client3.succeed(f"nix copy --no-check-sigs --to {fill} {busybox}")
        client3.succeed(f"systemd-run --unit=fill-{name} --collect --setenv=STORE={fill} /run/current-system/sw/bin/cluster-build fill-{name} -A {name}")
        rc, err = let_build_finish(client3, f"fill-{name}", f"{fill}/nix/var/nix")
        assert rc == "0", f"client3 couldn't fill the cache with nixremote-{name}:\n{err}"
        [path] = client3.succeed(f"cat /tmp/fill-{name}.out").split()
        client3.succeed(f"nix copy --no-check-sigs --from {fill} --to file:///cache {path}")
        return path, client3.succeed(f"cat {fill}{path}")

    def substitute(m, name):
        """Have m get name from the binary cache, in the background."""
        m.succeed(
            f"systemd-run --unit={name} --collect '--setenv=STORE={store}&require-sigs=false' "
            f"/run/current-system/sw/bin/cluster-build {name} -A {name} --option substituters file:///cache"
        )

    def hook(name, body="{}"):
        """Call one of the metadata service's test hooks, from client3,
        which never crashes."""
        return json.loads(client3.succeed(f"curl -sf -H 'Content-Type: application/json' -d '{body}' ${backend}/v1/test/{name}"))

    def crash_while_committing(m, path, drop):
        """Have m copy path into the store, and crash it once the service
        has its commit. Then apply the commit, or drop it as if it had never
        arrived."""
        hook("hold-commits")
        m.succeed(f"systemd-run --unit=copy --collect /run/current-system/sw/bin/nix copy --no-check-sigs --to '{store}' {path}")
        client3.wait_until_succeeds("curl -sf -d '{}' ${backend}/v1/test/stats | grep -q '\"held\": 1'", timeout=120)
        m.crash()
        released = hook("release-commits", json.dumps({"drop": drop}))
        assert released == {"released": 1}, f"released {released}, want the one commit {m.name} sent"

    def suspects():
        """The paths hosts have reported acting on without their lock."""
        listed = client3.succeed("curl -sf -H 'Content-Type: application/json' -d '{}' ${backend}/v1/suspects")
        return {s["path"] for s in json.loads(listed)["suspects"]}

    def host(name, body="{}"):
        """Have the host kill the metadata service or restart the NFS server
        (test/host-control), from client3."""
        return json.loads(client3.succeed(f"curl -sf -H 'Content-Type: application/json' -d '{body}' http://${host}:8081/v1/{name}"))

    def restart(m):
        """Boot m again after a crash, with the store mounted again."""
        m.start()
        m.wait_for_unit("multi-user.target")
        mount_shared(m)

    def notable_nfs_ops(m):
        """The NFS operations on /shared that m has spent over a second on
        in total, or that have failed, as {op: (count, milliseconds,
        errors)}. Time spent backing off before a retry isn't counted, but
        the error that caused it is."""
        [stats] = [d for d in m.succeed("cat /proc/self/mountstats").split("device ") if " mounted on /shared " in d]
        ops = {}
        # ops, transmissions, timeouts, bytes sent, bytes received,
        # milliseconds queued, in flight, and in total, errors.
        for op, fields in re.findall(r"^\s+([A-Z_]+): (\d+(?: \d+){8})$", stats, re.M):
            f = list(map(int, fields.split()))
            if f[7] > 1000 or f[8] > 0:
                ops[op] = (f[0], f[7], f[8])
        return ops

    start_all()

    with subtest("every client runs under KVM"):
        for m in clients:
            m.wait_for_unit("multi-user.target")
            virt = m.execute("systemd-detect-virt")[1].strip()
            assert virt == "kvm", f"{m.name} is virtualised by {virt!r}, not KVM"

    with subtest("every client mounts the host's store and uses its metadata service"):
        for m in clients:
            m.succeed("curl -sf ${backend}/v1/health")
            mount_shared(m)
            watermark = m.succeed("cat /sys/module/nfsv4/parameters/delegation_watermark").strip()
            assert watermark == "0", f"{m.name} has delegation_watermark={watermark}, want 0"
            m.succeed("nixremote-mkstate /var/lib/nixremote ${backend}")
        client1.succeed("nixremote-mkstate --lease 0 /var/lib/nixremote-unguarded ${backend}")

    with subtest("a path one client copies in is valid on every client"):
        client1.succeed(f"nix copy --no-check-sigs --to '{store}' {busybox}")
        for m in clients:
            m.succeed(f"nix path-info --store '{store}' {busybox}")
            m.succeed(f"test -x /shared{busybox}/bin/sh")

    with subtest("clients building the same derivation at once build it once"):
        results = build_everywhere("concurrent", "-A shared -A mine")
        shared = {out[0] for out, _ in results.values()}
        assert len(shared) == 1, f"clients disagree on the shared output: {shared}"
        builders = [name for name, (_, err) in results.items() if "nixremote-shared" in built(err)]
        assert len(builders) == 1, f"nixremote-shared was built by {builders}, want exactly one client"
        for name, (_, err) in results.items():
            assert f"nixremote-{name}" in built(err), f"{name} did not build its own output:\n{err}"

    with subtest("a client builds on the others' outputs without rebuilding them"):
        client3.succeed("/run/current-system/sw/bin/cluster-build combined -A combined")
        [combined], err = finished(client3, "combined")
        assert built(err) == ["nixremote-combined"], f"client3 built {built(err)}, want only nixremote-combined:\n{err}"
        want = "".join(f"shared\n{m.name}\n" for m in clients)
        for m in clients:
            got = m.succeed(f"cat /shared{combined}")
            assert got == want, f"{m.name} reads {got!r} from {combined}, want {want!r}"

    with subtest("clients building the same CA derivation at once build it once, and agree on what it was built as"):
        ca = "--extra-experimental-features ca-derivations"
        results = build_everywhere("ca", f"-A ca {ca}")
        outs = {out[0] for out, _ in results.values()}
        assert len(outs) == 1, f"clients disagree on nixremote-ca's output: {outs}"
        [ca_out] = outs
        builders = [name for name, (_, err) in results.items() if "nixremote-ca" in built(err)]
        assert len(builders) == 1, f"nixremote-ca was built by {builders}, want exactly one client"
        drv = client1.succeed(f"nix-store --store '{store}' -q --deriver {ca_out}").strip()
        traces = {m.name: m.succeed(f"nix realisation info --store '{store}' {ca} --json '{drv}^out'") for m in clients}
        print(f"{drv}^out: {traces['client1']}")
        assert len(set(traces.values())) == 1 and ca_out in traces["client1"], f"clients disagree on what {drv}^out was built as: {traces}"
        other = next(m for m in clients if m.name not in builders)
        other.succeed(f"/run/current-system/sw/bin/cluster-build ca-user -A ca-user {ca}")
        [ca_user], err = finished(other, "ca-user")
        assert built(err) == ["nixremote-ca-user"], f"{other.name} built {built(err)}, want only nixremote-ca-user:\n{err}"
        want = other.succeed(f"cat /shared{ca_out}")
        for m in clients:
            got = m.succeed(f"cat /shared{ca_user}")
            assert got == want, f"{m.name} reads {got!r} from {ca_user}, want {want!r}"

    with subtest("and then no client builds anything"):
        client1.succeed("/run/current-system/sw/bin/cluster-build again -A combined")
        _, err = finished(client1, "again")
        assert built(err) == [], f"client1 rebuilt {built(err)}"

    with subtest("every client agrees on the store's contents"):
        closures = {m.name: m.succeed(f"nix path-info --store '{store}' -r --json --json-format 1 {combined}") for m in clients}
        assert len(set(closures.values())) == 1, f"clients disagree on the closure of {combined}: {closures}"
        for m in clients:
            m.succeed(f"nix-store --store '{store}' --verify --check-contents")

    with subtest("reading what another client wrote doesn't wait on delegation recalls"):
        # Each recall shows up as a failed OPEN: NFS4ERR_DELAY, then a retry
        # about 100ms later. With the writer keeping its delegations, the
        # first client to verify busybox failed about 900 of them and took
        # 95 seconds; with delegation_watermark=0, a few.
        for m in clients:
            ops = notable_nfs_ops(m)
            print(f"{m.name}: NFS operations over a second or with errors (count, ms, errors): {ops or 'none'}")
            failed_opens = sum(ops.get(op, (0, 0, 0))[2] for op in ("OPEN", "OPEN_NOATTR"))
            assert failed_opens < 100, f"{m.name} failed {failed_opens} OPENs; is a writer keeping its delegations?"

    # The rest crash client1 and boot it again, so they come after
    # everything that reads its NFS statistics.

    with subtest("a build whose client crashes is built again by another client"):
        # client1 dies holding the output lock, a lock on NFS that nothing
        # will release until the NFS server gives up on client1. It leaves
        # half of the output in the build's chroot, which is next to the
        # derivation on NFS; the output moves into place only when the build
        # is done, and is registered after that.
        chroot = "/shared/nix/store/*-nixremote-interrupted.drv.chroot"
        client1.succeed("systemd-run --unit=interrupted --collect /run/current-system/sw/bin/cluster-build interrupted -A interrupted")
        client1.wait_until_succeeds(f"grep -qx started {chroot}/root/nix/store/*-nixremote-interrupted", timeout=120)
        client1.crash()
        start = time.monotonic()
        results = build_everywhere("resumed", "-A interrupted", [client2, client3])
        print(f"with client1 down, client2 and client3 built nixremote-interrupted in {time.monotonic() - start:.0f}s")
        outs = {out[0] for out, _ in results.values()}
        assert len(outs) == 1, f"clients disagree on nixremote-interrupted: {outs}"
        [interrupted] = outs
        builders = [name for name, (_, err) in results.items() if "nixremote-interrupted" in built(err)]
        assert len(builders) == 1, f"nixremote-interrupted was built by {builders}, want exactly one client"
        for m in (client2, client3):
            got = m.succeed(f"cat /shared{interrupted}")
            assert got == "started\nfinished\n", f"{m.name} reads {got!r} from {interrupted}"
        # Whoever builds a derivation deletes its old chroot first.
        client2.fail(f"ls -d {chroot}")

    with subtest("the crashed client comes back and sees what the others built"):
        restart(client1)
        client1.succeed(f"nix-store --store '{store}' --verify-path {interrupted}")
        client1.succeed("/run/current-system/sw/bin/cluster-build rebooted -A combined -A interrupted")
        _, err = finished(client1, "rebooted")
        assert built(err) == [], f"client1 rebuilt {built(err)} after its crash"

    with subtest("files a client wrote but crashed before registering are replaced"):
        crash_while_committing(client1, dropped, drop=True)
        # Nothing refers to them, and nothing will delete them: deletes=deny.
        client2.succeed(f"test -s /shared{dropped}/20")
        client2.fail(f"nix path-info --store '{store}' {dropped}")
        # client1 died holding the path's lock too.
        start = time.monotonic()
        client2.succeed(f"nix copy --no-check-sigs --to '{store}' {dropped}")
        print(f"with client1 down, client2 copied nixremote-dropped in {time.monotonic() - start:.0f}s")
        client3.succeed(f"nix-store --store '{store}' --verify-path {dropped}")
        restart(client1)

    with subtest("a commit applied after its client crashed registers complete files"):
        # The service had the whole request; client1 never hears the answer.
        # Nix closes every file before registering the path, and NFS writes
        # a file back on close, so its contents are on the server already.
        crash_while_committing(client1, applied, drop=False)
        for m in (client2, client3):
            m.succeed(f"nix-store --store '{store}' --verify-path {applied}")
        restart(client1)
        client1.succeed(f"nix-store --store '{store}' --verify-path {applied}")

    # A client cut off from the host rather than crashed. Its mount is hard,
    # so whatever touches NFS waits, but its builder waits on a local file
    # and carries on. Once nfsd's lease runs out, another client takes the
    # output lock. Nix never learns that client1 lost the lock, but the
    # plugin's watchdog kills a Nix process that holds a lock on NFS once
    # it has heard nothing from the server for two thirds of the lease.

    with subtest("a client cut off for less than the watchdog's deadline carries on"):
        cut_off_mid_build(client1, "blip")
        time.sleep(20)
        reconnect(client1)
        rc, err = let_build_finish(client1, "blip")
        report(client1, "blip", rc, err)
        assert rc == "0", f"client1's build of nixremote-blip should have survived a 20s cut-off, not exited {rc}"

    with subtest("a client cut off mid-build, while another builds the same derivation"):
        since = cut_off_mid_build(client1, "cutoff")
        client2.succeed("systemd-run --unit=cutoff --collect /run/current-system/sw/bin/cluster-build cutoff -A cutoff")
        killed(client1, "cutoff", since)
        # client2's build directory appears once it has the output lock, and
        # its builder runs once it has made its chroot, deleting client1's.
        client2.wait_until_succeeds("ls -d /var/lib/nixremote/builds/nix-*/build", timeout=300)
        client2.wait_until_succeeds("pgrep -f 'd[o] sleep 0.2'", timeout=60)
        print(f"with client1 cut off, client2 started building nixremote-cutoff after {time.monotonic() - since:.0f}s")
        # client1's nix-build is gone, so it can't delete client2's chroot.
        reconnect(client1)
        reaped(client1, "cutoff")
        rc, err = let_build_finish(client2, "cutoff")
        report(client2, "cutoff", rc, err)
        assert rc == "0", f"client2's build of nixremote-cutoff should have succeeded, not exited {rc}"
        [cutoff] = client2.succeed("cat /tmp/cutoff.out").split()
        for m in clients:
            m.succeed(f"nix-store --store '{store}' --verify-path {cutoff}")

    with subtest("a client cut off mid-build, while another substitutes its output"):
        substituted, cached = fill_cache("substituted")
        since = cut_off_mid_build(client1, "substituted")
        substitute(client2, "substituted")
        killed(client1, "substituted", since)
        rc, err = outcome(client2, "substituted")
        report(client2, "substituted", rc, err)
        print(f"with client1 cut off, client2 substituted nixremote-substituted after {time.monotonic() - since:.0f}s")
        assert rc == "0" and built(err) == [], "client2 should have substituted nixremote-substituted, not built it"
        reconnect(client1)
        reaped(client1, "substituted")
        for m in clients:
            got = m.succeed(f"cat /shared{substituted}")
            assert got == cached, f"{m.name} reads {got!r} from {substituted}, not the cache's {cached!r}"
            m.succeed(f"nix-store --store '{store}' --verify-path {substituted}")
        # Killed, client1 left its chroot behind, as a crashed client would,
        # and nothing else will delete it: the path is valid, so no one
        # builds it again.
        client3.succeed("rm -r /shared/nix/store/*-nixremote-substituted.drv.chroot")

    # The rest of these are without the watchdog, from client1's other state
    # directory: what the plugin's check that it holds the lock catches.

    with subtest("without the watchdog, a client cut off mid-build, while another substitutes its output but has yet to register it"):
        # As above, except that the service holds client2's commit. client1
        # comes back and finishes while client2's files are in place but not
        # yet registered.
        raced, cached = fill_cache("raced")
        cut_off_mid_build(client1, "raced", unguarded)
        # Only the next commit to register raced waits, which is client2's.
        hook("hold-commits", json.dumps({"path": raced, "count": 1}))
        start = time.monotonic()
        substitute(client2, "raced")
        client3.wait_until_succeeds("curl -sf -d '{}' ${backend}/v1/test/stats | grep -q '\"held\": 1'", timeout=300)
        print(f"with client1 cut off, client2 substituted nixremote-raced after {time.monotonic() - start:.0f}s, and has yet to register it")
        got = client3.succeed(f"cat /shared{raced}")
        assert got == cached, f"client3 reads {got!r} from {raced} before client2 registers it, not the cache's {cached!r}"
        reconnect(client1)
        # client1 goes to ask whether raced is valid, which it isn't yet, to
        # decide whether to delete what's there and move its own output in.
        # The plugin finds that client1 has lost its lock on raced, and
        # fails the query instead (src/lock.c).
        rc, err = let_build_finish(client1, "raced", unguarded)
        report(client1, "raced", rc, err)
        assert rc != "0" and "lost its lock on" in err, f"client1's build of nixremote-raced should have been stopped, not exited {rc}"
        # It can't tell whether it had moved its output in already, so it
        # reports the path as suspect.
        assert "reporting it as suspect" in err and raced in suspects(), f"client1 should have reported {raced} as suspect: {suspects()}"
        got = client3.succeed(f"cat /shared{raced}")
        assert got == cached, f"client3 reads {got!r} from {raced}; client1 should have left client2's files alone"
        released = hook("release-commits")
        assert released == {"released": 1}, f"released {released}, want client2's one commit"
        rc, err = outcome(client2, "raced")
        report(client2, "raced", rc, err)
        assert rc == "0", f"client2's substitution of nixremote-raced should have succeeded, not exited {rc}"
        for m in clients:
            got = m.succeed(f"cat /shared{raced}")
            assert got == cached, f"{m.name} reads {got!r} from {raced}, not the cache's {cached!r}"
            m.succeed(f"nix-store --store '{store}' --verify-path {raced}")

    with subtest("without the watchdog, a client cut off mid-build, whose check that its output is invalid is overtaken by another's commit"):
        # As above, except that client2's commit lands after client1 has
        # found the path invalid, and before it moves its output in: the
        # service holds its answer to client1.
        overtaken, cached = fill_cache("overtaken")
        cut_off_mid_build(client1, "overtaken", unguarded)
        hook("hold-commits", json.dumps({"path": overtaken, "count": 1}))
        start = time.monotonic()
        substitute(client2, "overtaken")
        client3.wait_until_succeeds("curl -sf -d '{}' ${backend}/v1/test/stats | grep -q '\"held\": 1'", timeout=300)
        print(f"with client1 cut off, client2 substituted nixremote-overtaken after {time.monotonic() - start:.0f}s, and has yet to register it")
        # Once its builder is done, the first thing client1 asks about
        # overtaken is whether it's valid, to decide whether to move its
        # output in (derivation-builder.cc).
        hook("hold-queries", json.dumps({"path": overtaken, "count": 1}))
        reconnect(client1)
        client1.succeed(f"for d in {unguarded}/builds/nix-*/build; do touch $d/go; done")
        client3.wait_until_succeeds("curl -sf -d '{}' ${backend}/v1/test/stats | grep -q '\"held_queries\": 1'", timeout=120)
        released = hook("release-commits")
        assert released == {"released": 1}, f"released {released}, want client2's one commit"
        rc, err = outcome(client2, "overtaken")
        report(client2, "overtaken", rc, err)
        assert rc == "0", f"client2's substitution of nixremote-overtaken should have succeeded, not exited {rc}"
        client3.succeed(f"nix-store --store '{store}' --verify-path {overtaken}")
        # The plugin gets the answer that overtaken is invalid, though client2
        # has just registered it. Before passing that on, it finds that
        # client1 has lost its lock on overtaken, and fails the query
        # instead, so client1 never deletes client2's files.
        released = hook("release-queries")
        assert released == {"released": 1}, f"released {released}, want client1's one query"
        rc, err = outcome(client1, "overtaken")
        report(client1, "overtaken", rc, err)
        assert rc != "0" and "lost its lock on" in err, f"client1's build of nixremote-overtaken should have been stopped, not exited {rc}"
        assert "reporting it as suspect" in err and overtaken in suspects(), f"client1 should have reported {overtaken} as suspect: {suspects()}"
        for m in clients:
            got = m.succeed(f"cat /shared{overtaken}")
            assert got == cached, f"{m.name} reads {got!r} from {overtaken}, not the cache's {cached!r}"
            m.succeed(f"nix-store --store '{store}' --verify-path {overtaken}")

    with subtest("what a client that lost its lock can tell"):
        # A lock on the export like Nix's, taken by client1 before it's cut
        # off, and by client2 once nfsd's lease runs out. Each then tries
        # what a process could check about its own lock (lockprobe.py):
        # client2 while it holds it, and client1 once it's back, both right
        # away and once its kernel has logged the lock lost.
        lock = "/shared/nixremote-probe.lock"
        client1.succeed(f"systemd-run --unit=lockprobe --collect /run/current-system/sw/bin/lockprobe {lock} /tmp/probe-go /tmp/probe.out")
        client1.wait_until_succeeds("grep -qx locked /tmp/probe.out", timeout=60)
        # The earlier subtests lost client1 some locks too.
        losses = client1.succeed("dmesg | grep -c 'lost .* locks' || true").strip()
        cut_off(client1)
        start = time.monotonic()
        client2.succeed("touch /tmp/probe-go /tmp/probe-go.again")
        client2.succeed(f"systemd-run --unit=lockprobe --collect /run/current-system/sw/bin/lockprobe {lock} /tmp/probe-go /tmp/probe.out")
        client2.wait_until_succeeds("grep -q '\"again\"' /tmp/probe.out", timeout=300)
        print(f"with client1 cut off, client2 took the lock after {time.monotonic() - start:.0f}s")
        reconnect(client1)
        client1.succeed("touch /tmp/probe-go")
        client1.wait_until_succeeds("grep -q '\"first\"' /tmp/probe.out", timeout=300)
        client1.wait_until_succeeds(f"[ $(dmesg | grep -c 'lost .* locks') -gt {losses} ]", timeout=120)
        lost = client1.succeed("dmesg | grep 'lost .* locks' | tail -n1")
        print(f"client1's kernel says: {lost.strip()}")
        client1.succeed("touch /tmp/probe-go.again")
        client1.wait_until_succeeds("grep -q '\"again\"' /tmp/probe.out", timeout=300)
        probes = {}
        for m in (client2, client1):
            print(f"{m.name}, {'holding the lock' if m == client2 else 'having lost it'}:")
            for line in m.succeed("grep '^{' /tmp/probe.out").splitlines():
                print(f"  {line}")
                probe = json.loads(line)
                probes[m.name, probe["round"]] = probe
        # Only a read that has to reach the server tells: the file is empty,
        # so an ordinary read never does. /proc/locks keeps the lost lock,
        # and taking it again might just succeed if no one else had it.
        for round in ("first", "again"):
            assert probes["client2", round]["pread O_DIRECT"].startswith("ok"), f"client2's O_DIRECT read of its own lock failed: {probes['client2', round]}"
            assert probes["client1", round]["pread O_DIRECT"] == "EIO", f"client1's O_DIRECT read didn't show its lock lost: {probes['client1', round]}"
            assert probes["client1", round]["pread"].startswith("ok"), f"client1's ordinary read now shows its lock lost: {probes['client1', round]}"
        for m in (client1, client2):
            m.succeed("touch /tmp/probe-go.exit")
            m.wait_until_succeeds("! systemctl is-active lockprobe", timeout=60)
        client3.succeed(f"rm {lock}")

    with subtest("clients carry on while the metadata service is down, and a commit it applied without answering is applied once"):
        # client1 copies a path in. The service applies the commit, and is
        # killed before it answers. client1 sends the commit again until the
        # service is back, which finds it applied already.
        hook("hold-replies", json.dumps({"path": replayed, "count": 1}))
        client1.succeed(f"systemd-run --unit=replayed --collect /run/current-system/sw/bin/logged replayed /run/current-system/sw/bin/nix copy --no-check-sigs --to '{store}' {replayed}")
        client3.wait_until_succeeds("curl -sf -d '{}' ${backend}/v1/test/stats | grep -q '\"held_replies\": 1'", timeout=120)
        host("kill-service", json.dumps({"down": 15}))
        start = time.monotonic()
        # A new process, so nothing it asks is cached.
        client2.succeed(f"/run/current-system/sw/bin/logged downtime /run/current-system/sw/bin/nix path-info --store '{store}' {busybox}")
        rc, err = outcome(client2, "downtime")
        report(client2, "downtime", rc, err)
        print(f"client2's lookup took {time.monotonic() - start:.0f}s with the service down for 15s")
        assert rc == "0" and "trying again" in err, f"client2's lookup should have waited for the service, not exited {rc}"
        rc, err = outcome(client1, "replayed")
        report(client1, "replayed", rc, err)
        assert rc == "0" and "trying again" in err, f"client1's copy should have sent its commit again, not exited {rc}"
        stats = hook("stats")
        assert stats["repeated"] == 1, f"the service should have seen client1's commit once more, having applied it: {stats}"
        for m in clients:
            m.succeed(f"nix-store --store '{store}' --verify-path {replayed}")

    with subtest("clients building the same derivation while the NFS server restarts build it once"):
        # client1 holds the output lock through the restart, reclaiming it
        # in nfsd's grace period, so client2 goes on waiting for it.
        client1.succeed("systemd-run --unit=nfsrestart --collect /run/current-system/sw/bin/cluster-build nfsrestart -A nfsrestart")
        client1.wait_until_succeeds("grep -qx started /shared/nix/store/*-nixremote-nfsrestart.drv.chroot/root/nix/store/*-nixremote-nfsrestart", timeout=120)
        client2.succeed("systemd-run --unit=nfsrestart --collect /run/current-system/sw/bin/cluster-build nfsrestart -A nfsrestart")
        restarted = host("restart-nfsd")
        print(f"the host restarted nfsd in {restarted['seconds']:.1f}s")
        start = time.monotonic()
        rc, err = let_build_finish(client1, "nfsrestart")
        report(client1, "nfsrestart", rc, err)
        print(f"client1 finished nixremote-nfsrestart {time.monotonic() - start:.0f}s after nfsd restarted")
        assert rc == "0", f"client1's build of nixremote-nfsrestart should have survived nfsd restarting, not exited {rc}"
        [nfsrestart] = client1.succeed("cat /tmp/nfsrestart.out").split()
        out, err = finished(client2, "nfsrestart")
        assert out == [nfsrestart] and built(err) == [], f"client2 should have waited for client1's lock, and found nixremote-nfsrestart valid:\n{err}"
        for m in clients:
            m.succeed(f"nix-store --store '{store}' --verify-path {nfsrestart}")

    with subtest("in the end, every client agrees on the store's contents"):
        paths = f"{combined} {ca_out} {ca_user} {interrupted} {dropped} {applied} {cutoff} {substituted} {raced} {overtaken} {replayed} {nfsrestart}"
        closures = {m.name: m.succeed(f"nix path-info --store '{store}' --json --json-format 1 {paths}") for m in clients}
        # Only the two that client1 stopped at without the watchdog; both
        # hold client2's files, and verify below.
        assert suspects() == {raced, overtaken}, f"the service lists {suspects()} as suspect, want {raced} and {overtaken}"
        assert len(set(closures.values())) == 1, f"clients disagree in the end: {closures}"
        for m in clients:
            m.succeed(f"nix-store --store '{store}' --verify --check-contents")
  '';
}).overrideTestDerivation
  (_: {
    __noChroot = true;
  })
