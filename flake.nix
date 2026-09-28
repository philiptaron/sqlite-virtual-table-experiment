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
            # Only the headers: the plugin binds to whatever libsqlite3 the
            # host process (Nix, or the sqlite3 shell) already has loaded.
            buildInputs = [ pkgs.sqlite.dev ];
            installFlags = [ "PREFIX=$(out)" ];
          };
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            inputsFrom = [ self.packages.${system}.default ];
            packages = [ pkgs.sqlite ];
          };
        }
      );
    };
}
