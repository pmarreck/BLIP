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
        pname = "blip";
        version = "0.2.0";
        isDarwin = pkgs.stdenv.isDarwin;

        zigDepsHash = "sha256-xLCFr0yspJN8NvZqMDpcTQrY5ivjBsFEz9bL47wNcdI=";

        zigDeps = pkgs.stdenv.mkDerivation {
          pname = "${pname}-zig-deps";
          inherit version;
          src = self;
          nativeBuildInputs = with pkgs; [ zig git cacert ];
          outputHashMode = "recursive";
          outputHashAlgo = "sha256";
          outputHash = zigDepsHash;
          buildPhase = ''
            export HOME=$TMPDIR
            export ZIG_GLOBAL_CACHE_DIR=$out
            export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
            export GIT_SSL_CAINFO=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
            zig build --fetch=all
          '';
          dontInstall = true;
          dontFixup = true;
        };
      in {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            zig
            hyperfine
          ];
        };

        packages.default = pkgs.stdenv.mkDerivation {
          inherit pname version;
          src = self;
          nativeBuildInputs = [ pkgs.zig ]
            ++ pkgs.lib.optionals isDarwin [
              pkgs.darwin.cctools
              pkgs.apple-sdk
            ];
          dontConfigure = true;
          dontInstall = true;
          dontFixup = true;
          buildPhase = ''
            export HOME="$TMPDIR"
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
            mkdir -p $ZIG_GLOBAL_CACHE_DIR
            cp -r ${zigDeps}/* $ZIG_GLOBAL_CACHE_DIR/
            chmod -R u+w $ZIG_GLOBAL_CACHE_DIR
            zig build --prefix $out -Doptimize=ReleaseFast
          '';
        };

        checks.default = pkgs.stdenv.mkDerivation {
          pname = "${pname}-tests";
          inherit version;
          src = self;
          nativeBuildInputs = [ pkgs.zig ]
            ++ pkgs.lib.optionals isDarwin [
              pkgs.darwin.cctools
              pkgs.apple-sdk
            ];
          dontConfigure = true;
          dontFixup = true;
          buildPhase = ''
            export HOME="$TMPDIR"
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
            mkdir -p $ZIG_GLOBAL_CACHE_DIR
            cp -r ${zigDeps}/* $ZIG_GLOBAL_CACHE_DIR/
            chmod -R u+w $ZIG_GLOBAL_CACHE_DIR
            timeout 600 zig build test || { echo "Tests failed"; exit 1; }
          '';
          installPhase = ''
            mkdir -p $out
            echo "tests passed" > $out/result
          '';
        };
      }
    );
}
