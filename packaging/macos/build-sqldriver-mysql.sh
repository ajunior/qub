#!/usr/bin/env bash
# build-sqldriver-mysql.sh — build Qt's MySQL/MariaDB driver plugin for macOS.
#
# Qt's official macOS binaries ship four SQL drivers — sqlite, psql, odbc and
# mimer — and no MySQL one at all, so no amount of client library on the machine
# makes QMYSQL appear in a DMG built from them. The plugin is ordinary Qt source
# that builds standalone against an installed Qt, which is what this does: fetch
# the sqldrivers directory of qtbase at exactly the Qt version in use, configure
# it for MySQL and nothing else, and leave the .dylib where package.sh will find
# it.
#
# Linked against MariaDB's Connector/C rather than Oracle's libmysqlclient, and
# not by accident: Connector/C is LGPL and qub is GPLv3, while libmysqlclient is
# GPLv2. It speaks to MySQL servers as well as MariaDB ones — the plugin
# registers both QMYSQL and QMARIADB either way.
#
# Prints the path of the built plugin on stdout. Run from the project root.
set -euo pipefail

WORK="${SQLDRIVER_WORK:-build-sqldrivers}"
SRC="$WORK/qtbase"
BUILD="$WORK/build"
OUT="$BUILD/plugins/sqldrivers/libqsqlmysql.dylib"

QT_VERSION="$(qmake -query QT_VERSION)"

# ── The client library ────────────────────────────────────────────────────────
# Keg-only, so it is never symlinked into the Homebrew prefix and has to be
# named. Its headers sit under include/mariadb rather than at the root of the
# prefix, which is not where Qt's FindMySQL looks on its own — hence both paths
# passed explicitly instead of the MySQL_ROOT shorthand.
MARIADB_PREFIX="${MARIADB_PREFIX:-$(brew --prefix mariadb-connector-c 2>/dev/null || true)}"
if [ -z "$MARIADB_PREFIX" ]; then
    echo "error: mariadb-connector-c is not installed (brew install mariadb-connector-c)" >&2
    exit 1
fi
MYSQL_INCLUDE="$MARIADB_PREFIX/include/mariadb"
MYSQL_LIB="$MARIADB_PREFIX/lib/libmariadb.dylib"
for f in "$MYSQL_INCLUDE/mysql.h" "$MYSQL_LIB"; do
    if [ ! -e "$f" ]; then
        echo "error: $f is missing from $MARIADB_PREFIX" >&2
        exit 1
    fi
done

# ── The source ────────────────────────────────────────────────────────────────
# A blobless sparse clone of one directory: the whole of qtbase is over a
# gigabyte and every byte of it but src/plugins/sqldrivers is dead weight here.
# Tagged, never a branch — the plugin must come from the same version as the Qt
# it is loaded into, since it is built against private headers.
if [ ! -d "$SRC/src/plugins/sqldrivers" ]; then
    rm -rf "$SRC"
    mkdir -p "$WORK"
    git clone --quiet --filter=blob:none --sparse --depth 1 \
        --branch "v$QT_VERSION" \
        "${QTBASE_REMOTE:-https://github.com/qt/qtbase.git}" "$SRC"
    git -C "$SRC" sparse-checkout set src/plugins/sqldrivers
fi

# ── Build ─────────────────────────────────────────────────────────────────────
# Every other driver is off: they would want their own client libraries, and Qt
# already ships the ones this bundle keeps. qt-cmake rather than cmake, so the
# toolchain, the deployment target and the architecture are Qt's own and the
# plugin matches the framework it will be loaded beside.
#
# The architecture is named rather than left to qt-cmake. Qt's macOS binaries
# are universal, and qt-cmake hands that down to anything built against them, so
# the plugin build asks for an x86_64 slice too and dies on Homebrew's
# single-slice libmariadb — which is what rc.22 did. What the plugin has to
# match is not Qt but the app it will be loaded into, and package.sh reads that
# off the built binary, so this only guesses when it is run on its own.
QT_CMAKE="$(command -v qt-cmake || echo "$(dirname "$(command -v qmake)")/qt-cmake")"
"$QT_CMAKE" -S "$SRC/src/plugins/sqldrivers" -B "$BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="${SQLDRIVER_ARCHS:-$(uname -m)}" \
    -DFEATURE_sql_mysql=ON \
    -DFEATURE_sql_psql=OFF -DFEATURE_sql_odbc=OFF -DFEATURE_sql_sqlite=OFF \
    -DFEATURE_sql_ibase=OFF -DFEATURE_sql_oci=OFF -DFEATURE_sql_db2=OFF \
    -DFEATURE_sql_mimer=OFF \
    -DMySQL_INCLUDE_DIR="$MYSQL_INCLUDE" \
    -DMySQL_LIBRARY="$MYSQL_LIB" >&2
cmake --build "$BUILD" --parallel >&2

if [ ! -f "$OUT" ]; then
    echo "error: the build produced no $OUT" >&2
    exit 1
fi
echo "$OUT"
