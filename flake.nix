{
  description = "A cache-coherent virtual table for use as a Nix file store DB";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.stdenv.mkDerivation {
            pname = "nixremote";
            version = "0.1.0";
            src = self;
            nativeBuildInputs = [ pkgs.pkg-config ];
            buildInputs = [
              # Only the headers: the plugin binds to whatever libsqlite3 the
              # host process (Nix, or the sqlite3 shell) already has loaded.
              pkgs.sqlite.dev
              pkgs.curl
              # For patchShebangs on server/nixremote-server.
              pkgs.python3
            ];
            installFlags = [ "PREFIX=$(out)" ];
          };
        }
      );

      # Not a check: the test needs servers outside the build sandbox (see
      # test/nfs-cluster.nix), so `nix flake check` can't run it.
      legacyPackages =
        nixpkgs.lib.genAttrs
          [
            "aarch64-linux"
            "x86_64-linux"
          ]
          (system: {
            nfs-cluster-test = import ./test/nfs-cluster.nix {
              pkgs = nixpkgs.legacyPackages.${system};
              nixremote = self.packages.${system}.default;
            };
          });

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            inputsFrom = [ self.packages.${system}.default ];
            packages = [
              pkgs.sqlite
              pkgs.python3
            ];
          };
        }
      );
    };
}
