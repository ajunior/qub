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

# ── Repair the SQL driver plugins ─────────────────────────────────────────────
# macdeployqt deploys the sqldrivers plugins itself and rewrites the references
# it can resolve. The ones it cannot resolve it leaves pointing wherever Qt's
# own build machine had them, prints "ERROR: no file at ..." and exits 0 — so
# `set -e` never sees it and the bundle ships with a dangling reference. That is
# not hypothetical: 0.44.9-rc.7 shipped libqsqlpsql.dylib still pointing at
#   /Applications/Postgres.app/Contents/Versions/14/lib/libpq.5.dylib
# which exists on no user's Mac, and at libiodbc under a Homebrew prefix that
# was not installed. Postgres and ODBC were both dead in that DMG.
#
# The old code here tried to patch that up but could not have worked: it passed
# install_name_tool the *Homebrew* path as the reference to replace, while the
# plugin held Qt's build-machine path, and it applied the change to
# `ls "$DRIVER_DST" | head -1` — whichever plugin sorted first, not the one that
# actually links the library. Both mistakes were swallowed by `2>/dev/null`.
#
# So instead: read each plugin's real references back with otool, and for any
# that points outside the bundle and outside the OS, find that library on this
# machine, copy it into Frameworks and rewrite the reference to it. A plugin
# whose library cannot be found anywhere is deleted rather than shipped broken.
DRIVER_DST="$APP/Contents/PlugIns/sqldrivers"
FRAMEWORKS="$APP/Contents/Frameworks"
mkdir -p "$FRAMEWORKS"

# >>> repair helpers — extracted and exercised by tests/tst_mac.sh, which fakes
# otool, install_name_tool and brew. Keep the markers: the test reads the code
# between them out of this file so that what it exercises is what ships.
# Where to look for a client library whose recorded path does not exist on this
# machine — Qt's plugins name the libraries of Qt's own build host. Homebrew
# keg-only formulae are not symlinked into the prefix, hence the explicit opt/
# entries. `brew --prefix <formula>` exits non-zero for a formula that is not
# installed, so each lookup is neutralised.
#
# Built once into a variable rather than re-run per lookup: as a function piped
# into a loop that returns early, every lookup that hit on the first directory
# killed the pipe and printed "echo: write error: Broken pipe".
SEARCH_DIRS=""
for f in libpq libiodbc unixodbc openssl@3 krb5; do
    d="$(brew --prefix "$f" 2>/dev/null || true)"
    if [ -n "$d" ]; then SEARCH_DIRS="$SEARCH_DIRS $d/lib"; fi
done
SEARCH_DIRS="$SEARCH_DIRS /usr/local/lib /opt/homebrew/lib"

locate_lib() {
    local name="$1" dir
    for dir in $SEARCH_DIRS; do
        if [ -f "$dir/$name" ]; then echo "$dir/$name"; return 0; fi
    done
    return 1
}

# The dependencies of a Mach-O file, and only those. Two lines in `otool -L`
# output are not dependencies and cost 0.44.9-rc.8 its macOS package:
#
#   * a header line per architecture, unindented, which in a universal binary
#     appears once per slice — `tail -n +2` dropped the first and kept the rest;
#   * the file's own install name, which is the first indented line.
#
# Header lines are dropped by requiring the leading tab; the self-reference is
# dropped by basename, since nothing links against a file named like itself.
deps() {
    otool -L "$1" | grep '^	' | awk '{print $1}' | sort -u
}

# References that need no rewriting: already relative to the bundle, or part of
# macOS itself and therefore present on every target machine.
is_ok_ref() {
    case "$1" in
        @*|/usr/lib/*|/System/*) return 0 ;;
        *) return 1 ;;
    esac
}

# Point one Mach-O binary at bundled copies of everything it still names by
# absolute path, recursing into each library brought in — libpq names its
# OpenSSL the same way it was itself named, so stopping at the first level
# would just move the dangling reference one step down.
#
# Echoes the basenames it could not resolve, so the caller can decide what to
# do about a driver that has no client library on this machine at all.
fix_binary() {
    local target="$1" ref lib found
    while read -r ref; do
        if is_ok_ref "$ref"; then continue; fi
        lib="$(basename "$ref")"
        # A universal binary lists its own install name once per slice.
        if [ "$lib" = "$(basename "$target")" ]; then continue; fi

        if [ ! -f "$FRAMEWORKS/$lib" ]; then
            # The recorded path first: a reference that still resolves here is
            # the library this binary was actually linked against, and chasing
            # it beats guessing from a search list. Homebrew's libpq names its
            # krb5 and OpenSSL that way, and no search list would have to know.
            if [ -f "$ref" ]; then found="$ref"; else found=""; fi
            if [ -n "$found" ] || found="$(locate_lib "$lib")"; then
                cp "$found" "$FRAMEWORKS/$lib"
                chmod u+w "$FRAMEWORKS/$lib"
                install_name_tool -id "@executable_path/../Frameworks/$lib" \
                    "$FRAMEWORKS/$lib"
                echo "    + Frameworks/$lib" >&2
                fix_binary "$FRAMEWORKS/$lib"
            else
                echo "$lib"
                continue
            fi
        fi

        install_name_tool -change "$ref" \
            "@executable_path/../Frameworks/$lib" "$target"
    done < <(deps "$target")
    # Explicit: the function is read through a pipeline under `set -o pipefail`,
    # so it must not end on the incidental status of a loop that finished.
    return 0
}
# <<< repair helpers

BROKEN_DRIVERS=""
for plugin in "$DRIVER_DST"/*.dylib; do
    [ -f "$plugin" ] || continue
    name="$(basename "$plugin")"
    chmod u+w "$plugin"
    echo "  $name"
    unresolved="$(fix_binary "$plugin" | sort -u | tr '\n' ' ')"

    if [ -n "${unresolved// /}" ]; then
        echo "    no client library for $unresolved — removing the driver"
        rm -f "$plugin"
        BROKEN_DRIVERS="$BROKEN_DRIVERS $name"
    fi
done

# SQLite, PostgreSQL and ODBC are what qub claims to support out of the box on
# macOS. Losing one of those is a broken release, not a degraded one.
for required in libqsqlite.dylib libqsqlpsql.dylib libqsqlodbc.dylib; do
    if [ ! -f "$DRIVER_DST/$required" ]; then
        echo "error: $required is not in the bundle (removed:$BROKEN_DRIVERS)" >&2
        exit 1
    fi
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
