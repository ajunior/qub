#include "AppDatabase.h"

#include <QSqlQuery>

namespace AppDatabase {

int schemaVersion(const QSqlDatabase &db)
{
    QSqlQuery q(db);
    if (!q.exec(QStringLiteral("PRAGMA user_version")) || !q.next())
        return 0;
    return q.value(0).toInt();
}

void stampIfNew(QSqlDatabase &db)
{
    QSqlQuery q(db);

    // sqlite_sequence and other internal tables are named sqlite_*; a file
    // holding only those was still never written to by us.
    if (!q.exec(QStringLiteral("SELECT count(*) FROM sqlite_master "
                               "WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"))
        || !q.next())
        return;
    if (q.value(0).toInt() > 0)
        return;

    // PRAGMA takes no bind parameters, and the value is a compile-time
    // constant, so there is nothing here to interpolate unsafely.
    q.exec(QStringLiteral("PRAGMA user_version = %1").arg(kSchemaVersion));
}

} // namespace AppDatabase
