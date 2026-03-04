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
          url = "https://github.com/pmarreck/z7z/archive/93112f05573ba294b18f98ec5473251b7fedd240.tar.gz";
          hash = "sha256-LgKhIr141lq+UZQ7Xv3r0u3UczNJs8Sly29Y9OFnJMQ=";
        };
        bzip2z-src = pkgs.fetchurl {
          url = "https://github.com/pmarreck/bzip2z/archive/76d3ca8f35dad2c1393eb35d97332d5a8e9da2bb.tar.gz";
          hash = "sha256-rkST0lDO7szyRsbIZRr4s9btyd79A5oVS5Q2eiO0PCw=";
        };
        lz4-src = pkgs.fetchurl {
          url = "https://github.com/pmarreck/lz4/archive/675532cbcc0609ddfc44a6e13240902574579a25.tar.gz";
          hash = "sha256-OQH1Fkaru+D2vThSE2tEJ+HQ07Koe9tEQ6EKPBzjeZ8=";
        };
        progrez-src = pkgs.fetchurl {
          url = "https://github.com/pmarreck/progrez/archive/377256d88ef8e664177b88a66a361a46be4e4c83.tar.gz";
          hash = "sha256-q7omg5xppVn5iIgl9VVYKqOMDiea5tm6KbBd0GUiy4E=";
        };
        zstdz-src = pkgs.fetchurl {
          url = "https://github.com/pmarreck/zstdz/archive/c79c202b8d6512a72a5b0b65ad771adfda66d301.tar.gz";
          hash = "sha256-Uq/M87sBrp1VB/Ahr8Pu4vE3AMgR/2nHjJQT18XfH8o=";
        };
        # Transitive dependency of z7z
        libmagic-src = pkgs.fetchurl {
          url = "https://github.com/pmarreck/libmagic/archive/refs/tags/zig-0.15.0.tar.gz";
          hash = "sha256-lEySLP0ththmbc/zRhbGlKcPk5H0jvGzDMohOYGmJqg=";
        };

        # Build a Zig system package directory from pre-fetched dependencies.
        # Zig's --system flag expects: <pkgdir>/<zig-hash>/...
        zigDeps = pkgs.stdenv.mkDerivation {
          name = "blip-zig-deps";
          dontUnpack = true;
          buildPhase = ''
            mkdir -p $out/z7z-0.1.0-rkKuF1v8BQAz2YEHTrHZ3KrgSvHwfPfiwiX3HOAPmF4Y
            tar xzf ${z7z-src} --strip-components=1 -C $out/z7z-0.1.0-rkKuF1v8BQAz2YEHTrHZ3KrgSvHwfPfiwiX3HOAPmF4Y
            mkdir -p $out/bzip2z-0.1.0-m5NdlvkqAwCEafj8KkeEu4fIXSTRp-sKQewGM28tYrcr
            tar xzf ${bzip2z-src} --strip-components=1 -C $out/bzip2z-0.1.0-m5NdlvkqAwCEafj8KkeEu4fIXSTRp-sKQewGM28tYrcr
            mkdir -p $out/lz4-1.10.0-TtaqjVLWBwDiQxASdpBmT-44zoqcVnVkA9kQGAonGWDf
            tar xzf ${lz4-src} --strip-components=1 -C $out/lz4-1.10.0-TtaqjVLWBwDiQxASdpBmT-44zoqcVnVkA9kQGAonGWDf
            mkdir -p $out/progrez-0.1.0-0YJXrl0CAgCI-gvYCSEWEnW2rsWMTPbehyOnOveB4EJp
            tar xzf ${progrez-src} --strip-components=1 -C $out/progrez-0.1.0-0YJXrl0CAgCI-gvYCSEWEnW2rsWMTPbehyOnOveB4EJp
            mkdir -p $out/zstdz-1.6.0-yDWjzshaNABOkMCYfrjAhKjPt46sKjdR9cLB-XgzeTt4
            tar xzf ${zstdz-src} --strip-components=1 -C $out/zstdz-1.6.0-yDWjzshaNABOkMCYfrjAhKjPt46sKjdR9cLB-XgzeTt4
            mkdir -p $out/libmagic-5.46.0-RysxHD9fCACu5caBjXS-x3qQnQM3nRfosCyktdVRzv-R
            tar xzf ${libmagic-src} --strip-components=1 -C $out/libmagic-5.46.0-RysxHD9fCACu5caBjXS-x3qQnQM3nRfosCyktdVRzv-R
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
