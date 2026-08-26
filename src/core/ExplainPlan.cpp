#include "core/ExplainPlan.h"

#include <QHash>
#include <QList>
#include <QString>
#include <QStringList>
#include <functional>

namespace ExplainPlan {

QVariantMap buildSqlite(const QList<QVariantList> &rows)
{
    // Rows are (id, parent, notused, detail). Build a tree keyed by id/parent.
    QHash<int, QVariantMap>  byId;
    QList<int>               order;
    QStringList warnings;
    QString     textDump;

    for (const QVariantList &row : rows) {
        const int     id     = row.value(0).toInt();
        const int     parent = row.value(1).toInt();
        const QString detail = row.value(3).toString();
        textDump += detail + QLatin1Char('\n');

        // First word ("SCAN"/"SEARCH"/"USE") is the operation; the rest is context.
        const int sp = detail.indexOf(QLatin1Char(' '));
        QVariantMap node;
        node[QStringLiteral("label")]  = sp > 0 ? detail.left(sp) : detail;
        node[QStringLiteral("detail")] = sp > 0 ? detail.mid(sp + 1) : QString();
        const bool fullScan = detail.startsWith(QStringLiteral("SCAN"))
                              && !detail.contains(QStringLiteral("USING INDEX"))
                              && !detail.contains(QStringLiteral("USING COVERING INDEX"));
        node[QStringLiteral("hot")]     = fullScan;
        node[QStringLiteral("metrics")] = QVariantList{};
        if (fullScan)
            warnings << QStringLiteral("Full scan: %1").arg(detail);

        node[QStringLiteral("_parent")] = parent;
        byId.insert(id, node);
        order.append(id);
    }

    // Assemble children bottom-up: attach each node to its parent's child list.
    std::function<QVariantMap(int)> assemble = [&](int id) -> QVariantMap {
        QVariantMap n = byId.value(id);
        QVariantList kids;
        for (int oid : order) {
            if (oid != id && byId.value(oid).value(QStringLiteral("_parent")).toInt() == id)
                kids.append(assemble(oid));
        }
        n.remove(QStringLiteral("_parent"));
        n[QStringLiteral("children")] = kids;
        return n;
    };

    QVariantList roots;
    for (int oid : order)
        if (byId.value(oid).value(QStringLiteral("_parent")).toInt() == 0)
            roots.append(assemble(oid));

    QVariantMap root;
    root[QStringLiteral("label")]    = QStringLiteral("QUERY PLAN");
    root[QStringLiteral("detail")]   = QString();
    root[QStringLiteral("metrics")]  = QVariantList{};
    root[QStringLiteral("hot")]      = false;
    root[QStringLiteral("children")] = roots;

    return {
        { QStringLiteral("success"),  true },
        { QStringLiteral("driver"),   QStringLiteral("sqlite") },
        { QStringLiteral("analyzed"), false },
        { QStringLiteral("root"),     root },
        { QStringLiteral("warnings"), warnings },
        { QStringLiteral("text"),     textDump.trimmed() },
    };
}

} // namespace ExplainPlan
