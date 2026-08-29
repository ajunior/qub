// Async orchestration tests for QueryExecutor: the guard/error paths and the
// worker-thread result plumbing that sit on top of the (separately tested)
// adapter. QueryExecutor takes an AdapterProvider, so the test drives it with a
// fake provider backed by a real on-disk SQLite database — on disk rather than
// ":memory:" because the executor clones the source connection onto a worker
// thread, and each in-memory connection is a distinct empty database.
//
// Run with: ctest --test-dir build  (or ./build/qub_executor_tests)

#include <QtTest>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QStandardPaths>

#include "core/LogManager.h"

#include "core/QueryExecutor.h"
#include "core/AdapterProvider.h"
#include "core/ResultModel.h"
#include "core/adapters/QtSqlAdapter.h"
#include "core/Types.h"

namespace {

// Owns one adapter and hands it back by name; any other name resolves to
// nullptr, exactly as ConnectionManager does for an unknown connection.
class FakeProvider : public AdapterProvider {
public:
    FakeProvider(const QString &name, DatabaseAdapter *a) : m_name(name), m_adapter(a) {}
    DatabaseAdapter *adapter(const QString &name) const override {
        return name == m_name ? m_adapter : nullptr;
    }
private:
    QString          m_name;
    DatabaseAdapter *m_adapter;
};

} // namespace

class TestExecutor : public QObject {
    Q_OBJECT

private slots:
    void initTestCase();
    void cleanupTestCase();

    // Guard / error paths
    void execute_unknownConnectionEmitsError();
    void execute_emptySqlIsNoOp();
    void execute_syntaxErrorPropagates();

    // Success / result plumbing
    void execute_selectPopulatesModelAndSignals();
    void execute_truncationFlagsAtRowLimit();

    // Cancellation (best-effort, non-racy assertions only)
    void cancel_returnsToIdle();
    void running_isTrueWhenTheChangeIsAnnounced();

    // The Output console's summary line (pure, no query needed)
    void formatDuration_growsUnitsOnlyAsNeeded();
    void resultSummary_readsLikeAConsoleLine();
    void execute_logsTheSummaryWithBothHalvesOfTheClock();

    // Schema-cache invalidation (pure classifier + the signal it drives)
    void mayChangeSchema_readsAreNotWrites();
    void mayChangeSchema_assumesTheWorstOtherwise();
    void execute_announcesSchemaChangeOnlyForWrites();

    // Full-result export
    void exportFull_guardsWhenNothingToReExport();
    void exportFull_writesFileForRememberedSelect();
    void exportFull_stripsTheEditorsInjectedLimit();
    void exportFull_keepsALimitTheUserWrote();

private:
    QTemporaryDir   m_dir;
    QtSqlAdapter   *m_adapter = nullptr;   // owned by m_provider's lifetime here
    FakeProvider   *m_provider = nullptr;
    QString         m_connName = "conn";

    QueryExecutor *makeExecutor() { return new QueryExecutor(m_provider, nullptr, this); }
};

void TestExecutor::initTestCase()
{
    QVERIFY(m_dir.isValid());

    ConnectionParams p;
    p.name     = m_connName;
    p.driver   = "QSQLITE";
    p.database = m_dir.filePath("exec.sqlite");   // real file → clonable on worker

    m_adapter = new QtSqlAdapter(this);
    QVERIFY2(m_adapter->open(p), "could not open backing SQLite file");

    QVERIFY(m_adapter->execute("CREATE TABLE t (id INTEGER, name TEXT)").success);
    QVERIFY(m_adapter->execute("INSERT INTO t VALUES (1,'a'),(2,'b'),(3,'c')").success);

    m_provider = new FakeProvider(m_connName, m_adapter);
}

void TestExecutor::cleanupTestCase()
{
    delete m_provider;
    m_provider = nullptr;
    // m_adapter is parented to `this`; Qt cleans it up.
}

// ── Guard / error paths ─────────────────────────────────────────────────────────

void TestExecutor::execute_unknownConnectionEmitsError()
{
    QueryExecutor *ex = makeExecutor();
    QSignalSpy errSpy(ex, &QueryExecutor::executionError);
    QSignalSpy startSpy(ex, &QueryExecutor::executionStarted);

    ex->execute("does-not-exist", "SELECT 1");

    QCOMPARE(errSpy.count(), 1);                        // synchronous refusal
    QVERIFY(errSpy.first().at(0).toString().contains("No active connection"));
    QCOMPARE(startSpy.count(), 0);                      // never claimed to start
    QVERIFY(!ex->isRunning());
    delete ex;
}

void TestExecutor::execute_emptySqlIsNoOp()
{
    QueryExecutor *ex = makeExecutor();
    QSignalSpy errSpy(ex, &QueryExecutor::executionError);
    QSignalSpy startSpy(ex, &QueryExecutor::executionStarted);

    ex->execute(m_connName, "   \n\t  ");              // whitespace only

    QCOMPARE(errSpy.count(), 0);
    QCOMPARE(startSpy.count(), 0);
    QVERIFY(!ex->isRunning());
    delete ex;
}

void TestExecutor::execute_syntaxErrorPropagates()
{
    QueryExecutor *ex = makeExecutor();
    QSignalSpy errSpy(ex, &QueryExecutor::executionError);
    QSignalSpy finSpy(ex, &QueryExecutor::executionFinished);

    ex->execute(m_connName, "SELCT bad syntax");

    QVERIFY(finSpy.wait(5000));                         // worker completes
    QCOMPARE(finSpy.count(), 1);
    QCOMPARE(finSpy.first().at(0).toBool(), false);     // success == false
    QCOMPARE(errSpy.count(), 1);
    QVERIFY(!errSpy.first().at(0).toString().isEmpty());
    QVERIFY(!ex->isRunning());
    delete ex;
}

// ── Success / result plumbing ────────────────────────────────────────────────────

void TestExecutor::execute_selectPopulatesModelAndSignals()
{
    QueryExecutor *ex = makeExecutor();
    ex->setActiveTabId(1);

    QSignalSpy resSpy(ex, &QueryExecutor::resultsReady);
    QSignalSpy finSpy(ex, &QueryExecutor::executionFinished);

    ex->execute(m_connName, "SELECT id, name FROM t ORDER BY id");

    QVERIFY(finSpy.wait(5000));
    QCOMPARE(finSpy.first().at(0).toBool(), true);      // success
    QCOMPARE(finSpy.first().at(2).toInt(), 3);          // rowCount

    QCOMPARE(resSpy.count(), 1);
    const QStringList cols = resSpy.first().at(0).toStringList();
    QCOMPARE(cols, QStringList({ "id", "name" }));
    QCOMPARE(resSpy.first().at(2).toBool(), false);     // not truncated

    // The active tab's model now holds the rows.
    ResultModel *model = ex->tabResultModel(1);
    QCOMPARE(model->rowCount(), 3);
    delete ex;
}

void TestExecutor::execute_truncationFlagsAtRowLimit()
{
    QueryExecutor *ex = makeExecutor();
    ex->setActiveTabId(2);
    ex->setRowLimit(10);                                // small cap for the test

    QSignalSpy resSpy(ex, &QueryExecutor::resultsReady);
    QSignalSpy finSpy(ex, &QueryExecutor::executionFinished);

    ex->execute(m_connName,
        "WITH RECURSIVE seq(n) AS ("
        "  SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 100"
        ") SELECT n FROM seq");

    QVERIFY(finSpy.wait(5000));
    QCOMPARE(resSpy.count(), 1);
    QCOMPARE(resSpy.first().at(2).toBool(), true);      // truncated
    QCOMPARE(ex->tabResultModel(2)->rowCount(), 10);    // capped to the limit
    delete ex;
}

// ── Cancellation ─────────────────────────────────────────────────────────────────

void TestExecutor::cancel_returnsToIdle()
{
    // Cancellation is inherently racy against a fast in-memory query, so this
    // asserts only the invariant that must always hold: after a cancel the
    // executor settles back to not-running and fires exactly one completion,
    // whether the query slipped through or was interrupted.
    QueryExecutor *ex = makeExecutor();
    ex->setActiveTabId(3);
    QSignalSpy finSpy(ex, &QueryExecutor::executionFinished);

    ex->execute(m_connName,
        "WITH RECURSIVE seq(n) AS ("
        "  SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 50000"
        ") SELECT n FROM seq");
    ex->cancel();

    QVERIFY(finSpy.wait(5000));
    QCOMPARE(finSpy.count(), 1);
    QVERIFY(!ex->isRunning());
    delete ex;
}

// The summary is only useful if the two halves of the clock actually reach it.
// This runs a real SELECT through the worker and reads the entry the console
// renders, rather than trusting that the plumbing lines up.
void TestExecutor::execute_logsTheSummaryWithBothHalvesOfTheClock()
{
    QStandardPaths::setTestModeEnabled(true);   // keeps qub.db out of the real profile

    LogManager     log;
    QueryExecutor *ex = new QueryExecutor(m_provider, &log, this);
    QSignalSpy     done(ex, &QueryExecutor::executionFinished);

    ex->execute(m_connName, "SELECT * FROM t");
    QVERIFY(done.wait(5000));

    const QVariantList entries = log.entries();
    QVERIFY(!entries.isEmpty());

    const QVariantMap entry  = entries.last().toMap();
    const QVariantMap detail = entry["detail"].toMap();

    QCOMPARE(entry["category"].toString(), QString("QUERY"));
    QCOMPARE(detail["rowCount"].toInt(), 3);
    QVERIFY(detail.contains("execMs"));
    QVERIFY(detail.contains("fetchMs"));

    // Neither half may exceed the whole, whatever the machine's timer does.
    const qint64 execMs  = detail["execMs"].toLongLong();
    const qint64 fetchMs = detail["fetchMs"].toLongLong();
    const qint64 total   = detail["elapsedMs"].toLongLong();
    QVERIFY(execMs  >= 0);
    QVERIFY(fetchMs >= 0);
    QVERIFY(execMs + fetchMs <= total + 1);   // +1: the two clocks round apart

    QVERIFY2(entry["message"].toString().startsWith("3 rows retrieved in "),
             qPrintable(entry["message"].toString()));
    QVERIFY(entry["message"].toString().contains("(execution: "));
    QVERIFY(entry["message"].toString().contains(", fetching: "));

    log.clear();
    delete ex;
}

// ── Full-result export ───────────────────────────────────────────────────────────

// The line a DBA pastes into a ticket. Both halves are pure functions, so the
// wording is pinned here rather than left to whatever a live query happens to
// produce.
void TestExecutor::formatDuration_growsUnitsOnlyAsNeeded()
{
    QCOMPARE(QueryExecutor::formatDuration(0),       QString("0 ms"));
    QCOMPARE(QueryExecutor::formatDuration(542),     QString("542 ms"));
    QCOMPARE(QueryExecutor::formatDuration(1000),    QString("1 s 0 ms"));
    QCOMPARE(QueryExecutor::formatDuration(10542),   QString("10 s 542 ms"));
    QCOMPARE(QueryExecutor::formatDuration(70542),   QString("1 m 10 s 542 ms"));
    QCOMPARE(QueryExecutor::formatDuration(3723004), QString("1 h 2 m 3 s 4 ms"));

    // A minute boundary still prints the smaller units, so the shape of the
    // string never depends on the value landing on a round number.
    QCOMPARE(QueryExecutor::formatDuration(60000),   QString("1 m 0 s 0 ms"));

    // A negative reading (a clock that went backwards) reads as zero rather
    // than as a nonsense duration.
    QCOMPARE(QueryExecutor::formatDuration(-5),      QString("0 ms"));
}

void TestExecutor::resultSummary_readsLikeAConsoleLine()
{
    // A SELECT: count, total, and the split that says which half was slow.
    QCOMPARE(QueryExecutor::resultSummary(true, 84, 0, false, 69980, 530, 70542),
             QString("84 rows retrieved in 1 m 10 s 542 ms "
                     "(execution: 1 m 9 s 980 ms, fetching: 530 ms)"));

    // One row is one row.
    QCOMPARE(QueryExecutor::resultSummary(true, 1, 0, false, 10, 2, 12),
             QString("1 row retrieved in 12 ms (execution: 10 ms, fetching: 2 ms)"));

    // An empty result set is still a result set — it must not read as DDL.
    QCOMPARE(QueryExecutor::resultSummary(true, 0, 0, false, 8, 0, 8),
             QString("0 rows retrieved in 8 ms (execution: 8 ms, fetching: 0 ms)"));

    // Hitting the row limit says so, so nobody pastes a partial count into a
    // ticket believing it is the whole answer.
    QCOMPARE(QueryExecutor::resultSummary(true, 1000, 0, true, 40, 60, 100),
             QString("first 1000 rows retrieved in 100 ms "
                     "(execution: 40 ms, fetching: 60 ms)"));

    // DML has no fetch half; printing "fetching: 0 ms" there would be noise.
    QCOMPARE(QueryExecutor::resultSummary(false, 0, 3, false, 25, 0, 25),
             QString("3 rows affected in 25 ms"));
    QCOMPARE(QueryExecutor::resultSummary(false, 0, 1, false, 25, 0, 25),
             QString("1 row affected in 25 ms"));

    // DDL, or DML that matched nothing: no count worth printing.
    QCOMPARE(QueryExecutor::resultSummary(false, 0, 0, false, 3, 0, 3),
             QString("completed in 3 ms"));
}

void TestExecutor::exportFull_guardsWhenNothingToReExport()
{
    QueryExecutor *ex = makeExecutor();
    // No query has run for tab 99, so there is nothing to re-run.
    QCOMPARE(ex->exportFull(99, "csv", QUrl::fromLocalFile(m_dir.filePath("x.csv")),
                            "t", "QSQLITE"),
             false);
    delete ex;
}

void TestExecutor::exportFull_writesFileForRememberedSelect()
{
    QueryExecutor *ex = makeExecutor();
    ex->setActiveTabId(4);

    QSignalSpy finSpy(ex, &QueryExecutor::executionFinished);
    ex->execute(m_connName, "SELECT id, name FROM t ORDER BY id");
    QVERIFY(finSpy.wait(5000));                         // remembers the SELECT

    const QString outPath = m_dir.filePath("full.csv");
    QSignalSpy expSpy(ex, &QueryExecutor::exportFinished);
    QVERIFY(ex->exportFull(4, "csv", QUrl::fromLocalFile(outPath), "t", "QSQLITE"));

    QVERIFY(expSpy.wait(5000));
    QCOMPARE(expSpy.first().at(0).toBool(), true);      // success
    QCOMPARE(expSpy.first().at(2).toInt(), 3);          // full row count

    QFile f(outPath);
    QVERIFY(f.open(QIODevice::ReadOnly | QIODevice::Text));
    const QString csv = QString::fromUtf8(f.readAll());
    QVERIFY(csv.contains("id,name"));
    QVERIFY(csv.contains("1,a"));
    QVERIFY(csv.contains("3,c"));
    delete ex;
}


// The editor pushes its display limit down to the server as a trailing
// "LIMIT n /* qub:limit */". A full export re-runs the remembered SQL with no
// row limit, so that clause has to come back off — otherwise the "complete"
// export stops at the very limit it exists to escape.
void TestExecutor::exportFull_stripsTheEditorsInjectedLimit()
{
    QueryExecutor *ex = makeExecutor();
    ex->setActiveTabId(7);
    ex->setRowLimit(1);

    QSignalSpy finSpy(ex, &QueryExecutor::executionFinished);
    ex->execute(m_connName, "SELECT id, name FROM t ORDER BY id\nLIMIT 2 /* qub:limit */");
    QVERIFY(finSpy.wait(5000));
    QCOMPARE(finSpy.first().at(2).toInt(), 1);          // one row shown, cut

    const QString outPath = m_dir.filePath("stripped.csv");
    QSignalSpy expSpy(ex, &QueryExecutor::exportFinished);
    QVERIFY(ex->exportFull(7, "csv", QUrl::fromLocalFile(outPath), "t", "QSQLITE"));

    QVERIFY(expSpy.wait(5000));
    QCOMPARE(expSpy.first().at(0).toBool(), true);
    QCOMPARE(expSpy.first().at(2).toInt(), 3);          // all three, not one or two
    delete ex;
}

// A LIMIT the user typed carries no marker and is part of the query's meaning,
// so the export must honour it.
void TestExecutor::exportFull_keepsALimitTheUserWrote()
{
    QueryExecutor *ex = makeExecutor();
    ex->setActiveTabId(8);
    ex->setRowLimit(0);

    QSignalSpy finSpy(ex, &QueryExecutor::executionFinished);
    ex->execute(m_connName, "SELECT id, name FROM t ORDER BY id\nLIMIT 2");
    QVERIFY(finSpy.wait(5000));

    const QString outPath = m_dir.filePath("userlimit.csv");
    QSignalSpy expSpy(ex, &QueryExecutor::exportFinished);
    QVERIFY(ex->exportFull(8, "csv", QUrl::fromLocalFile(outPath), "t", "QSQLITE"));

    QVERIFY(expSpy.wait(5000));
    QCOMPARE(expSpy.first().at(0).toBool(), true);
    QCOMPARE(expSpy.first().at(2).toInt(), 2);          // still two
    delete ex;
}

// ── Schema-cache invalidation ────────────────────────────────────────────────
// Getting this wrong in one direction costs a round-trip; in the other it
// serves a schema that no longer exists. So the reads are enumerated, and
// everything else is a write.

void TestExecutor::mayChangeSchema_readsAreNotWrites()
{
    const char *reads[] = {
        "SELECT 1",
        "select id from t",
        "  \n\t SELECT id FROM t",
        "WITH x AS (SELECT 1) SELECT * FROM x",
        "SHOW TABLES",
        "EXPLAIN SELECT 1",
        "PRAGMA table_info(t)",
        "VALUES (1), (2)",
        "TABLE t",                                   // Postgres shorthand
        "SELECT id FROM t; SELECT name FROM t;",     // every statement is a read
        "-- DROP TABLE t\nSELECT 1",                 // a comment is not a statement
        "/* CREATE TABLE x */ SELECT 1",
        "SELECT 'INSERT INTO t VALUES (1)' AS sql",  // nor is a string literal
    };
    for (const char *sql : reads)
        QVERIFY2(!QueryExecutor::mayChangeSchema(QString::fromUtf8(sql)), sql);
}

void TestExecutor::mayChangeSchema_assumesTheWorstOtherwise()
{
    const char *writes[] = {
        "CREATE TABLE t (id INT)",
        "DROP TABLE t",
        "ALTER TABLE t ADD COLUMN c TEXT",
        "INSERT INTO t VALUES (1)",
        "TRUNCATE t",
        "SELECT 1; DROP TABLE t",                    // the write is not first
        "WITH d AS (DELETE FROM t RETURNING *) SELECT * FROM d",
        "USE otherdb",                               // moves what a bare name means
        "SET search_path TO other",                  // so does this
        "CALL do_something()",                       // unrecognised: assume it did
        "VACUUM",
    };
    for (const char *sql : writes)
        QVERIFY2(QueryExecutor::mayChangeSchema(QString::fromUtf8(sql)), sql);
}

void TestExecutor::execute_announcesSchemaChangeOnlyForWrites()
{
    QueryExecutor *ex = makeExecutor();
    ex->setActiveTabId(9);

    QSignalSpy schemaSpy(ex, &QueryExecutor::schemaMayHaveChanged);
    QSignalSpy finSpy(ex, &QueryExecutor::executionFinished);

    ex->execute(m_connName, "SELECT id FROM t");
    QVERIFY(finSpy.wait(5000));
    QCOMPARE(schemaSpy.count(), 0);      // a read costs no schema re-read

    ex->execute(m_connName, "CREATE TABLE tst_sig (id INTEGER PRIMARY KEY)");
    QVERIFY(finSpy.wait(5000));
    QCOMPARE(schemaSpy.count(), 1);
    QCOMPARE(schemaSpy.first().at(0).toString(), m_connName);
    delete ex;
}

// The Run button reads `running` off this notification. Emitted before the
// watcher has a future, it announced a change to a value that was still false
// and never fired again, so the button never became Stop and the cancel it
// offers could not be reached.
void TestExecutor::running_isTrueWhenTheChangeIsAnnounced()
{
    QueryExecutor *ex = makeExecutor();
    ex->setActiveTabId(11);

    QList<bool> seen;
    connect(ex, &QueryExecutor::runningChanged, ex, [ex, &seen]() {
        seen << ex->isRunning();
    });

    QSignalSpy finSpy(ex, &QueryExecutor::executionFinished);
    ex->execute(m_connName, "SELECT id FROM t");

    QVERIFY(ex->isRunning());               // …and true the moment execute returns
    QVERIFY(!seen.isEmpty());
    QCOMPARE(seen.first(), true);           // the first announcement says so

    QVERIFY(finSpy.wait(5000));
    QCOMPARE(seen.last(), false);           // and the last one says it stopped
    delete ex;
}

QTEST_MAIN(TestExecutor)
#include "tst_executor.moc"
