# BLIP: Byte Length Integer Prefix

A variable-length integer encoding optimized for CPU-friendly decoding of small values.

See [BLIP_SPEC.md](BLIP_SPEC.md) for the full specification.

## Build

Requires [Nix](https://nixos.org/) with flakes enabled. All dependencies (Zig, hyperfine) are provided hermetically.

```bash
./test           # run tests
./build          # build (ReleaseFast)
./build --debug  # build (Debug)
./bm             # run benchmarks
```

Or directly:

```bash
nix develop -c zig build test
nix develop -c zig build -Doptimize=ReleaseFast
nix develop -c zig build bench -Doptimize=ReleaseFast
```

## License

MIT - see [LICENSE](LICENSE).
