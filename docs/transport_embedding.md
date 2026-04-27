# BLIP Transport Embedding Guide

How to carry a segmented BLIP archive (one or more SEGMENT containers — see [BLIP_CONTAINER_SPEC.md §Segmentation](../BLIP_CONTAINER_SPEC.md)) across various host transports. The container spec deliberately stays transport-agnostic; this document defines the canonical conventions used by the `blar` CLI and recommended for any host adapter.

**Author:** Peter Marreck
**Version:** 1.0 (2026-04-26)
**Depends on:** BLIP Container Format v3.0, BLIP Spec v1.2

## Scope

A SEGMENT container (TYPE=9) wraps a slice of a larger BLIP byte stream. Each segment carries its identity in the SEG attribute as `(I, M, N)` — stream ID, 0-based segment index, total count (or NIL for streaming). Reassembly only requires that a consumer can collect all the segments belonging to a given stream `I`; *how* it collects them is the transport adapter's job.

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
archive.blar.seg-{M:06d}-of-{N:06d}     numeric N (most archival cases)
archive.blar.seg-{M:06d}                streaming, N = NIL (no -of- suffix)
archive.blar.i{I}.seg-{M:06d}[-of-{N:06d}]   multi-stream host (I != 0)
```

- `M` and `N` are zero-padded to 6 digits so lexicographic sort matches numeric sort up to ~1 million segments. For larger archives, both fields widen to 9 digits.
- The `archive.blar` stem is whatever the user named the archive (without segment suffix). The dot separator before `seg-` is significant.
- The single-stream case (the overwhelmingly common one, `I = 0`) drops the `i{I}` infix.

### 1.2 Same-directory rule

All segments belonging to one archive **MUST live in the same directory**. The reassembler does not search subdirectories or sibling directories. Producers that need to span filesystems should produce one archive per filesystem (and not segment across the boundary).

### 1.3 Opening a segment opens the archive

Any operation on a single segment file **MUST behave as if invoked on the whole archive**. Examples:

```bash
blar list archive.blar.seg-000003-of-000010
blar extract archive.blar.seg-000003-of-000010 -o out/
blar verify  archive.blar.seg-000003-of-000010
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
<xxhash64-hex>  archive.blar.seg-000000-of-000010
<xxhash64-hex>  archive.blar.seg-000001-of-000010
<xxhash64-hex>  archive.blar.seg-000002-of-000010
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
        <string>blar.seg-000000</string>   <!-- LaunchServices uses pattern matching -->
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
    <glob pattern="*.blar.seg-*"/>
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

Register `.blar` and the `.blar.seg-XXXXXX` family under `HKCR\.blar` and `HKCR\.blar.seg-*` (using a wildcard subkey strategy; Windows file associations don't have native pattern matching, so the app's installer enumerates segment-naming variants up to a reasonable bound, e.g., `.blar.seg-000000` through `.blar.seg-999999` registered as the same ProgID).

A simpler alternative: register only `.blar` and have the BLIP archive app present an "Open .blar.seg-* segments" right-click context menu via shell extension.

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
| Disk files | `archive.blar.seg-{M}-of-{N}` (or header-scan) | Optional `archive.blar.SUMS` | No (use multi-file with numeric N) | Yes |
| JPEG APP11 | Marker order, identifier `"BLIP\0\0"` | N/A | No (JPEG is closed-form) | Yes |
| ISOBMFF uuid | UUID-tagged boxes in box order | N/A | No | Yes |
| PNG bLIP | Chunk order | N/A | No | Yes |
| UDP / MQTT | Packet/message order | N/A | Yes (live transports) | Yes |
| Multipart HTTP | Part order | N/A | Yes | Yes |

## License

MIT — see [LICENSE](../LICENSE).
