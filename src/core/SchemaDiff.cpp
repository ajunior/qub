#include "SchemaDiff.h"

#include <QMap>
#include <QStringList>

namespace {

// Preserve first-seen order while allowing keyed lookup.
struct Ordered {
    QStringList              order;
    QMap<QString, QVariantMap> byName;

    void add(const QString &key, const QVariantMap &val) {
        if (!byName.contains(key)) order << key;
        byName.insert(key, val);
    }
};

Ordered indexByName(const QVariantList &items, const QString &key = QStringLiteral("name"))
{
    Ordered idx;
    for (const QVariant &v : items) {
        const QVariantMap m = v.toMap();
        idx.add(m.value(key).toString(), m);
    }
    return idx;
}

// Merge the key order of two indexes: everything from A in order, then any
// keys only in B (in B's order).
QStringList mergedOrder(const Ordered &a, const Ordered &b)
{
    QStringList out = a.order;
    for (const QString &k : b.order)
        if (!out.contains(k)) out << k;
    return out;
}

bool typeEq(const QString &x, const QString &y)
{
    return QString::compare(x.trimmed(), y.trimmed(), Qt::CaseInsensitive) == 0;
}

// Compare one column present in both sides. Returns "same" or "changed" and
// fills `changes` with the differing attribute names.
QString diffColumn(const QVariantMap &l, const QVariantMap &r, QStringList &changes)
{
    if (!typeEq(l.value("type").toString(), r.value("type").toString()))
        changes << QStringLiteral("type");
    if (l.value("nullable").toBool() != r.value("nullable").toBool())
        changes << QStringLiteral("nullable");
    if (l.value("pk").toBool() != r.value("pk").toBool())
        changes << QStringLiteral("pk");
    return changes.isEmpty() ? QStringLiteral("same") : QStringLiteral("changed");
}

QVariantMap colAttrs(const QVariantMap &c)
{
    return QVariantMap{
        {"type",     c.value("type")},
        {"pk",       c.value("pk").toBool()},
        {"nullable", c.value("nullable").toBool()},
    };
}

} // namespace

namespace SchemaDiff {

QVariantMap compare(const QVariantList &left, const QVariantList &right)
{
    int schemasAdded = 0, schemasRemoved = 0;
    int tablesAdded = 0, tablesRemoved = 0, tablesChanged = 0;
    int colsAdded = 0, colsRemoved = 0, colsChanged = 0;

    const Ordered lSchemas = indexByName(left);
    const Ordered rSchemas = indexByName(right);

    QVariantList schemaNodes;

    for (const QString &sName : mergedOrder(lSchemas, rSchemas)) {
        const bool inL = lSchemas.byName.contains(sName);
        const bool inR = rSchemas.byName.contains(sName);

        const Ordered lTables = indexByName(
            inL ? lSchemas.byName.value(sName).value("tables").toList() : QVariantList{});
        const Ordered rTables = indexByName(
            inR ? rSchemas.byName.value(sName).value("tables").toList() : QVariantList{});

        QVariantList tableNodes;
        bool schemaDiffers = (inL != inR);

        for (const QString &tName : mergedOrder(lTables, rTables)) {
            const bool tInL = lTables.byName.contains(tName);
            const bool tInR = rTables.byName.contains(tName);
            const QVariantMap tL = lTables.byName.value(tName);
            const QVariantMap tR = rTables.byName.value(tName);

            const Ordered lCols = indexByName(tL.value("columns").toList());
            const Ordered rCols = indexByName(tR.value("columns").toList());

            QVariantList colNodes;
            bool tableDiffers = (tInL != tInR);

            for (const QString &cName : mergedOrder(lCols, rCols)) {
                const bool cInL = lCols.byName.contains(cName);
                const bool cInR = rCols.byName.contains(cName);
                const QVariantMap cL = lCols.byName.value(cName);
                const QVariantMap cR = rCols.byName.value(cName);

                // Only tally column-level deltas for tables present on both
                // sides; a wholly added/removed table is already counted once
                // at the table level, so its columns must not inflate the sum.
                const bool tallyCols = tInL && tInR;

                QVariantMap col{{"name", cName}};
                QString status;
                if (cInL && !cInR)      { status = "removed"; if (tallyCols) colsRemoved++; }
                else if (!cInL && cInR) { status = "added";   if (tallyCols) colsAdded++;   }
                else {
                    QStringList changes;
                    status = diffColumn(cL, cR, changes);
                    if (status == "changed") {
                        if (tallyCols) colsChanged++;
                        col["changes"] = changes;
                    }
                }
                col["status"] = status;
                if (cInL) col["left"]  = colAttrs(cL);
                if (cInR) col["right"] = colAttrs(cR);
                if (status != "same") tableDiffers = true;
                colNodes << col;
            }

            QVariantMap table{{"name", tName}};
            table["type"]    = (tInR ? tR : tL).value("type");
            table["columns"] = colNodes;
            QString tStatus;
            if (tInL && !tInR)      { tStatus = "removed"; tablesRemoved++; }
            else if (!tInL && tInR) { tStatus = "added";   tablesAdded++;   }
            else if (tableDiffers)  { tStatus = "changed"; tablesChanged++; }
            else                     tStatus = "same";
            table["status"] = tStatus;
            if (tStatus != "same") schemaDiffers = true;
            tableNodes << table;
        }

        QVariantMap schema{{"name", sName}};
        schema["tables"] = tableNodes;
        QString sStatus;
        if (inL && !inR)      { sStatus = "removed"; schemasRemoved++; }
        else if (!inL && inR) { sStatus = "added";   schemasAdded++;   }
        else if (schemaDiffers) sStatus = "changed";
        else                    sStatus = "same";
        schema["status"] = sStatus;
        schemaNodes << schema;
    }

    QVariantMap summary{
        {"schemasAdded",   schemasAdded},
        {"schemasRemoved", schemasRemoved},
        {"tablesAdded",    tablesAdded},
        {"tablesRemoved",  tablesRemoved},
        {"tablesChanged",  tablesChanged},
        {"columnsAdded",   colsAdded},
        {"columnsRemoved", colsRemoved},
        {"columnsChanged", colsChanged},
    };

    const bool differs = schemasAdded || schemasRemoved || tablesAdded ||
                         tablesRemoved || tablesChanged || colsAdded ||
                         colsRemoved || colsChanged;

    return QVariantMap{
        {"summary", summary},
        {"differs", differs},
        {"schemas", schemaNodes},
    };
}

} // namespace SchemaDiff
