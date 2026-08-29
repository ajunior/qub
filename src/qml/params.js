.pragma library

// Query-parameter extraction for the run/EXPLAIN paths.
//
// Finds the :named and $positional placeholders a statement needs filled in
// before it can run. Kept pure so the parsing is unit-testable through
// QJSEngine (see tst_core.cpp), like guard.js / complete.js / fk.js.

// Comments and string literals are not where parameters live. This matters
// beyond the obvious: the row limit appends its own "/* qub:limit */" marker,
// which read as a :limit parameter and popped the parameter dialog in front of
// every SELECT that had no LIMIT of its own.
function stripNonCode(sql) {
    return String(sql)
        .replace(/'(?:''|\\.|[^'])*'/g, "''")   // single-quoted literals
        .replace(/--[^\n]*/g, "")               // line comments
        .replace(/\/\*[\s\S]*?\*\//g, " ");     // block comments
}

function extractParams(sql) {
    var code   = stripNonCode(sql);
    var params = [];
    var seen   = {};
    var m;

    // Named :param. The guards on both sides are what keep a Postgres cast out:
    // "id::text" must not read as a :text parameter, so the colon may not be
    // preceded by one either.
    var namedRe = /(^|[^:]):([a-zA-Z_]\w*)(?!:)/g;
    while ((m = namedRe.exec(code)) !== null) {
        if (!seen[m[2]]) { seen[m[2]] = true; params.push({ name: m[2], positional: false }); }
    }
    if (params.length > 0) return params;

    // Positional $1 … $99
    var posRe = /\$(\d+)/g;
    var nums  = [];
    while ((m = posRe.exec(code)) !== null) {
        var n = parseInt(m[1], 10);
        if (!seen[String(n)]) { seen[String(n)] = true; nums.push(n); }
    }
    nums.sort(function (a, b) { return a - b; });
    for (var i = 0; i < nums.length; ++i)
        params.push({ name: String(nums[i]), positional: true });
    return params;
}
