#pragma once

#include <QVariantMap>
#include <QVariantList>

// Pure, connection-free helpers that turn raw driver EXPLAIN output into the
// normalised plan tree the UI consumes:
//   { success, driver, analyzed, text, warnings:[str],
//     root: { label, detail, metrics:[{key,value}], hot, children:[…] } }
// Kept out of DatabaseInspector so the tree assembly can be unit-tested without
// pulling in ConnectionManager / adapters / the keychain.
namespace ExplainPlan {

// Build the SQLite plan tree from `EXPLAIN QUERY PLAN` rows, each row being
// (id, parent, notused, detail).
QVariantMap buildSqlite(const QList<QVariantList> &rows);

} // namespace ExplainPlan
