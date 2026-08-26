#!/usr/bin/env bash
# build-appimage.sh — Build a self-contained AppImage for qub.
# Must be run from the project root with Qt already on PATH.
# cmake build output is expected in ./build/.
set -euo pipefail

# Portable on purpose: `grep -oP` is GNU-only and the BSD grep on macOS runners
# rejects it outright, so both packagers read the version the same POSIX way.
VERSION=$(sed -n 's/^project(.* VERSION \([0-9][0-9.]*\).*/\1/p' CMakeLists.txt | head -1)
APPDIR="$(pwd)/AppDir"
DIST="$(pwd)/dist"

mkdir -p "$DIST"

# ── Tools ────────────────────────────────────────────────────────────────────
LINUXDEPLOY_URL="https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage"
PLUGIN_URL="https://github.com/linuxdeploy/linuxdeploy-plugin-qt/releases/download/continuous/linuxdeploy-plugin-qt-x86_64.AppImage"

for bin in linuxdeploy linuxdeploy-plugin-qt; do
    if [[ ! -f "/tmp/$bin" ]]; then
        url=$([ "$bin" = "linuxdeploy" ] && echo "$LINUXDEPLOY_URL" || echo "$PLUGIN_URL")
        curl -sSL "$url" -o "/tmp/$bin"
        chmod +x "/tmp/$bin"
    fi
done

# ── Stage executable ─────────────────────────────────────────────────────────
rm -rf "$APPDIR"
install -Dm755 build/qub "$APPDIR/usr/bin/qub"

# ── SQL driver plugins ────────────────────────────────────────────────────────
QT_SQL_PLUGINS="$(qmake -query QT_INSTALL_PLUGINS)/sqldrivers"
install -Dm755 "$QT_SQL_PLUGINS/libqsqlpsql.so"    "$APPDIR/usr/lib/qt6/plugins/sqldrivers/libqsqlpsql.so"
install -Dm755 "$QT_SQL_PLUGINS/libqsqlmysql.so"   "$APPDIR/usr/lib/qt6/plugins/sqldrivers/libqsqlmysql.so" 2>/dev/null || true
install -Dm755 "$QT_SQL_PLUGINS/libqsqlite.so"     "$APPDIR/usr/lib/qt6/plugins/sqldrivers/libqsqlite.so"

# ── Desktop file + icon ───────────────────────────────────────────────────────
install -Dm644 packaging/linux/qub.desktop   "$APPDIR/usr/share/applications/qub.desktop"
convert assets/logo.svg -resize 256x256 /tmp/qub.png 2>/dev/null \
  || cp assets/qub.png /tmp/qub.png 2>/dev/null \
  || true
install -Dm644 /tmp/qub.png "$APPDIR/usr/share/icons/hicolor/256x256/apps/qub.png"

# ── linuxdeploy ───────────────────────────────────────────────────────────────
export QMAKE="$(which qmake)"
export OUTPUT="$DIST/qub-${VERSION}-x86_64.AppImage"

/tmp/linuxdeploy \
  --appdir "$APPDIR" \
  --plugin qt \
  --output appimage
