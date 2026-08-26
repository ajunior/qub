#pragma once

#include <QObject>
#include "QmlSingleton.h"
#include <QVariantList>
#include <QVariantMap>
#include <QSqlDatabase>
#include <QSet>

class LogManager;

// Threshold alerting for the live database-health metrics. Rules ("connections
// > 100", "cache hit ratio < 90", …) are persisted per connection in the shared
// qub.db. Evaluation is fed the *current* metric values by the Health tab each
// poll (the metric derivation — rates/ratios — already lives in QML), so this
// class stays free of adapter/timer coupling and the comparison logic is pure
// and unit-testable. Edge-triggered notifications (fire on entering breach,
// clear on recovery) are surfaced through LogManager + alertRaised/alertCleared.
class HealthAlertManager : public QObject {
    Q_OBJECT
    QUB_QML_SINGLETON(HealthAlertManager)

public:
    Q_PROPERTY(QVariantList rules READ rules NOTIFY changed)
public:
    explicit HealthAlertManager(LogManager *log = nullptr,
                                const QString &dbPath = QString(),
                                QObject *parent = nullptr);
    ~HealthAlertManager() override;

    // Every rule: { id, connectionName, metric, comparator ("gt"|"lt"),
    // threshold, enabled }.
    QVariantList rules() const;
    Q_INVOKABLE QVariantList rulesFor(const QString &connectionName) const;

    Q_INVOKABLE qint64 addRule(const QString &connectionName, const QString &metric,
                               const QString &comparator, double threshold);
    Q_INVOKABLE bool   removeRule(qint64 id);
    Q_INVOKABLE bool   setEnabled(qint64 id, bool enabled);

    // Pure: for every enabled rule of `connectionName`, look up the current
    // value in `values` (metric name → number) and report status. Returns one
    // map per enabled rule: { id, metric, comparator, threshold, value (or null
    // if the metric is missing), breached }.
    Q_INVOKABLE QVariantList evaluate(const QString &connectionName,
                                      const QVariantMap &values) const;

    // Same as evaluate(), but edge-triggered: logs a warning + emits
    // alertRaised on entering breach, and logs info + emits alertCleared on
    // recovery. Returns the full evaluate() list for live UI status.
    Q_INVOKABLE QVariantList checkAndNotify(const QString &connectionName,
                                            const QVariantMap &values);

signals:
    void changed();
    void alertRaised(const QString &connectionName, const QString &message);
    void alertCleared(const QString &connectionName, const QString &message);

private:
    void initDb(const QString &dbPath);
    static bool    matches(const QString &comparator, double value, double threshold);
    static QString describe(const QString &connectionName, const QString &metric,
                            const QString &comparator, double threshold, double value);

    LogManager  *m_log = nullptr;
    QString      m_connectionName;
    QSqlDatabase m_db;
    QSet<qint64> m_breached;   // rule ids currently in breach (edge detection)
};

QUB_QML_SINGLETON_FOREIGN(HealthAlertManager)
