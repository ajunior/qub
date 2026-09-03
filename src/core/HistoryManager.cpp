#include "HistoryManager.h"
#include "AppDatabase.h"
#include <QSqlQuery>
#include <QSqlError>
#include <QStandardPaths>
#include <QDir>
#include <QDateTime>
#include <QVariantMap>
#include <QRegularExpression>
#include <QHash>
#include <algorithm>

static const QString kConnectionName = "qub_history";

HistoryManager::HistoryManager(QObject *parent)
    : QObject(parent)
{
    initDb();
}

HistoryManager::~HistoryManager()
{
    m_db.close();
    m_db = QSqlDatabase();
    QSqlDatabase::removeDatabase(kConnectionName);
}

void HistoryManager::initDb()
{
    const QString dir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    QDir().mkpath(dir);

    m_db = QSqlDatabase::addDatabase("QSQLITE", kConnectionName);
    m_db.setDatabaseName(dir + "/qub.db");
    m_db.open();

    AppDatabase::stampIfNew(m_db);

    QSqlQuery q(m_db);
    q.exec(R"(
        CREATE TABLE IF NOT EXISTS history (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            connection_name TEXT    NOT NULL,
            sql             TEXT    NOT NULL,
            executed_at     TEXT    NOT NULL,
            success         INTEGER NOT NULL DEFAULT 1,
            row_count       INTEGER NOT NULL DEFAULT 0,
            elapsed_ms      INTEGER NOT NULL DEFAULT 0
        )
    )");
}

void HistoryManager::add(const QString &connectionName, const QString &sql,
                          bool success, int rowCount, qint64 elapsedMs)
{
    QSqlQuery q(m_db);
    q.prepare(R"(
        INSERT INTO history (connection_name, sql, executed_at, success, row_count, elapsed_ms)
        VALUES (?, ?, ?, ?, ?, ?)
    )");
    q.addBindValue(connectionName);
    q.addBindValue(sql);
    q.addBindValue(QDateTime::currentDateTime().toString(Qt::ISODate));
    q.addBindValue(success ? 1 : 0);
    q.addBindValue(rowCount);
    q.addBindValue(elapsedMs);
    q.exec();

    // Prune oldest entries beyond the configured cap
    QSqlQuery pruneQ(m_db);
    pruneQ.prepare(R"(
        DELETE FROM history WHERE id NOT IN (
            SELECT id FROM history ORDER BY id DESC LIMIT ?
        )
    )");
    pruneQ.addBindValue(qMax(1, m_limit));
    pruneQ.exec();

    emit changed();
}

void HistoryManager::setLimit(int limit)
{
    if (m_limit == limit) return;
    m_limit = limit;
    emit limitChanged();
}

QVariantList HistoryManager::entries(int limit) const
{
    QVariantList list;
    QSqlQuery q(m_db);
    q.prepare("SELECT id, connection_name, sql, executed_at, success, row_count, elapsed_ms "
              "FROM history ORDER BY id DESC LIMIT ?");
    q.addBindValue(limit);
    q.exec();
    while (q.next()) {
        QVariantMap entry;
        entry["id"]             = q.value(0);
        entry["connectionName"] = q.value(1);
        entry["sql"]            = q.value(2);
        entry["executedAt"]     = q.value(3);
        entry["success"]        = q.value(4).toBool();
        entry["rowCount"]       = q.value(5);
        entry["elapsedMs"]      = q.value(6);
        list << entry;
    }
    return list;
}

QVariantList HistoryManager::search(const QString &text, int limit) const
{
    // Treat the user's text literally: % and _ are LIKE wildcards.
    QString escaped = text;
    escaped.replace('\\', "\\\\").replace('%', "\\%").replace('_', "\\_");

    QVariantList list;
    QSqlQuery q(m_db);
    q.prepare("SELECT id, connection_name, sql, executed_at, success, row_count, elapsed_ms "
              "FROM history WHERE sql LIKE ? ESCAPE '\\' ORDER BY id DESC LIMIT ?");
    q.addBindValue("%" + escaped + "%");
    q.addBindValue(limit);
    q.exec();
    while (q.next()) {
        QVariantMap entry;
        entry["id"]             = q.value(0);
        entry["connectionName"] = q.value(1);
        entry["sql"]            = q.value(2);
        entry["executedAt"]     = q.value(3);
        entry["success"]        = q.value(4).toBool();
        entry["rowCount"]       = q.value(5);
        entry["elapsedMs"]      = q.value(6);
        list << entry;
    }
    return list;
}

QString HistoryManager::fingerprint(const QString &sql)
{
    QString s = sql;

    // Single-quoted string literals (doubled '' escapes included) → ?
    static const QRegularExpression strLit(QStringLiteral("'(?:[^']|'')*'"));
    s.replace(strLit, QStringLiteral("?"));

    // Numeric literals → ?
    static const QRegularExpression numLit(QStringLiteral("\\b\\d+(?:\\.\\d+)?\\b"));
    s.replace(numLit, QStringLiteral("?"));

    // Collapse all whitespace runs to a single space.
    static const QRegularExpression ws(QStringLiteral("\\s+"));
    s.replace(ws, QStringLiteral(" "));

    s = s.trimmed();
    if (s.endsWith(';'))
        s.chop(1);
    return s.trimmed();
}

QVariantList HistoryManager::slowQueries(int limit, const QString &connectionName) const
{
    struct Agg {
        QString sql;              // representative: most recent actual SQL
        QString connection;
        int     calls   = 0;
        qint64  totalMs = 0;
        qint64  maxMs   = 0;
        int     failures = 0;
        QString lastExecutedAt;
        qint64  lastId  = -1;
    };
    QHash<QString, Agg> groups;

    QString sqlStr = QStringLiteral(
        "SELECT id, connection_name, sql, executed_at, success, elapsed_ms FROM history");
    if (!connectionName.isEmpty())
        sqlStr += QStringLiteral(" WHERE connection_name = ?");

    QSqlQuery q(m_db);
    q.prepare(sqlStr);
    if (!connectionName.isEmpty())
        q.addBindValue(connectionName);
    q.exec();

    while (q.next()) {
        const qint64  id      = q.value(0).toLongLong();
        const QString conn    = q.value(1).toString();
        const QString sql     = q.value(2).toString();
        const QString at      = q.value(3).toString();
        const bool    success = q.value(4).toBool();
        const qint64  ms      = q.value(5).toLongLong();

        const QString key = conn + QChar('\n') + fingerprint(sql);
        Agg &a = groups[key];
        a.calls   += 1;
        a.totalMs += ms;
        a.maxMs    = qMax(a.maxMs, ms);
        if (!success) a.failures += 1;
        a.connection = conn;
        // Newest row (highest id) wins as the representative statement.
        if (id >= a.lastId) {
            a.lastId         = id;
            a.sql            = sql;
            a.lastExecutedAt = at;
        }
    }

    QList<Agg> aggs = groups.values();
    std::sort(aggs.begin(), aggs.end(), [](const Agg &x, const Agg &y) {
        if (x.totalMs != y.totalMs) return x.totalMs > y.totalMs;
        return x.lastId > y.lastId;   // stable-ish tiebreak: newest first
    });

    QVariantList out;
    for (int i = 0; i < aggs.size() && (limit <= 0 || i < limit); i++) {
        const Agg &a = aggs[i];
        QVariantMap m;
        m["sql"]            = a.sql;
        m["connectionName"] = a.connection;
        m["calls"]          = a.calls;
        m["totalMs"]        = a.totalMs;
        m["avgMs"]          = a.calls > 0 ? double(a.totalMs) / a.calls : 0.0;
        m["maxMs"]          = a.maxMs;
        m["failures"]       = a.failures;
        m["lastExecutedAt"] = a.lastExecutedAt;
        out << m;
    }
    return out;
}

void HistoryManager::remove(qint64 id)
{
    QSqlQuery q(m_db);
    q.prepare("DELETE FROM history WHERE id = ?");
    q.addBindValue(id);
    q.exec();
    emit changed();
}

void HistoryManager::clear()
{
    QSqlQuery q(m_db);
    q.exec("DELETE FROM history");
    emit changed();
}
