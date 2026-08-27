.pragma library

const MAP = {
    "QPSQL":     "PostgreSQL",
    "QMYSQL":    "MySQL",
    "QMARIADB":  "MariaDB",
    "QSQLITE":   "SQLite",
    "QODBC":     "ODBC",
    "QOCI":      "Oracle",
    "QIBASE":    "Firebird"
}

function label(qtKey) {
    return MAP[qtKey] !== undefined ? MAP[qtKey] : qtKey
}

function qtKey(lbl) {
    for (var k in MAP)
        if (MAP[k] === lbl) return k
    return lbl
}

// The order the connection form offers drivers in. Not derived from MAP: object
// key order is not something to lean on, and this is a deliberate ranking with
// the common databases first.
const ORDER = ["QPSQL", "QMYSQL", "QMARIADB", "QSQLITE", "QOCI", "QIBASE", "QODBC"]

// Labels for the drivers this build can actually load, in ORDER. `available` is
// the Qt key list from ConnectionManager.availableDrivers().
//
// A driver Qt has no plugin for can never work, and offering it produces a
// connection that fails with "driver could not be loaded" and no way for the
// user to act on it: Qt's official macOS and Windows binaries ship no MySQL
// plugin, and the macOS ones none for Oracle or Firebird. Keys Qt reports that
// qub has no support for (QMIMER) are dropped by the same intersection.
function availableLabels(available) {
    return ORDER.filter(function (k) { return available.indexOf(k) !== -1 })
                .map(label)
}
