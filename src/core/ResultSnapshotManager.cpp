#include "ResultSnapshotManager.h"
#include "AppDatabase.h"

#include <QSqlQuery>
#include <QSqlError>
#include <QStandardPaths>
#include <QDir>
#include <QDateTime>
#include <QJsonDocument>

static int s_instanceCount = 0;

ResultSnapshotManager::ResultSnapshotManager(const QString &dbPath, QObject *parent)
    : QObject(parent)
    , m_connectionName(QStringLiteral("qub_result_snapshots_%1").arg(++s_instanceCount))
{
    initDb(dbPath);
}

ResultSnapshotManager::~ResultSnapshotManager()
{
    m_db.close();
    m_db = QSqlDatabase();
    QSqlDatabase::removeDatabase(m_connectionName);
}

void ResultSnapshotManager::initDb(const QString &dbPath)
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
        CREATE TABLE IF NOT EXISTS result_snapshots (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            name            TEXT    NOT NULL,
            connection_name TEXT    NOT NULL DEFAULT '',
            sql             TEXT    NOT NULL DEFAULT '',
            captured_at     TEXT    NOT NULL,
            row_count       INTEGER NOT NULL DEFAULT 0,
            col_count       INTEGER NOT NULL DEFAULT 0,
            snapshot_json   TEXT    NOT NULL
        )
    )");
}

QVariantList ResultSnapshotManager::snapshots() const
{
    QVariantList list;
    QSqlQuery q(m_db);
    q.exec("SELECT id, name, connection_name, sql, captured_at, row_count, col_count "
           "FROM result_snapshots ORDER BY captured_at DESC, id DESC");
    while (q.next()) {
        QVariantMap e;
        e["id"]             = q.value(0);
        e["name"]           = q.value(1);
        e["connectionName"] = q.value(2);
        e["sql"]            = q.value(3);
        e["capturedAt"]     = q.value(4);
        e["rowCount"]       = q.value(5);
        e["colCount"]       = q.value(6);
        list << e;
    }
    return list;
}

qint64 ResultSnapshotManager::capture(const QString &name, const QString &connectionName,
                                      const QString &sql, const QVariantMap &snapshot)
{
    const QByteArray json =
        QJsonDocument::fromVariant(QVariant(snapshot)).toJson(QJsonDocument::Compact);
    const int rowCount = snapshot.value("rowCount").toInt();
    const int colCount = snapshot.value("columns").toList().size();

    QSqlQuery q(m_db);
    q.prepare("INSERT INTO result_snapshots "
              "(name, connection_name, sql, captured_at, row_count, col_count, snapshot_json) "
              "VALUES (?, ?, ?, ?, ?, ?, ?)");
    q.addBindValue(name.trimmed());
    q.addBindValue(connectionName);
    q.addBindValue(sql);
    q.addBindValue(QDateTime::currentDateTime().toString(Qt::ISODate));
    q.addBindValue(rowCount);
    q.addBindValue(colCount);
    q.addBindValue(QString::fromUtf8(json));
    if (!q.exec())
        return -1;

    emit changed();
    return q.lastInsertId().toLongLong();
}

bool ResultSnapshotManager::remove(qint64 id)
{
    QSqlQuery q(m_db);
    q.prepare("DELETE FROM result_snapshots WHERE id = ?");
    q.addBindValue(id);
    if (!q.exec())
        return false;
    emit changed();
    return true;
}

QVariantMap ResultSnapshotManager::snapshotOf(qint64 id) const
{
    QSqlQuery q(m_db);
    q.prepare("SELECT snapshot_json FROM result_snapshots WHERE id = ?");
    q.addBindValue(id);
    if (!q.exec() || !q.next())
        return {};
    return QJsonDocument::fromJson(q.value(0).toString().toUtf8()).toVariant().toMap();
}
