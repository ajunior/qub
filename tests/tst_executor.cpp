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

// ── Full-result export ───────────────────────────────────────────────────────────

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

QTEST_MAIN(TestExecutor)
#include "tst_executor.moc"
