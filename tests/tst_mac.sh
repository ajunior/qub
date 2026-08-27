#!/usr/bin/env bash
# tst_mac.sh — exercise the driver-repair helpers of packaging/macos/package.sh
# on a machine that is not a Mac, by faking otool, install_name_tool and brew.
#
# The helpers are read out of the shipped script between its markers rather than
# copied here: a copy is a second source of truth, and the first version of this
# test exercised one while the release shipped the other.
#
# The fakes model what the tools really print. That matters more than it sounds:
# 0.44.9-rc.8 lost its macOS package to `otool -L` output this test's earlier
# fake did not reproduce — a universal binary repeats its header once per
# architecture slice, and the first indented line of each slice is the file's
# own install name, not a dependency.
set -uo pipefail

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
FRAMEWORKS="$ROOT/app/Contents/Frameworks"
DRIVER_DST="$ROOT/app/Contents/PlugIns/sqldrivers"
BREW="$ROOT/brew/opt"
mkdir -p "$FRAMEWORKS" "$DRIVER_DST" \
         "$BREW/libpq/lib" "$BREW/libiodbc/lib" "$BREW/openssl@3/lib" "$BREW/krb5/lib"

# ── the reference graph, in the shape otool -L reports it ────────────────────
QT_PQ="/Applications/Postgres.app/Contents/Versions/14/lib/libpq.5.dylib"   # gone
BREW_PQ="$BREW/libpq/lib/libpq.5.dylib"                                     # here
BREW_SSL="$BREW/openssl@3/lib/libssl.3.dylib"
BREW_KRB="$BREW/krb5/lib/libgssapi_krb5.2.2.dylib"

declare -A SELF REFS ARCHS
add() {  # add <file> <install-name> <archs> <ref...>
    local f="$1" self="$2" archs="$3"; shift 3
    mkdir -p "$(dirname "$f")"; printf 'macho\n' > "$f"
    SELF["$f"]="$self"; ARCHS["$f"]="$archs"; REFS["$f"]="$*"
}

add "$DRIVER_DST/libqsqlpsql.dylib" libqsqlpsql.dylib "x86_64 arm64" \
    "$QT_PQ" "@rpath/QtSql.framework/Versions/A/QtSql" /usr/lib/libSystem.B.dylib
add "$DRIVER_DST/libqsqlite.dylib"  libqsqlite.dylib  "x86_64 arm64" \
    "@rpath/QtSql.framework/Versions/A/QtSql" /usr/lib/libc++.1.dylib
add "$DRIVER_DST/libqsqlmimer.dylib" libqsqlmimer.dylib "arm64" \
    /usr/local/lib/libmimerapi.dylib /usr/lib/libSystem.B.dylib
# Homebrew libraries carry an absolute install name and name their own
# dependencies by absolute path — which is how the real libpq reaches krb5.
add "$BREW_PQ"  "$BREW_PQ"  "arm64" "$BREW_SSL" "$BREW_KRB" /usr/lib/libSystem.B.dylib
add "$BREW_SSL" "$BREW_SSL" "arm64" /usr/lib/libSystem.B.dylib
add "$BREW_KRB" "$BREW_KRB" "arm64" /usr/lib/libSystem.B.dylib

# A copy keeps the references of the file it came from.
declare -A ORIGIN
cp() { command cp "$@"; ORIGIN["${!#}"]="$1"; }

otool() {   # otool -L <file>
    local f="$2" key arch r
    key="${ORIGIN[$f]:-$f}"
    for arch in ${ARCHS[$key]}; do
        printf '%s (architecture %s):\n' "$f" "$arch"
        printf '\t%s (compatibility version 1.0.0, current version 1.0.0)\n' "${SELF[$key]}"
        for r in ${REFS[$key]}; do
            printf '\t%s (compatibility version 1.0.0, current version 1.0.0)\n' "$r"
        done
    done
}

install_name_tool() {
    case "$1" in
        -id)     printf 'ID %s :: %s\n'     "$3" "$2" >> "$ROOT/changes.log" ;;
        -change) printf 'CHANGE %s :: %s -> %s\n' "$4" "$2" "$3" >> "$ROOT/changes.log" ;;
    esac
    return 0
}

brew() {    # brew --prefix <formula>
    local d="$BREW/$2"
    if [ -d "$d" ]; then echo "$d"; return 0; fi
    echo "Error: No available formula with the name \"$2\"." >&2
    return 1
}

: > "$ROOT/changes.log"

# ── the code under test, straight out of the shipped script ──────────────────
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/packaging/macos/package.sh"
HELPERS="$ROOT/helpers.sh"
sed -n '/>>> repair helpers/,/<<< repair helpers/p' "$SRC" > "$HELPERS"
if [ ! -s "$HELPERS" ]; then
    echo "could not extract the repair helpers from $SRC — are the markers still there?" >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$HELPERS"

# ── checks ───────────────────────────────────────────────────────────────────
FAILS=0
ck() {
    if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
    else FAILS=$((FAILS+1)); printf '  FAIL %s\n       got:      %s\n       expected: %s\n' "$1" "$2" "$3"; fi
}

echo "— otool parsing"
ck "a universal binary yields each dependency once" \
   "$(deps "$DRIVER_DST/libqsqlpsql.dylib" | wc -l | tr -d ' ')" "4"
ck "the architecture headers are not dependencies" \
   "$(deps "$DRIVER_DST/libqsqlpsql.dylib" | grep -c 'architecture')" "0"

echo "— a driver whose client library moved"
unresolved="$(fix_binary "$DRIVER_DST/libqsqlpsql.dylib" | sort -u | tr '\n' ' ')"
ck "nothing left unresolved"            "${unresolved// /}" ""
ck "libpq was brought in"               "$([ -f "$FRAMEWORKS/libpq.5.dylib" ] && echo yes)" "yes"
ck "openssl followed it"                "$([ -f "$FRAMEWORKS/libssl.3.dylib" ] && echo yes)" "yes"
ck "krb5 followed it too"               "$([ -f "$FRAMEWORKS/libgssapi_krb5.2.2.dylib" ] && echo yes)" "yes"
ck "the plugin now points into the bundle" \
   "$(grep -c "libqsqlpsql.dylib :: $QT_PQ -> @executable_path/../Frameworks/libpq.5.dylib" "$ROOT/changes.log")" "1"
ck "libpq's own krb5 reference was rewritten" \
   "$(grep -c "libpq.5.dylib :: $BREW_KRB -> @executable_path/../Frameworks/libgssapi_krb5.2.2.dylib" "$ROOT/changes.log")" "1"
ck "no library was told to point at itself" \
   "$(grep -c 'CHANGE .*libpq.5.dylib :: .*libpq.5.dylib -> .*libpq.5.dylib' "$ROOT/changes.log")" "0"

echo "— references that must not be touched"
ck "@rpath and /usr/lib left alone" \
   "$(grep -c '@rpath\|libSystem\|libc++' "$ROOT/changes.log")" "0"

echo "— a driver that needs nothing (the rc.8 regression)"
unresolved="$(fix_binary "$DRIVER_DST/libqsqlite.dylib" | sort -u | tr '\n' ' ')"
ck "sqlite is not reported as missing its own file" "${unresolved// /}" ""

echo "— a driver whose client library is nowhere"
unresolved="$(fix_binary "$DRIVER_DST/libqsqlmimer.dylib" | sort -u | tr '\n' ' ')"
ck "names the library that is missing" "${unresolved% }" "libmimerapi.dylib"

echo "— brew formulae that are not installed"
ck "the fixed directories are still searched" \
   "$(printf '%s\n' $SEARCH_DIRS | grep -c '^/opt/homebrew/lib$')" "1"
ck "an uninstalled formula does not abort the list" \
   "$(printf '%s\n' $SEARCH_DIRS | grep -c 'unixodbc')" "0"

echo
if [ "$FAILS" -gt 0 ]; then echo "$FAILS check(s) failed"; exit 1; fi
echo "all checks passed"
