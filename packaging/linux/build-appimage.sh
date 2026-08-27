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
# linuxdeploy's Qt plugin deploys every driver it finds in the Qt sqldrivers
# directory and resolves each one's shared libraries, so a driver whose client
# library is not installed kills the whole run — Mimer did exactly that
# ("Could not find dependency: libmimerapi.so"). Mimer and Oracle are the two we
# cannot ship: neither client library is packaged for Ubuntu, and Oracle's is not
# redistributable anyway. Move them aside for the duration and put them back on
# the way out, because this runs against a real Qt installation, CI or not.
QT_SQL_PLUGINS="$(qmake -query QT_INSTALL_PLUGINS)/sqldrivers"
SQLDRIVER_STASH="$(mktemp -d)"

restore_sqldrivers() {
    for stashed in "$SQLDRIVER_STASH"/*; do
        if [[ -e "$stashed" ]]; then
            mv -f "$stashed" "$QT_SQL_PLUGINS/"
        fi
    done
    rmdir "$SQLDRIVER_STASH" 2>/dev/null || true
}
trap restore_sqldrivers EXIT

for driver in libqsqlmimer.so libqsqloci.so; do
    if [[ -e "$QT_SQL_PLUGINS/$driver" ]]; then
        mv "$QT_SQL_PLUGINS/$driver" "$SQLDRIVER_STASH/"
    fi
done

# ── Desktop file + icon ───────────────────────────────────────────────────────
install -Dm644 packaging/linux/qub.desktop   "$APPDIR/usr/share/applications/qub.desktop"
# assets/qub.png is the same 1024px master the macOS icns and the Windows ico
# are cut from, so all three platforms show one icon. The copy is the fallback
# for a machine without ImageMagick: an oversized icon still beats none.
convert assets/qub.png -resize 256x256 /tmp/qub.png 2>/dev/null \
  || cp assets/qub.png /tmp/qub.png
install -Dm644 /tmp/qub.png "$APPDIR/usr/share/icons/hicolor/256x256/apps/qub.png"

# ── linuxdeploy ───────────────────────────────────────────────────────────────
export QMAKE="$(which qmake)"
export OUTPUT="$DIST/qub-${VERSION}-x86_64.AppImage"

/tmp/linuxdeploy \
  --appdir "$APPDIR" \
  --plugin qt \
  --output appimage
