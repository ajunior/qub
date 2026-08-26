.pragma library

// Clause keywords that each start on their own line.
// Order matters: longest / most-specific must come first.
const _CLAUSES = [
    "SELECT DISTINCT", "SELECT",
    "FROM",
    "LEFT OUTER JOIN", "RIGHT OUTER JOIN", "FULL OUTER JOIN",
    "LEFT JOIN", "RIGHT JOIN", "INNER JOIN", "CROSS JOIN", "FULL JOIN", "JOIN",
    "WHERE",
    "GROUP BY", "ORDER BY",
    "HAVING", "LIMIT", "OFFSET", "FETCH NEXT", "FETCH FIRST",
    "UNION ALL", "UNION", "INTERSECT ALL", "INTERSECT", "EXCEPT ALL", "EXCEPT",
    "INSERT INTO", "INSERT",
    "VALUES",
    "UPDATE",
    "SET",
    "DELETE FROM", "DELETE",
    "RETURNING",
    "WITH",
    "CREATE TABLE", "CREATE VIEW", "CREATE INDEX",
    "DROP TABLE", "DROP VIEW", "DROP INDEX",
    "ALTER TABLE",
]

function format(sql) {
    if (!sql || !sql.trim()) return sql

    // Protect string literals, quoted identifiers, and line comments from reformatting.
    const stash = []
    const _hide = m => { stash.push(m); return "\x01" + (stash.length - 1) + "\x01" }

    let s = sql
        .replace(/'(?:[^']|'')*'/g,  _hide)   // 'single-quoted strings'
        .replace(/"(?:[^"]|"")*"/g,   _hide)   // "double-quoted identifiers"
        .replace(/`(?:[^`]|``)*`/g,   _hide)   // `backtick identifiers`
        .replace(/--[^\n]*/g,         _hide)   // -- line comments

    // Collapse all whitespace to a single space
    s = s.trim().replace(/\s+/g, ' ')

    // Insert a newline before each major clause keyword (longest alternatives first)
    const alt = _CLAUSES.map(k => k.replace(/ /g, '\\s+')).join('|')
    s = s.replace(new RegExp('\\b(' + alt + ')\\b', 'gi'), '\n$1')
    s = s.replace(/^\n/, '')

    // Line-by-line pass: expand SELECT / SELECT DISTINCT column list
    const lines = s.split('\n')
    const out = []
    for (const line of lines) {
        const m = line.match(/^(SELECT(?:\s+DISTINCT)?)\s+([\s\S]+)/i)
        if (m) {
            const cols = _splitCols(m[2].trim())
            out.push(m[1])
            // Single-column or star — keep on the same line for brevity
            if (cols.length === 1) {
                out.push('  ' + cols[0])
            } else {
                cols.forEach((c, i) => {
                    out.push('  ' + c + (i < cols.length - 1 ? ',' : ''))
                })
            }
        } else {
            out.push(line)
        }
    }
    s = out.join('\n')

    // Restore stashed tokens
    s = s.replace(/\x01(\d+)\x01/g, (_, i) => stash[+i])
    return s
}

// Split a top-level comma list, respecting parenthesis / bracket depth.
// Input must already have commas stripped if they were inside stashed tokens.
function _splitCols(cols) {
    const items = []
    let cur = '', depth = 0
    for (let i = 0; i < cols.length; i++) {
        const c = cols[i]
        if      (c === '(' || c === '[') { depth++; cur += c }
        else if (c === ')' || c === ']') { depth--; cur += c }
        else if (c === ',' && depth === 0) {
            // Strip trailing comma from the stashed SELECT column list input
            if (cur.trim()) items.push(cur.trim())
            cur = ''
        } else {
            cur += c
        }
    }
    if (cur.trim()) items.push(cur.trim())
    return items
}
