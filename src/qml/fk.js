.pragma library

// Foreign-key navigation helpers for result cells.
//
// Given the connection's FK list (from DatabaseInspector.foreignKeys, a list of
// { fromSchema, fromTable, fromColumn, toSchema, toTable, toColumn }), the table
// the result came from, and the clicked column, work out where a value can
// navigate to:
//   - outgoing: this column is an FK → jump to the one referenced row
//   - incoming: this column is referenced by others → list rows that point here
// The matching + SQL building is pure so it can be unit-tested through QJSEngine
// (see tst_core.cpp), like guard.js and complete.js.

// A table reference split into its parts, lower-cased for comparison.
// "public.users" → { schema: "public", table: "users" }; "users" → schema "".
function _split(name) {
    var s = String(name);
    var dot = s.lastIndexOf(".");
    if (dot < 0) return { schema: "", table: s.toLowerCase() };
    return { schema: s.substring(0, dot).toLowerCase(),
             table:  s.substring(dot + 1).toLowerCase() };
}

// Strip one matched pair of identifier quotes: "users", `users`, [users].
function _unquote(part) {
    var p = String(part).trim();
    if (p.length < 2) return p;
    var a = p.charAt(0), b = p.charAt(p.length - 1);
    if ((a === '"' && b === '"') || (a === '`' && b === '`') || (a === '[' && b === ']'))
        return p.substring(1, p.length - 1);
    return p;
}

// Does one end of an FK refer to the same table as `ref` (from _split)?
//
// A bare name is not a table: two schemas may each hold an "orders". When the
// caller knows which schema its rows came from, both halves have to agree, so
// the FKs of public.orders are never offered on a row of analytics.orders. When
// the caller has only a bare name — a single-schema connection, or a tab whose
// table was recorded before any of this — the name is all there is to go on and
// matching on it alone is the old behaviour.
function _sameTable(fkSchema, fkTable, ref) {
    if (String(fkTable).toLowerCase() !== ref.table) return false;
    if (!ref.schema) return true;
    return String(fkSchema || "").toLowerCase() === ref.schema;
}

// The name to put in generated SQL and in a menu label. Qualified only where an
// unqualified name would be ambiguous — the same rule the browse and copy-name
// actions follow, so SQLite and single-schema connections never grow a prefix.
function qualify(schema, table, multiSchema) {
    return (multiSchema && schema) ? String(schema) + "." + String(table)
                                   : String(table);
}

// The referenced target for an FK column, as { toTable, toColumn }, or null.
// When the source table is known we only resolve an FK actually declared on it
// (never guess from a same-named column on another table). With no table
// context we resolve only when a single FK column matches (unambiguous).
function outgoing(fkList, tableName, columnName) {
    if (!fkList || !columnName) return null;
    var col = String(columnName).toLowerCase();
    var ref = tableName ? _split(tableName) : null;
    var matches = [];
    for (var i = 0; i < fkList.length; i++) {
        var fk = fkList[i];
        if (String(fk.fromColumn).toLowerCase() !== col) continue;
        if (ref) {
            if (_sameTable(fk.fromSchema, fk.fromTable, ref))
                return { toSchema: fk.toSchema, toTable: fk.toTable, toColumn: fk.toColumn };
        } else {
            matches.push(fk);
        }
    }
    if (!ref && matches.length === 1)
        return { toSchema: matches[0].toSchema, toTable: matches[0].toTable,
                 toColumn: matches[0].toColumn };
    return null;
}

// Tables/columns that reference this column, as [{ fromTable, fromColumn }].
// When the table is known, only FKs pointing at that exact table count.
function incoming(fkList, tableName, columnName) {
    var out = [];
    if (!fkList || !columnName) return out;
    var col = String(columnName).toLowerCase();
    var ref = tableName ? _split(tableName) : null;
    for (var i = 0; i < fkList.length; i++) {
        var fk = fkList[i];
        if (String(fk.toColumn).toLowerCase() !== col) continue;
        if (ref && !_sameTable(fk.toSchema, fk.toTable, ref)) continue;
        out.push({ fromSchema: fk.fromSchema, fromTable: fk.fromTable,
                   fromColumn: fk.fromColumn });
    }
    return out;
}

// The table a single-table SELECT reads from, normalised to "schema.table" or
// "table", or "" when the statement is not one.
//
// The previous expression captured \w+ after FROM, which cannot see a qualified
// name: on `SELECT * FROM "analytics"."users"` it matched nothing at all, so the
// tab recorded no table and both inline editing and FK navigation went quietly
// dead — for exactly the queries the browse button now generates.
function tableFromSelect(sql) {
    var IDENT = '(?:"[^"]+"|`[^`]+`|\\[[^\\]]+\\]|\\w+)';
    // The two halves are captured separately rather than split on "." after the
    // fact, so a quoted identifier that contains a dot stays in one piece.
    var re = new RegExp('^\\s*SELECT\\b[\\s\\S]*?\\bFROM\\s+(' + IDENT +
                        ')(?:\\s*\\.\\s*(' + IDENT + '))?(?:\\s|;|$)', 'i');
    var m = re.exec(String(sql).trim());
    if (!m) return "";
    var parts = [_unquote(m[1])];
    if (m[2] !== undefined) parts.push(_unquote(m[2]));
    return parts.join(".");
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

// Keywords of generated SQL, cased the way the user asked for in settings.
// Only keywords: an identifier keeps whatever case the database gave it,
// because lowercasing "Users" would change which table the name refers to on
// a case-sensitive server.
function kw(text, keywordCase) {
    return keywordCase === "lower" ? String(text).toLowerCase() : String(text);
}

// SELECT that fetches rows of `table` where `column` = `value`.
function selectBy(table, column, value, driver, keywordCase) {
    return kw("SELECT * FROM ", keywordCase) + ident(table, driver) +
           kw(" WHERE ", keywordCase) + ident(column, driver) + " = " +
           literal(value, driver);
}
