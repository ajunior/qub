#pragma once

#include <QStringList>
#include <QVariantList>
#include <QVariantMap>
#include <QList>

// Row-level diff of two result sets. Connection-free and pure so it is
// unit-testable without a live database (mirrors SchemaDiff / ExplainPlan).
//
// `keyColumn` selects how rows are matched across the two sets:
//   * -1  → whole-row mode: a multiset diff producing only added/removed rows.
//   * >=0 → keyed mode: rows are matched by that column's value, so a matched
//           pair whose other cells differ is reported as "changed".
//
// Both sides must share the same columns; otherwise `columnsMatch` is false and
// no rows are produced.
namespace ResultDiff {

QVariantMap compare(const QStringList &baseCols, const QList<QVariantList> &baseRows,
                    const QStringList &curCols,  const QList<QVariantList> &curRows,
                    int keyColumn);

} // namespace ResultDiff
