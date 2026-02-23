{
  description = "BLIP: Byte Length Integer Prefix encoding";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            zig
            hyperfine
          ];
        };

        packages.default = pkgs.stdenv.mkDerivation {
          pname = "blip";
          version = "0.1.0";
          src = ./.;
          nativeBuildInputs = [ pkgs.zig ];
          dontConfigure = true;
          dontInstall = true;
          doCheck = true;
          buildPhase = ''
            mkdir -p .cache
            zig build --cache-dir $(pwd)/.cache --global-cache-dir $(pwd)/.cache -Doptimize=ReleaseFast --prefix $out
          '';
          checkPhase = ''
            zig build test --cache-dir $(pwd)/.cache --global-cache-dir $(pwd)/.cache
          '';
        };
      }
    );
}
