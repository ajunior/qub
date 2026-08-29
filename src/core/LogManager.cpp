#include "LogManager.h"
#include <QDateTime>
#include <QDir>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonValue>
#include <QSqlQuery>
#include <QStandardPaths>

static const QString kConnectionName = "qub_logs";

static QVariantMap entryFromParts(qint64 id, qint64 epoch,
                                  const QString &level, const QString &category,
                                  const QString &connection, const QString &message,
                                  const QVariantMap &detail)
{
    const QDateTime dt = QDateTime::fromMSecsSinceEpoch(epoch);
    QVariantMap entry;
    entry["id"]         = id;
    entry["epoch"]      = epoch;
    // One stamp, carrying the date. A console line is read long after the day
    // it was written — the log keeps a week — and it gets pasted into tickets,
    // where "13:33:31" answers nothing on its own.
    entry["timestamp"]  = dt.toString("yyyy-MM-dd HH:mm:ss.zzz");
    entry["level"]      = level;
    entry["category"]   = category;
    entry["connection"] = connection;
    entry["message"]    = message;
    entry["detail"]     = detail;
    return entry;
}

LogManager::LogManager(QObject *parent) : QObject(parent)
{
    initDb();
    load();
}

LogManager::~LogManager()
{
    m_db.close();
    m_db = QSqlDatabase();
    QSqlDatabase::removeDatabase(kConnectionName);
}

void LogManager::initDb()
{
    const QString dir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    QDir().mkpath(dir);

    m_db = QSqlDatabase::addDatabase("QSQLITE", kConnectionName);
    m_db.setDatabaseName(dir + "/qub.db");
    m_db.open();

    QSqlQuery q(m_db);
    q.exec(R"(
        CREATE TABLE IF NOT EXISTS logs (
            id         INTEGER PRIMARY KEY,
            epoch      INTEGER NOT NULL,
            level      TEXT    NOT NULL,
            category   TEXT    NOT NULL,
            connection TEXT    NOT NULL,
            message    TEXT    NOT NULL,
            detail     TEXT    NOT NULL DEFAULT '{}'
        )
    )");

    // Retention: drop entries older than the window before loading.
    const qint64 cutoff = QDateTime::currentDateTime()
                              .addDays(-kRetentionDays).toMSecsSinceEpoch();
    QSqlQuery purge(m_db);
    purge.prepare("DELETE FROM logs WHERE epoch < ?");
    purge.addBindValue(cutoff);
    purge.exec();
}

void LogManager::load()
{
    // Most recent kMaxEntries, oldest-first in memory.
    QSqlQuery q(m_db);
    q.prepare(R"(
        SELECT id, epoch, level, category, connection, message, detail
        FROM (SELECT * FROM logs ORDER BY id DESC LIMIT ?)
        ORDER BY id ASC
    )");
    q.addBindValue(kMaxEntries);
    q.exec();

    while (q.next()) {
        const QVariantMap detail =
            QJsonDocument::fromJson(q.value(6).toByteArray()).object().toVariantMap();
        const QVariantMap entry = entryFromParts(
            q.value(0).toLongLong(), q.value(1).toLongLong(),
            q.value(2).toString(), q.value(3).toString(),
            q.value(4).toString(), q.value(5).toString(), detail);
        m_entries << entry;
        m_nextId = qMax(m_nextId, q.value(0).toLongLong() + 1);

        const QString level = q.value(2).toString();
        if (level == QLatin1String("error")) ++m_errorCount;
        if (level == QLatin1String("warn"))  ++m_warnCount;
    }
}

QVariantList LogManager::entries() const
{
    QVariantList out;
    out.reserve(m_entries.size());
    for (const auto &e : m_entries)
        out << e;
    return out;
}

void LogManager::post(const QString &level,
                      const QString &category,
                      const QString &connection,
                      const QString &summary,
                      const QVariantMap &detail)
{
    const qint64 epoch = QDateTime::currentMSecsSinceEpoch();
    const QVariantMap entry = entryFromParts(m_nextId++, epoch, level, category,
                                             connection, summary, detail);

    QSqlQuery q(m_db);
    q.prepare(R"(
        INSERT INTO logs (id, epoch, level, category, connection, message, detail)
        VALUES (?, ?, ?, ?, ?, ?, ?)
    )");
    q.addBindValue(entry["id"]);
    q.addBindValue(epoch);
    q.addBindValue(level);
    q.addBindValue(category);
    q.addBindValue(connection);
    q.addBindValue(summary);
    q.addBindValue(QString::fromUtf8(
        QJsonDocument(QJsonObject::fromVariantMap(detail)).toJson(QJsonDocument::Compact)));
    q.exec();

    if (m_entries.size() >= kMaxEntries) {
        const QString removed = m_entries.takeFirst()["level"].toString();
        if (removed == QLatin1String("error")) --m_errorCount;
        if (removed == QLatin1String("warn"))  --m_warnCount;
    }
    m_entries << entry;

    if (level == QLatin1String("error")) ++m_errorCount;
    if (level == QLatin1String("warn"))  ++m_warnCount;

    emit entryAdded(entry);
    emit entriesChanged();
}

void LogManager::clear()
{
    QSqlQuery q(m_db);
    q.exec("DELETE FROM logs");

    m_entries.clear();
    m_errorCount = 0;
    m_warnCount  = 0;
    emit entriesChanged();
}

QString LogManager::exportJson() const
{
    QJsonArray arr;
    for (const auto &e : m_entries) {
        QJsonObject obj;
        for (auto it = e.cbegin(); it != e.cend(); ++it) {
            if (it.key() == QLatin1String("detail")) {
                QJsonObject d;
                const auto detail = it.value().toMap();
                for (auto dit = detail.cbegin(); dit != detail.cend(); ++dit)
                    d[dit.key()] = QJsonValue::fromVariant(dit.value());
                obj["detail"] = d;
            } else {
                obj[it.key()] = QJsonValue::fromVariant(it.value());
            }
        }
        arr.append(obj);
    }
    return QJsonDocument(arr).toJson(QJsonDocument::Indented);
}

QString LogManager::exportCsv() const
{
    auto q = [](const QString &s) {
        QString v = s;
        // Neutralize spreadsheet formula injection: log summaries contain
        // SQL text and DB-sourced error messages.
        if (!v.isEmpty() && (v[0] == '=' || v[0] == '+' || v[0] == '-' ||
                             v[0] == '@' || v[0] == '\t' || v[0] == '\r')) {
            bool numeric = false;
            v.toDouble(&numeric);
            if (!numeric)
                v.prepend('\'');
        }
        return QStringLiteral("\"") + v.replace('"', QStringLiteral("\"\"")) + QStringLiteral("\"");
    };

    QString out = QStringLiteral("timestamp,level,category,connection,summary\n");
    for (const auto &e : m_entries) {
        out += q(e["timestamp"].toString()) + ','
             + q(e["level"].toString())     + ','
             + q(e["category"].toString())  + ','
             + q(e["connection"].toString())+ ','
             + q(e["message"].toString())   + '\n';
    }
    return out;
}
