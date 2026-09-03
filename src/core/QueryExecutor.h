#pragma once

#include <QObject>
#include "QmlSingleton.h"
#include <QFuture>
#include <QFutureWatcher>
#include <QMap>
#include <QStringList>
#include <QVariantList>
#include <QUrl>
#include <QDateTime>
#include <atomic>
#include <memory>
#include "Types.h"
#include "ResultModel.h"

class AdapterProvider;
class LogManager;

class QueryExecutor : public QObject {
    Q_OBJECT
    QUB_QML_SINGLETON(QueryExecutor)

public:
    Q_PROPERTY(bool running     READ isRunning   NOTIFY runningChanged)
    Q_PROPERTY(int  activeTabId READ activeTabId WRITE setActiveTabId NOTIFY activeTabIdChanged)
    Q_PROPERTY(int  rowLimit    READ rowLimit    WRITE setRowLimit    NOTIFY rowLimitChanged)

public:
    explicit QueryExecutor(AdapterProvider *connections, LogManager *log = nullptr, QObject *parent = nullptr);
    ~QueryExecutor() override;

    bool isRunning()   const;
    int  activeTabId() const { return m_activeTabId; }
    void setActiveTabId(int id);
    int  rowLimit()    const { return m_rowLimit; }
    void setRowLimit(int limit);

    Q_INVOKABLE void         execute(const QString &connectionName, const QString &sql);
    Q_INVOKABLE QStringList  splitStatements(const QString &sql,
                                             const QString &connectionName = QString()) const;
    Q_INVOKABLE void         cancel();
    Q_INVOKABLE ResultModel *tabResultModel(int tabId);
    Q_INVOKABLE void         closeTab(int tabId);

    // Export a tab's *complete* result set (not just the displayed, row-limited
    // rows) by re-running the SQL that produced it with no row limit on a
    // background worker and writing `format` ∈ {csv,tsv,json,xlsx,sql} to the
    // file. Used when the displayed result is truncated. Returns false if it
    // couldn't start (no remembered query, or an export already running).
    // Completion is reported via exportFinished / exportError.
    Q_INVOKABLE bool         exportFull(int tabId, const QString &format,
                                        const QUrl &fileUrl, const QString &tableName,
                                        const QString &driver);

    // The line the Output console prints after every statement, in the shape a
    // DBA pastes into a ticket: "84 rows retrieved in 1 m 10 s 542 ms
    // (execution: 1 m 9 s 980 ms, fetching: 530 ms)". Pure and static so the
    // wording is testable without running a query.
    // True unless every statement in `sql` is one that cannot change what qub
    // knows about the database. An allowlist, like the read-only guard: what is
    // not recognised as a plain read is assumed to change things, because a
    // cache that misses an invalidation serves a wrong schema, while one that
    // drops too often costs a round-trip. USE and SET are deliberately *not*
    // reads here — they move the current database or the search path, which
    // changes what an unqualified table name resolves to.
    static bool mayChangeSchema(const QString &sql);

    // Also the QML side's formatter: the results header, the status bar and
    // the log entry describe the same run the Output console does, and were
    // each printing raw milliseconds next to its "1 m 10 s 542 ms".
    Q_INVOKABLE static QString formatDuration(qint64 ms);
    static QString resultSummary(bool hasResultSet, int rowCount, int rowsAffected,
                                 bool truncated, qint64 execMs, qint64 fetchMs,
                                 qint64 totalMs);

signals:
    void runningChanged();
    void activeTabIdChanged();
    void rowLimitChanged();
    void executionStarted(const QString &connectionName, const QString &sql);
    void executionFinished(bool success, qint64 elapsedMs, int rowCount, int rowsAffected);
    void executionError(const QString &message);
    // A statement ran that may have changed `connectionName`'s schema. Schema
    // views listen to this rather than to every finished query, so a plain
    // SELECT no longer costs a full re-read of the database's structure.
    void schemaMayHaveChanged(const QString &connectionName);
    void resultsReady(const QStringList &columns, const QVariantList &rows, bool truncated);
    // Full-result export outcome. `truncated` = the full re-run itself still hit
    // the 500k safety ceiling.
    void exportFinished(bool success, const QString &path, int rowCount, bool truncated);
    void exportError(const QString &message);

private:
    void onFinished();
    void onExportFinished();

    AdapterProvider                     *m_connections;
    LogManager                          *m_log = nullptr;
    QMap<int, ResultModel *>             m_tabModels;
    QFutureWatcher<QueryResult>         *m_watcher;
    std::shared_ptr<std::atomic<bool>>   m_cancelFlag;
    int                                  m_activeTabId   = -1;
    int                                  m_rowLimit      = 1000;
    int                                  m_pendingTabId  = -1;
    QString                              m_pendingSql;
    // When the statement went out. The log entry is written when it comes
    // back, so without this the console has one timestamp for two events and
    // has to date the statement by the moment it finished.
    QDateTime                            m_pendingStartedAt;
    QString                              m_pendingConnName;

    // Per-tab memory of the last successfully-run SELECT, so a full export can
    // re-run exactly that query even if the editor text has since changed.
    QMap<int, QString>                   m_tabLastSql;
    QMap<int, QString>                   m_tabLastConn;

    // Full-result export runs on its own watcher so it never collides with the
    // single-flight interactive query.
    QFutureWatcher<QueryResult>         *m_exportWatcher;
    std::shared_ptr<std::atomic<bool>>   m_exportCancelFlag;
    QString                              m_exportFormat;
    QUrl                                 m_exportFile;
    QString                              m_exportTable;
    QString                              m_exportDriver;
};

QUB_QML_SINGLETON_FOREIGN(QueryExecutor)
