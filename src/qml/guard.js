.pragma library

// Statement-level query guard.
//
// `statements` must be the list produced by QueryExecutor.splitStatements(sql)
// so that every statement in the editor is checked individually — a write
// hidden behind "SELECT 1; DROP TABLE …" or a leading comment cannot slip
// past a prefix check on the full text.
//
// Returns null if execution is safe, or { blocked: bool, message: string }.
// blocked=true means deny; blocked=false means ask for confirmation.

// Strip leading whitespace and -- / /* */ comments so the first real keyword
// is at position 0.
function _stripLeadingComments(stmt) {
    let s = stmt
    for (;;) {
        s = s.replace(/^\s+/, "")
        if (s.startsWith("--")) {
            const nl = s.indexOf("\n")
            if (nl < 0) return ""
            s = s.slice(nl + 1)
        } else if (s.startsWith("/*")) {
            const end = s.indexOf("*/")
            if (end < 0) return ""
            s = s.slice(end + 2)
        } else {
            return s
        }
    }
}

// Read-only mode is an allowlist: anything not recognized as a read or
// session/transaction statement is refused, instead of trying to enumerate
// every write keyword.
const _readOnlyAllowed =
    /^(SELECT|WITH|SHOW|EXPLAIN|DESCRIBE|DESC|PRAGMA|TABLE|VALUES|USE|SET|BEGIN|COMMIT|ROLLBACK|START|END)\b/i

// PostgreSQL allows data-modifying CTEs (WITH x AS (DELETE …) SELECT …), so a
// WITH statement is only read-only if no write keyword appears anywhere in it.
const _writeKeyword =
    /\b(INSERT|UPDATE|DELETE|MERGE|REPLACE|DROP|TRUNCATE|ALTER|CREATE|GRANT|REVOKE)\b/i

function check(statements, profile) {
    if (!profile || !profile.name) return null

    const confirmations = []
    const confirm = function (msg) {
        if (confirmations.indexOf(msg) === -1) confirmations.push(msg)
    }

    for (let i = 0; i < statements.length; ++i) {
        const s = _stripLeadingComments(statements[i]).trim()
        if (s === "") continue

        if (profile.readOnly) {
            if (!_readOnlyAllowed.test(s)
                    || (/^WITH\b/i.test(s) && _writeKeyword.test(s)))
                return { blocked: true,
                         message: "This connection is in read-only mode. Write operations are not permitted." }
        }

        if (profile.confirmDelete
                && (/^DELETE\s+FROM\b/i.test(s)
                    || (/^WITH\b/i.test(s) && /\bDELETE\s+FROM\b/i.test(s))))
            confirm("You are about to run a DELETE statement. This may permanently remove rows.")

        if (profile.confirmDrop && /^DROP\s+(TABLE|DATABASE|SCHEMA|VIEW|INDEX)\b/i.test(s))
            confirm("You are about to DROP a database object. This action cannot be undone.")

        if (profile.confirmTruncate && /^TRUNCATE\b/i.test(s))
            confirm("You are about to TRUNCATE a table. All rows will be permanently deleted.")

        if (profile.confirmUpdateWithoutWhere
                && /^UPDATE\b/i.test(s)
                && !/\bWHERE\b/i.test(s))
            confirm("This UPDATE has no WHERE clause and will affect every row in the table.")
    }

    if (confirmations.length > 0)
        return { blocked: false, message: confirmations.join("\n") }
    return null
}
