#include "SnippetManager.h"
#include "AppDatabase.h"
#include <QSqlQuery>
#include <QSqlError>
#include <QStandardPaths>
#include <QDir>
#include <QDateTime>
#include <QVariantMap>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>

// Unique connection name per instance so tests can construct several managers
// without QSqlDatabase name collisions.
static int s_instanceCount = 0;

static QString nowIso()
{
    return QDateTime::currentDateTime().toString(Qt::ISODate);
}

SnippetManager::SnippetManager(const QString &dbPath, QObject *parent)
    : QObject(parent)
    , m_connectionName(QStringLiteral("qub_snippets_%1").arg(++s_instanceCount))
{
    initDb(dbPath);
}

SnippetManager::~SnippetManager()
{
    m_db.close();
    m_db = QSqlDatabase();
    QSqlDatabase::removeDatabase(m_connectionName);
}

void SnippetManager::initDb(const QString &dbPath)
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
        CREATE TABLE IF NOT EXISTS snippets (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            name            TEXT    NOT NULL,
            folder          TEXT    NOT NULL DEFAULT '',
            sql             TEXT    NOT NULL,
            created_at      TEXT    NOT NULL,
            updated_at      TEXT    NOT NULL
        )
    )");
}

QVariantList SnippetManager::snippets() const
{
    QVariantList list;
    QSqlQuery q(m_db);
    q.exec("SELECT id, name, folder, sql, created_at, updated_at "
           "FROM snippets ORDER BY folder, name COLLATE NOCASE");
    while (q.next()) {
        QVariantMap entry;
        entry["id"]             = q.value(0);
        entry["name"]           = q.value(1);
        entry["folder"]         = q.value(2);
        entry["sql"]            = q.value(3);
        entry["createdAt"]      = q.value(4);
        entry["updatedAt"]      = q.value(5);
        list << entry;
    }
    return list;
}

bool SnippetManager::nameInUse(const QString &name, const QString &folder,
                               qint64 excludeId) const
{
    QSqlQuery q(m_db);
    q.prepare("SELECT 1 FROM snippets WHERE name = ? COLLATE NOCASE "
              "AND folder = ? COLLATE NOCASE AND id != ? LIMIT 1");
    q.addBindValue(name.trimmed());
    q.addBindValue(folder.trimmed());
    q.addBindValue(excludeId);
    q.exec();
    return q.next();
}

qint64 SnippetManager::save(const QString &name, const QString &folder,
                            const QString &sql)
{
    const QString trimmed = name.trimmed();
    if (trimmed.isEmpty()) return -1;
    if (nameInUse(trimmed, folder)) return -1;

    QSqlQuery q(m_db);
    q.prepare(R"(
        INSERT INTO snippets (name, folder, sql, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?)
    )");
    q.addBindValue(trimmed);
    q.addBindValue(folder.trimmed());
    q.addBindValue(sql);
    q.addBindValue(nowIso());
    q.addBindValue(nowIso());
    if (!q.exec()) return -1;
    emit changed();
    return q.lastInsertId().toLongLong();
}

bool SnippetManager::update(qint64 id, const QString &name,
                            const QString &folder, const QString &sql)
{
    const QString trimmed = name.trimmed();
    if (trimmed.isEmpty()) return false;
    if (nameInUse(trimmed, folder, id)) return false;

    QSqlQuery q(m_db);
    q.prepare("UPDATE snippets SET name=?, folder=?, sql=?, updated_at=? WHERE id=?");
    q.addBindValue(trimmed);
    q.addBindValue(folder.trimmed());
    q.addBindValue(sql);
    q.addBindValue(nowIso());
    q.addBindValue(id);
    const bool ok = q.exec() && q.numRowsAffected() > 0;
    if (ok) emit changed();
    return ok;
}

bool SnippetManager::remove(qint64 id)
{
    QSqlQuery q(m_db);
    q.prepare("DELETE FROM snippets WHERE id=?");
    q.addBindValue(id);
    const bool ok = q.exec() && q.numRowsAffected() > 0;
    if (ok) emit changed();
    return ok;
}

bool SnippetManager::exportSnippets(const QUrl &fileUrl)
{
    QJsonArray arr;
    QSqlQuery q(m_db);
    q.exec("SELECT name, folder, sql FROM snippets ORDER BY folder, name COLLATE NOCASE");
    while (q.next()) {
        QJsonObject obj;
        obj["name"]   = q.value(0).toString();
        obj["folder"] = q.value(1).toString();
        obj["sql"]    = q.value(2).toString();
        arr.append(obj);
    }
    QJsonObject root;
    root["version"]  = 1;
    root["snippets"] = arr;

    QFile file(fileUrl.toLocalFile());
    if (!file.open(QIODevice::WriteOnly))
        return false;
    file.write(QJsonDocument(root).toJson());
    return true;
}

QVariantMap SnippetManager::importSnippets(const QUrl &fileUrl)
{
    QFile file(fileUrl.toLocalFile());
    if (!file.open(QIODevice::ReadOnly))
        return {{"success", false}, {"message", QString("Could not open file.")}};

    QJsonParseError err;
    const auto doc = QJsonDocument::fromJson(file.readAll(), &err);
    if (err.error != QJsonParseError::NoError)
        return {{"success", false}, {"message", QString("Invalid file: ") + err.errorString()}};

    const auto arr = doc.object()["snippets"].toArray();
    int added = 0, skipped = 0;
    for (const auto &v : arr) {
        const auto obj       = v.toObject();
        const QString name   = obj["name"].toString().trimmed();
        const QString folder = obj["folder"].toString().trimmed();
        if (name.isEmpty()) continue;

        if (nameInUse(name, folder)) { ++skipped; continue; }

        QSqlQuery ins(m_db);
        ins.prepare(R"(
            INSERT INTO snippets (name, folder, sql, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?)
        )");
        ins.addBindValue(name);
        ins.addBindValue(folder);
        ins.addBindValue(obj["sql"].toString());
        ins.addBindValue(nowIso());
        ins.addBindValue(nowIso());
        if (ins.exec()) ++added;
    }
    if (added > 0) emit changed();

    QString msg;
    if (added == 0 && skipped == 0)
        msg = "No valid snippets found in file.";
    else if (added == 0)
        msg = "All snippets already exist. Nothing imported.";
    else {
        msg = QString("Imported %1 snippet(s).").arg(added);
        if (skipped > 0)
            msg += QString(" Skipped %1 duplicate(s).").arg(skipped);
    }
    return {{"success", added > 0}, {"message", msg}};
}
