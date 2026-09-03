#include "SchemaSnapshotManager.h"
#include "AppDatabase.h"
#include "SchemaDiff.h"

#include <QSqlQuery>
#include <QSqlError>
#include <QStandardPaths>
#include <QDir>
#include <QDateTime>
#include <QJsonDocument>

// Unique connection name per instance so tests can construct several managers
// without QSqlDatabase name collisions.
static int s_instanceCount = 0;

SchemaSnapshotManager::SchemaSnapshotManager(const QString &dbPath, QObject *parent)
    : QObject(parent)
    , m_connectionName(QStringLiteral("qub_schema_snapshots_%1").arg(++s_instanceCount))
{
    initDb(dbPath);
}

SchemaSnapshotManager::~SchemaSnapshotManager()
{
    m_db.close();
    m_db = QSqlDatabase();
    QSqlDatabase::removeDatabase(m_connectionName);
}

void SchemaSnapshotManager::initDb(const QString &dbPath)
{
    QString path = dbPath;
    if (path.isEmpty()) {
        const QString dir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
        QDir().mkpath(dir);
        path = dir + "/qub.db";
    }

    m_db = QSqlDatabase::addDatabase("QSQLITE", m_connectionName);
    m_db.setDatabaseName(path);
    m_db.open();

    AppDatabase::stampIfNew(m_db);

    QSqlQuery q(m_db);
    q.exec(R"(
        CREATE TABLE IF NOT EXISTS schema_snapshots (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            name            TEXT    NOT NULL,
            connection_name TEXT    NOT NULL DEFAULT '',
            captured_at     TEXT    NOT NULL,
            table_count     INTEGER NOT NULL DEFAULT 0,
            schema_json     TEXT    NOT NULL
        )
    )");
}

int SchemaSnapshotManager::countTables(const QVariantList &schemas)
{
    int n = 0;
    for (const QVariant &s : schemas)
        n += s.toMap().value("tables").toList().size();
    return n;
}

QVariantList SchemaSnapshotManager::snapshots() const
{
    QVariantList list;
    QSqlQuery q(m_db);
    q.exec("SELECT id, name, connection_name, captured_at, table_count "
           "FROM schema_snapshots ORDER BY captured_at DESC, id DESC");
    while (q.next()) {
        QVariantMap entry;
        entry["id"]             = q.value(0);
        entry["name"]           = q.value(1);
        entry["connectionName"] = q.value(2);
        entry["capturedAt"]     = q.value(3);
        entry["tableCount"]     = q.value(4);
        list << entry;
    }
    return list;
}

qint64 SchemaSnapshotManager::capture(const QString &name, const QString &connectionName,
                                      const QVariantList &schemas)
{
    const QByteArray json =
        QJsonDocument::fromVariant(QVariant(schemas)).toJson(QJsonDocument::Compact);

    QSqlQuery q(m_db);
    q.prepare("INSERT INTO schema_snapshots "
              "(name, connection_name, captured_at, table_count, schema_json) "
              "VALUES (?, ?, ?, ?, ?)");
    q.addBindValue(name.trimmed());
    q.addBindValue(connectionName);
    q.addBindValue(QDateTime::currentDateTime().toString(Qt::ISODate));
    q.addBindValue(countTables(schemas));
    q.addBindValue(QString::fromUtf8(json));
    if (!q.exec())
        return -1;

    emit changed();
    return q.lastInsertId().toLongLong();
}

bool SchemaSnapshotManager::remove(qint64 id)
{
    QSqlQuery q(m_db);
    q.prepare("DELETE FROM schema_snapshots WHERE id = ?");
    q.addBindValue(id);
    if (!q.exec())
        return false;
    emit changed();
    return true;
}

QVariantList SchemaSnapshotManager::schemaOf(qint64 id) const
{
    QSqlQuery q(m_db);
    q.prepare("SELECT schema_json FROM schema_snapshots WHERE id = ?");
    q.addBindValue(id);
    if (!q.exec() || !q.next())
        return {};
    return QJsonDocument::fromJson(q.value(0).toString().toUtf8()).toVariant().toList();
}

QVariantMap SchemaSnapshotManager::diffLive(qint64 id, const QVariantList &liveSchemas) const
{
    const QVariantList base = schemaOf(id);
    if (base.isEmpty())
        return {};
    return SchemaDiff::compare(base, liveSchemas);
}
