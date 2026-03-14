#!/usr/bin/env bash
#
# rebuild-x64.sh — Rebuild OpenAI Codex.app from arm64 to macOS x86_64 (Intel)
#
# Usage:  ./rebuild-x64.sh [path-to-Codex.dmg]
#
# Prerequisites:
#   - macOS with Xcode Command Line Tools (xcode-select --install)
#   - Node.js + npm + npx
#
# Based on https://github.com/ry2009/codex-intel-mac
#
set -euo pipefail

# ─── Config ──────────────────────────────────────────────────────────────────
ELECTRON_VERSION="40.0.0"
BETTER_SQLITE3_VER="12.5.0"
NODE_PTY_VER="1.1.0"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DMG_PATH="${1:-$SCRIPT_DIR/Codex.dmg}"
WORK_DIR="$SCRIPT_DIR/_rebuild_work"
OUTPUT_DIR="$SCRIPT_DIR/output"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ─── Preflight ───────────────────────────────────────────────────────────────
command -v node >/dev/null || error "node is required."
command -v pnpm >/dev/null || error "pnpm is required. Install: npm i -g pnpm"
[ -f "$DMG_PATH" ] || error "DMG not found at: $DMG_PATH"

info "Electron ${ELECTRON_VERSION} | Target: darwin-x64"

# ─── Cleanup on exit ────────────────────────────────────────────────────────
MOUNT_POINT=""
cleanup() {
    if [ -n "$MOUNT_POINT" ] && mount | grep -q "$MOUNT_POINT"; then
        hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ─── Step 1: Mount DMG & copy app ───────────────────────────────────────────
info "Step 1/5: Mounting DMG and copying Codex.app..."
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" "$OUTPUT_DIR"

MOUNT_POINT="$(mktemp -d /tmp/codex-mount.XXXXXX)"

# Detach any previous mount of this DMG
PREV_MOUNT="$(hdiutil info 2>/dev/null | grep -B20 "$DMG_PATH" | grep "^/dev/" | awk '{print $1}' | head -1 || true)"
if [ -n "$PREV_MOUNT" ]; then
    info "  Detaching previous mount of this DMG..."
    hdiutil detach "$PREV_MOUNT" -quiet 2>/dev/null || true
fi

hdiutil attach "$DMG_PATH" -nobrowse -mountpoint "$MOUNT_POINT" || error "Failed to mount DMG"
[ -d "$MOUNT_POINT/Codex.app" ] || error "Codex.app not found in DMG"

ditto "$MOUNT_POINT/Codex.app" "$WORK_DIR/Codex.app"
hdiutil detach "$MOUNT_POINT" -quiet
MOUNT_POINT=""

APP="$WORK_DIR/Codex.app"
CONTENTS="$APP/Contents"
RESOURCES="$CONTENTS/Resources"
FRAMEWORKS="$CONTENTS/Frameworks"
UNPACKED="$RESOURCES/app.asar.unpacked"

info "  Done."

# ─── Step 2: Build x64 artifacts via @electron/rebuild ───────────────────────
info "Step 2/5: Building x64 native modules..."

ARTIFACT_DIR="$WORK_DIR/artifacts"
mkdir -p "$ARTIFACT_DIR"
cd "$ARTIFACT_DIR"

# Download Electron zip manually (avoids node install.js which often fails in China)
ELECTRON_ZIP="$WORK_DIR/electron-v${ELECTRON_VERSION}-darwin-x64.zip"
ELECTRON_URL="https://github.com/electron/electron/releases/download/v${ELECTRON_VERSION}/electron-v${ELECTRON_VERSION}-darwin-x64.zip"
if [ ! -f "$ELECTRON_ZIP" ]; then
    info "  Downloading Electron ${ELECTRON_VERSION} darwin-x64..."
    curl -L --progress-bar -o "$ELECTRON_ZIP" "$ELECTRON_URL"
fi

info "  Installing npm packages..."
pnpm init > /dev/null 2>&1

# Skip Electron's postinstall download — we handle it manually
ELECTRON_SKIP_BINARY_DOWNLOAD=1 pnpm add \
    "electron@${ELECTRON_VERSION}" \
    "better-sqlite3@${BETTER_SQLITE3_VER}" \
    "node-pty@${NODE_PTY_VER}" \
    "@electron/rebuild" 2>&1 | tail -5

# Unzip Electron runtime into the expected location
ELECTRON_DIST="$ARTIFACT_DIR/node_modules/electron/dist"
if [ ! -d "$ELECTRON_DIST/Electron.app" ]; then
    info "  Extracting Electron runtime..."
    mkdir -p "$ELECTRON_DIST"
    unzip -q -o "$ELECTRON_ZIP" -d "$ELECTRON_DIST"
fi

info "  Rebuilding native modules for x64..."
pnpm exec electron-rebuild \
    -f \
    -w better-sqlite3,node-pty \
    --arch x64 \
    --version "$ELECTRON_VERSION" \
    --module-dir . 2>&1 | tail -10

ELECTRON_APP="$ARTIFACT_DIR/node_modules/electron/dist/Electron.app"
SQLITE_NODE="$ARTIFACT_DIR/node_modules/better-sqlite3/build/Release/better_sqlite3.node"

# node-pty output can be in build/ or prebuilds/
PTY_NODE=""
SPAWN_HELPER=""
for candidate in \
    "$ARTIFACT_DIR/node_modules/node-pty/build/Release/pty.node" \
    "$ARTIFACT_DIR/node_modules/node-pty/prebuilds/darwin-x64/pty.node"; do
    [ -f "$candidate" ] && PTY_NODE="$candidate" && break
done
for candidate in \
    "$ARTIFACT_DIR/node_modules/node-pty/build/Release/spawn-helper" \
    "$ARTIFACT_DIR/node_modules/node-pty/prebuilds/darwin-x64/spawn-helper"; do
    [ -f "$candidate" ] && SPAWN_HELPER="$candidate" && break
done

[ -f "$SQLITE_NODE" ]  || error "better_sqlite3.node not found after rebuild"
[ -n "$PTY_NODE" ]     || error "pty.node not found after rebuild"
[ -n "$SPAWN_HELPER" ] || error "spawn-helper not found after rebuild"

file "$SQLITE_NODE" | grep -q "x86_64" || error "better_sqlite3.node is not x86_64"
file "$PTY_NODE"    | grep -q "x86_64" || error "pty.node is not x86_64"

info "  All native modules built OK."
cd "$SCRIPT_DIR"

# ─── Step 3: Replace arm64 binaries with x64 ────────────────────────────────
info "Step 3/5: Swapping arm64 -> x64 binaries..."

DONOR="$ELECTRON_APP"

# Main binary
info "  Main binary..."
cp -f "$DONOR/Contents/MacOS/Electron" "$CONTENTS/MacOS/Codex"
chmod +x "$CONTENTS/MacOS/Codex"

# Helper apps
for helper in \
    "Electron Helper:Codex Helper" \
    "Electron Helper (GPU):Codex Helper (GPU)" \
    "Electron Helper (Plugin):Codex Helper (Plugin)" \
    "Electron Helper (Renderer):Codex Helper (Renderer)"; do
    src_name="${helper%%:*}"
    dst_name="${helper##*:}"
    src_bin="$DONOR/Contents/Frameworks/${src_name}.app/Contents/MacOS/${src_name}"
    dst_bin="$FRAMEWORKS/${dst_name}.app/Contents/MacOS/${dst_name}"
    if [ -f "$src_bin" ] && [ -f "$dst_bin" ]; then
        info "  ${dst_name}..."
        cp -f "$src_bin" "$dst_bin"
        chmod +x "$dst_bin"
    fi
done

# Frameworks — Electron x64 ships with x64 versions of all four
for framework in \
    "Electron Framework.framework" \
    "Mantle.framework" \
    "ReactiveObjC.framework" \
    "Squirrel.framework"; do
    src_fw="$DONOR/Contents/Frameworks/$framework"
    dst_fw="$FRAMEWORKS/$framework"
    if [ -d "$src_fw" ]; then
        info "  ${framework}..."
        rm -rf "$dst_fw"
        ditto "$src_fw" "$dst_fw"
    fi
done

# Sparkle.framework is already universal in the original — thin to x64
info "  Thinning Sparkle.framework to x86_64..."
find "$FRAMEWORKS/Sparkle.framework" -type f \( -name "Sparkle" -o -name "Autoupdate" -o -name "Downloader" -o -name "Installer" \) | while read -r bin; do
    if file "$bin" | grep -q "universal"; then
        lipo "$bin" -thin x86_64 -output "${bin}.x64"
        mv "${bin}.x64" "$bin"
    fi
done

# Native addons in app.asar.unpacked
info "  Installing x64 native addons..."
cp -f "$SQLITE_NODE" "$UNPACKED/node_modules/better-sqlite3/build/Release/better_sqlite3.node"
cp -f "$PTY_NODE"    "$UNPACKED/node_modules/node-pty/build/Release/pty.node"
cp -f "$SPAWN_HELPER" "$UNPACKED/node_modules/node-pty/build/Release/spawn-helper"
chmod +x "$UNPACKED/node_modules/node-pty/build/Release/spawn-helper"

# Also copy pty.node to prebuilds dir if it exists
if [ -d "$UNPACKED/node_modules/node-pty/prebuilds" ] || \
   [ -d "$UNPACKED/node_modules/node-pty/bin" ]; then
    mkdir -p "$UNPACKED/node_modules/node-pty/prebuilds/darwin-x64"
    cp -f "$PTY_NODE" "$UNPACKED/node_modules/node-pty/prebuilds/darwin-x64/pty.node"
fi

# Remove sparkle.node — auto-update disabled for Intel rebuild
info "  Removing sparkle.node (auto-update disabled)..."
rm -f "$UNPACKED/native/sparkle.node"
rm -f "$RESOURCES/native/sparkle.node"

# Remove stale arm64 node-pty prebuilt
rm -rf "$UNPACKED/node_modules/node-pty/bin/darwin-arm64-"*

# Replace bundled codex CLI with x64 version
CODEX_CLI_X64=""
if command -v npm >/dev/null 2>&1; then
    NPM_ROOT="$(npm root -g 2>/dev/null || true)"
    for candidate in \
        "${NPM_ROOT}/@openai/codex/node_modules/@openai/codex-darwin-x64/vendor/x86_64-apple-darwin/codex/codex" \
        "/usr/local/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-x64/vendor/x86_64-apple-darwin/codex/codex"; do
        if [ -x "$candidate" ]; then
            CODEX_CLI_X64="$candidate"
            break
        fi
    done
fi

if [ -n "$CODEX_CLI_X64" ]; then
    info "  Bundling x64 codex CLI: $CODEX_CLI_X64"
    cp -f "$CODEX_CLI_X64" "$RESOURCES/codex"
    chmod +x "$RESOURCES/codex"
elif [ -f "$RESOURCES/codex" ]; then
    warn "  No x64 codex CLI found, removing arm64 version"
    warn "  Install with: npm i -g @openai/codex"
    rm -f "$RESOURCES/codex"
fi

# Replace bundled rg (ripgrep) with x64 version
RG_X64=""
for candidate in \
    "${NPM_ROOT:-}/@openai/codex/node_modules/@openai/codex-darwin-x64/vendor/x86_64-apple-darwin/path/rg" \
    "/usr/local/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-x64/vendor/x86_64-apple-darwin/path/rg"; do
    if [ -x "$candidate" ] && file "$candidate" | grep -q "x86_64"; then
        RG_X64="$candidate"
        break
    fi
done

if [ -n "$RG_X64" ]; then
    info "  Bundling x64 rg: $RG_X64"
    cp -f "$RG_X64" "$RESOURCES/rg"
    chmod +x "$RESOURCES/rg"
elif [ -f "$RESOURCES/rg" ]; then
    warn "  No x64 rg found, removing arm64 version"
    rm -f "$RESOURCES/rg"
fi

info "  Binary swap complete."

# ─── Step 4: Strip signatures & re-sign ─────────────────────────────────────
info "Step 4/5: Re-signing app..."

find "$APP" -name "_CodeSignature" -type d -prune -exec rm -rf {} +
xattr -cr "$APP"

codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

info "  Ad-hoc signature OK."

# ─── Step 5: Package into DMG ───────────────────────────────────────────────
info "Step 5/5: Creating DMG..."

OUTPUT_DMG="$OUTPUT_DIR/Codex-x64.dmg"
rm -f "$OUTPUT_DMG"

hdiutil create \
    -volname "Codex" \
    -srcfolder "$APP" \
    -ov \
    -format UDZO \
    "$OUTPUT_DMG" 2>&1 | tail -2

# ─── Done ────────────────────────────────────────────────────────────────────
echo ""
info "Verification:"
file "$CONTENTS/MacOS/Codex"
file "$UNPACKED/node_modules/better-sqlite3/build/Release/better_sqlite3.node"
file "$UNPACKED/node_modules/node-pty/build/Release/pty.node"

echo ""
info "========================================="
info "  Build complete!"
info "  Output: $OUTPUT_DMG"
info "========================================="
echo ""
info "Install: open output/Codex-x64.dmg, drag to Applications"
info "First launch: right-click -> Open (or run: xattr -dr com.apple.quarantine /Applications/Codex.app)"
info "Note: Auto-update (Sparkle) is disabled in this build."
