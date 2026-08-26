.pragma library

// Value-inspector helper for result cells.
//
// Given a cell's display value, decide how to present it in the expand-value
// dialog: JSON objects/arrays are pretty-printed; everything else is shown
// verbatim. Kept pure so the classification is unit-testable through QJSEngine
// (see tst_core.cpp), like guard.js / complete.js / fk.js.
function inspect(value) {
    var s = (value === null || value === undefined) ? "" : String(value);
    var t = s.trim();
    // Only attempt JSON when it looks like an object or array — this avoids
    // treating a bare number, "true", or a quoted string as a JSON document.
    if (t.length >= 2 && (t.charAt(0) === "{" || t.charAt(0) === "[")) {
        try {
            var parsed = JSON.parse(t);
            if (parsed !== null && typeof parsed === "object")
                return { kind: "json", text: JSON.stringify(parsed, null, 2) };
        } catch (e) { /* not valid JSON — fall through to plain text */ }
    }
    return { kind: "text", text: s };
}
