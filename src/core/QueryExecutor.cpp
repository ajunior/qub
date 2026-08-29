#include "QueryExecutor.h"
#include <QRegularExpression>
#include "AdapterProvider.h"
#include "LogManager.h"
#include "ResultModel.h"
#include "SqlUtils.h"
#include "adapters/DatabaseAdapter.h"
#include <QtConcurrent/QtConcurrent>
#include <QSqlDatabase>
#include <QSqlQuery>
#include <QSqlRecord>
#include <QSqlError>
#include <QElapsedTimer>
#include <QUuid>

// ── Worker ────────────────────────────────────────────────────────────────────
// Runs entirely on the worker thread. Clones the named connection so the
// main-thread adapter's QSqlDatabase is never accessed from here.
static QueryResult runQuery(const QString &sourceConnId,
                            const QString &sql,
                            int rowLimit,
                            std::shared_ptr<std::atomic<bool>> cancelFlag)
{
    // "No limit" (<= 0) still gets a generous safety ceiling: every fetched
    // row is held in memory, so a runaway SELECT must not OOM the app.
    constexpr int kNoLimitCeiling = 500000;
    const int cap = rowLimit > 0 ? rowLimit : kNoLimitCeiling;

    const QString workerConnId = sourceConnId + "_qry_" +
                                 QUuid::createUuid().toString(QUuid::WithoutBraces);
    QueryResult result;

    {
        QSqlDatabase workerDb = QSqlDatabase::cloneDatabase(sourceConnId, workerConnId);

        auto cleanup = qScopeGuard([&workerDb, &workerConnId] {
            workerDb.close();
            workerDb = QSqlDatabase();
            QSqlDatabase::removeDatabase(workerConnId);
        });

        if (!workerDb.open()) {
            result.error = "Worker connection: " + workerDb.lastError().text();
            return result;
        }

        const QStringList stmts = SqlUtils::splitStatements(sql, workerDb.driverName());
        if (stmts.isEmpty()) {
            result.success = true;
            return result;
        }

        QElapsedTimer timer;
        timer.start();

        for (const QString &stmt : stmts) {
            if (cancelFlag->load(std::memory_order_relaxed)) {
                result.error     = "Query cancelled.";
                result.elapsedMs = timer.elapsed();
                return result;
            }

            // Two clocks, because the interesting question when a query is
            // slow is *which half* was slow: the server planning and running
            // it, or the rows crossing the wire back to us.
            QElapsedTimer phase;
            phase.start();

            QSqlQuery query(workerDb);
            query.setForwardOnly(true);
            if (!query.exec(stmt)) {
                result.error     = query.lastError().text();
                result.execMs   += phase.elapsed();
                result.elapsedMs = timer.elapsed();
                return result;
            }
            result.execMs += phase.restart();

            const QSqlRecord rec      = query.record();
            const int        colCount = rec.count();

            if (colCount > 0) {
                // SELECT — overwrite any previous result (last SELECT wins)
                result.columns.clear();
                result.rows.clear();
                result.truncated = false;
                for (int i = 0; i < colCount; ++i)
                    result.columns << rec.fieldName(i);

                int fetched = 0;
                while (query.next() && fetched < cap + 1) {
                    if (cancelFlag->load(std::memory_order_relaxed)) {
                        result.error     = "Query cancelled.";
                        result.fetchMs  += phase.elapsed();
                        result.elapsedMs = timer.elapsed();
                        return result;
                    }
                    QVariantList row;
                    row.reserve(colCount);
                    for (int i = 0; i < colCount; ++i)
                        row << query.value(i);
                    result.rows << row;
                    ++fetched;
                }
                if (fetched == cap + 1) {
                    result.rows.removeLast();
                    result.truncated = true;
                }
                result.fetchMs += phase.elapsed();
            } else {
                // DML / DDL — accumulate affected rows
                const int affected = query.numRowsAffected();
                if (affected > 0)
                    result.rowsAffected += affected;
            }
        }

        result.elapsedMs = timer.elapsed();
        result.success   = true;
    }

    return result;
}

// ── QueryExecutor ─────────────────────────────────────────────────────────────
QueryExecutor::QueryExecutor(AdapterProvider *connections, LogManager *log, QObject *parent)
    : QObject(parent)
    , m_connections(connections)
    , m_log(log)
    , m_watcher(new QFutureWatcher<QueryResult>(this))
    , m_cancelFlag(std::make_shared<std::atomic<bool>>(false))
    , m_exportWatcher(new QFutureWatcher<QueryResult>(this))
    , m_exportCancelFlag(std::make_shared<std::atomic<bool>>(false))
{
    connect(m_watcher, &QFutureWatcher<QueryResult>::finished, this, &QueryExecutor::onFinished);
    connect(m_exportWatcher, &QFutureWatcher<QueryResult>::finished, this, &QueryExecutor::onExportFinished);
}

QueryExecutor::~QueryExecutor() = default;

bool QueryExecutor::isRunning() const
{
    return m_watcher->isRunning();
}

void QueryExecutor::setActiveTabId(int id)
{
    if (m_activeTabId == id) return;
    m_activeTabId = id;
    emit activeTabIdChanged();
}

ResultModel *QueryExecutor::tabResultModel(int tabId)
{
    auto it = m_tabModels.find(tabId);
    if (it == m_tabModels.end()) {
        auto *m = new ResultModel(this);
        it = m_tabModels.insert(tabId, m);
    }
    return it.value();
}

void QueryExecutor::closeTab(int tabId)
{
    if (auto *m = m_tabModels.take(tabId))
        m->deleteLater();
    m_tabLastSql.remove(tabId);
    m_tabLastConn.remove(tabId);
}

QStringList QueryExecutor::splitStatements(const QString &sql,
                                           const QString &connectionName) const
{
    auto *adapter = m_connections->adapter(connectionName);
    return SqlUtils::splitStatements(sql, adapter ? adapter->driverName() : QString());
}

void QueryExecutor::execute(const QString &connectionName, const QString &sql)
{
    if (sql.trimmed().isEmpty() || m_watcher->isRunning())
        return;

    auto *adapter = m_connections->adapter(connectionName);
    if (!adapter) {
        emit executionError("No active connection: " + connectionName);
        return;
    }

    const QString sourceConnId = adapter->connectionId();
    m_cancelFlag->store(false, std::memory_order_relaxed);

    m_pendingTabId   = m_activeTabId;
    m_pendingSql     = sql;
    m_pendingConnName = connectionName;
    tabResultModel(m_pendingTabId)->clear();
    emit executionStarted(connectionName, sql);
    emit runningChanged();

    auto flag  = m_cancelFlag;
    const int limit = m_rowLimit;
    m_watcher->setFuture(QtConcurrent::run([sourceConnId, sql, limit, flag]() {
        return runQuery(sourceConnId, sql, limit, flag);
    }));
}

void QueryExecutor::setRowLimit(int limit)
{
    if (m_rowLimit == limit) return;
    m_rowLimit = limit;
    emit rowLimitChanged();
}

void QueryExecutor::cancel()
{
    m_cancelFlag->store(true, std::memory_order_relaxed);
}

QString QueryExecutor::formatDuration(qint64 ms)
{
    if (ms < 0) ms = 0;

    const qint64 h = ms / 3600000;
    const qint64 m = (ms / 60000) % 60;
    const qint64 s = (ms / 1000)  % 60;

    // Units appear only once one above them does, so a fast query reads
    // "542 ms" and a slow one reads "1 m 10 s 542 ms".
    QStringList parts;
    if (h)           parts << QString::number(h) + " h";
    if (h || m)      parts << QString::number(m) + " m";
    if (h || m || s) parts << QString::number(s) + " s";
    parts << QString::number(ms % 1000) + " ms";
    return parts.join(u' ');
}

QString QueryExecutor::resultSummary(bool hasResultSet, int rowCount, int rowsAffected,
                                     bool truncated, qint64 execMs, qint64 fetchMs,
                                     qint64 totalMs)
{
    QString head;
    if (hasResultSet) {
        head = truncated
             ? QString("first %1 rows retrieved").arg(rowCount)
             : QString("%1 row%2 retrieved").arg(rowCount).arg(rowCount == 1 ? "" : "s");
    } else if (rowsAffected > 0) {
        head = QString("%1 row%2 affected").arg(rowsAffected).arg(rowsAffected == 1 ? "" : "s");
    } else {
        // DDL, or DML that matched nothing: there is no count worth printing.
        head = QStringLiteral("completed");
    }

    QString line = head + " in " + formatDuration(totalMs);

    // The split is only meaningful when rows came back; for DML the fetch half
    // is structurally zero and printing it would just be noise.
    if (hasResultSet)
        line += " (execution: " + formatDuration(execMs)
              + ", fetching: "  + formatDuration(fetchMs) + ")";

    return line;
}

void QueryExecutor::onFinished()
{
    const QueryResult result = m_watcher->result();

    if (result.success) {
        tabResultModel(m_pendingTabId)->setResult(result);

        if (!result.columns.isEmpty()) {
            // Remember the query behind this result so a later full export can
            // re-run it unlimited regardless of subsequent editor edits.
            m_tabLastSql[m_pendingTabId]  = m_pendingSql;
            m_tabLastConn[m_pendingTabId] = m_pendingConnName;

            QVariantList varRows;
            varRows.reserve(result.rows.size());
            for (const QVariantList &row : result.rows)
                varRows.append(QVariant::fromValue(row));
            emit resultsReady(result.columns, varRows, result.truncated);
        }

        if (m_log) {
            const int  rows         = static_cast<int>(result.rows.size());
            const bool hasResultSet = !result.columns.isEmpty();
            m_log->post("info", "QUERY", m_pendingConnName,
                        resultSummary(hasResultSet, rows, result.rowsAffected,
                                      result.truncated, result.execMs, result.fetchMs,
                                      result.elapsedMs),
                        {{"sql", m_pendingSql},
                         {"elapsedMs", result.elapsedMs},
                         {"execMs", result.execMs},
                         {"fetchMs", result.fetchMs},
                         {"rowCount", rows},
                         {"rowsAffected", result.rowsAffected}});
        }
    } else {
        if (m_log)
            m_log->post("error", "QUERY", m_pendingConnName,
                        "failed after " + formatDuration(result.elapsedMs),
                        {{"sql", m_pendingSql}, {"error", result.error},
                         {"elapsedMs", result.elapsedMs},
                         {"execMs", result.execMs}, {"fetchMs", result.fetchMs}});
        emit executionError(result.error);
    }

    emit executionFinished(result.success, result.elapsedMs,
                           static_cast<int>(result.rows.size()),
                           result.rowsAffected);
    emit runningChanged();
}

bool QueryExecutor::exportFull(int tabId, const QString &format, const QUrl &fileUrl,
                               const QString &tableName, const QString &driver)
{
    if (m_exportWatcher->isRunning())
        return false;

    QString       sql  = m_tabLastSql.value(tabId);
    const QString conn = m_tabLastConn.value(tabId);
    if (sql.isEmpty())
        return false;

    // The remembered SQL carries the display limit the editor pushed down to
    // the server, so re-running it "unlimited" would still stop at that clause.
    // Strip it — the marker is what distinguishes our clause from a LIMIT the
    // user wrote, which must be honoured.
    static const QRegularExpression injectedLimit(
        R"(\s*\bLIMIT\s+\d+\s*/\*\s*qub:limit\s*\*/\s*$)",
        QRegularExpression::CaseInsensitiveOption);
    sql.remove(injectedLimit);

    auto *adapter = m_connections->adapter(conn);
    if (!adapter)
        return false;

    const QString sourceConnId = adapter->connectionId();
    m_exportCancelFlag->store(false, std::memory_order_relaxed);
    m_exportFormat = format;
    m_exportFile   = fileUrl;
    m_exportTable  = tableName;
    m_exportDriver = driver;

    auto flag = m_exportCancelFlag;
    m_exportWatcher->setFuture(QtConcurrent::run([sourceConnId, sql, flag]() {
        return runQuery(sourceConnId, sql, 0 /* no limit → 500k safety ceiling */, flag);
    }));
    return true;
}

void QueryExecutor::onExportFinished()
{
    const QueryResult result = m_exportWatcher->result();
    if (!result.success) {
        emit exportError(result.error);
        return;
    }

    // Reuse ResultModel's formatters by loading the full re-run into a throwaway
    // model. This transiently holds up to the 500k-row ceiling — the same cost
    // as a "Limit: None" interactive run.
    ResultModel model;
    model.setResult(result);

    bool ok = false;
    if      (m_exportFormat == QLatin1String("csv"))  ok = model.exportCsv(m_exportFile);
    else if (m_exportFormat == QLatin1String("tsv"))  ok = model.exportTsv(m_exportFile);
    else if (m_exportFormat == QLatin1String("json")) ok = model.exportJson(m_exportFile);
    else if (m_exportFormat == QLatin1String("xlsx")) ok = model.exportXlsx(m_exportFile);
    else if (m_exportFormat == QLatin1String("sql"))
        ok = model.exportSql(m_exportFile, m_exportTable, m_exportDriver);

    if (ok)
        emit exportFinished(true, m_exportFile.toLocalFile(),
                            static_cast<int>(result.rows.size()), result.truncated);
    else
        emit exportError("Could not write file.");
}
