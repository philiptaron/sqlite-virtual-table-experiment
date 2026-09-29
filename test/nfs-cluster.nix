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
        pkgs.curl
        pkgs.iptables
        pkgs.sqlite
      ];
      virtualisation.additionalPaths = [
        dropped
        applied
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
    busybox = "${pkgs.busybox}"
    dropped = "${dropped}"
    applied = "${applied}"
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

    def let_build_finish(m, round, state="/var/lib/nixremote"):
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
    # output lock. Then client1 comes back, and each builder finishes in
    # turn. What each build does is printed rather than checked, for now.

    with subtest("a client cut off mid-build, while another builds the same derivation"):
        client1.succeed("systemd-run --unit=cutoff --collect /run/current-system/sw/bin/cluster-build cutoff -A cutoff")
        client1.wait_until_succeeds("grep -qx started /shared/nix/store/*-nixremote-cutoff.drv.chroot/root/nix/store/*-nixremote-cutoff", timeout=120)
        cut_off(client1)
        start = time.monotonic()
        client2.succeed("systemd-run --unit=cutoff --collect /run/current-system/sw/bin/cluster-build cutoff -A cutoff")
        # client2's build directory appears once it has the output lock.
        client2.wait_until_succeeds("ls -d /var/lib/nixremote/builds/nix-*/build", timeout=300)
        print(f"with client1 cut off, client2 started building nixremote-cutoff after {time.monotonic() - start:.0f}s")
        reconnect(client1)
        report(client1, "cutoff", *let_build_finish(client1, "cutoff"))
        report(client2, "cutoff", *let_build_finish(client2, "cutoff"))
        client3.succeed("systemd-run --unit=cutoff --collect /run/current-system/sw/bin/cluster-build cutoff -A cutoff")
        rc, err = let_build_finish(client3, "cutoff")
        report(client3, "cutoff", rc, err)
        assert rc == "0", "client3 couldn't build nixremote-cutoff after client1 and client2"
        [cutoff] = client3.succeed("cat /tmp/cutoff.out").split()
        for m in clients:
            print(f"{m.name} reads {m.succeed(f'cat /shared{cutoff}')!r} from {cutoff}")

    with subtest("a client cut off mid-build, while another substitutes its output"):
        # client3 fills the binary cache from a build in a store of its own.
        fill = "/var/lib/cachefill"
        client3.succeed(f"nix copy --no-check-sigs --to {fill} {busybox}")
        client3.succeed(f"systemd-run --unit=fill --collect --setenv=STORE={fill} /run/current-system/sw/bin/cluster-build fill -A substituted")
        rc, err = let_build_finish(client3, "fill", f"{fill}/nix/var/nix")
        assert rc == "0", f"client3 couldn't fill the cache:\n{err}"
        [substituted] = client3.succeed("cat /tmp/fill.out").split()
        client3.succeed(f"nix copy --no-check-sigs --from {fill} --to file:///cache {substituted}")
        cached = client3.succeed(f"cat {fill}{substituted}")

        client1.succeed("systemd-run --unit=substituted --collect /run/current-system/sw/bin/cluster-build substituted -A substituted")
        client1.wait_until_succeeds("grep -qx started /shared/nix/store/*-nixremote-substituted.drv.chroot/root/nix/store/*-nixremote-substituted", timeout=120)
        cut_off(client1)
        start = time.monotonic()
        client2.succeed(
            f"systemd-run --unit=substituted --collect '--setenv=STORE={store}&require-sigs=false' "
            "/run/current-system/sw/bin/cluster-build substituted -A substituted --option substituters file:///cache"
        )
        rc, err = outcome(client2, "substituted")
        report(client2, "substituted", rc, err)
        print(f"with client1 cut off, client2 substituted nixremote-substituted after {time.monotonic() - start:.0f}s")
        assert rc == "0" and built(err) == [], "client2 should have substituted nixremote-substituted, not built it"
        reconnect(client1)
        report(client1, "substituted", *let_build_finish(client1, "substituted"))
        print(f"the cache holds {cached!r}")
        for m in clients:
            print(f"{m.name} reads {m.succeed(f'cat /shared{substituted}')!r} from {substituted}")
            status, out = m.execute(f"nix-store --store '{store}' --verify-path {substituted} 2>&1")
            print(f"{m.name}: --verify-path exited {status}: {out.strip()}")

    with subtest("in the end, every client agrees on the store's contents"):
        paths = f"{combined} {interrupted} {dropped} {applied} {cutoff} {substituted}"
        closures = {m.name: m.succeed(f"nix path-info --store '{store}' --json --json-format 1 {paths}") for m in clients}
        assert len(set(closures.values())) == 1, f"clients disagree in the end: {closures}"
        for m in clients:
            m.succeed(f"nix-store --store '{store}' --verify --check-contents")
  '';
}).overrideTestDerivation
  (_: {
    __noChroot = true;
  })
