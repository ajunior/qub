#include "HealthAlertManager.h"
#include "LogManager.h"

#include <QSqlQuery>
#include <QSqlError>
#include <QStandardPaths>
#include <QDir>
#include <QDateTime>

static int s_instanceCount = 0;

HealthAlertManager::HealthAlertManager(LogManager *log, const QString &dbPath, QObject *parent)
    : QObject(parent)
    , m_log(log)
    , m_connectionName(QStringLiteral("qub_health_alerts_%1").arg(++s_instanceCount))
{
    initDb(dbPath);
}

HealthAlertManager::~HealthAlertManager()
{
    m_db.close();
    m_db = QSqlDatabase();
    QSqlDatabase::removeDatabase(m_connectionName);
}

void HealthAlertManager::initDb(const QString &dbPath)
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

    QSqlQuery q(m_db);
    q.exec(R"(
        CREATE TABLE IF NOT EXISTS health_alerts (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            connection_name TEXT    NOT NULL,
            metric          TEXT    NOT NULL,
            comparator      TEXT    NOT NULL DEFAULT 'gt',
            threshold       REAL    NOT NULL DEFAULT 0,
            enabled         INTEGER NOT NULL DEFAULT 1,
            created_at      TEXT    NOT NULL
        )
    )");
}

bool HealthAlertManager::matches(const QString &comparator, double value, double threshold)
{
    if (comparator == QLatin1String("lt")) return value < threshold;
    return value > threshold;   // default / "gt"
}

QString HealthAlertManager::describe(const QString &connectionName, const QString &metric,
                                     const QString &comparator, double threshold, double value)
{
    const QString sym = comparator == QLatin1String("lt") ? QStringLiteral("<")
                                                          : QStringLiteral(">");
    auto fmt = [](double d) {
        return (d == qRound(d)) ? QString::number(qint64(d))
                                : QString::number(d, 'f', 1);
    };
    return QStringLiteral("%1: %2 %3 %4 (now %5)")
        .arg(connectionName, metric, sym, fmt(threshold), fmt(value));
}

QVariantList HealthAlertManager::rules() const
{
    QVariantList list;
    QSqlQuery q(m_db);
    q.exec("SELECT id, connection_name, metric, comparator, threshold, enabled "
           "FROM health_alerts ORDER BY connection_name, metric");
    while (q.next()) {
        QVariantMap e;
        e["id"]             = q.value(0);
        e["connectionName"] = q.value(1);
        e["metric"]         = q.value(2);
        e["comparator"]     = q.value(3);
        e["threshold"]      = q.value(4);
        e["enabled"]        = q.value(5).toInt() != 0;
        list << e;
    }
    return list;
}

QVariantList HealthAlertManager::rulesFor(const QString &connectionName) const
{
    QVariantList list;
    QSqlQuery q(m_db);
    q.prepare("SELECT id, connection_name, metric, comparator, threshold, enabled "
              "FROM health_alerts WHERE connection_name = ? ORDER BY metric");
    q.addBindValue(connectionName);
    q.exec();
    while (q.next()) {
        QVariantMap e;
        e["id"]             = q.value(0);
        e["connectionName"] = q.value(1);
        e["metric"]         = q.value(2);
        e["comparator"]     = q.value(3);
        e["threshold"]      = q.value(4);
        e["enabled"]        = q.value(5).toInt() != 0;
        list << e;
    }
    return list;
}

qint64 HealthAlertManager::addRule(const QString &connectionName, const QString &metric,
                                   const QString &comparator, double threshold)
{
    const QString cmp = (comparator == QLatin1String("lt")) ? QStringLiteral("lt")
                                                            : QStringLiteral("gt");
    QSqlQuery q(m_db);
    q.prepare("INSERT INTO health_alerts "
              "(connection_name, metric, comparator, threshold, enabled, created_at) "
              "VALUES (?, ?, ?, ?, 1, ?)");
    q.addBindValue(connectionName);
    q.addBindValue(metric);
    q.addBindValue(cmp);
    q.addBindValue(threshold);
    q.addBindValue(QDateTime::currentDateTime().toString(Qt::ISODate));
    if (!q.exec())
        return -1;
    emit changed();
    return q.lastInsertId().toLongLong();
}

bool HealthAlertManager::removeRule(qint64 id)
{
    QSqlQuery q(m_db);
    q.prepare("DELETE FROM health_alerts WHERE id = ?");
    q.addBindValue(id);
    if (!q.exec())
        return false;
    m_breached.remove(id);
    emit changed();
    return true;
}

bool HealthAlertManager::setEnabled(qint64 id, bool enabled)
{
    QSqlQuery q(m_db);
    q.prepare("UPDATE health_alerts SET enabled = ? WHERE id = ?");
    q.addBindValue(enabled ? 1 : 0);
    q.addBindValue(id);
    if (!q.exec())
        return false;
    if (!enabled)
        m_breached.remove(id);
    emit changed();
    return true;
}

QVariantList HealthAlertManager::evaluate(const QString &connectionName,
                                          const QVariantMap &values) const
{
    QVariantList out;
    for (const QVariant &rv : rulesFor(connectionName)) {
        const QVariantMap r = rv.toMap();
        if (!r.value("enabled").toBool())
            continue;

        const QString metric = r.value("metric").toString();
        QVariantMap e;
        e["id"]         = r.value("id");
        e["metric"]     = metric;
        e["comparator"] = r.value("comparator");
        e["threshold"]  = r.value("threshold");

        if (!values.contains(metric)) {
            e["value"]    = QVariant();   // metric not present in this sample
            e["breached"] = false;
        } else {
            const double v = values.value(metric).toDouble();
            e["value"]    = v;
            e["breached"] = matches(r.value("comparator").toString(), v,
                                    r.value("threshold").toDouble());
        }
        out << e;
    }
    return out;
}

QVariantList HealthAlertManager::checkAndNotify(const QString &connectionName,
                                                const QVariantMap &values)
{
    const QVariantList list = evaluate(connectionName, values);
    for (const QVariant &ev : list) {
        const QVariantMap e = ev.toMap();
        const qint64 id      = e.value("id").toLongLong();
        const bool   breached = e.value("breached").toBool();
        const bool   was      = m_breached.contains(id);

        if (breached && !was) {
            m_breached.insert(id);
            const QString msg = describe(connectionName, e.value("metric").toString(),
                                         e.value("comparator").toString(),
                                         e.value("threshold").toDouble(),
                                         e.value("value").toDouble());
            if (m_log)
                m_log->post(QStringLiteral("warn"), QStringLiteral("HEALTH"),
                            connectionName, msg);
            emit alertRaised(connectionName, msg);
        } else if (!breached && was) {
            m_breached.remove(id);
            const QString msg = QStringLiteral("%1: %2 recovered")
                                    .arg(connectionName, e.value("metric").toString());
            if (m_log)
                m_log->post(QStringLiteral("info"), QStringLiteral("HEALTH"),
                            connectionName, msg);
            emit alertCleared(connectionName, msg);
        }
    }
    return list;
}
