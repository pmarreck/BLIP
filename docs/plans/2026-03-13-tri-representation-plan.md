# Tri-Representation Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make blar archives expressible in three losslessly interconvertible representations (binary, text, directory tree) and replace hardcoded container expansion with a codec plugin system.

**Architecture:** Codec plugin vtable wraps existing PDF/PNG/ZIP expansion functions. Text serializer walks the archive entry list and emits indented text with printable-binary payloads. Directory explode writes files + JSON metadata sidecars. All conversions are lossless round-trips.

**Tech Stack:** C (blar.c, blar_common.h), Zig (lib.zig, existing modules), printable-binary (vendored), PCRE2 (for glob, future phase).

**Design Doc:** `docs/plans/2026-03-13-tri-representation-design.md`

---

## Task 1: Define Codec Interface (C header)

**Files:**
- Modify: `src/blip.h` (add codec types after existing typedefs)
- Modify: `src/blar.c` (add codec struct instances, no behavior change yet)

**Step 1: Add codec type definitions to blip.h**

Add after the existing `blip_archive_entry` typedef (around line 50):

```c
/* ── Codec plugin interface ── */

typedef struct entry_list entry_list_t;  /* forward decl, defined in blar.c */

typedef struct blar_codec {
    const char *name;                    /* e.g. "pdf", "png", "zip" */
    const char *const *extensions;       /* NULL-terminated: {".pdf", NULL} */
    bool (*detect)(const uint8_t *buf, size_t len);
    bool (*expand)(entry_list_t *el, const uint8_t *content, size_t content_len,
                   const blip_archive_entry *entry);
    /* collapse is called during extraction to reconstruct the original file
       from its container children. Returns malloc'd buffer in *out. */
    bool (*collapse)(const uint8_t *archive_buf, size_t archive_len,
                     size_t dir_index, size_t entry_count,
                     uint8_t **out, size_t *out_len);
} blar_codec_t;

typedef struct blar_codec_registry {
    const blar_codec_t *codecs;
    size_t count;
} blar_codec_registry_t;

const blar_codec_t *blar_codec_find_by_name(const blar_codec_registry_t *reg,
                                             const char *name, size_t name_len);
const blar_codec_t *blar_codec_detect(const blar_codec_registry_t *reg,
                                       const uint8_t *buf, size_t len);
```

**Step 2: Run build to verify header compiles**

Run: `nix develop -c zig build 2>&1 | tail -20`
Expected: Build succeeds (warnings OK, no errors)

**Step 3: Commit**

```bash
git add src/blip.h
git commit -m "feat: add codec plugin interface types to blip.h"
```

---

## Task 2: Extract PDF Codec Struct

**Files:**
- Modify: `src/blar.c` (wrap existing `expand_pdf_container` + extraction logic)

**Step 1: Create PDF codec struct and detection/expand wrappers**

Near the top of blar.c (after includes, before `expand_zip_container`), add:

```c
/* ── PDF Codec ── */
static const char *pdf_extensions[] = {".pdf", NULL};

static bool pdf_detect(const uint8_t *buf, size_t len) {
    return blip_is_pdf(buf, len);
}

/* expand_pdf_container already exists with correct signature */

static const blar_codec_t codec_pdf = {
    .name = "pdf",
    .extensions = pdf_extensions,
    .detect = pdf_detect,
    .expand = expand_pdf_container,
    .collapse = NULL,  /* extraction handled inline for now */
};
```

Note: The existing `expand_pdf_container` already has the exact signature `bool (*)(entry_list_t *, const uint8_t *, size_t, const blip_archive_entry *)` — just wire it up. The `collapse` function will be extracted from the Pass 3 extraction code in a later task.

**Step 2: Repeat for PNG and ZIP**

```c
/* ── PNG Codec ── */
static const char *png_extensions[] = {".png", NULL};

static bool png_detect(const uint8_t *buf, size_t len) {
    return len >= 8 && blip_is_png(buf, len);
}

static const blar_codec_t codec_png = {
    .name = "png",
    .extensions = png_extensions,
    .detect = png_detect,
    .expand = expand_png_container,
    .collapse = NULL,
};

/* ── ZIP Codec ── */
static const char *zip_extensions[] = {".zip", ".epub", ".docx", ".xlsx", ".pptx",
                                        ".jar", ".apk", ".odt", ".ods", NULL};

static bool zip_detect(const uint8_t *buf, size_t len) {
    return len >= 4 && blip_is_zip(buf, len);
}

static const blar_codec_t codec_zip = {
    .name = "zip",
    .extensions = zip_extensions,
    .detect = zip_detect,
    .expand = expand_zip_container,
    .collapse = NULL,
};
```

**Step 3: Create the built-in registry and lookup functions**

```c
/* ── Built-in Codec Registry ── */
static const blar_codec_t builtin_codecs[] = {
    codec_zip,   /* check zip first (epub, docx are zips) */
    codec_pdf,
    codec_png,
};

static const blar_codec_registry_t builtin_registry = {
    .codecs = builtin_codecs,
    .count = sizeof(builtin_codecs) / sizeof(builtin_codecs[0]),
};

const blar_codec_t *blar_codec_find_by_name(const blar_codec_registry_t *reg,
                                             const char *name, size_t name_len) {
    for (size_t i = 0; i < reg->count; i++) {
        if (strlen(reg->codecs[i].name) == name_len &&
            memcmp(reg->codecs[i].name, name, name_len) == 0)
            return &reg->codecs[i];
    }
    return NULL;
}

const blar_codec_t *blar_codec_detect(const blar_codec_registry_t *reg,
                                       const uint8_t *buf, size_t len) {
    for (size_t i = 0; i < reg->count; i++) {
        if (reg->codecs[i].detect(buf, len))
            return &reg->codecs[i];
    }
    return NULL;
}
```

**Step 4: Run build to verify**

Run: `nix develop -c zig build 2>&1 | tail -20`
Expected: Build succeeds

**Step 5: Commit**

```bash
git add src/blar.c src/blip.h
git commit -m "feat: wrap PDF/PNG/ZIP expansion as codec plugin structs"
```

---

## Task 3: Replace Detection Dispatch with Codec Registry

**Files:**
- Modify: `src/blar.c` — `collect_entries_recurse()` (around line 1170)

**Step 1: Replace the three `if (!expanded && ...)` blocks with a single registry loop**

Find the detection dispatch in `collect_entries_recurse`. Replace the three sequential if-blocks (ZIP, PDF, PNG) with:

```c
if (el->expand_containers && !expanded) {
    const blar_codec_t *codec = blar_codec_detect(&builtin_registry,
                                                    content, content_len);
    if (codec) {
        /* ZIP special case: only expand if --expand-all-zips or not archive ext */
        if (strcmp(codec->name, "zip") == 0 &&
            !el->expand_all_zips && is_archive_extension(entry_copy.path)) {
            codec = NULL;
        }
        if (codec && codec->expand(el, content, content_len, &entry_copy)) {
            expanded = true;
        }
    }
}
```

This preserves the existing ZIP archive-extension guard while using the registry for detection.

**Step 2: Run existing tests to verify no behavior change**

Run: `nix develop -c zig build test 2>&1 | tail -5`
Expected: All tests pass

Run: `nix develop -c bash tests/container_expansion_test.sh 2>&1 | tail -10`
Expected: All container expansion tests pass (if test exists and test PDFs/PNGs available)

**Step 3: Commit**

```bash
git add src/blar.c
git commit -m "refactor: use codec registry for container detection dispatch"
```

---

## Task 4: Replace Extraction Dispatch with Codec Registry Lookup

**Files:**
- Modify: `src/blar.c` — Pass 3 extraction (around line 2164)

**Step 1: Replace `co` type string comparisons with registry lookup**

In the extraction Pass 3, where `co_type` is checked with `memcmp(co_type, "pdf", 3)`, replace the dispatch with:

```c
const blar_codec_t *codec = blar_codec_find_by_name(&builtin_registry,
                                                      co_type, co_type_len);
if (!codec) {
    fprintf(stderr, "warning: codec \"%.*s\" not found, extracting raw parts\n",
            (int)co_type_len, co_type);
    /* TODO: extract raw children as files */
    continue;
}
```

For now, keep the existing inline extraction code for each type — just add the warning path for unknown codecs. Moving extraction into `collapse` callbacks is a future refactor.

**Step 2: Update `blar list` type character assignment**

Replace the hardcoded `memcmp` chain with:

```c
const blar_codec_t *codec = blar_codec_find_by_name(&builtin_registry,
                                                      co_type, co_type_len);
if (codec) {
    if (strcmp(codec->name, "pdf") == 0) type_char = 'p';
    else if (strcmp(codec->name, "png") == 0) type_char = 'n';
    else type_char = 'z';
} else {
    type_char = '?';  /* unknown codec */
}
```

**Step 3: Build and test**

Run: `nix develop -c zig build 2>&1 | tail -20`
Expected: Build succeeds

**Step 4: Commit**

```bash
git add src/blar.c
git commit -m "refactor: use codec registry lookup for extraction and list display"
```

---

## Task 5: Text Serializer — `blar text` command

**Files:**
- Modify: `src/blar.c` — add `cmd_text()` function and wire into main dispatch
- Modify: `src/blip.h` — add `blip_encode_printable_binary` if not already exported (it is — line 1018 of lib.zig)

**Step 1: Write the failing test**

Create a shell test that exercises `blar text`:

```bash
# In tests/text_roundtrip_test.sh
#!/usr/bin/env bash
set -euo pipefail

BLAR="${BLAR:-blar}"
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# Create a simple archive with a text file and a binary file
echo "hello world" > "$TMPDIR/hello.txt"
dd if=/dev/urandom bs=64 count=1 of="$TMPDIR/random.bin" 2>/dev/null

$BLAR create -z "$TMPDIR/test.blar" "$TMPDIR/hello.txt" "$TMPDIR/random.bin"

# Text dump should produce valid output
$BLAR text "$TMPDIR/test.blar" > "$TMPDIR/test.blar.txt"

# Should start with BLAR/1 header
head -1 "$TMPDIR/test.blar.txt" | grep -q "^BLAR/1$" || { echo "FAIL: missing BLAR/1 header"; exit 1; }

# Should contain FILE entries
grep -q 'FILE "hello.txt"' "$TMPDIR/test.blar.txt" || { echo "FAIL: missing hello.txt entry"; exit 1; }
grep -q 'FILE "random.bin"' "$TMPDIR/test.blar.txt" || { echo "FAIL: missing random.bin entry"; exit 1; }

echo "PASS: blar text basic output"
```

**Step 2: Run test to verify it fails**

Run: `nix develop -c bash tests/text_roundtrip_test.sh 2>&1`
Expected: FAIL — `blar text` is not a recognized command

**Step 3: Implement `cmd_text()`**

Add to blar.c before `main()`:

```c
static int cmd_text(int argc, char **argv) {
    if (argc < 1) {
        fprintf(stderr, "Usage: blar text <archive.blar> [--path <glob>] [-o <output>]\n");
        return 1;
    }
    const char *archive_path = argv[0];
    const char *output_path = NULL;
    const char *path_filter = NULL;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-o") == 0 && i + 1 < argc) {
            output_path = argv[++i];
        } else if (strcmp(argv[i], "--path") == 0 && i + 1 < argc) {
            path_filter = argv[++i];
        }
    }

    /* Read archive */
    uint8_t *buf = NULL;
    size_t buf_len = 0;
    if (read_file(archive_path, &buf, &buf_len) != 0) {
        fprintf(stderr, "error: cannot read '%s'\n", archive_path);
        return 1;
    }

    /* Decompress if needed */
    uint8_t *data = buf;
    size_t data_len = buf_len;
    bool owns_data = false;
    if (blip_is_compressed(buf, buf_len)) {
        uint8_t *dec = NULL;
        size_t dec_len = 0;
        if (blip_decompress_container(buf, buf_len, &dec, &dec_len) != BLIP_OK) {
            fprintf(stderr, "error: decompression failed\n");
            free(buf);
            return 1;
        }
        data = dec;
        data_len = dec_len;
        owns_data = true;
    }

    FILE *out = stdout;
    if (output_path) {
        out = fopen(output_path, "w");
        if (!out) {
            fprintf(stderr, "error: cannot open '%s' for writing\n", output_path);
            if (owns_data) blip_free(data);
            free(buf);
            return 1;
        }
    }

    /* Header */
    fprintf(out, "BLAR/1\n");

    /* Walk entries */
    uint64_t count = 0;
    blip_archive_file_count(data, data_len, &count);

    int depth = 0;
    for (uint64_t i = 0; i < count; i++) {
        int entry_type = blip_archive_entry_type(data, data_len, i);
        const char *path = NULL;
        size_t path_len = 0;
        blip_archive_file_path(data, data_len, i, &path, &path_len);

        /* TODO: path_filter matching (Task 11) */

        /* Indent */
        char indent[64] = {0};
        int ind = depth * 2;
        if (ind > 62) ind = 62;
        memset(indent, ' ', ind);

        if (entry_type == 0x07) {
            /* DIR entry */
            const char *co_type = NULL;
            size_t co_type_len = 0;
            blip_archive_entry_container_type(data, data_len, i,
                &co_type, &co_type_len);

            fprintf(out, "%sDIR \"%.*s\"", indent, (int)path_len, path);

            /* Metadata */
            uint32_t mode = 0;
            int64_t mtime = 0;
            blip_archive_entry_metadata(data, data_len, i, &mode, &mtime);
            if (mode) fprintf(out, " mode=0%o", mode);
            if (mtime) fprintf(out, " mtime=%lld", (long long)mtime);
            if (co_type) fprintf(out, " co=%.*s", (int)co_type_len, co_type);

            fprintf(out, "\n");
            depth++;
        } else if (entry_type == 0x05) {
            /* Sentinel (end of DIR) */
            if (depth > 0) depth--;
        } else if (entry_type == 0x06) {
            /* FILE entry */
            fprintf(out, "%sFILE \"%.*s\"", indent, (int)path_len, path);

            /* Metadata */
            uint32_t mode = 0;
            int64_t mtime = 0;
            blip_archive_entry_metadata(data, data_len, i, &mode, &mtime);
            if (mode) fprintf(out, " mode=0%o", mode);
            if (mtime) fprintf(out, " mtime=%lld", (long long)mtime);

            /* Container-specific metadata */
            const char *jx = NULL;
            size_t jx_len = 0;
            blip_archive_entry_jxl_source(data, data_len, i, &jx, &jx_len);
            if (jx) fprintf(out, " jx=%.*s", (int)jx_len, jx);

            uint64_t po = 0, pl = 0;
            if (blip_archive_entry_pdf_offset(data, data_len, i, &po) == BLIP_OK && po)
                fprintf(out, " po=%llu", (unsigned long long)po);
            if (blip_archive_entry_pdf_length(data, data_len, i, &pl) == BLIP_OK && pl)
                fprintf(out, " pl=%llu", (unsigned long long)pl);

            fprintf(out, "\n");

            /* Payload: encode with printable-binary */
            const uint8_t *content = NULL;
            size_t content_len = 0;
            if (blip_archive_file_content(data, data_len, i,
                    &content, &content_len) == BLIP_OK && content_len > 0) {
                uint8_t *pb = NULL;
                size_t pb_len = 0;
                if (blip_encode_printable_binary(content, content_len,
                        &pb, &pb_len) == BLIP_OK) {
                    /* Write payload lines, wrapping at ~76 chars */
                    fprintf(out, "%s  |", indent);
                    size_t col = 0;
                    for (size_t j = 0; j < pb_len; j++) {
                        fputc(pb[j], out);
                        col++;
                        if (col >= 76 && j + 1 < pb_len) {
                            fprintf(out, "|\n%s  |", indent);
                            col = 0;
                        }
                    }
                    fprintf(out, "|\n");
                    blip_free(pb);
                }
            }
        }
    }

    if (output_path) fclose(out);
    if (owns_data) blip_free(data);
    free(buf);
    return 0;
}
```

**Step 4: Wire `cmd_text` into main dispatch**

In `main()`, add alongside other commands:

```c
if (strcmp(arg1, "text") == 0)      return cmd_text(argc - 2, argv + 2);
```

**Step 5: Run test to verify it passes**

Run: `nix develop -c bash tests/text_roundtrip_test.sh 2>&1`
Expected: PASS

**Step 6: Commit**

```bash
git add src/blar.c tests/text_roundtrip_test.sh
git commit -m "feat: add 'blar text' command for human-readable archive dump"
```

---

## Task 6: Text Deserializer — `blar from-text` command

**Files:**
- Modify: `src/blar.c` — add `cmd_from_text()` function

**Step 1: Write the failing test**

Extend `tests/text_roundtrip_test.sh`:

```bash
# Round-trip: archive → text → archive → extract → compare
$BLAR from-text "$TMPDIR/test.blar.txt" -o "$TMPDIR/roundtrip.blar"

mkdir -p "$TMPDIR/original" "$TMPDIR/roundtrip"
$BLAR extract "$TMPDIR/test.blar" -C "$TMPDIR/original"
$BLAR extract "$TMPDIR/roundtrip.blar" -C "$TMPDIR/roundtrip"

# Compare extracted files
diff "$TMPDIR/original/hello.txt" "$TMPDIR/roundtrip/hello.txt" || { echo "FAIL: hello.txt differs"; exit 1; }
cmp "$TMPDIR/original/random.bin" "$TMPDIR/roundtrip/random.bin" || { echo "FAIL: random.bin differs"; exit 1; }

echo "PASS: blar text round-trip"
```

**Step 2: Run test to verify it fails**

Run: `nix develop -c bash tests/text_roundtrip_test.sh 2>&1`
Expected: FAIL — `blar from-text` not recognized

**Step 3: Implement `cmd_from_text()`**

This is the most complex task. The parser reads line by line:

```c
static int cmd_from_text(int argc, char **argv) {
    if (argc < 1) {
        fprintf(stderr, "Usage: blar from-text <file.txt> -o <archive.blar> [-z]\n");
        return 1;
    }
    const char *input_path = argv[0];
    const char *output_path = NULL;
    bool compress = false;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-o") == 0 && i + 1 < argc)
            output_path = argv[++i];
        else if (strcmp(argv[i], "-z") == 0)
            compress = true;
    }
    if (!output_path) {
        fprintf(stderr, "error: -o <output> required\n");
        return 1;
    }

    /* Read input text */
    uint8_t *text = NULL;
    size_t text_len = 0;
    if (read_file(input_path, &text, &text_len) != 0) {
        fprintf(stderr, "error: cannot read '%s'\n", input_path);
        return 1;
    }

    /* Parse text into entry list */
    entry_list_t el;
    entry_list_init(&el);

    /* Line-by-line parser */
    const char *p = (const char *)text;
    const char *end = p + text_len;
    char *line = NULL;
    size_t line_cap = 0;

    /* Skip header */
    /* Read "BLAR/1" line */
    const char *nl = memchr(p, '\n', end - p);
    if (!nl || (nl - p) < 6 || memcmp(p, "BLAR/1", 6) != 0) {
        fprintf(stderr, "error: missing BLAR/1 header\n");
        free(text);
        return 1;
    }
    p = nl + 1;

    /* State: stack of DIR indices for nesting */
    size_t dir_stack[256];
    int stack_depth = 0;
    int pending_payload_idx = -1;  /* index of FILE entry awaiting payload */
    /* Payload accumulation buffer */
    uint8_t *payload_buf = NULL;
    size_t payload_len = 0;
    size_t payload_cap = 0;

    while (p < end) {
        nl = memchr(p, '\n', end - p);
        size_t llen = nl ? (size_t)(nl - p) : (size_t)(end - p);

        /* Measure indent (leading spaces) */
        size_t indent = 0;
        while (indent < llen && p[indent] == ' ') indent++;

        const char *trimmed = p + indent;
        size_t trimmed_len = llen - indent;

        if (trimmed_len == 0) {
            /* blank line */
        } else if (trimmed[0] == '|') {
            /* Payload line: |...| */
            /* Append content between pipes to payload_buf */
            const char *pstart = trimmed + 1;
            const char *pend_mark = memchr(pstart, '|', trimmed_len - 1);
            if (pend_mark) {
                size_t chunk_len = pend_mark - pstart;
                /* Grow payload buffer */
                if (payload_len + chunk_len > payload_cap) {
                    payload_cap = (payload_len + chunk_len) * 2;
                    payload_buf = realloc(payload_buf, payload_cap);
                }
                memcpy(payload_buf + payload_len, pstart, chunk_len);
                payload_len += chunk_len;
            }
        } else {
            /* Flush pending payload if any */
            if (pending_payload_idx >= 0 && payload_len > 0) {
                /* Decode printable-binary payload */
                uint8_t *decoded = NULL;
                size_t decoded_len = 0;
                if (blip_decode(payload_buf, payload_len, &decoded, &decoded_len) == BLIP_OK) {
                    /* Store decoded content in entry */
                    el.entries[pending_payload_idx].content = decoded;
                    el.entries[pending_payload_idx].content_len = decoded_len;
                }
                payload_len = 0;
                pending_payload_idx = -1;
            }

            /* Close DIRs based on indent change */
            int expected_depth = (int)(indent / 2);
            while (stack_depth > expected_depth) {
                /* Add sentinel */
                blip_archive_entry sentinel = {0};
                sentinel.entry_type = 0x05;  /* sentinel */
                entry_list_add(&el, &sentinel, NULL, 0);
                stack_depth--;
            }

            if (memcmp(trimmed, "DIR ", 4) == 0) {
                /* Parse: DIR "name" key=val key=val ... */
                blip_archive_entry entry = {0};
                entry.entry_type = 0x07;
                /* Parse quoted name */
                const char *q1 = memchr(trimmed + 4, '"', trimmed_len - 4);
                if (q1) {
                    const char *q2 = memchr(q1 + 1, '"', trimmed_len - (q1 + 1 - trimmed));
                    if (q2) {
                        size_t namelen = q2 - q1 - 1;
                        char *name = malloc(namelen + 1);
                        memcpy(name, q1 + 1, namelen);
                        name[namelen] = '\0';
                        entry.path = name;
                        entry.path_len = namelen;
                        /* Parse key=value pairs after closing quote */
                        parse_text_metadata(q2 + 1, trimmed + trimmed_len, &entry);
                    }
                }
                entry_list_add(&el, &entry, NULL, 0);
                dir_stack[stack_depth++] = el.count - 1;
            } else if (memcmp(trimmed, "FILE ", 5) == 0) {
                blip_archive_entry entry = {0};
                entry.entry_type = 0x06;
                const char *q1 = memchr(trimmed + 5, '"', trimmed_len - 5);
                if (q1) {
                    const char *q2 = memchr(q1 + 1, '"', trimmed_len - (q1 + 1 - trimmed));
                    if (q2) {
                        size_t namelen = q2 - q1 - 1;
                        char *name = malloc(namelen + 1);
                        memcpy(name, q1 + 1, namelen);
                        name[namelen] = '\0';
                        entry.path = name;
                        entry.path_len = namelen;
                        parse_text_metadata(q2 + 1, trimmed + trimmed_len, &entry);
                    }
                }
                entry_list_add(&el, &entry, NULL, 0);
                pending_payload_idx = (int)(el.count - 1);
            }
        }

        p = nl ? nl + 1 : end;
    }

    /* Flush final payload */
    if (pending_payload_idx >= 0 && payload_len > 0) {
        uint8_t *decoded = NULL;
        size_t decoded_len = 0;
        if (blip_decode(payload_buf, payload_len, &decoded, &decoded_len) == BLIP_OK) {
            el.entries[pending_payload_idx].content = decoded;
            el.entries[pending_payload_idx].content_len = decoded_len;
        }
    }

    /* Close remaining DIRs */
    while (stack_depth > 0) {
        blip_archive_entry sentinel = {0};
        sentinel.entry_type = 0x05;
        entry_list_add(&el, &sentinel, NULL, 0);
        stack_depth--;
    }

    /* Build archive from entry list */
    uint8_t *archive = NULL;
    size_t archive_len = 0;
    /* Use blip_archive_create_full with the entry list */
    /* ... (reuse existing archive creation logic) ... */

    if (compress) {
        uint8_t *compressed = NULL;
        size_t compressed_len = 0;
        blip_compress_container(archive, archive_len, &compressed, &compressed_len);
        free(archive);
        archive = compressed;
        archive_len = compressed_len;
    }

    write_file(output_path, archive, archive_len);
    free(archive);
    free(payload_buf);
    free(text);
    entry_list_free(&el);

    return 0;
}
```

Note: The `parse_text_metadata` helper parses `key=value` pairs from the text after the quoted filename. This needs to handle: `mode=0755`, `mtime=1710000000`, `co=pdf`, `jx=jpeg`, `po=1234`, `pl=5678`.

```c
static void parse_text_metadata(const char *start, const char *end,
                                 blip_archive_entry *entry) {
    const char *p = start;
    while (p < end) {
        while (p < end && *p == ' ') p++;
        if (p >= end) break;

        const char *eq = memchr(p, '=', end - p);
        if (!eq) break;

        size_t key_len = eq - p;
        const char *val = eq + 1;
        const char *val_end = memchr(val, ' ', end - val);
        if (!val_end) val_end = end;
        size_t val_len = val_end - val;

        if (key_len == 4 && memcmp(p, "mode", 4) == 0) {
            entry->mode = (uint32_t)strtoul(val, NULL, 8);
        } else if (key_len == 5 && memcmp(p, "mtime", 5) == 0) {
            entry->mtime = (int64_t)strtoll(val, NULL, 10);
        } else if (key_len == 2 && memcmp(p, "co", 2) == 0) {
            entry->container_type = strndup(val, val_len);
            entry->container_type_len = val_len;
        } else if (key_len == 2 && memcmp(p, "jx", 2) == 0) {
            entry->jxl_source_format = strndup(val, val_len);
            entry->jxl_source_format_len = val_len;
        } else if (key_len == 2 && memcmp(p, "po", 2) == 0) {
            entry->pdf_stream_offset = (uint64_t)strtoull(val, NULL, 10);
        } else if (key_len == 2 && memcmp(p, "pl", 2) == 0) {
            entry->pdf_stream_length = (uint64_t)strtoull(val, NULL, 10);
        }
        p = val_end;
    }
}
```

**Step 4: Wire into main dispatch**

```c
if (strcmp(arg1, "from-text") == 0)  return cmd_from_text(argc - 2, argv + 2);
```

**Step 5: Run test to verify it passes**

Run: `nix develop -c bash tests/text_roundtrip_test.sh 2>&1`
Expected: PASS — round-trip produces identical files

**Step 6: Commit**

```bash
git add src/blar.c tests/text_roundtrip_test.sh
git commit -m "feat: add 'blar from-text' command for text-to-binary conversion"
```

---

## Task 7: Directory Explode — `blar explode` command

**Files:**
- Modify: `src/blar.c` — add `cmd_explode()` function

**Step 1: Write the failing test**

Add to `tests/text_roundtrip_test.sh` (or new `tests/explode_implode_test.sh`):

```bash
#!/usr/bin/env bash
set -euo pipefail

BLAR="${BLAR:-blar}"
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

echo "hello world" > "$TMPDIR/hello.txt"
chmod 644 "$TMPDIR/hello.txt"
mkdir -p "$TMPDIR/subdir"
echo "nested" > "$TMPDIR/subdir/nested.txt"

$BLAR create -z "$TMPDIR/test.blar" "$TMPDIR/hello.txt" "$TMPDIR/subdir"

# Explode to directory tree
$BLAR explode "$TMPDIR/test.blar" -C "$TMPDIR/tree"

# Should have files
test -f "$TMPDIR/tree/hello.txt" || { echo "FAIL: hello.txt missing"; exit 1; }
test -f "$TMPDIR/tree/subdir/nested.txt" || { echo "FAIL: nested.txt missing"; exit 1; }

# Should have metadata sidecar
test -f "$TMPDIR/tree/__meta__.json" || { echo "FAIL: __meta__.json missing"; exit 1; }

# File content should match
diff "$TMPDIR/hello.txt" "$TMPDIR/tree/hello.txt" || { echo "FAIL: hello.txt differs"; exit 1; }
diff "$TMPDIR/subdir/nested.txt" "$TMPDIR/tree/subdir/nested.txt" || { echo "FAIL: nested.txt differs"; exit 1; }

echo "PASS: blar explode basic"
```

**Step 2: Run test to verify it fails**

Run: `nix develop -c bash tests/explode_implode_test.sh 2>&1`
Expected: FAIL — `blar explode` not recognized

**Step 3: Implement `cmd_explode()`**

```c
static int cmd_explode(int argc, char **argv) {
    if (argc < 1) {
        fprintf(stderr, "Usage: blar explode <archive.blar> -C <output_dir>\n");
        return 1;
    }
    const char *archive_path = argv[0];
    const char *output_dir = ".";

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-C") == 0 && i + 1 < argc)
            output_dir = argv[++i];
    }

    /* Read + decompress archive */
    uint8_t *buf = NULL;
    size_t buf_len = 0;
    if (read_file(archive_path, &buf, &buf_len) != 0) return 1;

    uint8_t *data = buf;
    size_t data_len = buf_len;
    bool owns_data = false;
    if (blip_is_compressed(buf, buf_len)) {
        uint8_t *dec = NULL;
        size_t dec_len = 0;
        if (blip_decompress_container(buf, buf_len, &dec, &dec_len) != BLIP_OK) {
            free(buf);
            return 1;
        }
        data = dec; data_len = dec_len; owns_data = true;
    }

    mkdir_p(output_dir);

    uint64_t count = 0;
    blip_archive_file_count(data, data_len, &count);

    /* Build path prefix stack for nested dirs */
    char path_buf[4096] = {0};

    /* Per-directory metadata accumulator */
    /* Write __meta__.json for each directory */
    /* Structure: { "filename": { "mode": N, "mtime": N, ... }, ... } */

    /* Simple approach: two passes
       Pass 1: create dirs and extract files
       Pass 2: write __meta__.json sidecars */

    /* Pass 1: extract */
    int depth = 0;
    char *dir_paths[256];
    memset(dir_paths, 0, sizeof(dir_paths));
    dir_paths[0] = strdup(output_dir);

    for (uint64_t i = 0; i < count; i++) {
        int etype = blip_archive_entry_type(data, data_len, i);
        const char *path = NULL;
        size_t path_len = 0;
        blip_archive_file_path(data, data_len, i, &path, &path_len);

        if (etype == 0x07) {
            /* DIR: create directory */
            snprintf(path_buf, sizeof(path_buf), "%s/%.*s",
                     dir_paths[depth], (int)path_len, path);
            /* Remove trailing slash for mkdir */
            size_t pbl = strlen(path_buf);
            if (pbl > 0 && path_buf[pbl - 1] == '/') path_buf[pbl - 1] = '\0';
            mkdir_p(path_buf);
            depth++;
            dir_paths[depth] = strdup(path_buf);
        } else if (etype == 0x05) {
            /* Sentinel: pop dir */
            if (depth > 0) {
                free(dir_paths[depth]);
                dir_paths[depth] = NULL;
                depth--;
            }
        } else if (etype == 0x06) {
            /* FILE: extract content */
            snprintf(path_buf, sizeof(path_buf), "%s/%.*s",
                     dir_paths[depth], (int)path_len, path);

            const uint8_t *content = NULL;
            size_t content_len = 0;
            blip_archive_file_content(data, data_len, i, &content, &content_len);

            write_file(path_buf, content, content_len);
        }
    }

    /* Pass 2: write __meta__.json sidecars */
    /* Re-walk entries, accumulate metadata per directory, write JSON */
    depth = 0;
    dir_paths[0] = strdup(output_dir);
    /* ... (JSON metadata writing logic) ... */

    /* Cleanup */
    for (int d = 0; d <= depth; d++) free(dir_paths[d]);
    if (owns_data) blip_free(data);
    free(buf);
    return 0;
}
```

The `__meta__.json` sidecar writing involves accumulating metadata for each entry in a directory and writing a JSON object. Use `fprintf` to write JSON directly — no need for a JSON library for simple key-value output.

**Step 4: Wire into main dispatch**

```c
if (strcmp(arg1, "explode") == 0)    return cmd_explode(argc - 2, argv + 2);
```

**Step 5: Run test to verify it passes**

Run: `nix develop -c bash tests/explode_implode_test.sh 2>&1`
Expected: PASS

**Step 6: Commit**

```bash
git add src/blar.c tests/explode_implode_test.sh
git commit -m "feat: add 'blar explode' command for directory tree extraction"
```

---

## Task 8: Directory Implode — `blar implode` command

**Files:**
- Modify: `src/blar.c` — add `cmd_implode()` function

**Step 1: Write the failing test**

Extend `tests/explode_implode_test.sh`:

```bash
# Round-trip: archive → explode → implode → extract → compare
$BLAR implode "$TMPDIR/tree" -o "$TMPDIR/roundtrip.blar"

mkdir -p "$TMPDIR/original" "$TMPDIR/roundtrip"
$BLAR extract "$TMPDIR/test.blar" -C "$TMPDIR/original"
$BLAR extract "$TMPDIR/roundtrip.blar" -C "$TMPDIR/roundtrip"

diff "$TMPDIR/original/hello.txt" "$TMPDIR/roundtrip/hello.txt" || { echo "FAIL: hello.txt differs"; exit 1; }
diff "$TMPDIR/original/subdir/nested.txt" "$TMPDIR/roundtrip/subdir/nested.txt" || { echo "FAIL: nested.txt differs"; exit 1; }

echo "PASS: blar explode/implode round-trip"
```

**Step 2: Run test to verify it fails**

Expected: FAIL — `blar implode` not recognized

**Step 3: Implement `cmd_implode()`**

```c
static int cmd_implode(int argc, char **argv) {
    if (argc < 1) {
        fprintf(stderr, "Usage: blar implode <dir> -o <archive.blar> [-z]\n");
        return 1;
    }
    const char *input_dir = argv[0];
    const char *output_path = NULL;
    bool compress = false;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-o") == 0 && i + 1 < argc)
            output_path = argv[++i];
        else if (strcmp(argv[i], "-z") == 0)
            compress = true;
    }
    if (!output_path) {
        fprintf(stderr, "error: -o <output> required\n");
        return 1;
    }

    /* Walk directory tree, read __meta__.json sidecars, build entry list */
    entry_list_t el;
    entry_list_init(&el);

    /* Recursive directory walker */
    implode_recurse(&el, input_dir, "");

    /* Build archive from entry list (reuse existing create logic) */
    /* ... */

    return 0;
}

static void implode_recurse(entry_list_t *el, const char *base_dir,
                              const char *rel_path) {
    char full_path[4096];
    snprintf(full_path, sizeof(full_path), "%s/%s", base_dir, rel_path);

    /* Read __meta__.json if it exists */
    char meta_path[4096];
    snprintf(meta_path, sizeof(meta_path), "%s/__meta__.json", full_path);
    /* Parse JSON for metadata... */

    /* Scan directory entries (sorted) */
    DIR *dir = opendir(full_path);
    if (!dir) return;

    struct dirent *de;
    while ((de = readdir(dir)) != NULL) {
        if (de->d_name[0] == '.' && (de->d_name[1] == '\0' ||
            (de->d_name[1] == '.' && de->d_name[2] == '\0')))
            continue;
        if (strcmp(de->d_name, "__meta__.json") == 0) continue;
        if (strcmp(de->d_name, "__archive__.json") == 0) continue;

        char child_rel[4096];
        snprintf(child_rel, sizeof(child_rel), "%s%s%s",
                 rel_path, rel_path[0] ? "/" : "", de->d_name);

        char child_full[4096];
        snprintf(child_full, sizeof(child_full), "%s/%s", full_path, de->d_name);

        struct stat st;
        if (stat(child_full, &st) != 0) continue;

        if (S_ISDIR(st.st_mode)) {
            /* Add DIR entry + recurse + sentinel */
            blip_archive_entry entry = {0};
            entry.entry_type = 0x07;
            /* Apply metadata from __meta__.json if present */
            char dir_name[4096];
            snprintf(dir_name, sizeof(dir_name), "%s/", de->d_name);
            entry.path = strdup(dir_name);
            entry.path_len = strlen(dir_name);
            entry_list_add(el, &entry, NULL, 0);

            implode_recurse(el, base_dir, child_rel);

            blip_archive_entry sentinel = {0};
            sentinel.entry_type = 0x05;
            entry_list_add(el, &sentinel, NULL, 0);
        } else if (S_ISREG(st.st_mode)) {
            /* Add FILE entry with content */
            blip_archive_entry entry = {0};
            entry.entry_type = 0x06;
            entry.path = strdup(de->d_name);
            entry.path_len = strlen(de->d_name);
            entry.mode = st.st_mode & 0777;

            uint8_t *content = NULL;
            size_t content_len = 0;
            read_file(child_full, &content, &content_len);
            entry_list_add(el, &entry, content, content_len);
            free(content);
        }
    }
    closedir(dir);
}
```

**Step 4: Wire into main dispatch**

```c
if (strcmp(arg1, "implode") == 0)    return cmd_implode(argc - 2, argv + 2);
```

**Step 5: Run test to verify it passes**

Run: `nix develop -c bash tests/explode_implode_test.sh 2>&1`
Expected: PASS

**Step 6: Commit**

```bash
git add src/blar.c tests/explode_implode_test.sh
git commit -m "feat: add 'blar implode' command for directory tree to archive"
```

---

## Task 9: Container Round-Trip Tests

**Files:**
- Create: `tests/tri_representation_test.sh`

**Step 1: Write comprehensive round-trip tests**

```bash
#!/usr/bin/env bash
set -euo pipefail

BLAR="${BLAR:-blar}"
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# === Test 1: Simple file round-trip via text ===
echo "hello" > "$TMPDIR/t1.txt"
$BLAR create "$TMPDIR/t1.blar" "$TMPDIR/t1.txt"
$BLAR text "$TMPDIR/t1.blar" > "$TMPDIR/t1.txt.blar"
head -1 "$TMPDIR/t1.txt.blar" | grep -q "^BLAR/1$" && pass "text header" || fail "text header"

# === Test 2: Text round-trip ===
$BLAR from-text "$TMPDIR/t1.txt.blar" -o "$TMPDIR/t1_rt.blar"
mkdir -p "$TMPDIR/t1_orig" "$TMPDIR/t1_rt"
$BLAR extract "$TMPDIR/t1.blar" -C "$TMPDIR/t1_orig"
$BLAR extract "$TMPDIR/t1_rt.blar" -C "$TMPDIR/t1_rt"
diff "$TMPDIR/t1_orig/t1.txt" "$TMPDIR/t1_rt/t1.txt" && pass "text round-trip" || fail "text round-trip"

# === Test 3: Explode/implode round-trip ===
$BLAR explode "$TMPDIR/t1.blar" -C "$TMPDIR/t1_tree"
test -f "$TMPDIR/t1_tree/t1.txt" && pass "explode creates file" || fail "explode creates file"
$BLAR implode "$TMPDIR/t1_tree" -o "$TMPDIR/t1_imp.blar"
mkdir -p "$TMPDIR/t1_imp"
$BLAR extract "$TMPDIR/t1_imp.blar" -C "$TMPDIR/t1_imp"
diff "$TMPDIR/t1_orig/t1.txt" "$TMPDIR/t1_imp/t1.txt" && pass "explode/implode round-trip" || fail "explode/implode round-trip"

# === Test 4: Nested directories ===
mkdir -p "$TMPDIR/nested/a/b"
echo "deep" > "$TMPDIR/nested/a/b/deep.txt"
echo "top" > "$TMPDIR/nested/top.txt"
$BLAR create "$TMPDIR/nested.blar" "$TMPDIR/nested"
$BLAR text "$TMPDIR/nested.blar" | grep -q 'DIR "a/"' && pass "nested dir in text" || fail "nested dir in text"
$BLAR explode "$TMPDIR/nested.blar" -C "$TMPDIR/nested_tree"
test -f "$TMPDIR/nested_tree/nested/a/b/deep.txt" && pass "nested explode" || fail "nested explode"

# === Test 5: Binary content preserved ===
dd if=/dev/urandom bs=256 count=1 of="$TMPDIR/bin.dat" 2>/dev/null
$BLAR create "$TMPDIR/bin.blar" "$TMPDIR/bin.dat"
$BLAR text "$TMPDIR/bin.blar" > "$TMPDIR/bin.blar.txt"
$BLAR from-text "$TMPDIR/bin.blar.txt" -o "$TMPDIR/bin_rt.blar"
mkdir -p "$TMPDIR/bin_orig" "$TMPDIR/bin_rt"
$BLAR extract "$TMPDIR/bin.blar" -C "$TMPDIR/bin_orig"
$BLAR extract "$TMPDIR/bin_rt.blar" -C "$TMPDIR/bin_rt"
cmp "$TMPDIR/bin_orig/bin.dat" "$TMPDIR/bin_rt/bin.dat" && pass "binary round-trip" || fail "binary round-trip"

# === Test 6: Container archive text output ===
# Create a PNG if python3 + PIL available
if python3 -c "from PIL import Image; Image.new('RGBA', (4,4), (255,0,0,255)).save('/tmp/test_tri.png')" 2>/dev/null; then
    $BLAR create "$TMPDIR/img.blar" /tmp/test_tri.png
    $BLAR text "$TMPDIR/img.blar" | grep -q 'co=png' && pass "container type in text" || fail "container type in text"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
test $FAIL -eq 0
```

**Step 2: Run tests**

Run: `nix develop -c bash tests/tri_representation_test.sh 2>&1`
Expected: All tests PASS

**Step 3: Commit**

```bash
git add tests/tri_representation_test.sh
git commit -m "test: add tri-representation round-trip tests"
```

---

## Task 10: External Codec Protocol (Future)

**Note:** This task is deferred — the built-in codec refactor provides immediate value. External codec discovery via `blar-codec-*` executables on PATH can be added later when there's a concrete use case (e.g., BG3 save files).

**Sketch of implementation:**
1. At startup or lazily, scan PATH for `blar-codec-*` executables
2. Run `blar-codec-foo info` to get JSON metadata (name, extensions, magic)
3. Register as additional codecs in the registry
4. `expand` and `collapse` pipe data through stdin/stdout
5. Built-in codecs always take priority over external ones

---

## Task 11: Glob Path Selection (Future)

**Note:** Deferred — the `--path` flag in `blar text` and `blar explode` can start with exact string prefix matching. Full PCRE2-based glob support (from dirtree) added when partial expansion is more mature.

**Sketch:**
1. Port `globToRegex()` from dirtree (PCRE2-based)
2. Apply to `--path` argument in `cmd_text()` and `cmd_explode()`
3. Filter entries: only emit those whose full path matches the pattern
4. For text form: non-matching subtrees shown as `<opaque>` reference

---

## Summary

| Task | Description | Dependencies |
|------|-------------|--------------|
| 1 | Codec interface types in blip.h | None |
| 2 | PDF/PNG/ZIP codec structs + registry | Task 1 |
| 3 | Replace detection dispatch with registry | Task 2 |
| 4 | Replace extraction dispatch with registry lookup | Task 2 |
| 5 | `blar text` command (serializer) | None |
| 6 | `blar from-text` command (deserializer) | Task 5 |
| 7 | `blar explode` command | None |
| 8 | `blar implode` command | Task 7 |
| 9 | Integration tests | Tasks 5-8 |
| 10 | External codec protocol | Task 2 (future) |
| 11 | Glob path selection | Tasks 5, 7 (future) |

Tasks 1-4 (codec refactor) and Tasks 5-8 (text/directory) are independent tracks that can be done in parallel.
