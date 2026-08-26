#pragma once

#include <QObject>
#include "QmlSingleton.h"
#include <QVariantMap>

class ConnectionManager;
class DatabaseAdapter;

class DatabaseInspector : public QObject {
    Q_OBJECT
    QUB_QML_SINGLETON(DatabaseInspector)

public:
    Q_PROPERTY(bool loading READ loading NOTIFY loadingChanged)

public:
    explicit DatabaseInspector(ConnectionManager *cm, QObject *parent = nullptr);

    bool loading() const { return m_loading; }

    Q_INVOKABLE void         inspect(const QString &connectionName);
    Q_INVOKABLE QVariantList foreignKeys(const QString &connectionName) const;
    Q_INVOKABLE QVariantMap  tableStats(const QString &connectionName, const QString &tableName) const;
    Q_INVOKABLE QString      tableDdl(const QString &connectionName, const QString &tableName) const;

    // Runs a dialect-appropriate EXPLAIN and returns a normalised plan tree:
    //   { success, error, driver, analyzed, text, warnings:[str],
    //     root: { label, detail, metrics:[{key,value}], self, hot, children:[…] } }
    // `analyze` uses EXPLAIN ANALYZE (Postgres) — which *executes* the statement;
    // the QML gates it to read-only queries.
    Q_INVOKABLE QVariantMap  explain(const QString &connectionName,
                                     const QString &sql, bool analyze = false) const;

    // Structural diff of two connections' live schemas. `connA` is the base,
    // `connB` the comparison. See SchemaDiff::compare for the returned shape.
    Q_INVOKABLE QVariantMap  schemaDiff(const QString &connA, const QString &connB) const;

    // Instantaneous, cheap scalar health metrics for the active database.
    // Returns raw counters/gauges; the UI keeps history and derives rates.
    // Empty map when not connected.
    Q_INVOKABLE QVariantMap  metrics(const QString &connectionName) const;

signals:
    void loadingChanged();
    void resultReady(const QVariantMap &info);
    void errorOccurred(const QString &message);

private:
    ConnectionManager *m_cm;
    bool               m_loading = false;

    QVariantMap inspectPostgres(const QString &connectionName) const;
    QVariantMap inspectMysql(const QString &connectionName)    const;
    QVariantMap inspectSqlite(const QString &connectionName)   const;

    QVariantMap metricsPostgres(const QString &connectionName) const;
    QVariantMap metricsMysql(const QString &connectionName)    const;
    QVariantMap metricsSqlite(const QString &connectionName)   const;

    QVariantMap explainPostgres(DatabaseAdapter *a, const QString &sql, bool analyze) const;
    QVariantMap explainMysql(DatabaseAdapter *a, const QString &sql)   const;
    QVariantMap explainSqlite(DatabaseAdapter *a, const QString &sql)  const;
};

QUB_QML_SINGLETON_FOREIGN(DatabaseInspector)
