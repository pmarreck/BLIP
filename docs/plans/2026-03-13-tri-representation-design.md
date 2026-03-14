# Tri-Representation Design: Binary + Text + Filesystem

## Problem

Blar archives are opaque binary blobs. Users can't inspect, diff, or hand-edit them without specialized tooling. Container expansion (PDF, PNG, ZIP) is hardcoded, making it difficult to add new formats. The c0 project already solved several of these problems — codec plugins, human-readable text form — but lacks blar's compression, random access, and real-world testing.

## Goal

Make blar archives expressible in three equivalent, losslessly interconvertible representations:

```
    blar binary
    /         \
   /    ↔↔↔    \
  /               \
text form ←→ directory tree
```

Additionally, replace hardcoded container expansion with a codec plugin system.

## Design

### 1. Codec Plugin System

Replace `expand_pdf_container()`, `expand_png_container()`, `expand_zip_container()` with a vtable-based codec interface.

#### Interface

```c
typedef struct {
    const char *name;           // "pdf", "png", "zip"
    const char **extensions;    // {".pdf", NULL}
    bool (*detect)(const uint8_t *buf, size_t len);
    bool (*expand)(entry_list_t *el, const uint8_t *content, size_t len,
                   const blip_archive_entry *entry);
    bool (*collapse)(const uint8_t *const *parts, const size_t *part_lens,
                     size_t part_count, uint8_t **out, size_t *out_len);
} blar_codec_t;
```

#### Built-in codecs

PDF, PNG, ZIP — current code refactored into codec structs. No behavior change, just structural reorganization.

#### External codecs

Executables named `blar-codec-<name>` discovered on PATH. Communication via stdin/stdout protocol:

```
blar-codec-bg3lsv info        → JSON: {name, extensions, magic}
blar-codec-bg3lsv expand      → stdin: raw bytes, stdout: entry list (length-prefixed)
blar-codec-bg3lsv collapse    → stdin: entry list, stdout: raw bytes
```

#### Missing plugin handling

The `co` metadata key already stores the codec name in the archive. On extraction, if codec not found:
- Warn: `warning: codec "bg3lsv" not found, extracting raw parts`
- Extract constituent files as-is (the `__body__`, `__img_*` children)
- The archive remains valid and re-archivable

### 2. Human-Readable Text Form

A lossless text serialization of any blar archive using printable-binary encoding for binary payloads.

#### Format

```
BLAR/1
DIR "photos/" mode=0755 mtime=1710000000
  DIR "vacation.pdf/" co=pdf mode=0644 mtime=1710000000
    FILE "__body__" po=0 pl=50000
      |SGVsbG8gV29ybGQ=...|
    FILE "__img_3_0.jxl" jx=jpeg po=1234 pl=5678
      |/9j/4AAQSkZJRg...|
  FILE "readme.txt" mode=0644 mtime=1710000000
    |This is plain text, printable-binary encoded|
```

#### Properties

- **Lossless round-trip**: `blar → text → blar` produces identical binary output
- **Printable-binary payloads**: All binary data encoded via printable-binary (already a dependency)
- **Metadata inline**: All FileEntry metadata keys as `key=value` on the entry line
- **Indentation**: 2-space indent per nesting level, matching directory structure
- **Payload delimiter**: `|...|` on indented lines following a FILE entry
- **Streaming**: Can be produced/consumed line by line without buffering entire archive

#### Partial expansion

Expand only a subtree of the archive:

```bash
blar text archive.blar --path "photos/vacation.pdf/"
```

Path specification supports glob patterns (PCRE2-based glob→regex from dirtree):
- `*.pdf/` — all PDF containers
- `photos/**` — everything under photos
- `[0]` — first entry (array-style index for positional access)

Unexpanded subtrees appear as opaque references:

```
FILE "other_stuff.tar.gz" mode=0644 mtime=1710000000 size=1048576
  <opaque>
```

### 3. Filesystem Directory Tree

A real directory tree on disk as the third representation.

#### Layout

```
archive_root/
├── photos/
│   ├── vacation.pdf/           # directory = container (co=pdf)
│   │   ├── __body__
│   │   ├── __img_3_0.jxl
│   │   └── __meta__.json       # metadata sidecar
│   └── readme.txt
├── __meta__.json               # directory-level metadata
└── __archive__.json            # archive-level settings
```

#### Metadata sidecars

Each directory contains a `__meta__.json` with metadata for all entries in that directory:

```json
{
  "vacation.pdf/": {"co": "pdf", "mode": 493, "mtime": 1710000000},
  "__body__": {"po": 0, "pl": 50000},
  "__img_3_0.jxl": {"jx": "jpeg", "po": 1234, "pl": 5678},
  "readme.txt": {"mode": 420, "mtime": 1710000000}
}
```

Why sidecar files instead of xattrs: portable across filesystems, visible to standard tools, diffable.

#### Round-trip fidelity

`blar → directory → blar` preserves all metadata. Filesystem metadata (mode, mtime) is restored from sidecar JSON, not from the filesystem itself, to avoid platform-specific lossy conversions.

### 4. CLI Interface

```bash
# Text form
blar text archive.blar                          # full text to stdout
blar text archive.blar --path "*.pdf/"          # partial expansion
blar text archive.blar -o archive.blar.txt      # write to file
blar from-text archive.blar.txt -o archive.blar # text → binary

# Directory tree
blar explode archive.blar -C ./tree/            # binary → directory tree
blar implode ./tree/ -o archive.blar            # directory tree → binary
```

### 5. Conversion Paths

Direct conversions (no intermediate form needed):

| From | To | Command |
|------|----|---------|
| binary | text | `blar text` |
| text | binary | `blar from-text` |
| binary | directory | `blar explode` |
| directory | binary | `blar implode` |
| text | directory | `blar from-text \| blar explode` (pipe or two-step) |
| directory | text | `blar implode \| blar text` (pipe or two-step) |

Text ↔ directory could get direct commands later if the two-step is too slow, but YAGNI for now.

## Edge Cases

| Case | Handling |
|------|----------|
| Binary payload contains `\|` | Printable-binary encoding handles this |
| Filename contains quotes/newlines | Escaped in text form: `\"`, `\n` |
| Empty file | `FILE "empty" mode=0644` with no payload lines |
| Symlinks | Stored as `LINK "name" → "target"` in text form |
| Very large files | Streaming text form; directory form uses actual files |
| `__meta__.json` name collision | Reserved name — real files with this name get `__meta__.json.orig` |
| Nested containers | Recursive expansion in text form; nested directories in filesystem |

## Non-Goals (YAGNI)

- GUI viewer (text form + standard editors are sufficient)
- Real-time sync between representations (explicit conversion commands)
- Text form as primary storage (binary is canonical, text is for inspection)
- Backward compatibility with c0 format (inspired by, not compatible with)

## Implementation Phases

1. **Codec plugin refactor** — Extract PDF/PNG/ZIP into codec structs, add registry, no behavior change
2. **External codec protocol** — Subprocess discovery, stdin/stdout communication, `blar-codec-*`
3. **Text serializer** — `blar text` command with printable-binary payloads and partial expansion
4. **Text deserializer** — `blar from-text` command
5. **Directory explode** — `blar explode` with metadata sidecars
6. **Directory implode** — `blar implode` reading sidecars back
7. **Glob path selection** — PCRE2-based glob for `--path` in text form and explode

Each phase ships independently and is testable in isolation.
