#pragma once

#include <QObject>
#include "QmlSingleton.h"
#include <QFuture>
#include <QFutureWatcher>
#include <QMap>
#include <QStringList>
#include <QVariantList>
#include <QUrl>
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

signals:
    void runningChanged();
    void activeTabIdChanged();
    void rowLimitChanged();
    void executionStarted(const QString &connectionName, const QString &sql);
    void executionFinished(bool success, qint64 elapsedMs, int rowCount, int rowsAffected);
    void executionError(const QString &message);
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
