#!/usr/bin/env bash
# package.sh — Bundle qub.app and create a DMG for macOS.
# Run from the project root after cmake --build build.
set -euo pipefail

# Portable on purpose: `grep -oP` is GNU-only and the BSD grep on macOS runners
# rejects it outright, so both packagers read the version the same POSIX way.
VERSION=$(sed -n 's/^project(.* VERSION \([0-9][0-9.]*\).*/\1/p' CMakeLists.txt | head -1)
APP="build/qub.app"
DIST="$(pwd)/dist"
DMG_NAME="qub-${VERSION}-macos.dmg"
STAGE_DIR="$(mktemp -d)/qub-dmg"

mkdir -p "$DIST" "$STAGE_DIR"

# ── macdeployqt ───────────────────────────────────────────────────────────────
macdeployqt "$APP" \
    -qmldir=src/qml \
    -no-strip

# ── Bundle SQL driver plugins manually (macdeployqt may miss them) ─────────────
QT_PLUGINS="$(qmake -query QT_INSTALL_PLUGINS)"
DRIVER_DST="$APP/Contents/PlugIns/sqldrivers"
mkdir -p "$DRIVER_DST"

for drv in libqsqlpsql.dylib libqsqlmysql.dylib libqsqlite.dylib; do
    src="$QT_PLUGINS/sqldrivers/$drv"
    [ -f "$src" ] && cp "$src" "$DRIVER_DST/" || true
done

# Fix rpath for SQL driver dependencies (libpq, libmariadb) so they load from
# the bundle's Frameworks directory rather than Homebrew paths.
FRAMEWORKS="$APP/Contents/Frameworks"
mkdir -p "$FRAMEWORKS"

fix_dylib() {
    local lib="$1"
    local name
    name="$(basename "$lib")"
    [ -f "$FRAMEWORKS/$name" ] || cp "$lib" "$FRAMEWORKS/$name"
    install_name_tool -change "$lib" "@executable_path/../Frameworks/$name" \
        "$DRIVER_DST/$(ls "$DRIVER_DST" | head -1)" 2>/dev/null || true
}

for lib in \
    "$(brew --prefix libpq)/lib/libpq.5.dylib" \
    "$(brew --prefix mariadb-connector-c)/lib/mariadb/libmariadb.3.dylib"; do
    [ -f "$lib" ] && fix_dylib "$lib" || true
done

# ── Code-sign (ad-hoc when no Developer ID is available) ─────────────────────
if [ -n "${DEVELOPER_ID:-}" ]; then
    codesign --deep --force --verify --verbose \
        --sign "$DEVELOPER_ID" \
        --options runtime \
        --entitlements packaging/macos/entitlements.plist \
        "$APP"
else
    codesign --deep --force --sign - "$APP"
fi

# ── Create DMG ────────────────────────────────────────────────────────────────
cp -R "$APP" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"

hdiutil create \
    -volname "qub $VERSION" \
    -srcfolder "$STAGE_DIR" \
    -ov -format UDZO \
    "$DIST/$DMG_NAME"

rm -rf "$STAGE_DIR"
echo "DMG created: $DIST/$DMG_NAME"
