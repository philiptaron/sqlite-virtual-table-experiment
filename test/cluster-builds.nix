# What the clients in test/nfs-cluster.nix build, in the store they share.
#
# busybox is a store path already in the shared store; it is the only
# toolchain. client names the client doing the build, and clients lists
# them all.
{
  busybox,
  client ? "",
  clients ? [ ],
}:
let
  bb = builtins.storePath busybox;
  mk =
    name: script:
    derivation {
      inherit name;
      system = builtins.currentSystem;
      builder = "${bb}/bin/sh";
      args = [
        "-ec"
        script
      ];
      PATH = "${bb}/bin";
    };
  own = name: mk "nixremote-${name}" "cat ${shared} > $out; echo ${name} >> $out";
  shared = mk "nixremote-shared" "sleep 10; echo shared > $out";
in
{
  # Every client asks for this at once. The sleep keeps the first build
  # running while the others arrive, so they have to wait on its output
  # lock (a lock file on NFS) and then find the path already valid.
  inherit shared;
  # Only this client builds its own output.
  mine = own client;
  # Built from every client's output, on one client, without rebuilding any
  # of them.
  combined = mk "nixremote-combined" "cat ${toString (map own clients)} > $out";
}
