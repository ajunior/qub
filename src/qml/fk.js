.pragma library

// Foreign-key navigation helpers for result cells.
//
// Given the connection's FK list (from DatabaseInspector.foreignKeys, a list of
// { fromTable, fromColumn, toTable, toColumn }), the table the result came from,
// and the clicked column, work out where a value can navigate to:
//   - outgoing: this column is an FK → jump to the one referenced row
//   - incoming: this column is referenced by others → list rows that point here
// The matching + SQL building is pure so it can be unit-tested through QJSEngine
// (see tst_core.cpp), like guard.js and complete.js.

// Schema-qualified tail, lower-cased ("public.users" → "users").
function _bare(name) {
    var s = String(name);
    var dot = s.lastIndexOf(".");
    return (dot >= 0 ? s.substring(dot + 1) : s).toLowerCase();
}

// The referenced target for an FK column, as { toTable, toColumn }, or null.
// When the source table is known we only resolve an FK actually declared on it
// (never guess from a same-named column on another table). With no table
// context we resolve only when a single FK column matches (unambiguous).
function outgoing(fkList, tableName, columnName) {
    if (!fkList || !columnName) return null;
    var col = String(columnName).toLowerCase();
    var tbl = tableName ? _bare(tableName) : "";
    var matches = [];
    for (var i = 0; i < fkList.length; i++) {
        var fk = fkList[i];
        if (String(fk.fromColumn).toLowerCase() !== col) continue;
        if (tbl) {
            if (_bare(fk.fromTable) === tbl)
                return { toTable: fk.toTable, toColumn: fk.toColumn };
        } else {
            matches.push(fk);
        }
    }
    if (!tbl && matches.length === 1)
        return { toTable: matches[0].toTable, toColumn: matches[0].toColumn };
    return null;
}

// Tables/columns that reference this column, as [{ fromTable, fromColumn }].
// When the table is known, only FKs pointing at that exact table count.
function incoming(fkList, tableName, columnName) {
    var out = [];
    if (!fkList || !columnName) return out;
    var col = String(columnName).toLowerCase();
    var tbl = tableName ? _bare(tableName) : "";
    for (var i = 0; i < fkList.length; i++) {
        var fk = fkList[i];
        if (String(fk.toColumn).toLowerCase() !== col) continue;
        if (tbl && _bare(fk.toTable) !== tbl) continue;
        out.push({ fromTable: fk.fromTable, fromColumn: fk.fromColumn });
    }
    return out;
}

// Quote an identifier (handles schema-qualified names) for the given Qt driver.
function ident(name, driver) {
    var q = (driver === "QMYSQL" || driver === "QMARIADB") ? "`" : "\"";
    return String(name).split(".").map(function (p) {
        return q + p.split(q).join(q + q) + q;
    }).join(".");
}

// SQL literal for a value pulled from a cell (a display string). Numbers are
// emitted raw; everything else is single-quoted (backslashes doubled for the
// back-tick dialects). Empty → NULL.
function literal(value, driver) {
    if (value === null || value === undefined) return "NULL";
    var s = String(value);
    if (s === "") return "NULL";
    if (/^-?\d+(\.\d+)?$/.test(s)) return s;
    if (driver === "QMYSQL" || driver === "QMARIADB")
        return "'" + s.split("\\").join("\\\\").split("'").join("''") + "'";
    return "'" + s.split("'").join("''") + "'";
}

// SELECT that fetches rows of `table` where `column` = `value`.
function selectBy(table, column, value, driver) {
    return "SELECT * FROM " + ident(table, driver) +
           " WHERE " + ident(column, driver) + " = " + literal(value, driver);
}
