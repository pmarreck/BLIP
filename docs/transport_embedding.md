# BLIP Transport Embedding Guide

How to carry a segmented BLIP archive (one or more SEGMENT containers — see [BLIP_CONTAINER_SPEC.md §Segmentation](../BLIP_CONTAINER_SPEC.md)) across various host transports. The container spec deliberately stays transport-agnostic; this document defines the canonical conventions used by the `blar` CLI and recommended for any host adapter.

**Author:** Peter Marreck
**Version:** 1.0 (2026-04-26)
**Depends on:** BLIP Container Format v3.0, BLIP Spec v1.2

## Scope

A SEGMENT container (TYPE=9) wraps a slice of a larger BLIP byte stream. Each segment carries its identity in the SEG attribute as `(I, M, N)` — stream ID, 1-based segment index, total count (or NIL for streaming). Reassembly only requires that a consumer can collect all the segments belonging to a given stream `I`; *how* it collects them is the transport adapter's job.

This document covers the most common transports:
- **Disk files** (multi-file archive on a filesystem)
- **JPEG APP markers** (parity / metadata embedded in JPEG)
- **ISOBMFF `uuid` boxes** (HEIC, MP4, MOV, AVIF)
- **PNG ancillary chunks**
- **Network datagrams / message queues** (UDP, MQTT, Kafka)

The document also covers desktop integration so OS file managers treat segments as a unified archive.

## 1. Disk-files transport (the `blar` convention)

### 1.1 File-naming pattern

When `blar` writes a segmented archive to a directory, each SEGMENT container becomes one file:

```
archive.blar.{M}-of-{N}.seg     numeric N (most archival cases)
archive.blar.{M}.seg            streaming, N = NIL (no -of- suffix; M unpadded)
```

- `M` is **1-based**: the first segment is `archive.blar.1-of-N.seg`. `M = 0` does not appear.
- `M` and `N` are zero-padded to the **minimum width** that fits `N` (i.e. `width = ceil(log10(N + 1))`). For `N = 5` the width is 1 (`1-of-5.seg`); for `N = 28` it's 2 (`02-of-28.seg`); for `N = 1000` it's 4 (`0001-of-1000.seg`). Within a single archive set, every filename has the same width on both sides, so lexicographic sort matches numeric sort.
- The `archive.blar` stem is whatever the user named the archive (without segment suffix). The trailing `.seg` extension is significant — it lets file managers and find/glob tools locate segments uniformly (`find . -name '*.seg'`).
- The single-stream case (`I = 0`) is the only documented case in this version. Multi-stream-on-disk (multiple distinct `I` values sharing one directory) is **deferred**; if it's ever needed, this section will gain an `i{I}` infix in a future revision. For now, the SEGMENT container's `I` field is still meaningful in non-disk transports (network, JPEG, etc.).

### 1.2 Same-directory rule

All segments belonging to one archive **MUST live in the same directory**. The reassembler does not search subdirectories or sibling directories. Producers that need to span filesystems should produce one archive per filesystem (and not segment across the boundary).

### 1.3 Opening a segment opens the archive

Any operation on a single segment file **MUST behave as if invoked on the whole archive**. Examples:

```bash
blar list archive.blar.03-of-10.seg
blar extract archive.blar.03-of-10.seg -o out/
blar verify  archive.blar.03-of-10.seg
```

These are equivalent to operating on the conceptual `archive.blar`. The CLI MUST:

1. Detect that the path matches the segment filename pattern.
2. Locate the sibling segments in the same directory.
3. Verify completeness (numeric N) or accept whatever is present (streaming / partial).
4. Reassemble in memory or via streaming.
5. Run the requested operation on the reassembled archive.

This applies to the BLIP archive GUI app as well — double-clicking any segment file in Finder / a file manager opens the archive.

### 1.4 Header-scan fallback

If a directory contains files that do **not** match the naming convention but **do** parse as SEGMENT containers, the reassembler MUST scan the headers of every file in the directory and group by stream ID `I`:

1. For each regular file in the directory, attempt a quick header parse (LP envelope + TYPE attribute).
2. Collect the SEGMENT containers found, indexed by their `(I, M, N)`.
3. Reassemble normally.

This handles cases where files have been renamed, stripped of suffixes by a transfer tool, or deliberately given non-standard names. The header-scan is the authoritative source — names are advisory.

When both well-named and oddly-named SEGMENT files coexist in a directory, the header content always wins. If a manifest is also present (§1.5), it is consulted first as an optimization but it is also subordinate to the header content.

### 1.5 Manifest (optional)

A manifest is **never required**. SEGMENT containers are self-describing via their SEG attribute, and the header-scan fallback (§1.4) handles every loss-of-naming scenario. A manifest is purely a fail-fast optimization for the common case.

When present, the manifest is named `archive.blar.SUMS` (matching GNU coreutils / BSD sum-tool conventions) and uses the standard one-line-per-file text format:

```
<xxhash64-hex>  archive.blar.01-of-10.seg
<xxhash64-hex>  archive.blar.02-of-10.seg
<xxhash64-hex>  archive.blar.03-of-10.seg
...
```

- Whitespace separator is exactly two spaces (compatible with `xxhsum -c`).
- The hash covers the **whole segment file's bytes** (including the BLIP envelope), not the SEG payload only — so a user can run `xxhsum -c archive.blar.SUMS` for a quick verify without knowing anything about BLIP.
- Filenames are relative to the directory containing the manifest.

Producers MAY emit a manifest. Consumers MAY consult one. If a manifest exists and disagrees with the actual segment files, the **segment files win** — the manifest is advisory and may have desynchronized.

In streaming mode (N = NIL) a manifest cannot exist by definition (the producer doesn't know the totals when emitting).

## 2. JPEG APP markers

JPEG APP markers cap at 65,533 payload bytes each. Embedded BLIP data uses APP11 (JPEG-2000 reserves APP1–APP10; APP11 is the first marker without prior conventions in widespread use, except JPL identifier rules — see below).

### 2.1 Identifier prefix

Each APP11 marker begins with the BLIP-JPEG identifier, then carries one SEGMENT container's wire bytes:

```
FF EB <length:2B BE>            APP11 marker + length (length includes own 2 bytes)
"BLIP\0\0"                       6-byte identifier (NUL-padded)
<SEGMENT container bytes>       LP envelope, TYPE=9, SEG attribute, VAL slice
```

- Stream ID `I` should be `0` for the typical "this JPEG carries one BLIP payload" case. Use `I > 0` only when carrying multiple independent BLIP streams in one JPEG (e.g., parity + supplementary EXIF).
- Per-segment CSUM is RECOMMENDED (catches per-marker corruption from buggy JPEG editors).
- All segments for one stream MUST appear in marker order before SOS (Start-Of-Scan).

### 2.2 Reader algorithm

1. Walk APP11 markers from SOI to SOS.
2. Markers whose payload begins with `"BLIP\0\0"` are BLIP segments.
3. Strip the identifier, parse the SEGMENT container, collect.
4. Apply standard reassembly per BLIP_CONTAINER_SPEC §Segmentation.

JPEG editors that strip unknown APP markers will destroy embedded BLIP data. Recommend storing parity in `.par2` sidecars when the JPEG might pass through hostile editors (Photoshop legacy modes have been known to drop APP11+).

## 3. ISOBMFF (`uuid` boxes for HEIC, MP4, MOV, AVIF)

ISOBMFF allows arbitrarily-sized `uuid`-typed boxes. Single-segment is the typical case (one `uuid` box holds the whole BLIP payload — no segmentation needed).

If splitting is desired (e.g., to keep individual boxes under a transport's per-record cap), use multiple `uuid` boxes with a registered BLIP UUID:

```
uuid box:
  size:    4 or 8 bytes (standard ISOBMFF header)
  type:    'uuid'
  uuid:    <16-byte BLIP-segment UUID, registered>
  payload: <SEGMENT container bytes>
```

A registered UUID for BLIP-segment payloads is reserved (allocate when the spec ships): `bl1pseg0-...` (TBD).

## 4. PNG ancillary chunks

PNG ancillary chunks cap at 2^31 - 1 bytes — segmentation rarely needed. Single-chunk is standard. The chunk type for BLIP is `bLIP` (lowercase first letter = ancillary, uppercase second/third/fourth = public-required-for-image-rendering bits set per PNG conventions). When segmentation is needed, multiple `bLIP` chunks each carry one SEGMENT container.

## 5. Network and message-queue transports

For UDP, MQTT, Kafka, multipart HTTP uploads, etc., each transport message carries one SEGMENT container as its payload. The transport's own framing handles delivery; BLIP's reassembly handles ordering and gap detection. Streaming mode (N = NIL) is the natural fit for live network transports; switch to numeric N when retrospective loss-detection matters.

## 6. Desktop integration

To make segmented archives "look like one file" in OS file managers — so a user can double-click any segment and have the BLIP archive GUI open the whole archive — file-type registration is needed.

### 6.1 macOS — Uniform Type Identifiers (UTI)

In the BLIP archive app's `Info.plist`:

```xml
<key>UTExportedTypeDeclarations</key>
<array>
  <dict>
    <key>UTTypeIdentifier</key>          <string>net.blarchive.blar</string>
    <key>UTTypeDescription</key>         <string>BLIP Archive</string>
    <key>UTTypeConformsTo</key>          <array><string>public.archive</string></array>
    <key>UTTypeTagSpecification</key>
    <dict>
      <key>public.filename-extension</key>     <array><string>blar</string></array>
      <key>public.mime-type</key>              <array><string>application/x-blar</string></array>
    </dict>
  </dict>
  <dict>
    <key>UTTypeIdentifier</key>          <string>net.blarchive.blar.segment</string>
    <key>UTTypeDescription</key>         <string>BLIP Archive Segment</string>
    <key>UTTypeConformsTo</key>          <array><string>net.blarchive.blar</string></array>
    <key>UTTypeTagSpecification</key>
    <dict>
      <key>public.filename-extension</key>
      <array>
        <string>seg</string>
      </array>
    </dict>
  </dict>
</array>
<key>CFBundleDocumentTypes</key>
<array>
  <dict>
    <key>LSItemContentTypes</key>
    <array>
      <string>net.blarchive.blar</string>
      <string>net.blarchive.blar.segment</string>
    </array>
    <key>CFBundleTypeRole</key>           <string>Editor</string>
  </dict>
</array>
```

When the user opens any file conforming to `net.blarchive.blar.segment`, LaunchServices invokes the BLIP archive app, which then performs the same-directory expansion described in §1.3.

**Type/creator codes (legacy, deprecated):** the four-character `OSType` codes from classic Mac OS are no longer honored by modern LaunchServices. Don't bother — UTI replaces them entirely on macOS 10.4+.

### 6.2 Linux — MIME types

Register via `~/.local/share/mime/packages/blar.xml` (per-user) or `/usr/share/mime/packages/blar.xml` (system):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">
  <mime-type type="application/x-blar">
    <comment>BLIP archive</comment>
    <glob pattern="*.blar"/>
    <glob pattern="*.seg"/>
    <magic priority="60">
      <!-- BLIP container LP envelope starts with 0x80-0xFF (BLIP length byte).
           Identification is best done after parsing the LP envelope; magic-number
           heuristics for short prefixes are weak. -->
      <match type="string" offset="0" value="\x82"/> <!-- weak heuristic -->
    </magic>
  </mime-type>
</mime-info>
```

Then `update-mime-database ~/.local/share/mime` and create a `blar.desktop` file pointing the MIME type at the BLIP archive app. The app handles same-directory expansion.

### 6.3 Windows — file associations

Register `.blar` and `.seg` under `HKCR\.blar` and `HKCR\.seg` respectively. The `.seg` association points at the BLIP archive app, which inspects the file's BLIP header on open to confirm it's a SEGMENT container before performing the same-directory expansion described in §1.3 (a non-BLIP `.seg` file is rejected with an explanatory error).

A simpler alternative for users who don't want a global `.seg` association: register only `.blar` and have the BLIP archive app present an "Open BLIP segments in this folder…" right-click context menu via shell extension.

## 7. Cross-cutting requirements (all transports)

### 7.1 Stream-ID hygiene

`I = 0` is reserved with the meaning "default / unnamed stream." Use `I = 0` whenever a host carries one logical BLIP payload — which is the vast majority of cases. Use `I > 0` only when explicitly carrying multiple independent BLIP streams in one host container.

`I > 0` values are caller-chosen and uniqueness is scoped to **one host container** (one JPEG file, one directory of segment files, one network session). Different host containers may freely reuse the same `I` values without conflict.

### 7.2 Per-segment CSUM

RECOMMENDED on every transport. Especially valuable when:
- The transport is unreliable (network, message queues).
- The transport may be edited by tools that don't understand BLIP (JPEG editors, ISOBMFF muxers).
- Retransmission is possible (network) — the duplicate-M dedup rule (BLIP_CONTAINER_SPEC §Segmentation) requires per-segment CSUM to be safe.

xxHash64 is the recommended algorithm — fast enough that it can run on every datagram, strong enough to catch all realistic transport corruption, and matches the hash used inside the inner ARRAY/DICT/FILE/DIR containers.

### 7.3 N must be consistent

All segments of a stream MUST agree on `N`. If a producer can't decide between numeric and NIL, it MUST use NIL until end-of-stream is known, then optionally re-emit a final-segment "N now known" signal via a separate out-of-band mechanism (transport-specific). The reassembly algorithm rejects an inconsistent-N stream with `InconsistentTotal`.

## 8. Summary table

| Transport | Naming/addressing | Manifest? | Streaming N=NIL works? | Segment CSUM recommended? |
|-----------|-------------------|-----------|-----------------------|---------------------------|
| Disk files | `archive.blar.{M}-of-{N}.seg` (or header-scan) | Optional `archive.blar.SUMS` | No (use multi-file with numeric N) | Yes |
| JPEG APP11 | Marker order, identifier `"BLIP\0\0"` | N/A | No (JPEG is closed-form) | Yes |
| ISOBMFF uuid | UUID-tagged boxes in box order | N/A | No | Yes |
| PNG bLIP | Chunk order | N/A | No | Yes |
| UDP / MQTT | Packet/message order | N/A | Yes (live transports) | Yes |
| Multipart HTTP | Part order | N/A | Yes | Yes |

## 9. Comparison with existing segmentation / fragmentation solutions

This section evaluates BLIP SEGMENT against the most relevant prior art across network, file-format, and transport-embedded contexts. The honest summary: **BLIP SEGMENT is uniquely superior at *scope unification*** — one primitive that subsumes archival, streaming, transport-embedded, and disk-files use cases. On individual quality axes it is sometimes superior, sometimes comparable, and sometimes inferior to specialized solutions.

### Network / protocol layer

| System | What it does | vs. BLIP SEGMENT |
|--------|--------------|------------------|
| **IPv4 fragmentation** | Routers split datagrams; reassembled by destination via 16-bit ID + 13-bit offset | BLIP wins on per-fragment integrity (IPv4 has none), self-describing payload (IPv4 fragments are opaque), and unbounded N (IPv4 caps at 65535 bytes total). Deprecated in IPv6 for reasons that don't apply to BLIP (BLIP is application-layer, doesn't share IPv4's MTU pain). |
| **IPv6 fragmentation** | Source-only fragmentation; 32-bit ID, 13-bit offset | BLIP wins on integrity + self-description; IPv6 wins on no-reassembly-state-explosion (it's stateless across the network). Different layer; not a fair fight. |
| **TCP segmentation** | Continuous byte stream with sequence numbers + ACKs + retransmits | TCP is online; BLIP's reassembly is offline. TCP wins on flow control, congestion control, retransmission. BLIP wins on application-layer transparency (you can stick TCP-segmented BLIP segments inside another transport). Different problem. |
| **QUIC streams** | Multiplexed, retransmit-aware, encrypted | QUIC is online and connection-oriented. BLIP SEGMENT carries the same identity primitives (stream-id, offset-equivalent in M) but at archival rest. QUIC wins for live transport; BLIP wins for transport-agnostic embedding. |
| **SCTP chunks** | TSN-numbered chunks with selective retransmit | SCTP is online; same difference as TCP. |

**Verdict (network layer):** Different problem domain. BLIP is application-layer and offline-reassembly; networks solve online, link-layer reassembly. Not directly comparable.

### File-format / archival layer

| System | What it does | vs. BLIP SEGMENT |
|--------|--------------|------------------|
| **PAR2** | Forward-error-correction (Reed-Solomon recovery slices) over a base file set | **PAR2 wins for FEC use cases** — you can lose K of N PAR2 blocks and still recover the original. BLIP SEGMENT has no FEC; lose one numeric-N segment and reassembly fails. PAR2 also has a complex packet-typed format. BLIP wins on simplicity, transport-embedding, and that BLIP SEGMENT can carry a PAR2 payload as VAL. The two compose well. |
| **ZIP multi-volume (.z01/.z02/.zip)** | Splits archive across N files; central directory in last volume | BLIP wins on per-segment integrity (ZIP multi-volume has none), naming flexibility (BLIP doesn't require last-volume sentinel), and order-independence (ZIP requires sequential read). ZIP wins on tooling ubiquity. |
| **7-Zip multi-volume (.001/.002)** | Dumb byte split of a single archive across files | BLIP wins on every axis except tooling ubiquity: BLIP has per-segment identity, integrity, ordering, order-independence; 7z has none of these — recover-from-loss is impossible without a separate sidecar. |
| **RAR multi-volume + Recovery Record** | Volumes with optional XOR-based recovery records | RAR's recovery record is roughly PAR2-lite. Same FEC trade-off as PAR2 above. BLIP unifies the multi-volume case more cleanly. |
| **Unix `split` / `cat`** | Byte-level split, blind reassembly via `cat` | BLIP wins on all metadata axes. `split` is the lowest baseline. |

**Verdict (file-format layer):** BLIP SEGMENT is strictly better than dumb-split formats (ZIP/7z/RAR multi-volume). It is *worse* than PAR2/RAR-recovery for FEC scenarios — but those compose orthogonally (a PAR2-protected archive can be carried as BLIP SEGMENT VAL).

### Streaming media layer

| System | What it does | vs. BLIP SEGMENT |
|--------|--------------|------------------|
| **HLS (.m3u8 + .ts segments)** | Time-indexed media segments + master playlist; supports byte-range requests, encryption keys per segment | HLS wins for **random-access media playback** — you can fetch and decode segment K without segments 0..K-1. BLIP SEGMENT requires sequential reassembly. HLS is media-format-coupled; BLIP is content-agnostic. |
| **DASH (.mpd + segment URLs)** | Manifest-driven adaptive bitrate streaming | Same as HLS: better for random-access media, worse for general byte-stream segmentation. |
| **HTTP chunked transfer** | Length-prefixed chunks with no integrity | BLIP wins on every quality axis; HTTP chunked is the absolute minimum (just framing). |
| **MIME multipart** | Boundary-delimited parts with optional Content-MD5 per part | BLIP wins on length-prefix vs boundary-scanning (no false-positive worry), unlimited part counts, and integrated dedup-on-retransmit. MIME wins on tooling ubiquity in email/HTTP. |

**Verdict (streaming layer):** BLIP SEGMENT is better than primitive framing (HTTP chunked) and at least equivalent to MIME multipart on integrity. For random-access media playback specifically, HLS/DASH win — they index *into* media time, not byte-stream offsets.

### Transport-embedded (the original motivation)

| System | What it does | vs. BLIP SEGMENT |
|--------|--------------|------------------|
| **JPEG ICC profile chunking** | APP2 markers with `chunk_num` (u8) + `total_chunks` (u8). 255-chunk cap (one byte for 1-based count). | BLIP wins on: unbounded N (BLIP integers vs ICC's u8); per-chunk integrity (ICC has none); applies to *any* host (ICC is JPEG-only). Both are 1-based. |
| **JPEG XMP / Extended XMP** | APP1 with NUL-terminated namespace strings + tiny ad-hoc continuation protocol (MD5 + offset + length per packet) | BLIP wins on: cleaner spec (XMP's continuation is barely standardized); standard 64-bit fields (XMP truncates to 32-bit lengths); composability with other BLIP attrs. |
| **JPEG EXIF Extended** | Underspecified APP1 continuation; in practice almost no readers handle it correctly | BLIP wins by simply existing as a single coherent spec rather than three incompatible ad-hocs (EXIF/ICC/XMP). |
| **PNG ancillary chunks (4-char codes)** | `chunkType` + length per chunk | Single-chunk PNG ancillary is fine; multi-chunk requires a layer above (which is what BLIP SEGMENT *is*). |
| **ISOBMFF `uuid` boxes** | UUID-tagged boxes inside MP4/HEIC/MOV | Single-box is fine; multi-box requires a layer above. BLIP SEGMENT IS that layer. |

**Verdict (transport-embedded):** **BLIP SEGMENT is unambiguously superior here**, because the existing solutions are either inconsistent within one host format (JPEG) or single-payload-only (PNG/ISOBMFF). One canonical primitive replaces three JPEG-specific protocols.

### Distributed systems

| System | What it does | vs. BLIP SEGMENT |
|--------|--------------|------------------|
| **IPFS chunks (Merkle DAG)** | Content-addressed chunks in a Merkle tree; native deduplication | IPFS wins for **dedup and content-addressing**. BLIP SEGMENT has neither — two segments with identical VAL are stored twice. Different design goal: IPFS is a storage layer; BLIP SEGMENT is a transport-framing layer. They compose. |
| **BitTorrent pieces** | Fixed-size pieces with SHA-1 hash per piece, indexed by .torrent file | BitTorrent wins for swarm/peer-to-peer scenarios (it has a tracker/DHT layer). BLIP SEGMENT has none. Different domain. |
| **Git pack files** | Delta-compressed object database | Different problem; not segmentation. |
| **Kafka partitions** | Per-topic ordered logs with offsets | Online streaming with consumer-group coordination. BLIP SEGMENT is offline. Different problem. |

**Verdict (distributed):** BLIP SEGMENT does not compete with content-addressed or peer-to-peer systems. It composes with them (you can BitTorrent BLIP SEGMENT files; you can IPFS-store reassembled BLIP archives).

### Score card

| Axis | Winner | Notes |
|------|--------|-------|
| **Per-segment self-description** | BLIP SEGMENT (tied with HLS, MIME) | Each segment is parseable standalone via SEG attribute |
| **Per-segment integrity** | BLIP SEGMENT (tied with PAR2) | xxHash64/BLAKE3 native, optional |
| **Order-independence on disk** | BLIP SEGMENT | Sort-by-M after collection, no required ordering on the wire |
| **Streaming and archival in one primitive** | BLIP SEGMENT | NIL N for streaming, numeric N for archival — most formats specialize |
| **Transport-agnostic** | BLIP SEGMENT | One spec for JPEG / ISOBMFF / PNG / disk / network |
| **Forward-error-correction** | PAR2 / RAR | BLIP has none; compose at a different layer |
| **Random-access into a long stream** | HLS / DASH | BLIP requires sequential reassembly; HLS supports independent decoding per segment |
| **Content-addressed dedup** | IPFS | BLIP has none |
| **Tooling / ecosystem** | ZIP / TCP / MIME | BLIP is new |
| **Spec simplicity** | BLIP SEGMENT (tied with HTTP chunked) | One LP envelope, three integer fields, one optional checksum |
| **Composability with other attributes** | BLIP SEGMENT | Native COMP/CSUM/ENC stack; per-segment and whole-stream attribute layers don't interfere |
| **Unbounded segment count** | BLIP SEGMENT | BLIP integers vs ICC's u8 cap (254) or some legacy formats' u16 caps (65535) |
| **Forward-compat with old parsers** | BLIP SEGMENT | v2 readers skip TYPE=9 cleanly via Length; many other formats panic on unknown types |
| **Duplicate-on-retransmit safety** | BLIP SEGMENT | Checksum-aware dedup rule (matching VAL coalesces, mismatching errors) is novel as a *spec-level* guarantee |

### Final assessment

The design **is superior** in:
- The transport-embedded / JPEG-host segmentation niche (no contest — existing solutions are fragmented across three incompatible JPEG sub-protocols).
- Scope unification: one primitive serving archival + streaming + transport-embedded + disk-files. No other format covers all of this.
- Composability: per-segment vs whole-stream attributes are independently meaningful, not entangled.
- Spec simplicity for the value delivered.

The design **is comparable** in:
- Per-segment integrity (PAR2, MIME's Content-MD5, HLS).
- Self-describing per-segment metadata (HLS playlist entries, gRPC frames).
- Order-independence (PAR2, MIME).

The design **is inferior** in:
- FEC use cases (PAR2 wins; compose at a different layer rather than competing).
- Random-access media (HLS/DASH win; BLIP requires sequential reassembly).
- Content-addressed dedup (IPFS wins; different design goal).
- Tooling ubiquity (everything wins; BLIP is new).

The honest claim is therefore: **superior unification of scope** rather than "superior on every axis." The unification is itself a meaningful contribution because it lets one tool (`blar`) handle JPEG embedding, network transport, multi-file archives, and live streams without inventing four different sub-protocols.

## License

MIT — see [LICENSE](../LICENSE).
