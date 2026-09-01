.pragma library

// Ordering and text filtering for the Home screen's four saved-item lists —
// data sources, SSH connections, workspaces and snippets.
//
// The four arrived at four different orders: connections and SSH configs came
// back in the order they happened to be written to disk, workspaces by most
// recently opened, snippets grouped by folder. Ordering is decided here, in one
// place, so a list's order is a property of the list rather than an accident of
// the manager that happens to load it. Kept pure so it is unit-testable through
// QJSEngine (see tst_core.cpp), like guard.js / complete.js / fk.js.

// Case- and accent-insensitive key for comparing names typed by a person.
// "Produção" and "producao" sort together and match each other in a filter,
// which is the whole point on a machine where half the names carry accents.
function foldText(v) {
    var s = (v === null || v === undefined) ? "" : String(v);
    if (typeof s.normalize === "function")
        s = s.normalize("NFD").replace(/[\u0300-\u036f]/g, "");
    return s.toLowerCase();
}

// Compare two field values. Numbers and dates compare as themselves; anything
// else compares as folded text, so an empty or missing field sorts as "" rather
// than throwing the whole comparison off.
function compareValues(a, b) {
    if (typeof a === "number" && typeof b === "number")
        return a < b ? -1 : (a > b ? 1 : 0);

    var da = (a instanceof Date) ? a.getTime() : NaN;
    var db = (b instanceof Date) ? b.getTime() : NaN;
    if (!isNaN(da) && !isNaN(db))
        return da < db ? -1 : (da > db ? 1 : 0);

    var sa = foldText(a), sb = foldText(b);
    return sa < sb ? -1 : (sa > sb ? 1 : 0);
}

// Sort `items` by `key`, ascending or descending.
//
// Ties break on the item's name so the order is total: without that, two
// workspaces opened in the same minute would swap places on every reload and
// the list would look like it was shuffling itself. The tiebreak keeps its
// ascending direction regardless, because it is there to be stable rather than
// to be read.
function sortItems(items, key, ascending) {
    var out = (items || []).slice();
    var dir = ascending === false ? -1 : 1;
    out.sort(function (x, y) {
        var c = compareValues(x ? x[key] : undefined, y ? y[key] : undefined);
        if (c !== 0) return c * dir;
        if (key === "name") return 0;
        return compareValues(x ? x.name : undefined, y ? y.name : undefined);
    });
    return out;
}

// Keep the items where any of `fields` contains `query` as a substring.
//
// A blank query returns everything rather than nothing, so a cleared search box
// restores the list instead of emptying it.
function filterItems(items, query, fields) {
    var q = foldText(query).trim();
    if (q === "") return (items || []).slice();
    var keys = fields && fields.length ? fields : ["name"];
    return (items || []).filter(function (it) {
        if (!it) return false;
        for (var i = 0; i < keys.length; ++i)
            if (foldText(it[keys[i]]).indexOf(q) !== -1) return true;
        return false;
    });
}

// Filter first, then sort. The order matters only for cost, but it is the order
// a reader expects to be told: these are the ones that matched, arranged so.
function arrange(items, query, fields, key, ascending) {
    return sortItems(filterItems(items, query, fields), key, ascending);
}

// Snippets are drawn grouped under folder headers, so they are arranged in two
// passes: the folders in the chosen direction, and the snippets within each
// folder likewise. Unfoldered snippets keep their place at the top — an
// unfiled item is not the first letter of the alphabet, and burying it among
// the folders when the direction flips would lose it.
function arrangeGrouped(items, query, fields, key, ascending) {
    var rows = arrange(items, query, fields, key, ascending);
    var loose = [], byFolder = {}, folders = [];
    for (var i = 0; i < rows.length; ++i) {
        var f = rows[i].folder || "";
        if (f === "") { loose.push(rows[i]); continue; }
        if (!byFolder[f]) { byFolder[f] = []; folders.push(f); }
        byFolder[f].push(rows[i]);
    }
    folders.sort(function (a, b) {
        return compareValues(a, b) * (ascending === false ? -1 : 1);
    });
    var out = loose.slice();
    for (var j = 0; j < folders.length; ++j)
        out = out.concat(byFolder[folders[j]]);
    return out;
}
