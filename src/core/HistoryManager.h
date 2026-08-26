#pragma once

#include <QObject>
#include "QmlSingleton.h"
#include <QVariantList>
#include <QSqlDatabase>

class HistoryManager : public QObject {
    Q_OBJECT
    QUB_QML_SINGLETON(HistoryManager)

public:
    // Maximum number of entries kept in the history database; older entries
    // are pruned on insert. Bound to appSettings.historyLimit from QML.
    Q_PROPERTY(int limit READ limit WRITE setLimit NOTIFY limitChanged)
public:
    explicit HistoryManager(QObject *parent = nullptr);
    ~HistoryManager() override;

    int  limit() const { return m_limit; }
    void setLimit(int limit);

    Q_INVOKABLE void         add(const QString &connectionName, const QString &sql,
                                  bool success, int rowCount, qint64 elapsedMs);
    Q_INVOKABLE QVariantList entries(int limit = 200) const;
    Q_INVOKABLE QVariantList search(const QString &text, int limit = 50) const;
    // Aggregate stored executions by a normalised SQL fingerprint, ranked by
    // total time spent. Optionally scoped to a single connection.
    Q_INVOKABLE QVariantList slowQueries(int limit = 20,
                                          const QString &connectionName = QString()) const;
    Q_INVOKABLE void         remove(qint64 id);
    Q_INVOKABLE void         clear();

    // Collapse a SQL statement to a fingerprint that groups structurally
    // identical queries: string/number literals become '?', whitespace is
    // collapsed, and a trailing ';' is dropped. Static + pure so it is
    // unit-testable without a database.
    static QString fingerprint(const QString &sql);

signals:
    void changed();
    void limitChanged();

private:
    void initDb();

    QSqlDatabase m_db;
    int          m_limit = 500;
};

QUB_QML_SINGLETON_FOREIGN(HistoryManager)
