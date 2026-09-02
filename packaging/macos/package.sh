#!/usr/bin/env bash
# package.sh — Bundle qub.app and create a DMG for macOS.
# Run from the project root after cmake --build build.
#
# Signing and notarization are opt-in through DEVELOPER_ID and the NOTARY_*
# variables; SIGNING.md, next to this script, is where they come from.
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

# ── Code-sign ─────────────────────────────────────────────────────────────────
# With DEVELOPER_ID set this is a real Developer ID signature: hardened runtime,
# which notarization refuses to proceed without, and a secure timestamp, which
# is what keeps builds already in people's hands valid after the certificate
# behind them expires. Without it, an ad-hoc signature — enough for macOS to run
# the app on the machine that built it, not enough for anyone else's.
#
# Signed inside out rather than with --deep. Apple has discouraged --deep for
# years: it hands the same options to everything it finds and is documented as a
# way to repair a bundle rather than to sign one. macdeployqt leaves dozens of
# dylibs and a stack of Qt frameworks in here, and each has to be signed before
# whatever contains it — a bundle's signature seals what is inside it, so
# signing the outside first only invalidates it on the next inner change.
if [ -n "${DEVELOPER_ID:-}" ]; then
    sign() { codesign --force --timestamp --options runtime --sign "$DEVELOPER_ID" "$@"; }

    echo "Signing with: $DEVELOPER_ID"

    # Loose libraries and plugins first. Qt's own framework binaries carry no
    # extension, so this matches the deployed dylibs without reaching into them.
    while IFS= read -r -d '' f; do sign "$f"; done < <(
        find "$APP/Contents" -type f \( -name '*.dylib' -o -name '*.so' \) -print0)

    # Then each framework bundle as a whole.
    while IFS= read -r -d '' f; do sign "$f"; done < <(
        find "$APP/Contents/Frameworks" -maxdepth 1 -name '*.framework' -print0)

    # Then the app, which is the only part that carries entitlements.
    sign --entitlements packaging/macos/entitlements.plist "$APP"

    codesign --verify --deep --strict --verbose=2 "$APP"
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

# ── Sign, notarize and staple the DMG ─────────────────────────────────────────
# The app inside is signed already; the disk image around it is a separate file
# and needs its own signature. Notarization then sends the whole thing to Apple,
# which scans it and issues a ticket, and stapling writes that ticket into the
# DMG so a Mac that has never been online can still verify it. Skipping any of
# the three leaves the download exactly as blocked as an unsigned one.
if [ -n "${DEVELOPER_ID:-}" ]; then
    codesign --force --timestamp --sign "$DEVELOPER_ID" "$DIST/$DMG_NAME"

    # Two doors, because two things run this script. A developer on their own
    # Mac stores credentials once with `xcrun notarytool store-credentials` and
    # names the profile here; CI has no keychain to keep a profile in and passes
    # an App Store Connect API key instead, which can be revoked on its own and
    # is not tied to anybody's Apple ID password.
    NOTARY_ARGS=()
    if [ -n "${NOTARY_PROFILE:-}" ]; then
        NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
    elif [ -n "${NOTARY_KEY:-}" ]; then
        NOTARY_ARGS=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
    fi

    if [ ${#NOTARY_ARGS[@]} -gt 0 ]; then
        # `notarytool submit --wait` does two very different jobs in one command:
        # it uploads the DMG, and then it holds a single long connection open
        # while Apple's queue works through it. The queue can take the better
        # part of an hour, and any network hiccup in that hour kills the command
        # — with a non-zero exit, as if the submission had been rejected, when in
        # fact it is alive on Apple's side and about to be accepted. That is a
        # release build thrown away over a dropped packet.
        #
        # So the two jobs are separated. The upload happens once, and the waiting
        # is a poll that can fail and be tried again: an unreadable status is
        # treated as "ask again in thirty seconds", and only a verdict from Apple
        # ends the loop either way.
        SUBMISSION_ID="$(xcrun notarytool submit "$DIST/$DMG_NAME" \
                             "${NOTARY_ARGS[@]}" --no-wait \
                         | sed -n 's/^ *id: *//p' | head -1)"
        if [ -z "$SUBMISSION_ID" ]; then
            echo "error: notarytool accepted no submission — nothing to wait for." >&2
            exit 1
        fi
        echo "Notarization submission: $SUBMISSION_ID"

        # 120 × 30s = one hour, which is past anything Apple's queue has taken
        # here and still short enough to fit inside the job's own timeout.
        NOTARY_STATUS=""
        for _ in $(seq 1 120); do
            sleep 30
            NOTARY_STATUS="$(xcrun notarytool info "$SUBMISSION_ID" \
                                 "${NOTARY_ARGS[@]}" 2>/dev/null \
                             | sed -n 's/^ *status: *//p' | head -1)"
            case "$NOTARY_STATUS" in
                Accepted)          echo "Notarization accepted."; break ;;
                Invalid|Rejected)  break ;;
                "")                echo "  (status unreadable — retrying)" ;;
                *)                 echo "  status: $NOTARY_STATUS" ;;
            esac
        done

        # The log is worth printing either way: on a rejection it is the only
        # place that says which binary Apple objected to, and on an acceptance it
        # still lists the warnings that will become rejections later.
        xcrun notarytool log "$SUBMISSION_ID" "${NOTARY_ARGS[@]}" || true

        if [ "$NOTARY_STATUS" != "Accepted" ]; then
            echo "error: notarization ended as '${NOTARY_STATUS:-unknown}'." >&2
            echo "       Resume with: xcrun notarytool info $SUBMISSION_ID …" >&2
            exit 1
        fi

        # Stapling reaches out to Apple too, and fails the same transient way.
        for attempt in 1 2 3; do
            if xcrun stapler staple "$DIST/$DMG_NAME"; then
                break
            fi
            if [ "$attempt" = 3 ]; then
                echo "error: could not staple the ticket after three tries." >&2
                exit 1
            fi
            echo "stapler failed (attempt $attempt) — retrying in 30s" >&2
            sleep 30
        done
        xcrun stapler validate "$DIST/$DMG_NAME"
        echo "DMG signed, notarized and stapled."
    else
        echo "warning: signed but NOT notarized — no NOTARY_PROFILE or NOTARY_KEY" >&2
        echo "         set. Gatekeeper blocks this DMG on any other Mac." >&2
    fi
fi
