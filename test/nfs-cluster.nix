# Several NixOS VMs sharing one Nix store: the files on NFS, the metadata
# in nixremote-server. Both servers run on the machine running the test,
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

  client =
    { config, pkgs, ... }:
    let
      nix = config.nix.package;
      # cluster-build ROUND ARGS...: nix-build test/cluster-builds.nix in the
      # shared store, leaving /tmp/ROUND.{out,err,rc}.
      clusterBuild = pkgs.writeShellScriptBin "cluster-build" ''
        round=$1
        shift
        rc=0
        ${nix}/bin/nix-build --store '${store}' ${./cluster-builds.nix} --no-out-link \
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
        pkgs.sqlite
      ];
    };
in
(pkgs.testers.runNixOSTest {
  name = "nixremote-nfs-cluster";

  nodes = pkgs.lib.genAttrs clients (_: client);

  testScript = ''
    import re

    store = "${store}"
    busybox = "${pkgs.busybox}"
    clients = [${toString (map (c: "${c},") clients)}]

    def build_everywhere(round, args):
        """Start the same build on every client at once, wait for all of
        them, and return each one's (output paths, stderr)."""
        for m in clients:
            m.succeed(f"systemd-run --unit={round} --collect /run/current-system/sw/bin/cluster-build {round} {args}")
        return {m.name: finished(m, round) for m in clients}

    def finished(m, round):
        m.wait_until_succeeds(f"test -e /tmp/{round}.rc", timeout=900)
        err = m.succeed(f"cat /tmp/{round}.err")
        rc = m.succeed(f"cat /tmp/{round}.rc").strip()
        assert rc == "0", f"{m.name}: nix-build exited {rc}:\n{err}"
        return m.succeed(f"cat /tmp/{round}.out").split(), err

    def built(err):
        """The names of the derivations a nix-build actually built."""
        return re.findall(r"^building '/nix/store/[a-z0-9]+-([^']+)\.drv'", err, re.M)

    def slow_nfs_ops(m):
        """The NFS operations on /shared that m has spent over a second on,
        in total, as {op: (count, milliseconds)}."""
        [stats] = [d for d in m.succeed("cat /proc/self/mountstats").split("device ") if " mounted on /shared " in d]
        ops = {}
        # ops, transmissions, timeouts, bytes sent, bytes received, then
        # milliseconds queued, in flight, and in total (then errors).
        for op, fields in re.findall(r"^\s+([A-Z_]+): (\d+(?: \d+){7,})$", stats, re.M):
            f = list(map(int, fields.split()))
            if f[7] > 1000:
                ops[op] = (f[0], f[7])
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
            m.succeed("mkdir -p /shared && mount -t nfs4 -o vers=4.2 ${host}:/ /shared")
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

    # Not an assertion, but a stall waiting on NFS shows up here.
    for m in clients:
        print(f"{m.name}: NFS operations taking over a second in total: {slow_nfs_ops(m) or 'none'}")
  '';
}).overrideTestDerivation
  (_: {
    __noChroot = true;
  })
