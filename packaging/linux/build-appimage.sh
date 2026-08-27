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

# ── QML modules ───────────────────────────────────────────────────────────────
# linuxdeploy's Qt plugin runs qmlimportscanner only when QML_SOURCES_PATHS is
# set, and when it is not set it deploys no QML module at all — silently. The
# AppImage then carries libQt6Quick.so and no qml/ directory, and the app dies
# on its first import: "module QtQuick.Controls is not installed". Every 0.44.9
# release candidate through rc.9 shipped exactly that, because nothing in the
# pipeline ever started the artifact it had just built.
#
# Mahina's sources are scanned alongside qub's: they import QtQuick.Effects and
# QtQml.Models, which nothing under src/qml does. It arrives through
# FetchContent normally and from ../mahina when that checkout is present, so
# both are looked for. macdeployqt and windeployqt take the equivalent flag
# (-qmldir), which is why only the AppImage was broken.
QML_PATHS="$(pwd)/src/qml"
for mahina in "$(pwd)/build/_deps/mahina-src/qml" "$(pwd)/../mahina/qml"; do
    if [[ -d "$mahina" ]]; then
        QML_PATHS="$QML_PATHS:$mahina"
        break
    fi
done
export QML_SOURCES_PATHS="$QML_PATHS"

# The offscreen platform plugin is not deployed by default and is what the smoke
# test below needs; it costs 60 KB and makes the artifact testable anywhere.
export EXTRA_PLATFORM_PLUGINS="libqoffscreen.so"

# ── linuxdeploy ───────────────────────────────────────────────────────────────
export QMAKE="$(which qmake)"
export OUTPUT="$DIST/qub-${VERSION}-x86_64.AppImage"

/tmp/linuxdeploy \
  --appdir "$APPDIR" \
  --plugin qt \
  --output appimage

# ── Start what was just built ─────────────────────────────────────────────────
# A packager that only checks its own file list cannot tell that the file list
# is missing a whole subsystem. This starts the AppImage — the artifact, not the
# build tree — in an empty profile and requires it to still be up ten seconds
# later with nothing on stderr. Exit 124 from `timeout` is the good case.
#
# APPIMAGE_EXTRACT_AND_RUN sidesteps FUSE, which a container may not offer, and
# the session bus is cleared because qtkeychain would otherwise try to spawn one.
echo "── smoke test ──"
SMOKE_HOME="$(mktemp -d)"
mkdir -p "$SMOKE_HOME"/{data,config,cache,run}

set +e
smoke_out=$(APPIMAGE_EXTRACT_AND_RUN=1 \
    XDG_DATA_HOME="$SMOKE_HOME/data" \
    XDG_CONFIG_HOME="$SMOKE_HOME/config" \
    XDG_CACHE_HOME="$SMOKE_HOME/cache" \
    XDG_RUNTIME_DIR="$SMOKE_HOME/run" \
    DBUS_SESSION_BUS_ADDRESS= \
    QT_QPA_PLATFORM=offscreen \
    timeout 10 "$OUTPUT" 2>&1)
smoke_rc=$?
set -e
rm -rf "$SMOKE_HOME"

if [[ $smoke_rc -ne 124 ]]; then
    echo "error: the AppImage did not stay up (exit $smoke_rc)" >&2
    echo "$smoke_out" >&2
    exit 1
fi
if [[ -n "$smoke_out" ]]; then
    echo "error: the AppImage booted but printed:" >&2
    echo "$smoke_out" >&2
    exit 1
fi
echo "  qub booted from the AppImage and stayed up, silent"
