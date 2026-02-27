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

        # Pre-fetch Zig dependencies for sandbox-compatible builds
        z7z-src = pkgs.fetchurl {
          url = "https://github.com/pmarreck/z7z/archive/18e094eab1cb545c86a6b6e72cc9c48db3539ddd.tar.gz";
          hash = "sha256-Wt9Z7lg1TtUWH8UDJbPhNDRrIn2lb1B217DllFOOxcg=";
        };

        # Build a Zig system package directory from pre-fetched dependencies.
        # Zig's --system flag expects: <pkgdir>/<zig-hash>/...
        zigDeps = pkgs.stdenv.mkDerivation {
          name = "blip-zig-deps";
          dontUnpack = true;
          buildPhase = ''
            mkdir -p $out/z7z-0.1.0-rkKuF0UdBQDsZxiiNFWuuoHVeGLFO078oGD6yQQiSXoA
            tar xzf ${z7z-src} --strip-components=1 -C $out/z7z-0.1.0-rkKuF0UdBQDsZxiiNFWuuoHVeGLFO078oGD6yQQiSXoA
          '';
          dontInstall = true;
        };
      in {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            zig
            hyperfine
          ];
        };

        packages.default = pkgs.stdenv.mkDerivation {
          pname = "blip";
          version = "0.2.0";
          src = ./.;
          nativeBuildInputs = [ pkgs.zig ];
          dontConfigure = true;
          dontInstall = true;
          doCheck = true;
          buildPhase = ''
            mkdir -p .cache
            zig build \
              --cache-dir $(pwd)/.cache \
              --global-cache-dir $(pwd)/.cache \
              --system ${zigDeps} \
              -Doptimize=ReleaseFast \
              --prefix $out
          '';
          checkPhase = ''
            zig build test \
              --cache-dir $(pwd)/.cache \
              --global-cache-dir $(pwd)/.cache \
              --system ${zigDeps}
          '';
        };
      }
    );
}
