#!/usr/bin/env bash
set -euo pipefail

# Build Blip Archiver macOS app
# Must be run from the macos-app/ directory or BLIP root
# Requires: nix develop shell (for libjxl, zlib, etc.)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BLIP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
APP_BUNDLE="$BUILD_DIR/Blip Archiver.app"

SDK="$(xcrun --show-sdk-path)"
ARCH="$(uname -m)"

echo "=== Building Blip Archiver ==="

# Step 1: Build libblip.a via Zig
echo "Building libblip.a..."
cd "$BLIP_ROOT"
zig build 2>&1 | grep -v "^warning: Unrecognized" || true

# Step 2: Find Zig-built static libs for LZ4 and ZSTD
LZ4_LIB="$(find .zig-cache -name 'liblz4.a' 2>/dev/null | head -1)"
ZSTD_LIB="$(find .zig-cache -name 'libzstd.a' 2>/dev/null | head -1)"
FLAC_LIB="$(find .zig-cache -name 'libflac.a' 2>/dev/null | head -1)"

if [ -z "$LZ4_LIB" ] || [ -z "$ZSTD_LIB" ]; then
    echo "ERROR: Cannot find liblz4.a, libzstd.a, or libflac.a in .zig-cache"
    exit 1
fi

echo "  libblip.a: zig-out/lib/libblip.a"
echo "  liblz4.a:  $LZ4_LIB"
echo "  libzstd.a: $ZSTD_LIB"
echo "  libflac.a: $FLAC_LIB"

# Step 3: Create app bundle structure
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Step 4: Compile Swift sources
echo "Compiling Swift..."

# Extract library search paths from NIX_LDFLAGS
LIB_SEARCH_FLAGS=""
if [ -n "${NIX_LDFLAGS:-}" ]; then
    for flag in $NIX_LDFLAGS; do
        case "$flag" in
            -L*) LIB_SEARCH_FLAGS="$LIB_SEARCH_FLAGS $flag" ;;
        esac
    done
fi

# Use the SYSTEM SDK (Xcode) for Swift, not the Nix SDK.
# Nix SDK has Swift 5.10 modules incompatible with the system Swift 6.x compiler.
# We only need NIX_LDFLAGS for library search paths (libjxl, brotli, etc).
# Must unset SDKROOT so xcrun finds the Xcode SDK, not the Nix one.
# Find the Xcode SDK directly — nix overrides xcrun
SYSTEM_SDK="$(ls -d /Applications/Xcode*.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX*.sdk 2>/dev/null | sort -V | tail -1)"
if [ -z "$SYSTEM_SDK" ]; then
    echo "ERROR: Cannot find Xcode macOS SDK"
    exit 1
fi
echo "  System SDK: $SYSTEM_SDK"

# Use the SYSTEM swiftc (not Nix's) to match the SDK version
SYSTEM_SWIFTC="$(ls /Applications/Xcode*.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc 2>/dev/null | head -1)"
if [ -z "$SYSTEM_SWIFTC" ]; then
    SYSTEM_SWIFTC="/usr/bin/swiftc"
fi
echo "  swiftc: $SYSTEM_SWIFTC"

# Zig-built .a files have 4-byte aligned members; Apple ld requires 8-byte.
# Re-archive with libtool to fix alignment.
MERGED_LIB="$BUILD_DIR/libblip_merged.a"
MERGE_LIBS="$BLIP_ROOT/zig-out/lib/libblip.a $BLIP_ROOT/$LZ4_LIB $BLIP_ROOT/$ZSTD_LIB"
if [ -n "$FLAC_LIB" ]; then
    MERGE_LIBS="$MERGE_LIBS $BLIP_ROOT/$FLAC_LIB"
fi
libtool -static -o "$MERGED_LIB" $MERGE_LIBS 2>/dev/null
echo "  Merged lib: $MERGED_LIB"

# Compile the C extraction wrapper (uses blar_common.h)
# -I for BlarArchive/ FIRST so our stub progrez.h is found before the real one
echo "Compiling C wrapper..."
WRAPPER_OBJ="$BUILD_DIR/blar_extract_wrapper.o"
cc -c -O2 -std=c11 \
    -I "$SCRIPT_DIR/BlarArchive" \
    -I "$BLIP_ROOT/src" \
    -o "$WRAPPER_OBJ" \
    "$SCRIPT_DIR/BlarArchive/blar_extract_wrapper.c"

SDKROOT= "$SYSTEM_SWIFTC" \
    -o "$APP_BUNDLE/Contents/MacOS/BlarArchive" \
    -import-objc-header "$SCRIPT_DIR/BlarArchive/BlarArchive-Bridging-Header.h" \
    -I "$BLIP_ROOT/src" \
    "$MERGED_LIB" \
    "$WRAPPER_OBJ" \
    $LIB_SEARCH_FLAGS \
    -ljxl -ljxl_threads \
    -lz -lbrotlienc -lbrotlidec -lbrotlicommon -lhwy \
    -lc++ \
    -sdk "$SYSTEM_SDK" \
    -target "$ARCH-apple-macosx14.0" \
    -framework Cocoa \
    -framework Security \
    "$SCRIPT_DIR"/BlarArchive/*.swift

echo "Swift compilation successful."

# Step 5: Copy Info.plist
cp "$SCRIPT_DIR/BlarArchive/Info.plist" "$APP_BUNDLE/Contents/"

# Step 6: Compile asset catalog
xcrun actool "$SCRIPT_DIR/BlarArchive/Assets.xcassets" \
    --compile "$APP_BUNDLE/Contents/Resources" \
    --platform macosx \
    --minimum-deployment-target 14.0 \
    --app-icon AppIcon \
    --output-partial-info-plist /dev/null \
    2>/dev/null || echo "  (asset catalog compilation skipped — icons may be missing)"

# Step 7: Copy document icon
cp "$SCRIPT_DIR/BlarArchive/Assets.xcassets/DocumentIcon.icns" "$APP_BUNDLE/Contents/Resources/"

# Step 8: Copy blar CLI into bundle
cp "$BLIP_ROOT/zig-out/bin/blar" "$APP_BUNDLE/Contents/MacOS/" 2>/dev/null || true

echo ""
echo "=== Built: $APP_BUNDLE ==="
echo ""
echo "To run:    open '$APP_BUNDLE'"
echo "To install: cp -R '$APP_BUNDLE' /Applications/"
