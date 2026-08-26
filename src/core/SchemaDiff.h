#pragma once

#include <QVariantList>
#include <QVariantMap>

// Structural diff of two database schemas, each in the shape produced by
// ConnectionManager::schemas():
//   [ { name, tables: [ { name, type, columns: [ { name, type, pk, nullable } ] } ] } ]
//
// Connection-free and pure so it can be unit-tested without a live database
// (mirrors the ExplainPlan extraction).
namespace SchemaDiff {

// Compare `left` (base / "A") against `right` (compare / "B"). Every schema,
// table and column node carries a `status` of "added" (only in B), "removed"
// (only in A), "changed" (present in both, differs) or "same". Column nodes
// that changed also carry `left`/`right` attribute maps and a `changes` list
// naming which of {type, nullable, pk} differ. The returned map also holds a
// `summary` of counts and a `differs` bool.
QVariantMap compare(const QVariantList &left, const QVariantList &right);

} // namespace SchemaDiff
