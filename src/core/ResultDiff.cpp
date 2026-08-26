#include "ResultDiff.h"

#include <QHash>
#include <QSet>

namespace {

// Distinguish NULL from the empty string, and any value from any other, when
// building a comparison key for a single cell.
QString cellKey(const QVariant &v)
{
    return (!v.isValid() || v.isNull()) ? QStringLiteral("\x01n")
                                        : QStringLiteral("\x01v") + v.toString();
}

QString rowKey(const QVariantList &row)
{
    QString k;
    for (const QVariant &c : row) {
        k += cellKey(c);
        k += QChar(0x1f);
    }
    return k;
}

// Display form of a row: NULL → "(null)".
QVariantList displayRow(const QVariantList &row)
{
    QVariantList out;
    out.reserve(row.size());
    for (const QVariant &c : row)
        out << ((!c.isValid() || c.isNull()) ? QStringLiteral("(null)") : c.toString());
    return out;
}

QString displayCell(const QVariant &v)
{
    return (!v.isValid() || v.isNull()) ? QStringLiteral("(null)") : v.toString();
}

} // namespace

namespace ResultDiff {

QVariantMap compare(const QStringList &baseCols, const QList<QVariantList> &baseRows,
                    const QStringList &curCols,  const QList<QVariantList> &curRows,
                    int keyColumn)
{
    QVariantMap out;
    out["columns"]   = curCols;
    out["keyColumn"] = keyColumn;

    const bool columnsMatch = (baseCols == curCols);
    out["columnsMatch"] = columnsMatch;

    int added = 0, removed = 0, changed = 0, same = 0;
    QVariantList rows;

    if (!columnsMatch) {
        out["summary"] = QVariantMap{{"added", 0}, {"removed", 0}, {"changed", 0}, {"same", 0}};
        out["rows"]    = rows;
        out["differs"] = true; // differing columns is itself a difference
        return out;
    }

    const int nCols = curCols.size();
    const bool keyed = (keyColumn >= 0 && keyColumn < nCols);

    if (!keyed) {
        // Whole-row multiset diff — added/removed only.
        QHash<QString, int> remaining;
        for (const QVariantList &r : baseRows)
            remaining[rowKey(r)]++;

        for (const QVariantList &r : curRows) {
            const QString k = rowKey(r);
            if (remaining.value(k) > 0) {
                remaining[k]--;
                ++same;
                rows << QVariantMap{{"status", "same"}, {"cells", displayRow(r)}};
            } else {
                ++added;
                rows << QVariantMap{{"status", "added"}, {"cells", displayRow(r)}};
            }
        }
        for (const QVariantList &r : baseRows) {
            const QString k = rowKey(r);
            if (remaining.value(k) > 0) {
                remaining[k]--;
                ++removed;
                rows << QVariantMap{{"status", "removed"}, {"before", displayRow(r)}};
            }
        }
    } else {
        // Keyed diff — first occurrence of a key wins on each side (dup keys
        // collapse; a documented v1 limitation).
        QHash<QString, int> baseIdx; // keyStr → index into baseRows
        QStringList         baseOrder;
        for (int i = 0; i < baseRows.size(); ++i) {
            const QString k = cellKey(baseRows.at(i).value(keyColumn));
            if (!baseIdx.contains(k)) { baseIdx.insert(k, i); baseOrder << k; }
        }

        QSet<QString> matched;
        for (const QVariantList &cur : curRows) {
            const QString k = cellKey(cur.value(keyColumn));
            const QString keyDisp = displayCell(cur.value(keyColumn));

            if (baseIdx.contains(k) && !matched.contains(k)) {
                matched.insert(k);
                const QVariantList base = baseRows.at(baseIdx.value(k));
                QVariantList changedCols;
                for (int c = 0; c < nCols; ++c) {
                    if (c == keyColumn) continue;
                    if (cellKey(cur.value(c)) != cellKey(base.value(c)))
                        changedCols << c;
                }
                if (changedCols.isEmpty()) {
                    ++same;
                    rows << QVariantMap{{"status", "same"}, {"key", keyDisp},
                                        {"cells", displayRow(cur)}};
                } else {
                    ++changed;
                    rows << QVariantMap{{"status", "changed"}, {"key", keyDisp},
                                        {"cells", displayRow(cur)},
                                        {"before", displayRow(base)},
                                        {"changedCols", changedCols}};
                }
            } else {
                ++added;
                rows << QVariantMap{{"status", "added"}, {"key", keyDisp},
                                    {"cells", displayRow(cur)}};
            }
        }
        for (const QString &k : baseOrder) {
            if (matched.contains(k)) continue;
            const QVariantList base = baseRows.at(baseIdx.value(k));
            ++removed;
            rows << QVariantMap{{"status", "removed"},
                                {"key", displayCell(base.value(keyColumn))},
                                {"before", displayRow(base)}};
        }
    }

    out["summary"] = QVariantMap{
        {"added", added}, {"removed", removed}, {"changed", changed}, {"same", same}};
    out["differs"] = (added || removed || changed);
    out["rows"]    = rows;
    return out;
}

} // namespace ResultDiff
