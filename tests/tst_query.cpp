// Unit tests for the query and connection error paths, exercised at the layer
// where they are actually implemented: QtSqlAdapter. This is the synchronous
// engine underneath QueryExecutor (which only adds threading) and
// ConnectionManager (which only adds credential/SSH plumbing), so driving the
// adapter directly covers the real open()/execute() failure handling without
// pulling the OS keychain or a worker thread into the test — both of which
// would make these assertions flaky instead of trustworthy.
//
// Run with: ctest --test-dir build  (or ./build/qub_adapter_tests)

#include <QtTest>
#include <QSignalSpy>
#include <QTemporaryDir>

#include "core/adapters/QtSqlAdapter.h"
#include "core/Types.h"

class TestQuery : public QObject {
    Q_OBJECT

private slots:
    // ── Connection (open) error paths ─────────────────────────────────────────
    void open_unknownDriverFailsAndSignals();
    void open_uncreatableSqlitePathFails();
    void open_validSqliteSucceeds();

    // ── Query (execute) error paths ───────────────────────────────────────────
    void execute_selectReturnsColumnsAndRows();
    void execute_syntaxErrorIsReportedNotThrown();
    void execute_missingTableIsReported();
    void execute_dmlReportsRowsAffectedNoColumns();
    void execute_truncatesAtRowLimit();
    void execute_onClosedConnectionFails();

private:
    // Build params for an in-memory SQLite connection.
    static ConnectionParams memParams()
    {
        ConnectionParams p;
        p.name     = "t";
        p.driver   = "QSQLITE";
        p.database = ":memory:";
        return p;
    }
};

// ── Connection (open) error paths ───────────────────────────────────────────────

void TestQuery::open_unknownDriverFailsAndSignals()
{
    QtSqlAdapter adapter;
    QSignalSpy   errSpy(&adapter, &DatabaseAdapter::errorOccurred);

    ConnectionParams p = memParams();
    p.driver = "QNOSUCHDRIVER";

    QVERIFY(!adapter.open(p));          // open fails
    QVERIFY(!adapter.isOpen());         // and leaves the adapter closed
    QCOMPARE(errSpy.count(), 1);        // with a surfaced error message
    QVERIFY(!errSpy.first().at(0).toString().isEmpty());
}

void TestQuery::open_uncreatableSqlitePathFails()
{
    // A database file inside a directory that does not exist cannot be created,
    // so SQLite refuses to open it. This is the "bad connection target" path.
    QTemporaryDir dir;
    QVERIFY(dir.isValid());

    QtSqlAdapter adapter;
    QSignalSpy   errSpy(&adapter, &DatabaseAdapter::errorOccurred);

    ConnectionParams p = memParams();
    p.database = dir.filePath("no/such/nested/dir/db.sqlite");

    QVERIFY(!adapter.open(p));
    QVERIFY(!adapter.isOpen());
    QCOMPARE(errSpy.count(), 1);
}

void TestQuery::open_validSqliteSucceeds()
{
    QtSqlAdapter adapter;
    QSignalSpy   openedSpy(&adapter, &DatabaseAdapter::opened);

    QVERIFY(adapter.open(memParams()));
    QVERIFY(adapter.isOpen());
    QCOMPARE(adapter.driverName(),     QStringLiteral("QSQLITE"));
    QCOMPARE(adapter.connectionName(), QStringLiteral("t"));
    QCOMPARE(openedSpy.count(), 1);

    adapter.close();
    QVERIFY(!adapter.isOpen());
}

// ── Query (execute) error paths ─────────────────────────────────────────────────

void TestQuery::execute_selectReturnsColumnsAndRows()
{
    QtSqlAdapter adapter;
    QVERIFY(adapter.open(memParams()));

    QVERIFY(adapter.execute("CREATE TABLE t (id INTEGER, name TEXT)").success);
    QVERIFY(adapter.execute("INSERT INTO t VALUES (1,'a'),(2,'b')").success);

    const QueryResult r = adapter.execute("SELECT id, name FROM t ORDER BY id");
    QVERIFY(r.success);
    QVERIFY(r.error.isEmpty());
    QCOMPARE(r.columns, QStringList({ "id", "name" }));
    QCOMPARE(r.rows.size(), 2);
    QCOMPARE(r.rows.at(0).at(0).toInt(),        1);
    QCOMPARE(r.rows.at(1).at(1).toString(),     QStringLiteral("b"));
    QVERIFY(!r.truncated);
}

void TestQuery::execute_syntaxErrorIsReportedNotThrown()
{
    QtSqlAdapter adapter;
    QVERIFY(adapter.open(memParams()));

    const QueryResult r = adapter.execute("SELCT 1");   // typo → syntax error
    QVERIFY(!r.success);
    QVERIFY(!r.error.isEmpty());
    QVERIFY(r.columns.isEmpty());
    QVERIFY(r.rows.isEmpty());
}

void TestQuery::execute_missingTableIsReported()
{
    QtSqlAdapter adapter;
    QVERIFY(adapter.open(memParams()));

    const QueryResult r = adapter.execute("SELECT * FROM does_not_exist");
    QVERIFY(!r.success);
    QVERIFY(r.error.contains("does_not_exist", Qt::CaseInsensitive));
}

void TestQuery::execute_dmlReportsRowsAffectedNoColumns()
{
    QtSqlAdapter adapter;
    QVERIFY(adapter.open(memParams()));
    QVERIFY(adapter.execute("CREATE TABLE t (id INTEGER)").success);
    QVERIFY(adapter.execute("INSERT INTO t VALUES (1),(2),(3)").success);

    const QueryResult upd = adapter.execute("UPDATE t SET id = id + 10");
    QVERIFY(upd.success);
    QVERIFY(upd.columns.isEmpty());     // DML has no result set
    QVERIFY(upd.rows.isEmpty());
    QCOMPARE(upd.rowsAffected, 3);
}

void TestQuery::execute_truncatesAtRowLimit()
{
    QtSqlAdapter adapter;
    QVERIFY(adapter.open(memParams()));

    // Generate more than the adapter's 1000-row display ceiling.
    const QueryResult r = adapter.execute(
        "WITH RECURSIVE seq(n) AS ("
        "  SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 1500"
        ") SELECT n FROM seq");
    QVERIFY(r.success);
    QCOMPARE(r.rows.size(), 1000);      // capped
    QVERIFY(r.truncated);               // and flagged as capped
}

void TestQuery::execute_onClosedConnectionFails()
{
    QtSqlAdapter adapter;
    QVERIFY(adapter.open(memParams()));
    adapter.close();
    QVERIFY(!adapter.isOpen());

    const QueryResult r = adapter.execute("SELECT 1");
    QVERIFY(!r.success);
    QVERIFY(r.rows.isEmpty());
    QVERIFY(r.columns.isEmpty());
    // Qt's QSqlQuery::lastError() text is empty on a closed connection; the
    // adapter must still surface an actionable message rather than a blank one.
    QVERIFY(!r.error.isEmpty());
    QVERIFY(r.error.contains("not open", Qt::CaseInsensitive));
}

QTEST_MAIN(TestQuery)
#include "tst_query.moc"
