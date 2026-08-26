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
