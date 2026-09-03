// Unit tests for the pure-logic core pieces: the SQL statement splitter, the
// query guard (guard.js, exercised through QJSEngine), spreadsheet-injection
// neutralization in the CSV/TSV exports, and HistoryManager limits/search.
//
// Run with: ctest --test-dir build  (or ./build/qub_tests)

#include <QtTest>
#include <QJSEngine>
#include <QJSValue>
#include <QStandardPaths>
#include <QTemporaryDir>

#include "core/SqlUtils.h"
#include "core/MarkdownDoc.h"
#include "core/ResultModel.h"
#include "core/CsvImporter.h"
#include "core/ExplainPlan.h"
#include "core/HistoryManager.h"
#include "core/SchemaDiff.h"
#include "core/ResultDiff.h"
#include "core/AppDatabase.h"
#include "core/SchemaSnapshotManager.h"
#include "core/HealthAlertManager.h"
#include "core/ResultSnapshotManager.h"
#include "core/LogManager.h"
#include "core/DockerDiscovery.h"

#include <QSqlDatabase>
#include <QSqlQuery>
#include <QSqlError>

class TestCore : public QObject {
    Q_OBJECT

private slots:
    void initTestCase();

    // SqlUtils::splitStatements
    void split_basic();
    void split_semicolonInString();
    void split_escapedQuote();
    void split_comments();
    void split_emptyDropped();
    void split_pgDollarQuoting();
    void split_mysqlBackslashEscape();

    // MarkdownDoc
    void md_segments();
    void md_toMarkdown();
    void md_exportFile();

    // guard.js
    void guard_readOnlyBlocksWrites();
    void guard_readOnlyAllowsReads();
    void guard_commentBypassBlocked();
    void guard_cteWriteBlocked();
    void guard_confirmations();
    void guard_noProfile();

    // complete.js
    void complete_tablesInScope();
    void complete_dottedTable();

    // ── Foreign-key navigation (fk.js) ────────────────────────────────────────
    void fk_outgoingResolves();
    void fk_incomingLists();
    void fk_selectByDialects();

    // ── Cell value inspector (cellview.js) ────────────────────────────────────
    void cellview_classifies();

    // ── Saved-list ordering (listsort.js) ─────────────────────────────────────
    void listsort_sortsByNameBothWays();
    void listsort_foldsCaseAndAccents();
    void listsort_breaksTiesOnName();
    void listsort_sortsDatesAndNumbers();
    void listsort_filtersAcrossFields();
    void listsort_blankQueryKeepsEverything();
    void listsort_groupsSnippetsByFolder();

    // AppDatabase schema stamping
    void schemaVersion_stampsOnlyAFreshDatabase();

    // ── Driver list (drivers.js) ──────────────────────────────────────────────
    void drivers_onlyAvailableOffered();

    // ── Query parameters (params.js) ──────────────────────────────────────────
    void params_namedAndPositional();
    void params_ignoreCommentsAndLiterals();

    // CSV / TSV export
    void export_csvNeutralizesFormulas();
    void export_csvQuoting();
    void export_tsvNeutralizesFormulas();
    void export_markdownTable();
    void export_sqlInserts();
    void export_xlsxZipChecksums();
    void columnStats_numericAndText();
    void filter_matchingNothingHidesEveryRow();
    void columnValues_visibleRows();
    void numericColumns_perColumn();
    void profile_perColumn();
    void pivot_crossTabAggregates();

    // CsvImporter
    void csv_previewInfersTypes();
    void csv_importCreatesQueryableTable();
    void csv_quotedFieldsAndDelimiterSniff();
    void csv_importIntoExistingAddsTable();

    // ExplainPlan (SQLite query-plan tree)
    void explain_buildsTreeFromParents();
    void explain_flagsFullScanFromRealSqlite();

    // HistoryManager
    void history_limitPrunes();
    void history_searchLiteralWildcards();
    void history_fingerprintNormalises();
    void history_slowQueriesAggregates();

    // SchemaDiff
    void schemaDiff_detectsStructuralChanges();

    // ResultModel expectations
    void expectations_evaluateChecks();

    // ResultDiff
    void resultDiff_keyedAndWholeRow();

    // SchemaSnapshotManager
    void schemaSnapshot_captureRoundTripAndDiff();

    // HealthAlertManager
    void healthAlert_evaluateAndEdgeTrigger();
    void resultSnapshot_captureRoundTrip();

    // LogManager
    void log_persistsAcrossRestart();

    // DockerDiscovery::parseContainers
    void docker_parsesPostgres();
    void docker_mysqlRootFallbackAndMappedPort();
    void docker_skipsUnpublishedAndUnknown();
    void docker_ignoresGarbageJson();

private:
    QJSValue runGuard(const QString &statementsJson, const QString &profileJson);

    QJSEngine m_js;
};

void TestCore::initTestCase()
{
    // Keep HistoryManager's SQLite file out of the real AppData directory.
    QStandardPaths::setTestModeEnabled(true);
    const QString dir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    QDir(dir).removeRecursively();

    // Load guard.js, minus the QML-only ".pragma library" directive.
    QFile f(QStringLiteral(GUARD_JS_PATH));
    QVERIFY2(f.open(QIODevice::ReadOnly | QIODevice::Text), "guard.js not found");
    QString src = QString::fromUtf8(f.readAll());
    src.remove(QRegularExpression(QStringLiteral("^\\.pragma[^\n]*\n")));
    const QJSValue result = m_js.evaluate(src, QStringLiteral("guard.js"));
    QVERIFY2(!result.isError(), qPrintable(result.toString()));
    QVERIFY(m_js.globalObject().property("check").isCallable());

    // Load complete.js into the same engine (function names don't collide).
    QFile cf(QStringLiteral(COMPLETE_JS_PATH));
    QVERIFY2(cf.open(QIODevice::ReadOnly | QIODevice::Text), "complete.js not found");
    QString csrc = QString::fromUtf8(cf.readAll());
    csrc.remove(QRegularExpression(QStringLiteral("^\\.pragma[^\n]*\n")));
    const QJSValue cres = m_js.evaluate(csrc, QStringLiteral("complete.js"));
    QVERIFY2(!cres.isError(), qPrintable(cres.toString()));
    QVERIFY(m_js.globalObject().property("tablesInScope").isCallable());

    // Load fk.js into the same engine (function names don't collide).
    QFile ff(QStringLiteral(FK_JS_PATH));
    QVERIFY2(ff.open(QIODevice::ReadOnly | QIODevice::Text), "fk.js not found");
    QString fsrc = QString::fromUtf8(ff.readAll());
    fsrc.remove(QRegularExpression(QStringLiteral("^\\.pragma[^\n]*\n")));
    const QJSValue fres = m_js.evaluate(fsrc, QStringLiteral("fk.js"));
    QVERIFY2(!fres.isError(), qPrintable(fres.toString()));
    QVERIFY(m_js.globalObject().property("outgoing").isCallable());

    // Load cellview.js into the same engine (function names don't collide).
    QFile vf(QStringLiteral(CELLVIEW_JS_PATH));
    QVERIFY2(vf.open(QIODevice::ReadOnly | QIODevice::Text), "cellview.js not found");
    QString vsrc = QString::fromUtf8(vf.readAll());
    vsrc.remove(QRegularExpression(QStringLiteral("^\\.pragma[^\n]*\n")));
    const QJSValue vres = m_js.evaluate(vsrc, QStringLiteral("cellview.js"));
    QVERIFY2(!vres.isError(), qPrintable(vres.toString()));
    QVERIFY(m_js.globalObject().property("inspect").isCallable());

    // Load listsort.js into the same engine (function names don't collide).
    QFile lf(QStringLiteral(LISTSORT_JS_PATH));
    QVERIFY2(lf.open(QIODevice::ReadOnly | QIODevice::Text), "listsort.js not found");
    QString lsrc = QString::fromUtf8(lf.readAll());
    lsrc.remove(QRegularExpression(QStringLiteral("^\\.pragma[^\n]*\n")));
    const QJSValue lres = m_js.evaluate(lsrc, QStringLiteral("listsort.js"));
    QVERIFY2(!lres.isError(), qPrintable(lres.toString()));
    QVERIFY(m_js.globalObject().property("arrange").isCallable());

    // Load drivers.js into the same engine (function names don't collide).
    QFile df(QStringLiteral(DRIVERS_JS_PATH));
    QVERIFY2(df.open(QIODevice::ReadOnly | QIODevice::Text), "drivers.js not found");
    QString dsrc = QString::fromUtf8(df.readAll());
    dsrc.remove(QRegularExpression(QStringLiteral("^\\.pragma[^\n]*\n")));
    const QJSValue dres = m_js.evaluate(dsrc, QStringLiteral("drivers.js"));
    QVERIFY2(!dres.isError(), qPrintable(dres.toString()));
    QVERIFY(m_js.globalObject().property("availableLabels").isCallable());

    // Load params.js into the same engine (function names don't collide).
    QFile pf(QStringLiteral(PARAMS_JS_PATH));
    QVERIFY2(pf.open(QIODevice::ReadOnly | QIODevice::Text), "params.js not found");
    QString psrc = QString::fromUtf8(pf.readAll());
    psrc.remove(QRegularExpression(QStringLiteral("^\\.pragma[^\n]*\n")));
    const QJSValue pres = m_js.evaluate(psrc, QStringLiteral("params.js"));
    QVERIFY2(!pres.isError(), qPrintable(pres.toString()));
    QVERIFY(m_js.globalObject().property("extractParams").isCallable());
}

QJSValue TestCore::runGuard(const QString &statementsJson, const QString &profileJson)
{
    const QJSValue v = m_js.evaluate(
        QStringLiteral("check(%1, %2)").arg(statementsJson, profileJson));
    Q_ASSERT(!v.isError());
    return v;
}

// ── SqlUtils ──────────────────────────────────────────────────────────────────

void TestCore::split_basic()
{
    const auto stmts = SqlUtils::splitStatements("SELECT 1; SELECT 2;\nSELECT 3");
    QCOMPARE(stmts, QStringList({"SELECT 1", "SELECT 2", "SELECT 3"}));
}

void TestCore::split_semicolonInString()
{
    const auto stmts = SqlUtils::splitStatements("SELECT 'a;b'; SELECT 2");
    QCOMPARE(stmts.size(), 2);
    QCOMPARE(stmts[0], QStringLiteral("SELECT 'a;b'"));
}

void TestCore::split_escapedQuote()
{
    const auto stmts = SqlUtils::splitStatements("SELECT 'it''s; fine'; SELECT 2");
    QCOMPARE(stmts.size(), 2);
    QCOMPARE(stmts[0], QStringLiteral("SELECT 'it''s; fine'"));
}

void TestCore::split_comments()
{
    const auto line = SqlUtils::splitStatements("SELECT 1 -- not a split ;\n; SELECT 2");
    QCOMPARE(line.size(), 2);

    const auto block = SqlUtils::splitStatements("SELECT /* ; */ 1; SELECT 2");
    QCOMPARE(block.size(), 2);
    QCOMPARE(block[0], QStringLiteral("SELECT /* ; */ 1"));
}

void TestCore::split_emptyDropped()
{
    QCOMPARE(SqlUtils::splitStatements(";;;  ;"), QStringList{});
    QCOMPARE(SqlUtils::splitStatements("  SELECT 1  ;;  "), QStringList{"SELECT 1"});
}

void TestCore::split_pgDollarQuoting()
{
    // Semicolons inside a dollar-quoted function body must not split.
    const QString fn =
        "CREATE FUNCTION f() RETURNS int AS $$\n"
        "BEGIN SELECT 1; RETURN 2; END\n"
        "$$ LANGUAGE plpgsql";
    const auto stmts = SqlUtils::splitStatements(fn + "; SELECT 3", "QPSQL");
    QCOMPARE(stmts.size(), 2);
    QCOMPARE(stmts[0], fn);

    // Tagged variant, with a nested plain $$ that belongs to the body.
    const auto tagged = SqlUtils::splitStatements(
        "CREATE FUNCTION g() AS $body$ SELECT '$$'; $body$; SELECT 1", "QPSQL");
    QCOMPARE(tagged.size(), 2);

    // $1 positional parameters are not dollar-quote delimiters.
    const auto params = SqlUtils::splitStatements(
        "SELECT * FROM t WHERE a = $1 AND b = $2; SELECT 2", "QPSQL");
    QCOMPARE(params.size(), 2);

    // Without the Postgres driver the generic splitter is unchanged.
    QVERIFY(SqlUtils::splitStatements(fn + "; SELECT 3").size() > 2);
}

void TestCore::split_mysqlBackslashEscape()
{
    // \' does not terminate a MySQL string literal.
    const auto stmts = SqlUtils::splitStatements(
        R"(SELECT 'it\'s; fine'; SELECT 2)", "QMYSQL");
    QCOMPARE(stmts.size(), 2);
    QCOMPARE(stmts[0], QStringLiteral(R"(SELECT 'it\'s; fine')"));

    // Postgres standard strings treat backslash literally: a string that ends
    // with a backslash must still close on the next quote.
    const auto pg = SqlUtils::splitStatements(
        R"(SELECT 'C:\'; SELECT 2)", "QPSQL");
    QCOMPARE(pg.size(), 2);
}

// ── MarkdownDoc ───────────────────────────────────────────────────────────────

void TestCore::md_segments()
{
    MarkdownDoc doc;

    const auto segs = doc.segments(
        "/* @md\n# Users\nCreate the table first.\n*/\n"
        "CREATE TABLE users (id int);\n"
        "/* @md Then seed it. */\n"
        "INSERT INTO users VALUES (1);");
    QCOMPARE(segs.size(), 4);
    QCOMPARE(segs[0].toMap()["type"], QVariant("md"));
    QCOMPARE(segs[0].toMap()["text"], QVariant("# Users\nCreate the table first."));
    QCOMPARE(segs[1].toMap()["type"], QVariant("sql"));
    QCOMPARE(segs[1].toMap()["text"], QVariant("CREATE TABLE users (id int);"));
    QCOMPARE(segs[2].toMap()["text"], QVariant("Then seed it."));
    QCOMPARE(segs[3].toMap()["type"], QVariant("sql"));

    // Plain comments are SQL, not markdown; pure SQL yields one segment.
    const auto plain = doc.segments("/* not md */ SELECT 1;");
    QCOMPARE(plain.size(), 1);
    QCOMPARE(plain[0].toMap()["type"], QVariant("sql"));

    // An unclosed block runs to the end of the buffer (mid-typing state).
    const auto open = doc.segments("SELECT 1;\n/* @md still typing");
    QCOMPARE(open.size(), 2);
    QCOMPARE(open[1].toMap()["type"], QVariant("md"));
    QCOMPARE(open[1].toMap()["text"], QVariant("still typing"));

    // @mdx must not match the @md word.
    QCOMPARE(doc.segments("/* @mdx */ SELECT 1;").size(), 1);

    QCOMPARE(doc.segments("   \n").size(), 0);
}

void TestCore::md_toMarkdown()
{
    MarkdownDoc doc;
    const QString md = doc.toMarkdown(
        "/* @md # Title */\nSELECT 1;\n/* @md done */");
    QCOMPARE(md, QStringLiteral("# Title\n\n```sql\nSELECT 1;\n```\n\ndone\n"));

    QCOMPARE(doc.toMarkdown(""), QString());
}

void TestCore::md_exportFile()
{
    MarkdownDoc   doc;
    QTemporaryDir dir;

    // ".md" is appended when missing.
    QVERIFY(doc.exportMarkdown("/* @md hi */", QUrl::fromLocalFile(dir.filePath("out"))));
    QFile f(dir.filePath("out.md"));
    QVERIFY(f.open(QIODevice::ReadOnly | QIODevice::Text));
    QCOMPARE(QString::fromUtf8(f.readAll()), QStringLiteral("hi\n"));

    QVERIFY(!doc.exportMarkdown("x", QUrl::fromLocalFile(dir.path() + "/no/such/dir/f.md")));
}

// ── guard.js ──────────────────────────────────────────────────────────────────

static const char *kReadOnly = R"({ "name": "p", "readOnly": true })";
static const char *kConfirmAll =
    R"({ "name": "p", "confirmDelete": true, "confirmDrop": true,
         "confirmTruncate": true, "confirmUpdateWithoutWhere": true })";

void TestCore::guard_readOnlyBlocksWrites()
{
    // A write hidden behind a harmless first statement must still be blocked.
    QVERIFY(runGuard(R"(["SELECT 1", "DROP TABLE users"])", kReadOnly)
                .property("blocked").toBool());
    QVERIFY(runGuard(R"js(["INSERT INTO t VALUES (1)"])js", kReadOnly)
                .property("blocked").toBool());
    // Not on the read allowlist → refused.
    QVERIFY(runGuard(R"js(["CALL do_stuff()"])js", kReadOnly)
                .property("blocked").toBool());
}

void TestCore::guard_readOnlyAllowsReads()
{
    QVERIFY(runGuard(R"(["SELECT * FROM t"])", kReadOnly).isNull());
    QVERIFY(runGuard(R"(["EXPLAIN SELECT 1"])", kReadOnly).isNull());
    QVERIFY(runGuard(R"(["WITH x AS (SELECT 1) SELECT * FROM x"])", kReadOnly).isNull());
}

void TestCore::guard_commentBypassBlocked()
{
    QVERIFY(runGuard(R"(["-- hi\nDELETE FROM t"])", kReadOnly)
                .property("blocked").toBool());
    QVERIFY(runGuard(R"(["/* x */ UPDATE t SET a=1"])", kReadOnly)
                .property("blocked").toBool());
    // A comment-only statement is not a violation.
    QVERIFY(runGuard(R"(["-- just a comment"])", kReadOnly).isNull());
}

void TestCore::guard_cteWriteBlocked()
{
    QVERIFY(runGuard(R"(["WITH x AS (DELETE FROM t RETURNING *) SELECT * FROM x"])",
                     kReadOnly).property("blocked").toBool());
}

void TestCore::guard_confirmations()
{
    // DELETE needs confirmation (blocked=false) even as a later statement.
    const QJSValue del = runGuard(R"(["SELECT 1", "DELETE FROM t WHERE id=1"])", kConfirmAll);
    QVERIFY(!del.isNull());
    QCOMPARE(del.property("blocked").toBool(), false);

    // Two different confirmations are aggregated into one message.
    const QJSValue two = runGuard(R"(["DELETE FROM a WHERE x=1", "TRUNCATE b"])", kConfirmAll);
    QCOMPARE(two.property("message").toString().split('\n').size(), 2);

    // UPDATE with WHERE passes; without WHERE it needs confirmation.
    QVERIFY(runGuard(R"(["UPDATE t SET a=1 WHERE id=2"])", kConfirmAll).isNull());
    QCOMPARE(runGuard(R"(["UPDATE t SET a=1"])", kConfirmAll)
                 .property("blocked").toBool(), false);
}

void TestCore::guard_noProfile()
{
    QVERIFY(runGuard(R"(["DROP TABLE t"])", "null").isNull());
    QVERIFY(runGuard(R"(["DROP TABLE t"])", "{}").isNull());
}

// ── complete.js (schema-aware completion scope) ─────────────────────────────────

void TestCore::complete_tablesInScope()
{
    // Returns [{name, alias}] as a "name:alias|name:alias" string, sorted, for
    // easy comparison.
    auto scope = [&](const QString &sql, int pos) {
        const QString lit = QStringLiteral("'") + QString(sql).replace("'", "\\'") + "'";
        const QJSValue v = m_js.evaluate(
            QStringLiteral("tablesInScope(%1, %2)").arg(lit).arg(pos));
        QStringList parts;
        const int n = v.property("length").toInt();
        for (int i = 0; i < n; ++i)
            parts << v.property(i).property("name").toString() + ":" +
                     v.property(i).property("alias").toString();
        parts.sort();
        return parts.join("|");
    };

    QCOMPARE(scope("SELECT * FROM users", 3), QStringLiteral("users:"));
    QCOMPARE(scope("SELECT * FROM users AS u", 3), QStringLiteral("users:u"));
    QCOMPARE(scope("SELECT u.id FROM users u JOIN orders o ON u.id=o.uid", 8),
             QStringLiteral("orders:o|users:u"));
    QCOMPARE(scope("SELECT * FROM a x, b y", 3), QStringLiteral("a:x|b:y"));
    QCOMPARE(scope("UPDATE t SET x = 1", 0), QStringLiteral("t:"));
    QCOMPARE(scope("INSERT INTO tbl (a) VALUES (1)", 0), QStringLiteral("tbl:"));

    // A following clause keyword is never read as an alias.
    QCOMPARE(scope("SELECT * FROM users WHERE id = 1", 3), QStringLiteral("users:"));

    // Statement isolation: cursor in the 2nd statement sees only its tables.
    QCOMPARE(scope("SELECT * FROM foo; SELECT * FROM bar", 30), QStringLiteral("bar:"));
}

void TestCore::complete_dottedTable()
{
    auto dotted = [&](const QString &prefix, const QString &scopeJson) {
        const QJSValue v = m_js.evaluate(
            QStringLiteral("dottedTable('%1', %2)").arg(prefix, scopeJson));
        return v.isNull() ? QStringLiteral("<null>") : v.toString();
    };

    const QString scope = QStringLiteral("[{name:'users',alias:'u'},{name:'public.orders',alias:''}]");

    // Alias resolves to its table.
    QCOMPARE(dotted("u.na", scope), QStringLiteral("users"));
    // Table name (and its unqualified tail) resolve.
    QCOMPARE(dotted("users.na", scope), QStringLiteral("users"));
    QCOMPARE(dotted("orders.i", scope), QStringLiteral("public.orders"));
    // Unknown qualifier falls back to itself (so an unlisted "table." still works).
    QCOMPARE(dotted("x.na", scope), QStringLiteral("x"));
    // No dot → null.
    QCOMPARE(dotted("nam", scope), QStringLiteral("<null>"));
}

// ── Foreign-key navigation (fk.js) ──────────────────────────────────────────────

// A small FK list: orders.customer_id → customers.id, orders.product_id →
// products.id, and (deliberately ambiguous) an items.customer_id → people.id.
static const char *FK_LIST =
    "[{fromTable:'orders',fromColumn:'customer_id',toTable:'customers',toColumn:'id'},"
    " {fromTable:'orders',fromColumn:'product_id', toTable:'products', toColumn:'id'},"
    " {fromTable:'items', fromColumn:'customer_id',toTable:'people',   toColumn:'id'}]";

void TestCore::fk_outgoingResolves()
{
    auto out = [&](const QString &table, const QString &col) {
        const QJSValue v = m_js.evaluate(
            QStringLiteral("(function(){var r=outgoing(%1,%2,'%3');"
                           "return r?r.toTable+'.'+r.toColumn:'<null>';})()")
                .arg(QString::fromUtf8(FK_LIST),
                     table.isEmpty() ? QStringLiteral("''") : QStringLiteral("'%1'").arg(table),
                     col));
        return v.toString();
    };

    // Known table + FK column → the referenced target.
    QCOMPARE(out("orders", "customer_id"), QStringLiteral("customers.id"));
    QCOMPARE(out("orders", "product_id"),  QStringLiteral("products.id"));
    // Schema-qualified source table still matches on the bare name.
    QCOMPARE(out("public.orders", "customer_id"), QStringLiteral("customers.id"));
    // Known table without that FK → no guess.
    QCOMPARE(out("orders", "id"), QStringLiteral("<null>"));
    // No table context + a column that's ambiguous across tables → no guess.
    QCOMPARE(out("", "customer_id"), QStringLiteral("<null>"));
    // No table context + a column unique to one FK → resolves.
    QCOMPARE(out("", "product_id"), QStringLiteral("products.id"));
}

void TestCore::fk_incomingLists()
{
    auto inc = [&](const QString &table, const QString &col) {
        const QJSValue v = m_js.evaluate(
            QStringLiteral("(function(){var a=incoming(%1,%2,'%3');"
                           "return a.map(function(x){return x.fromTable+'.'+x.fromColumn;})"
                           ".sort().join('|');})()")
                .arg(QString::fromUtf8(FK_LIST),
                     table.isEmpty() ? QStringLiteral("''") : QStringLiteral("'%1'").arg(table),
                     col));
        return v.toString();
    };

    // customers.id is referenced by orders.customer_id.
    QCOMPARE(inc("customers", "id"), QStringLiteral("orders.customer_id"));
    // With the table known, people.id only counts its own referrers.
    QCOMPARE(inc("people", "id"), QStringLiteral("items.customer_id"));
    // A column nobody references → empty.
    QCOMPARE(inc("products", "sku"), QString());
    // No table context → every FK whose target column matches (both id targets).
    QCOMPARE(inc("", "id"),
             QStringLiteral("items.customer_id|orders.customer_id|orders.product_id"));
}

void TestCore::fk_selectByDialects()
{
    auto sel = [&](const QString &table, const QString &col,
                   const QString &val, const QString &driver) {
        const QJSValue v = m_js.evaluate(
            QStringLiteral("selectBy('%1','%2',%3,'%4')")
                .arg(table, col, val, driver));
        return v.toString();
    };

    // Standard (double-quote) identifiers, numeric literal emitted raw.
    QCOMPARE(sel("customers", "id", "'42'", "QPSQL"),
             QStringLiteral("SELECT * FROM \"customers\" WHERE \"id\" = 42"));
    // MySQL back-tick identifiers, string literal single-quoted.
    QCOMPARE(sel("customers", "name", "\"o'brien\"", "QMYSQL"),
             QStringLiteral("SELECT * FROM `customers` WHERE `name` = 'o''brien'"));
    // Schema-qualified target quotes each part.
    QCOMPARE(sel("public.customers", "id", "'7'", "QSQLITE"),
             QStringLiteral("SELECT * FROM \"public\".\"customers\" WHERE \"id\" = 7"));
    // Empty value → NULL comparison (navigation is disabled in the UI, but the
    // literal is still well-formed).
    QCOMPARE(sel("t", "c", "''", "QSQLITE"),
             QStringLiteral("SELECT * FROM \"t\" WHERE \"c\" = NULL"));
}

// ── Cell value inspector (cellview.js) ──────────────────────────────────────────

void TestCore::cellview_classifies()
{
    auto kind = [&](const QString &valueJsLiteral) {
        return m_js.evaluate(QStringLiteral("inspect(%1).kind").arg(valueJsLiteral)).toString();
    };
    auto text = [&](const QString &valueJsLiteral) {
        return m_js.evaluate(QStringLiteral("inspect(%1).text").arg(valueJsLiteral)).toString();
    };

    // A JSON object is classified as json and pretty-printed (indented, multi-line).
    QCOMPARE(kind(QStringLiteral("'{\"a\":1,\"b\":[2,3]}'")), QStringLiteral("json"));
    const QString pretty = text(QStringLiteral("'{\"a\":1,\"b\":[2,3]}'"));
    QVERIFY(pretty.contains('\n'));
    QVERIFY(pretty.contains(QStringLiteral("  \"a\": 1")));

    // A JSON array too.
    QCOMPARE(kind(QStringLiteral("'[1, 2, 3]'")), QStringLiteral("json"));

    // A bare number / boolean is NOT treated as a JSON document (kept as text).
    QCOMPARE(kind(QStringLiteral("'42'")),   QStringLiteral("text"));
    QCOMPARE(kind(QStringLiteral("'true'")), QStringLiteral("text"));

    // Plain text stays text and is returned verbatim.
    QCOMPARE(kind(QStringLiteral("'hello world'")), QStringLiteral("text"));
    QCOMPARE(text(QStringLiteral("'hello world'")), QStringLiteral("hello world"));

    // Malformed JSON that merely starts with a brace falls back to text.
    QCOMPARE(kind(QStringLiteral("'{not: valid'")), QStringLiteral("text"));

    // Null / empty → empty text, no crash.
    QCOMPARE(text(QStringLiteral("null")), QString());
    QCOMPARE(kind(QStringLiteral("''")),   QStringLiteral("text"));
}

// ── Driver list (drivers.js) ──────────────────────────────────────────────────

void TestCore::drivers_onlyAvailableOffered()
{
    auto labels = [&](const QString &keysJsArray) {
        return m_js.evaluate(QStringLiteral("availableLabels(%1).join('|')").arg(keysJsArray))
                   .toString();
    };

    // What Qt's official Windows binaries report: six plugins, no MySQL. The
    // form must not offer MySQL or MariaDB there, because no client library the
    // user installs can make them work.
    QCOMPARE(labels(QStringLiteral(
                 "['QIBASE','QSQLITE','QMIMER','QOCI','QODBC','QPSQL']")),
             QStringLiteral("PostgreSQL|SQLite|Oracle|Firebird|ODBC"));

    // macOS: no MySQL, no Oracle, no Firebird either.
    QCOMPARE(labels(QStringLiteral("['QMIMER','QODBC','QPSQL','QSQLITE']")),
             QStringLiteral("PostgreSQL|SQLite|ODBC"));

    // Linux, where every driver qub supports is present. QMYSQL and QMARIADB
    // are two keys of one plugin and both are offered.
    QCOMPARE(labels(QStringLiteral(
                 "['QIBASE','QSQLITE','QMIMER','QMARIADB','QMYSQL','QOCI','QODBC','QPSQL']")),
             QStringLiteral("PostgreSQL|MySQL|MariaDB|SQLite|Oracle|Firebird|ODBC"));

    // QMIMER is reported by Qt on all three but qub has no support for it, so
    // it never reaches the form — the intersection drops it in every case above.

    // The order is the declared one, not the order Qt happens to report in.
    QCOMPARE(labels(QStringLiteral("['QODBC','QPSQL','QSQLITE']")),
             QStringLiteral("PostgreSQL|SQLite|ODBC"));

    // A build with no SQL plugins at all yields an empty list rather than
    // throwing: the form renders an empty dropdown, which is the truth.
    QCOMPARE(labels(QStringLiteral("[]")), QString());

    // label()/qtKey() round-trip for every key the list can produce.
    QCOMPARE(m_js.evaluate(QStringLiteral("qtKey(label('QMARIADB'))")).toString(),
             QStringLiteral("QMARIADB"));
    QCOMPARE(m_js.evaluate(QStringLiteral("label('QMIMER')")).toString(),
             QStringLiteral("QMIMER"));   // unmapped keys pass through
}

// ── Query parameters (params.js) ─────────────────────────────────────────────

void TestCore::params_namedAndPositional()
{
    auto names = [&](const QString &sql) {
        return m_js.evaluate(
                    QStringLiteral("extractParams(%1).map(p => "
                                   "(p.positional ? '$' : ':') + p.name).join('|')")
                        .arg(sql)).toString();
    };

    QCOMPARE(names(R"("SELECT * FROM t WHERE id = :id AND region = :region")"),
             QStringLiteral(":id|:region"));

    // Repeats collapse: one prompt per distinct name.
    QCOMPARE(names(R"("SELECT :a, :a, :b")"), QStringLiteral(":a|:b"));

    // Positional placeholders come back in numeric order, not the order met.
    QCOMPARE(names(R"("SELECT * FROM t WHERE a = $2 AND b = $1")"),
             QStringLiteral("$1|$2"));

    // A Postgres ::cast is not a parameter, and neither is a :// URL.
    QCOMPARE(names(R"("SELECT id::text FROM t WHERE url = 'http://x'")"), QString());

    QCOMPARE(names(R"("SELECT 1")"), QString());
}

void TestCore::params_ignoreCommentsAndLiterals()
{
    auto count = [&](const QString &sql) {
        return m_js.evaluate(QStringLiteral("extractParams(%1).length").arg(sql)).toInt();
    };

    // The regression this module exists for: _applyLimit appends its own
    // "/* qub:limit */" marker, which read as a :limit parameter, so every
    // SELECT without a LIMIT of its own opened the parameter dialog instead of
    // running.
    QCOMPARE(count(R"("SELECT * FROM t LIMIT 1001 /* qub:limit */")"), 0);

    // Comments and string literals in general are not where parameters live.
    QCOMPARE(count(R"("SELECT 1 -- and :nope")"), 0);
    QCOMPARE(count(R"("SELECT 'a :nope b' FROM t")"), 0);

    // But a real parameter alongside a decoy still comes back.
    QCOMPARE(count(R"("SELECT * FROM t WHERE id = :id /* :nope */")"), 1);
}

// ── CSV / TSV export ──────────────────────────────────────────────────────────

static QString exportRows(const QStringList &columns, const QList<QVariantList> &rows,
                          bool tsv, QTemporaryDir &dir)
{
    QueryResult r;
    r.success = true;
    r.columns = columns;
    r.rows    = rows;

    ResultModel model;
    model.setResult(r);

    const QString path = dir.filePath(tsv ? "out.tsv" : "out.csv");
    const bool ok = tsv ? model.exportTsv(QUrl::fromLocalFile(path))
                        : model.exportCsv(QUrl::fromLocalFile(path));
    if (!ok) return {};

    QFile f(path);
    f.open(QIODevice::ReadOnly | QIODevice::Text);
    return QString::fromUtf8(f.readAll());
}

void TestCore::export_csvNeutralizesFormulas()
{
    QTemporaryDir dir;
    const QString out = exportRows({"a", "b", "c"},
        {{ "=HYPERLINK(\"http://x\")", "@SUM(A1)", "+cmd|/c calc" }}, false, dir);

    QVERIFY(out.contains("'=HYPERLINK"));
    QVERIFY(out.contains("'@SUM"));
    QVERIFY(out.contains("'+cmd"));
}

void TestCore::export_csvQuoting()
{
    QTemporaryDir dir;
    const QString out = exportRows({"n", "s", "q"},
        {{ "-42.5", "a,b", "say \"hi\"" }}, false, dir);

    // Negative numbers are not formula-neutralized.
    QVERIFY(out.contains("\n-42.5,"));
    // Comma value quoted; embedded quotes doubled.
    QVERIFY(out.contains("\"a,b\""));
    QVERIFY(out.contains("\"say \"\"hi\"\"\""));
}

void TestCore::export_tsvNeutralizesFormulas()
{
    QTemporaryDir dir;
    const QString out = exportRows({"a", "b"},
        {{ "=1+1", "-7" }}, true, dir);

    QVERIFY(out.contains("'=1+1"));
    QVERIFY(out.contains("\t-7"));   // plain number untouched
}

void TestCore::export_markdownTable()
{
    QueryResult r;
    r.success = true;
    r.columns = { "id", "name" };
    r.rows    = { { "1", "a|b" }, { "2", "line1\nline2" }, { "3", "c" } };

    ResultModel model;
    model.setResult(r);

    // maxRows caps the body and adds a footer.
    const QString capped = model.toMarkdown(2);
    QVERIFY(capped.contains("| id | name |"));
    QVERIFY(capped.contains("| --- | --- |"));
    QVERIFY(capped.contains("| 1 | a\\|b |"));      // pipe escaped
    QVERIFY(capped.contains("| 2 | line1 line2 |")); // newline flattened
    QVERIFY(!capped.contains("| 3 | c |"));          // beyond the cap
    QVERIFY(capped.contains("_… 1 more rows not shown_"));

    // No cap → every row, no footer.
    const QString full = model.toMarkdown(100);
    QVERIFY(full.contains("| 3 | c |"));
    QVERIFY(!full.contains("more rows not shown"));

    // Empty model yields empty string.
    ResultModel empty;
    QCOMPARE(empty.toMarkdown(100), QString());
}

void TestCore::export_sqlInserts()
{
    QueryResult r;
    r.success = true;
    r.columns = { "id", "name", "active", "note" };
    r.rows = {
        { 1, QStringLiteral("O'Brien"), true,  QVariant() },   // quote + null
        { 2, QStringLiteral("a\\b"),    false, 3.5 },          // backslash + number
    };

    ResultModel model;
    model.setResult(r);

    // Default (standard) dialect → double-quoted identifiers, 1/0 for bools,
    // NULL for a null cell, doubled single-quote, backslash left as-is.
    const QString std = model.toSqlInserts("users", "QSQLITE");
    const QStringList lines = std.split('\n', Qt::SkipEmptyParts);
    QCOMPARE(lines.size(), 2);
    QCOMPARE(lines.at(0),
             QStringLiteral("INSERT INTO \"users\" (\"id\", \"name\", \"active\", \"note\") "
                            "VALUES (1, 'O''Brien', 1, NULL);"));
    QCOMPARE(lines.at(1),
             QStringLiteral("INSERT INTO \"users\" (\"id\", \"name\", \"active\", \"note\") "
                            "VALUES (2, 'a\\b', 0, 3.5);"));

    // PostgreSQL → TRUE/FALSE booleans.
    const QString pg = model.toSqlInserts("users", "QPSQL");
    QVERIFY(pg.contains(QStringLiteral(", TRUE, ")));
    QVERIFY(pg.contains(QStringLiteral(", FALSE, ")));

    // MySQL → backtick identifiers and backslash doubled inside strings.
    const QString my = model.toSqlInserts("users", "QMYSQL");
    QVERIFY(my.contains(QStringLiteral("INSERT INTO `users` (`id`, `name`, `active`, `note`)")));
    QVERIFY(my.contains(QStringLiteral("'a\\\\b'")));   // a\b → a\\b in source terms

    // Row cap and empty-model guard.
    QCOMPARE(model.toSqlInserts("users", "QSQLITE", 1).split('\n', Qt::SkipEmptyParts).size(), 1);
    ResultModel empty;
    QCOMPARE(empty.toSqlInserts("users", "QSQLITE"), QString());
}

// The XLSX writer builds a STORE-only ZIP by hand, and every entry carries a
// CRC-32 that Excel refuses the file without. The checksum used to come from
// zlib; it is computed in ResultModel.cpp now, so this walks the archive back
// and re-checks each entry with a deliberately different implementation —
// bit-by-bit, no lookup table.
static quint32 bitwiseCrc32(const QByteArray &data)
{
    quint32 c = 0xFFFFFFFFu;
    for (const char byte : data) {
        c ^= quint8(byte);
        for (int k = 0; k < 8; ++k)
            c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
    }
    return c ^ 0xFFFFFFFFu;
}

static quint32 u32At(const QByteArray &b, int off)
{
    return quint32(quint8(b.at(off)))
         | quint32(quint8(b.at(off + 1))) << 8
         | quint32(quint8(b.at(off + 2))) << 16
         | quint32(quint8(b.at(off + 3))) << 24;
}

static quint16 u16At(const QByteArray &b, int off)
{
    return quint16(quint8(b.at(off))) | quint16(quint8(b.at(off + 1))) << 8;
}

void TestCore::export_xlsxZipChecksums()
{
    QueryResult r;
    r.success = true;
    r.columns = { "id", "name" };
    r.rows = { { 1, QStringLiteral("Ada") }, { 2, QStringLiteral("Grace & <co>") } };

    ResultModel model;
    model.setResult(r);

    QTemporaryDir dir;
    const QString path = dir.filePath("out.xlsx");
    QVERIFY(model.exportXlsx(QUrl::fromLocalFile(path)));

    QFile f(path);
    QVERIFY(f.open(QIODevice::ReadOnly));
    const QByteArray zip = f.readAll();

    QVERIFY(zip.startsWith("PK\x03\x04"));
    QVERIFY(zip.contains("PK\x05\x06"));          // end of central directory

    QStringList names;
    int off = 0;
    while (off + 30 <= zip.size() && zip.mid(off, 4) == QByteArray("PK\x03\x04", 4)) {
        const quint32 crc      = u32At(zip, off + 14);
        const quint32 size     = u32At(zip, off + 18);
        const quint16 nameLen  = u16At(zip, off + 26);
        const quint16 extraLen = u16At(zip, off + 28);
        const QByteArray name  = zip.mid(off + 30, nameLen);
        const QByteArray data  = zip.mid(off + 30 + nameLen + extraLen, size);

        QCOMPARE(quint32(data.size()), size);
        QCOMPARE(crc, bitwiseCrc32(data));

        names << QString::fromUtf8(name);
        off += 30 + nameLen + extraLen + size;
    }

    // Every part Excel needs, and the cells actually made it in.
    QVERIFY(names.contains("[Content_Types].xml"));
    QVERIFY(names.contains("xl/workbook.xml"));
    QVERIFY(names.contains("xl/worksheets/sheet1.xml"));
    QVERIFY(zip.contains("Ada"));
    QVERIFY(zip.contains("Grace &amp; &lt;co&gt;"));
}

void TestCore::columnStats_numericAndText()
{
    QueryResult r;
    r.success = true;
    r.columns = { "n", "label" };
    QVariantList nullCell; // an invalid QVariant reads as NULL
    r.rows = {
        { 10,  "a" },
        { 20,  "b" },
        { 30,  "a" },
        { QVariant(), "c" },   // NULL in the numeric column
    };

    ResultModel model;
    model.setResult(r);

    // Numeric column: aggregates over the 3 non-null values.
    const QVariantMap n = model.columnStats(0);
    QCOMPARE(n["numeric"].toBool(), true);
    QCOMPARE(n["count"].toInt(),    3);
    QCOMPARE(n["nulls"].toInt(),    1);
    QCOMPARE(n["distinct"].toInt(), 3);
    QCOMPARE(n["sum"].toDouble(),   60.0);
    QCOMPARE(n["avg"].toDouble(),   20.0);
    QCOMPARE(n["min"].toDouble(),   10.0);
    QCOMPARE(n["max"].toDouble(),   30.0);

    // Text column: not numeric, distinct collapses "a".
    const QVariantMap t = model.columnStats(1);
    QCOMPARE(t["numeric"].toBool(),  false);
    QCOMPARE(t["count"].toInt(),     4);
    QCOMPARE(t["distinct"].toInt(),  3);
    QVERIFY(!t.contains("sum"));

    // Out-of-range column → empty map.
    QVERIFY(model.columnStats(9).isEmpty());

    // A filter narrows the aggregates to the visible rows.
    model.setFilterText("a");   // matches rows with "a" in any column → n=10 and n=30
    const QVariantMap f = model.columnStats(0);
    QCOMPARE(f["count"].toInt(), 2);
    QCOMPARE(f["sum"].toDouble(), 40.0);
}

void TestCore::filter_matchingNothingHidesEveryRow()
{
    // m_visibleRows used to be empty for two different reasons — "no filter, so
    // show everything" and "the filter matched nothing" — so a filter that
    // excluded every row silently showed the whole result set instead, and every
    // API documented as respecting the filter read the unfiltered rows.
    QueryResult r;
    r.success = true;
    r.columns = { "n", "label" };
    r.rows = { { 10, "a" }, { 20, "b" }, { 30, "c" } };

    ResultModel model;
    model.setResult(r);
    QCOMPARE(model.rowCount(), 3);

    model.setFilterText("zzzznotfound");
    QCOMPARE(model.rowCount(), 0);
    QCOMPARE(model.columnStats(0)["count"].toInt(), 0);
    QCOMPARE(model.columnValues(0).size(), 0);

    // Clearing the filter brings every row back.
    model.setFilterText("");
    QCOMPARE(model.rowCount(), 3);

    // And a fresh result after a no-match filter is not still hidden.
    model.setFilterText("zzzznotfound");
    model.setResult(r);
    QCOMPARE(model.rowCount(), 3);
}

void TestCore::numericColumns_perColumn()
{
    QueryResult r;
    r.success = true;
    r.columns = { "n", "label", "mixed", "allnull", "quoted" };
    r.rows = {
        { 10,  "a", 1,   QVariant(), "1.5"  },
        { 20,  "b", "x", QVariant(), "2.5"  },
        { 30,  "a", 3,   QVariant(), "-3"   },
    };

    ResultModel model;
    model.setResult(r);

    const QVariantList num = model.numericColumns();
    QCOMPARE(num.size(), 5);
    QCOMPARE(num.at(0).toBool(), true);   // every value parses
    QCOMPARE(num.at(1).toBool(), false);  // text
    QCOMPARE(num.at(2).toBool(), false);  // one value spoils the column
    QCOMPARE(num.at(3).toBool(), false);  // all NULL — not vacuously numeric
    QCOMPARE(num.at(4).toBool(), true);   // numbers arriving as strings count

    // The verdict must agree with columnStats(), which is the slow path for the
    // same question.
    for (int c = 0; c < num.size(); ++c)
        QCOMPARE(num.at(c).toBool(), model.columnStats(c)["numeric"].toBool());

    // Respects the filter: hiding the row that carries "x" makes `mixed` numeric.
    model.setFilterText("b");
    QCOMPARE(model.numericColumns().at(2).toBool(), false);
    model.setFilterText("30");
    QCOMPARE(model.numericColumns().at(2).toBool(), true);

    // No rows at all → nothing is numeric.
    model.setFilterText("no such value");
    const QVariantList none = model.numericColumns();
    QCOMPARE(none.size(), 5);
    for (const QVariant &v : none)
        QCOMPARE(v.toBool(), false);

    // No columns at all → empty list, not a crash.
    ResultModel empty;
    QCOMPARE(empty.numericColumns().size(), 0);
}

void TestCore::columnValues_visibleRows()
{
    QueryResult r;
    r.success = true;
    r.columns = { "n", "label" };
    r.rows = { { 10, "a" }, { 20, "b" }, { 30, "a" } };

    ResultModel model;
    model.setResult(r);

    // Full column, in row order.
    const QVariantList all = model.columnValues(1);
    QCOMPARE(all.size(), 3);
    QCOMPARE(all.at(0).toString(), QStringLiteral("a"));
    QCOMPARE(all.at(2).toString(), QStringLiteral("a"));

    // Respects the active filter (only rows containing "b").
    model.setFilterText("b");
    const QVariantList filtered = model.columnValues(0);
    QCOMPARE(filtered.size(), 1);
    QCOMPARE(filtered.at(0).toInt(), 20);

    // Out-of-range column → empty.
    QVERIFY(model.columnValues(5).isEmpty());
}

void TestCore::profile_perColumn()
{
    QueryResult r;
    r.success = true;
    r.columns = { "n", "label", "empty" };
    r.rows = {
        { 10, "a", QVariant() },
        { 20, "b", QVariant() },
        { 30, "a", QVariant() },
        { 40, "a", QVariant() },
        { QVariant(), "c", QVariant() },   // NULL numeric
    };

    ResultModel model;
    model.setResult(r);

    const QVariantList prof = model.profile();
    QCOMPARE(prof.size(), 3);

    // Numeric column: describe-style stats over the 4 non-null values 10/20/30/40.
    const QVariantMap n = prof.at(0).toMap();
    QCOMPARE(n["column"].toString(),  QStringLiteral("n"));
    QCOMPARE(n["type"].toString(),    QStringLiteral("numeric"));
    QCOMPARE(n["count"].toInt(),      4);
    QCOMPARE(n["nulls"].toInt(),      1);
    QCOMPARE(n["distinct"].toInt(),   4);
    QCOMPARE(n["min"].toDouble(),     10.0);
    QCOMPARE(n["max"].toDouble(),     40.0);
    QCOMPARE(n["mean"].toDouble(),    25.0);
    QCOMPARE(n["median"].toDouble(),  25.0);   // (20+30)/2
    QVERIFY(!n.contains("topValues"));

    // Text column: top values ordered by frequency, "a" first with count 3.
    const QVariantMap t = prof.at(1).toMap();
    QCOMPARE(t["type"].toString(),    QStringLiteral("text"));
    QCOMPARE(t["count"].toInt(),      5);
    QCOMPARE(t["distinct"].toInt(),   3);
    const QVariantList top = t["topValues"].toList();
    QVERIFY(top.size() >= 1);
    QCOMPARE(top.at(0).toMap()["value"].toString(), QStringLiteral("a"));
    QCOMPARE(top.at(0).toMap()["count"].toInt(),    3);
    QVERIFY(!t.contains("min"));

    // All-NULL column classified as empty.
    const QVariantMap e = prof.at(2).toMap();
    QCOMPARE(e["type"].toString(),   QStringLiteral("empty"));
    QCOMPARE(e["count"].toInt(),     0);
    QCOMPARE(e["nulls"].toInt(),     5);

    // Profile follows the active filter.
    model.setFilterText("b");   // only the row with "b"
    const QVariantList fp = model.profile();
    QCOMPARE(fp.at(0).toMap()["count"].toInt(), 1);
    QCOMPARE(fp.at(0).toMap()["mean"].toDouble(), 20.0);
}

void TestCore::pivot_crossTabAggregates()
{
    QueryResult r;
    r.success = true;
    r.columns = { "region", "quarter", "amount" };
    r.rows = {
        { "east", "Q1", 10 },
        { "east", "Q1", 5  },   // same cell as above → sum 15
        { "east", "Q2", 20 },
        { "west", "Q1", 100 },
        { "west", "Q2", QVariant() },  // NULL amount — counted, not summed
    };

    ResultModel model;
    model.setResult(r);

    // sum of amount by region (rows) × quarter (cols).
    const QVariantMap p = model.pivot(0, 1, 2, "sum");
    QCOMPARE(p["rowField"].toString(),  QStringLiteral("region"));
    QCOMPARE(p["colField"].toString(),  QStringLiteral("quarter"));
    QCOMPARE(p["valueField"].toString(),QStringLiteral("amount"));

    const QVariantList colKeys = p["colKeys"].toList();
    QCOMPARE(colKeys.size(), 2);
    QCOMPARE(colKeys.at(0).toString(), QStringLiteral("Q1"));
    QCOMPARE(colKeys.at(1).toString(), QStringLiteral("Q2"));

    const QVariantList rows = p["rows"].toList();
    QCOMPARE(rows.size(), 2);
    // Keys sort lexically: "east" before "west".
    const QVariantMap east = rows.at(0).toMap();
    QCOMPARE(east["key"].toString(), QStringLiteral("east"));
    const QVariantList eastCells = east["cells"].toList();
    QCOMPARE(eastCells.at(0).toDouble(), 15.0);  // Q1: 10 + 5
    QCOMPARE(eastCells.at(1).toDouble(), 20.0);  // Q2
    QCOMPARE(east["total"].toDouble(),   35.0);

    const QVariantMap west = rows.at(1).toMap();
    const QVariantList westCells = west["cells"].toList();
    QCOMPARE(westCells.at(0).toDouble(), 100.0); // Q1
    QVERIFY(westCells.at(1).isNull());           // Q2 amount was NULL → no numeric
    QCOMPARE(west["total"].toDouble(),   100.0);

    // Column & grand totals.
    const QVariantList colTotals = p["colTotals"].toList();
    QCOMPARE(colTotals.at(0).toDouble(), 115.0); // Q1: 15 + 100
    QCOMPARE(colTotals.at(1).toDouble(), 20.0);  // Q2
    QCOMPARE(p["grandTotal"].toDouble(), 135.0);

    // count ignores the value column and tallies rows, including the NULL amount.
    const QVariantMap c = model.pivot(0, 1, -1, "count");
    QCOMPARE(c["grandTotal"].toInt(), 5);
    const QVariantList cWest = c["rows"].toList().at(1).toMap()["cells"].toList();
    QCOMPARE(cWest.at(1).toInt(), 1);            // west/Q2 has one row despite NULL

    // Out-of-range column → empty map.
    QVERIFY(model.pivot(9, 1, 2, "sum").isEmpty());
}

// ── CsvImporter ─────────────────────────────────────────────────────────────

// Helper: write text to a temp file and return its path.
static QString writeTemp(QTemporaryDir &dir, const QString &name, const QString &content)
{
    const QString path = dir.filePath(name);
    QFile f(path);
    f.open(QIODevice::WriteOnly | QIODevice::Text);
    f.write(content.toUtf8());
    f.close();
    return path;
}

void TestCore::csv_previewInfersTypes()
{
    QTemporaryDir dir;
    const QString path = writeTemp(dir, "people.csv",
        "id,name,score\n"
        "1,Alice,9.5\n"
        "2,Bob,8\n"
        "3,Carol,\n");

    CsvImporter imp;
    const QVariantMap p = imp.preview(QUrl::fromLocalFile(path));
    QVERIFY(p["success"].toBool());
    QCOMPARE(p["delimiter"].toString(), QStringLiteral(","));
    QCOMPARE(p["table"].toString(),     QStringLiteral("people"));

    const QVariantList cols = p["columns"].toList();
    QCOMPARE(cols.size(), 3);
    QCOMPARE(cols.at(0).toMap()["name"].toString(), QStringLiteral("id"));
    QCOMPARE(cols.at(0).toMap()["type"].toString(), QStringLiteral("INTEGER"));
    QCOMPARE(cols.at(1).toMap()["type"].toString(), QStringLiteral("TEXT"));
    // Mixed 9.5 / 8 / blank → REAL (blank ignored, not forced to TEXT).
    QCOMPARE(cols.at(2).toMap()["type"].toString(), QStringLiteral("REAL"));

    // Three data rows sampled.
    QCOMPARE(p["rows"].toList().size(), 3);
}

void TestCore::csv_importCreatesQueryableTable()
{
    QTemporaryDir dir;
    const QString path = writeTemp(dir, "nums.csv",
        "n,label\n"
        "10,a\n"
        "20,b\n"
        "30,a\n");

    CsvImporter imp;
    const QVariantMap r = imp.import(QUrl::fromLocalFile(path));
    QVERIFY2(r["success"].toBool(), qPrintable(r["error"].toString()));
    QCOMPARE(r["table"].toString(),      QStringLiteral("nums"));
    QCOMPARE(r["rowCount"].toInt(),      3);
    QCOMPARE(r["columnCount"].toInt(),   2);

    const QString dbPath = r["database"].toString();
    QVERIFY(QFile::exists(dbPath));

    // The produced SQLite file is queryable as an ordinary database.
    {
        QSqlDatabase db = QSqlDatabase::addDatabase("QSQLITE", "csv_test_conn");
        db.setDatabaseName(dbPath);
        QVERIFY(db.open());
        QSqlQuery q(db);
        QVERIFY(q.exec("SELECT SUM(n) FROM \"nums\" WHERE label = 'a'"));
        QVERIFY(q.next());
        QCOMPARE(q.value(0).toInt(), 40);   // 10 + 30
        db.close();
    }
    QSqlDatabase::removeDatabase("csv_test_conn");
}

void TestCore::csv_quotedFieldsAndDelimiterSniff()
{
    QTemporaryDir dir;
    // Tab-delimited, with a quoted field containing a tab, a comma and a newline.
    const QString path = writeTemp(dir, "q.tsv",
        "id\tnote\n"
        "1\t\"has\ta tab, and\nnewline\"\n"
        "2\tplain\n");

    CsvImporter imp;
    const QVariantMap p = imp.preview(QUrl::fromLocalFile(path));
    QVERIFY(p["success"].toBool());
    QCOMPARE(p["delimiter"].toString(), QStringLiteral("\t"));
    // Two data rows despite the embedded newline inside the quoted field.
    QCOMPARE(p["rows"].toList().size(), 2);
    const QString note = p["rows"].toList().at(0).toList().at(1).toString();
    QVERIFY(note.contains('\t'));
    QVERIFY(note.contains('\n'));
    QVERIFY(note.contains(QStringLiteral("and")));
}

void TestCore::csv_importIntoExistingAddsTable()
{
    QTemporaryDir dir;
    const QString aPath = writeTemp(dir, "orders.csv",
        "id,customer\n"
        "1,alice\n"
        "2,bob\n");
    const QString bPath = writeTemp(dir, "customers.csv",
        "customer,city\n"
        "alice,paris\n"
        "bob,berlin\n");

    CsvImporter imp;
    // First CSV creates the database.
    const QVariantMap r1 = imp.import(QUrl::fromLocalFile(aPath));
    QVERIFY2(r1["success"].toBool(), qPrintable(r1["error"].toString()));
    const QString dbPath = r1["database"].toString();

    // Second CSV joins it as a new table in the *same* database.
    const QVariantMap r2 = imp.importInto(dbPath, QUrl::fromLocalFile(bPath),
                                          QStringLiteral("customers"));
    QVERIFY2(r2["success"].toBool(), qPrintable(r2["error"].toString()));
    QCOMPARE(r2["table"].toString(),    QStringLiteral("customers"));
    QCOMPARE(r2["rowCount"].toInt(),    2);
    QCOMPARE(r2["database"].toString(), dbPath);

    // Both tables live in one database, so a plain SQL join works.
    {
        QSqlDatabase db = QSqlDatabase::addDatabase("QSQLITE", "csv_join_conn");
        db.setDatabaseName(dbPath);
        QVERIFY(db.open());
        QSqlQuery q(db);
        QVERIFY2(q.exec("SELECT c.city FROM \"orders\" o "
                        "JOIN \"customers\" c ON o.customer = c.customer "
                        "WHERE o.id = 2"),
                 qPrintable(q.lastError().text()));
        QVERIFY(q.next());
        QCOMPARE(q.value(0).toString(), QStringLiteral("berlin"));
        db.close();
    }
    QSqlDatabase::removeDatabase("csv_join_conn");

    // Importing a table whose name already exists is rejected.
    const QVariantMap r3 = imp.importInto(dbPath, QUrl::fromLocalFile(bPath),
                                          QStringLiteral("customers"));
    QVERIFY(!r3["success"].toBool());
    QVERIFY(r3["error"].toString().contains("already exists"));
}

// ── ExplainPlan ────────────────────────────────────────────────────────────────

void TestCore::explain_buildsTreeFromParents()
{
    // Mimic `EXPLAIN QUERY PLAN` rows (id, parent, notused, detail): a nested-loop
    // join whose two SCAN legs hang off a common parent node id=3.
    QList<QVariantList> rows = {
        { 3, 0, 0, QStringLiteral("MATERIALIZE 1") },
        { 5, 3, 0, QStringLiteral("SCAN a") },
        { 9, 3, 0, QStringLiteral("SEARCH b USING INDEX b_pk (id=?)") },
    };

    const QVariantMap plan = ExplainPlan::buildSqlite(rows);
    QVERIFY(plan.value("success").toBool());
    QCOMPARE(plan.value("driver").toString(), QStringLiteral("sqlite"));

    const QVariantMap root = plan.value("root").toMap();
    QCOMPARE(root.value("label").toString(), QStringLiteral("QUERY PLAN"));

    // The single real root (id=3) nests under the synthetic QUERY PLAN root.
    const QVariantList top = root.value("children").toList();
    QCOMPARE(top.size(), 1);
    const QVariantMap materialize = top.first().toMap();
    QCOMPARE(materialize.value("label").toString(), QStringLiteral("MATERIALIZE"));

    // Both scan legs are attached as children of id=3, in row order.
    const QVariantList legs = materialize.value("children").toList();
    QCOMPARE(legs.size(), 2);
    QCOMPARE(legs.at(0).toMap().value("label").toString(),  QStringLiteral("SCAN"));
    QCOMPARE(legs.at(0).toMap().value("detail").toString(), QStringLiteral("a"));
    // A SCAN (no index) is a full scan → hot + a warning; a SEARCH USING INDEX is not.
    QVERIFY(legs.at(0).toMap().value("hot").toBool());
    QVERIFY(!legs.at(1).toMap().value("hot").toBool());

    const QStringList warnings = plan.value("warnings").toStringList();
    QCOMPARE(warnings.size(), 1);
    QVERIFY(warnings.first().contains(QStringLiteral("SCAN a")));
}

void TestCore::explain_flagsFullScanFromRealSqlite()
{
    // Drive the builder with genuine SQLite EXPLAIN QUERY PLAN output so the parsing
    // tracks what the engine actually emits, not just our synthetic shape.
    QSqlDatabase db = QSqlDatabase::addDatabase("QSQLITE", "explain_conn");
    db.setDatabaseName(":memory:");
    QVERIFY(db.open());
    {
        QSqlQuery q(db);
        QVERIFY(q.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)"));
        QVERIFY(q.exec("INSERT INTO t (name) VALUES ('a'), ('b'), ('c')"));

        auto planFor = [&](const QString &sql) -> QVariantMap {
            QSqlQuery e(db);
            if (!e.exec("EXPLAIN QUERY PLAN " + sql))
                return {};
            QList<QVariantList> rows;
            while (e.next())
                rows.append({ e.value(0), e.value(1), e.value(2), e.value(3) });
            return ExplainPlan::buildSqlite(rows);
        };

        // Filtering a non-indexed column forces a full table scan → hot + warning.
        const QVariantMap scan = planFor("SELECT * FROM t WHERE name = 'a'");
        const QVariantList scanKids = scan.value("root").toMap().value("children").toList();
        QVERIFY(!scanKids.isEmpty());
        QVERIFY2(scanKids.first().toMap().value("hot").toBool(),
                 "a WHERE on an unindexed column should be a hot full scan");
        QVERIFY(!scan.value("warnings").toStringList().isEmpty());

        // Looking up by the integer primary key uses the index → not hot, no warning.
        const QVariantMap seek = planFor("SELECT * FROM t WHERE id = 1");
        const QVariantList seekKids = seek.value("root").toMap().value("children").toList();
        QVERIFY(!seekKids.isEmpty());
        QVERIFY(!seekKids.first().toMap().value("hot").toBool());
        QVERIFY(seek.value("warnings").toStringList().isEmpty());
    }
    db.close();
    QSqlDatabase::removeDatabase("explain_conn");
}

// ── HistoryManager ────────────────────────────────────────────────────────────

void TestCore::history_limitPrunes()
{
    HistoryManager history;
    history.clear();
    history.setLimit(3);

    for (int i = 0; i < 5; ++i)
        history.add("conn", QStringLiteral("SELECT %1").arg(i), true, 1, 1);

    const QVariantList entries = history.entries(100);
    QCOMPARE(entries.size(), 3);
    // Newest kept, oldest pruned.
    QCOMPARE(entries.first().toMap().value("sql").toString(), QStringLiteral("SELECT 4"));
    QCOMPARE(entries.last().toMap().value("sql").toString(),  QStringLiteral("SELECT 2"));
}

void TestCore::history_searchLiteralWildcards()
{
    HistoryManager history;
    history.clear();
    history.setLimit(100);

    history.add("conn", "SELECT '100%' AS pct", true, 1, 1);
    history.add("conn", "SELECT 100 AS plain",  true, 1, 1);
    history.add("conn", "SELECT a_b FROM t",    true, 1, 1);
    history.add("conn", "SELECT axb FROM t",    true, 1, 1);

    // '%' must match literally, not as a wildcard.
    QCOMPARE(history.search("100%", 100).size(), 1);
    // '_' must match literally, not "any single character".
    QCOMPARE(history.search("a_b", 100).size(), 1);
}

void TestCore::history_fingerprintNormalises()
{
    // String and number literals collapse to '?'; whitespace normalises; a
    // trailing ';' is dropped — so these three group into one fingerprint.
    const QString a = HistoryManager::fingerprint("SELECT * FROM t WHERE id = 1");
    const QString b = HistoryManager::fingerprint("SELECT  *  FROM t  WHERE id = 42 ;");
    const QString c = HistoryManager::fingerprint("SELECT * FROM t WHERE id = 999999");
    QCOMPARE(a, b);
    QCOMPARE(a, c);
    QCOMPARE(a, QStringLiteral("SELECT * FROM t WHERE id = ?"));

    // Quoted strings (with doubled-quote escapes) also collapse.
    QCOMPARE(HistoryManager::fingerprint("SELECT * FROM t WHERE name = 'O''Brien'"),
             QStringLiteral("SELECT * FROM t WHERE name = ?"));

    // Structurally different queries keep distinct fingerprints.
    QVERIFY(HistoryManager::fingerprint("SELECT a FROM t")
            != HistoryManager::fingerprint("SELECT b FROM t"));
}

void TestCore::history_slowQueriesAggregates()
{
    HistoryManager history;
    history.clear();
    history.setLimit(1000);

    // Same shape, different literals → one group. Total 30ms, max 20, avg 10.
    history.add("db1", "SELECT * FROM t WHERE id = 1",  true,  1, 5);
    history.add("db1", "SELECT * FROM t WHERE id = 2",  true,  1, 20);
    history.add("db1", "SELECT * FROM t WHERE id = 3",  false, 0, 5);
    // A cheaper distinct query on the same connection.
    history.add("db1", "SELECT count(*) FROM t",        true,  1, 2);
    // Different connection — excluded when scoped to db1.
    history.add("db2", "SELECT * FROM t WHERE id = 9",  true,  1, 100);

    const QVariantList allGroups = history.slowQueries(10);
    // 2 groups on db1 + 1 on db2 = 3.
    QCOMPARE(allGroups.size(), 3);
    // Ranked by total time: db2's 100ms group leads.
    QCOMPARE(allGroups.first().toMap().value("connectionName").toString(),
             QStringLiteral("db2"));

    // Scope to db1 and inspect the hot group.
    const QVariantList db1 = history.slowQueries(10, "db1");
    QCOMPARE(db1.size(), 2);
    const QVariantMap hot = db1.first().toMap();
    QCOMPARE(hot.value("calls").toInt(),    3);
    QCOMPARE(hot.value("totalMs").toLongLong(), qint64(30));
    QCOMPARE(hot.value("maxMs").toLongLong(),   qint64(20));
    QCOMPARE(hot.value("avgMs").toDouble(),     10.0);
    QCOMPARE(hot.value("failures").toInt(),  1);
    // Representative SQL is the most recent actual statement in the group.
    QCOMPARE(hot.value("sql").toString(),
             QStringLiteral("SELECT * FROM t WHERE id = 3"));

    history.clear();
}

// ── ResultModel expectations ──────────────────────────────────────────────────

void TestCore::expectations_evaluateChecks()
{
    QueryResult r;
    r.success = true;
    r.columns = { "id", "email", "age" };
    r.rows = {
        { 1,          "a@x.com",  30 },
        { 2,          "b@x.com",  -5 },        // age fails positive/range
        { 3,          QVariant(), 40 },        // email NULL → not_null/not_empty fail
        { 1,          "d@x.com",  25 },        // id duplicate of row 0
        { 5,          "not-mail", 200 },       // email fails regex, age fails range
    };

    ResultModel model;
    model.setResult(r);

    auto run = [&](const QString &col, const QString &check, const QString &arg) {
        QVariantList rules;
        rules << QVariantMap{{"column", col}, {"check", check}, {"arg", arg}};
        return model.checkExpectations(rules).first().toMap();
    };

    // not_null on email — one NULL.
    const QVariantMap nn = run("email", "not_null", "");
    QCOMPARE(nn.value("passed").toBool(),     false);
    QCOMPARE(nn.value("violations").toInt(),  1);
    QCOMPARE(nn.value("checked").toInt(),     5);

    // unique on id — value "1" appears twice → 2 offending rows.
    const QVariantMap uq = run("id", "unique", "");
    QCOMPARE(uq.value("passed").toBool(),    false);
    QCOMPARE(uq.value("violations").toInt(), 2);

    // positive on age — the -5 fails (NULL none here); 200 passes positivity.
    const QVariantMap pos = run("age", "positive", "");
    QCOMPARE(pos.value("violations").toInt(), 1);

    // range on age 0..100 — -5 and 200 fail.
    const QVariantMap rng = run("age", "range", "0,100");
    QCOMPARE(rng.value("violations").toInt(), 2);
    QVERIFY(!rng.contains("error"));

    // matches on email — the NULL and "not-mail" fail a simple address pattern.
    const QVariantMap rx = run("email", "matches", "[^@]+@[^@]+\\.[^@]+");
    QCOMPARE(rx.value("violations").toInt(), 2);

    // A passing check reports passed=true, zero violations, no sample.
    const QVariantMap ok = run("id", "not_null", "");
    QCOMPARE(ok.value("passed").toBool(),    true);
    QCOMPARE(ok.value("violations").toInt(), 0);
    QVERIFY(!ok.contains("sample"));

    // Unknown column → error, not passed.
    const QVariantMap bad = run("nope", "not_null", "");
    QCOMPARE(bad.value("passed").toBool(), false);
    QVERIFY(bad.contains("error"));

    // Bad arg (range without two numbers) → error.
    const QVariantMap badArg = run("age", "range", "abc");
    QVERIFY(badArg.contains("error"));
    QCOMPARE(badArg.value("passed").toBool(), false);

    // Filter narrows the evaluated row set.
    model.setFilterText("x.com");   // rows 0,1,3 (emails contain x.com)
    const QVariantMap filtered = run("age", "positive", "");
    QCOMPARE(filtered.value("checked").toInt(),    3);
    QCOMPARE(filtered.value("violations").toInt(), 1); // only the -5 remains
    model.setFilterText("");
}

// ── ResultDiff ────────────────────────────────────────────────────────────────

void TestCore::resultDiff_keyedAndWholeRow()
{
    const QStringList cols = { "id", "name" };

    const QList<QVariantList> base = {
        { 1, "alice" },
        { 2, "bob" },
        { 3, "carol" },
    };
    const QList<QVariantList> cur = {
        { 1, "alice" },     // unchanged
        { 2, "bobby" },     // name changed
        { 4, "dave" },      // added
        // id 3 (carol) removed
    };

    // Keyed diff on column 0.
    const QVariantMap kd = ResultDiff::compare(cols, base, cols, cur, 0);
    QVERIFY(kd.value("columnsMatch").toBool());
    QVERIFY(kd.value("differs").toBool());
    const QVariantMap ks = kd.value("summary").toMap();
    QCOMPARE(ks.value("same").toInt(),    1);
    QCOMPARE(ks.value("changed").toInt(), 1);
    QCOMPARE(ks.value("added").toInt(),   1);
    QCOMPARE(ks.value("removed").toInt(), 1);

    // Find the changed row and confirm it flags column 1 (name).
    QVariantMap changedRow;
    for (const QVariant &rv : kd.value("rows").toList()) {
        const QVariantMap r = rv.toMap();
        if (r.value("status").toString() == "changed") changedRow = r;
    }
    QCOMPARE(changedRow.value("key").toString(), QStringLiteral("2"));
    QCOMPARE(changedRow.value("changedCols").toList().first().toInt(), 1);
    QCOMPARE(changedRow.value("before").toList().at(1).toString(), QStringLiteral("bob"));
    QCOMPARE(changedRow.value("cells").toList().at(1).toString(),  QStringLiteral("bobby"));

    // Whole-row mode: the changed pair becomes one removed + one added, so
    // there is no "changed"; only exact-row matches count as same.
    const QVariantMap wr = ResultDiff::compare(cols, base, cols, cur, -1);
    const QVariantMap ws = wr.value("summary").toMap();
    QCOMPARE(ws.value("same").toInt(),    1);   // (1, alice)
    QCOMPARE(ws.value("changed").toInt(), 0);
    QCOMPARE(ws.value("added").toInt(),   2);   // (2,bobby) + (4,dave)
    QCOMPARE(ws.value("removed").toInt(), 2);   // (2,bob) + (3,carol)

    // Mismatched columns short-circuit.
    const QVariantMap mm = ResultDiff::compare({ "a" }, {}, { "b" }, {}, -1);
    QCOMPARE(mm.value("columnsMatch").toBool(), false);
    QCOMPARE(mm.value("rows").toList().size(), 0);
}

// ── SchemaDiff ──────────────────────────────────────────────────────────────

static QVariantMap mkCol(const QString &name, const QString &type, bool pk, bool nullable)
{
    return QVariantMap{{"name", name}, {"type", type}, {"pk", pk}, {"nullable", nullable}};
}

void TestCore::schemaDiff_detectsStructuralChanges()
{
    // Left ("A") schema
    const QVariantList left = {
        QVariantMap{{"name", "main"}, {"tables", QVariantList{
            QVariantMap{{"name", "users"}, {"type", "table"}, {"columns", QVariantList{
                mkCol("id",      "INTEGER", true,  false),
                mkCol("name",    "TEXT",    false, true),
                mkCol("old_col", "TEXT",    false, true),
            }}},
            QVariantMap{{"name", "orders"}, {"type", "table"}, {"columns", QVariantList{
                mkCol("id", "INTEGER", true, false),
            }}},
        }}},
    };

    // Right ("B") schema: users.name retyped + made NOT NULL, old_col dropped,
    // new_col added; orders table removed; products table added.
    const QVariantList right = {
        QVariantMap{{"name", "main"}, {"tables", QVariantList{
            QVariantMap{{"name", "users"}, {"type", "table"}, {"columns", QVariantList{
                mkCol("id",      "INTEGER", true,  false),
                mkCol("name",    "VARCHAR", false, false),
                mkCol("new_col", "TEXT",    false, true),
            }}},
            QVariantMap{{"name", "products"}, {"type", "table"}, {"columns", QVariantList{
                mkCol("id", "INTEGER", true, false),
            }}},
        }}},
    };

    const QVariantMap diff = SchemaDiff::compare(left, right);
    QVERIFY(diff.value("differs").toBool());

    const QVariantMap s = diff.value("summary").toMap();
    QCOMPARE(s.value("tablesAdded").toInt(),    1);   // products
    QCOMPARE(s.value("tablesRemoved").toInt(),  1);   // orders
    QCOMPARE(s.value("tablesChanged").toInt(),  1);   // users
    QCOMPARE(s.value("columnsAdded").toInt(),   1);   // users.new_col
    QCOMPARE(s.value("columnsRemoved").toInt(), 1);   // users.old_col
    QCOMPARE(s.value("columnsChanged").toInt(), 1);   // users.name

    // Walk into the "users" table and confirm the changed column carries the
    // differing attribute names.
    const QVariantList schemas = diff.value("schemas").toList();
    QCOMPARE(schemas.size(), 1);
    const QVariantList tables = schemas.first().toMap().value("tables").toList();

    QVariantMap users;
    for (const QVariant &t : tables)
        if (t.toMap().value("name").toString() == "users") users = t.toMap();
    QCOMPARE(users.value("status").toString(), QStringLiteral("changed"));

    QVariantMap nameCol;
    for (const QVariant &c : users.value("columns").toList())
        if (c.toMap().value("name").toString() == "name") nameCol = c.toMap();
    QCOMPARE(nameCol.value("status").toString(), QStringLiteral("changed"));
    const QStringList changes = nameCol.value("changes").toStringList();
    QVERIFY(changes.contains("type"));
    QVERIFY(changes.contains("nullable"));
    QVERIFY(!changes.contains("pk"));

    // A wholly added table's columns must not inflate columnsAdded.
    QVariantMap products;
    for (const QVariant &t : tables)
        if (t.toMap().value("name").toString() == "products") products = t.toMap();
    QCOMPARE(products.value("status").toString(), QStringLiteral("added"));
}

void TestCore::schemaSnapshot_captureRoundTripAndDiff()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString dbPath = dir.filePath("snap.db");

    const QVariantList baseSchema = {
        QVariantMap{{"name", "main"}, {"tables", QVariantList{
            QVariantMap{{"name", "users"}, {"type", "table"}, {"columns", QVariantList{
                mkCol("id",   "INTEGER", true,  false),
                mkCol("name", "TEXT",    false, true),
            }}},
            QVariantMap{{"name", "orders"}, {"type", "table"}, {"columns", QVariantList{
                mkCol("id", "INTEGER", true, false),
            }}},
        }}},
    };
    const QVariantList liveSchema = {
        QVariantMap{{"name", "main"}, {"tables", QVariantList{
            QVariantMap{{"name", "users"}, {"type", "table"}, {"columns", QVariantList{
                mkCol("id",    "INTEGER", true,  false),
                mkCol("name",  "TEXT",    false, true),
                mkCol("email", "TEXT",    false, true),   // new column
            }}},
            // orders dropped
        }}},
    };

    SchemaSnapshotManager mgr(dbPath);
    const qint64 id = mgr.capture("baseline", "conn1", baseSchema);
    QVERIFY(id > 0);

    // Metadata
    const QVariantList snaps = mgr.snapshots();
    QCOMPARE(snaps.size(), 1);
    const QVariantMap m = snaps.first().toMap();
    QCOMPARE(m.value("name").toString(),           QStringLiteral("baseline"));
    QCOMPARE(m.value("connectionName").toString(), QStringLiteral("conn1"));
    QCOMPARE(m.value("tableCount").toInt(),        2);

    // Round-trip: stored JSON deserializes back to the same structure.
    const QVariantList restored = mgr.schemaOf(id);
    QCOMPARE(restored, baseSchema);

    // Diff live schema against the saved snapshot.
    const QVariantMap diff = mgr.diffLive(id, liveSchema);
    QVERIFY(diff.value("differs").toBool());
    const QVariantMap s = diff.value("summary").toMap();
    QCOMPARE(s.value("tablesRemoved").toInt(), 1);   // orders
    QCOMPARE(s.value("columnsAdded").toInt(),  1);   // users.email

    // Bad id → empty results.
    QVERIFY(mgr.schemaOf(9999).isEmpty());
    QVERIFY(mgr.diffLive(9999, liveSchema).isEmpty());

    // Removal.
    QVERIFY(mgr.remove(id));
    QCOMPARE(mgr.snapshots().size(), 0);
}

void TestCore::healthAlert_evaluateAndEdgeTrigger()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    HealthAlertManager mgr(nullptr, dir.filePath("alerts.db"));

    const qint64 idConn = mgr.addRule("c1", "Active connections", "gt", 100);
    const qint64 idHit  = mgr.addRule("c1", "Cache hit ratio",    "lt", 90);
    QVERIFY(idConn > 0);
    QVERIFY(idHit  > 0);

    // Rules are scoped per connection.
    QCOMPARE(mgr.rulesFor("c1").size(), 2);
    QCOMPARE(mgr.rulesFor("other").size(), 0);

    auto breachedIds = [](const QVariantList &l) {
        QSet<qint64> s;
        for (const QVariant &v : l)
            if (v.toMap().value("breached").toBool())
                s.insert(v.toMap().value("id").toLongLong());
        return s;
    };

    // Below/above thresholds → nothing breached. A missing metric → value null.
    QVariantMap ok{{"Active connections", 50}, {"Cache hit ratio", 95}};
    QVERIFY(breachedIds(mgr.evaluate("c1", ok)).isEmpty());

    QVariantMap bad{{"Active connections", 150}, {"Cache hit ratio", 80}};
    QCOMPARE(breachedIds(mgr.evaluate("c1", bad)), (QSet<qint64>{idConn, idHit}));

    // Missing metric is never a breach.
    QVariantMap partial{{"Active connections", 150}};
    QCOMPARE(breachedIds(mgr.evaluate("c1", partial)), (QSet<qint64>{idConn}));

    // Edge-triggered notifications.
    QSignalSpy raised(&mgr,  &HealthAlertManager::alertRaised);
    QSignalSpy cleared(&mgr, &HealthAlertManager::alertCleared);

    mgr.checkAndNotify("c1", bad);
    QCOMPARE(raised.count(), 2);        // both entered breach
    mgr.checkAndNotify("c1", bad);
    QCOMPARE(raised.count(), 2);        // still breached → no new alert (edge, not level)
    mgr.checkAndNotify("c1", ok);
    QCOMPARE(cleared.count(), 2);       // both recovered

    // Disabling a rule drops it from evaluation.
    QVERIFY(mgr.setEnabled(idHit, false));
    QCOMPARE(mgr.evaluate("c1", bad).size(), 1);

    QVERIFY(mgr.removeRule(idConn));
    QCOMPARE(mgr.rulesFor("c1").size(), 1);
}

void TestCore::resultSnapshot_captureRoundTrip()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    ResultSnapshotManager mgr(dir.filePath("results.db"));

    // A snapshot map shaped like ResultModel::snapshot(): { columns, rows, rowCount }.
    QVariantMap snap{
        {"columns",  QVariantList{"id", "name"}},
        {"rows",     QVariantList{QVariantList{1, "a"}, QVariantList{2, "b"}}},
        {"rowCount", 2},
    };

    QSignalSpy changed(&mgr, &ResultSnapshotManager::changed);
    const qint64 id = mgr.capture("before migration", "c1", "SELECT * FROM t", snap);
    QVERIFY(id > 0);
    QCOMPARE(changed.count(), 1);

    // Metadata is surfaced, newest first.
    const QVariantList list = mgr.snapshots();
    QCOMPARE(list.size(), 1);
    const QVariantMap meta = list.first().toMap();
    QCOMPARE(meta.value("name").toString(),           QStringLiteral("before migration"));
    QCOMPARE(meta.value("connectionName").toString(), QStringLiteral("c1"));
    QCOMPARE(meta.value("sql").toString(),            QStringLiteral("SELECT * FROM t"));
    QCOMPARE(meta.value("rowCount").toInt(),          2);
    QCOMPARE(meta.value("colCount").toInt(),          2);

    // The stored payload round-trips back to the { columns, rows, rowCount } map.
    const QVariantMap loaded = mgr.snapshotOf(id);
    QCOMPARE(loaded.value("columns").toList(), (QVariantList{"id", "name"}));
    QCOMPARE(loaded.value("rowCount").toInt(), 2);
    const QVariantList rows = loaded.value("rows").toList();
    QCOMPARE(rows.size(), 2);
    QCOMPARE(rows.at(1).toList().at(1).toString(), QStringLiteral("b"));

    // A bad id yields an empty map, not a crash.
    QVERIFY(mgr.snapshotOf(999999).isEmpty());

    // Removal clears it and notifies.
    QVERIFY(mgr.remove(id));
    QCOMPARE(mgr.snapshots().size(), 0);
    QCOMPARE(changed.count(), 2);   // one from capture, one from remove
}

void TestCore::log_persistsAcrossRestart()
{
    {
        LogManager lm;
        lm.clear();
        lm.post("error", "QUERY", "c1", "boom", {{"sql", "SELECT 1"}});
        lm.post("info",  "CONN",  "c1", "connected");
    }   // destroyed — a fresh instance must reload from SQLite

    LogManager lm2;
    QCOMPARE(lm2.entries().size(), 2);
    QCOMPARE(lm2.errorCount(), 1);

    const auto e = lm2.entries().first().toMap();
    QCOMPARE(e["message"].toString(), QStringLiteral("boom"));
    QCOMPARE(e["detail"].toMap()["sql"].toString(), QStringLiteral("SELECT 1"));
    // The stamp carries the date, not just the clock. Checked against the
    // entry's own epoch rather than against "today", so the assertion cannot
    // fail for having run across midnight.
    QCOMPARE(e["timestamp"].toString(),
             QDateTime::fromMSecsSinceEpoch(e["epoch"].toLongLong())
                 .toString("yyyy-MM-dd HH:mm:ss.zzz"));
    QVERIFY(e["epoch"].toLongLong() > 0);

    // New entries continue with unique ids after reload.
    lm2.post("warn", "SSH", "c1", "later");
    const auto ids = lm2.entries();
    QVERIFY(ids[2].toMap()["id"].toLongLong() > ids[1].toMap()["id"].toLongLong());

    lm2.clear();
}

// ── DockerDiscovery::parseContainers ──────────────────────────────────────────
// Fixtures mimic the JSON array printed by `docker inspect <ids…>`.

void TestCore::docker_parsesPostgres()
{
    const QByteArray json = R"([
      {
        "Name": "/pg-prod",
        "Config": {
          "Image": "postgres:16",
          "Env": ["POSTGRES_USER=alice","POSTGRES_PASSWORD=s3cret","POSTGRES_DB=shop"]
        },
        "NetworkSettings": {
          "Ports": { "5432/tcp": [ { "HostIp": "0.0.0.0", "HostPort": "5432" } ] }
        }
      }
    ])";

    const QVariantList out = DockerDiscovery::parseContainers(json);
    QCOMPARE(out.size(), 1);
    const QVariantMap c = out.first().toMap();
    QCOMPARE(c["name"].toString(),     QString("pg-prod"));
    QCOMPARE(c["driver"].toString(),   QString("QPSQL"));
    QCOMPARE(c["host"].toString(),     QString("127.0.0.1"));
    QCOMPARE(c["port"].toInt(),        5432);
    QCOMPARE(c["username"].toString(), QString("alice"));
    QCOMPARE(c["password"].toString(), QString("s3cret"));
    QCOMPARE(c["database"].toString(), QString("shop"));
}

void TestCore::docker_mysqlRootFallbackAndMappedPort()
{
    // No MYSQL_USER → falls back to root + MYSQL_ROOT_PASSWORD. The container's
    // 3306 is published on a non-default host port (49154) — the whole reason
    // to inspect rather than assume the default.
    const QByteArray json = R"([
      {
        "Name": "/my-db",
        "Config": {
          "Image": "mysql:8",
          "Env": ["MYSQL_ROOT_PASSWORD=rootpw","MYSQL_DATABASE=inventory"]
        },
        "NetworkSettings": {
          "Ports": { "3306/tcp": [ { "HostIp": "0.0.0.0", "HostPort": "49154" } ] }
        }
      }
    ])";

    const QVariantList out = DockerDiscovery::parseContainers(json);
    QCOMPARE(out.size(), 1);
    const QVariantMap c = out.first().toMap();
    QCOMPARE(c["driver"].toString(),   QString("QMYSQL"));
    QCOMPARE(c["port"].toInt(),        49154);
    QCOMPARE(c["username"].toString(), QString("root"));
    QCOMPARE(c["password"].toString(), QString("rootpw"));
    QCOMPARE(c["database"].toString(), QString("inventory"));
}

void TestCore::docker_skipsUnpublishedAndUnknown()
{
    // Three containers: a Postgres reachable only on a Docker network (no host
    // binding), a Redis (unsupported engine), and a MariaDB that IS published.
    // Only the last should survive, and mariadb must not be read as mysql.
    const QByteArray json = R"([
      {
        "Name": "/pg-internal",
        "Config": { "Image": "postgres:15", "Env": ["POSTGRES_PASSWORD=x"] },
        "NetworkSettings": { "Ports": { "5432/tcp": null } }
      },
      {
        "Name": "/cache",
        "Config": { "Image": "redis:7", "Env": [] },
        "NetworkSettings": { "Ports": { "6379/tcp": [ { "HostIp": "0.0.0.0", "HostPort": "6379" } ] } }
      },
      {
        "Name": "/maria",
        "Config": { "Image": "mariadb:11", "Env": ["MARIADB_USER=bob","MARIADB_PASSWORD=pw","MARIADB_DATABASE=app"] },
        "NetworkSettings": { "Ports": { "3306/tcp": [ { "HostIp": "0.0.0.0", "HostPort": "3307" } ] } }
      }
    ])";

    const QVariantList out = DockerDiscovery::parseContainers(json);
    QCOMPARE(out.size(), 1);
    const QVariantMap c = out.first().toMap();
    QCOMPARE(c["name"].toString(),     QString("maria"));
    QCOMPARE(c["driver"].toString(),   QString("QMARIADB"));
    QCOMPARE(c["port"].toInt(),        3307);
    QCOMPARE(c["username"].toString(), QString("bob"));
    QCOMPARE(c["database"].toString(), QString("app"));
}

void TestCore::docker_ignoresGarbageJson()
{
    QVERIFY(DockerDiscovery::parseContainers("").isEmpty());
    QVERIFY(DockerDiscovery::parseContainers("not json").isEmpty());
    QVERIFY(DockerDiscovery::parseContainers("{}").isEmpty());   // object, not array
    QVERIFY(DockerDiscovery::parseContainers("[]").isEmpty());
}

// ── Saved-list ordering (listsort.js) ───────────────────────────────────────────

// Returns the "name" of every row, in order, as a comma-joined string — which
// is the only thing these tests care about and reads far better in a failure
// message than a nested QVariantList dump.
static QString namesOf(QJSEngine &js, const QString &expr)
{
    return js.evaluate(QStringLiteral("(%1).map(function(x){return x.name}).join(',')")
                       .arg(expr)).toString();
}

void TestCore::listsort_sortsByNameBothWays()
{
    const QString items = QStringLiteral(
        "[{name:'staging'},{name:'analytics'},{name:'prod'}]");

    QCOMPARE(namesOf(m_js, QStringLiteral("sortItems(%1,'name',true)").arg(items)),
             QStringLiteral("analytics,prod,staging"));
    QCOMPARE(namesOf(m_js, QStringLiteral("sortItems(%1,'name',false)").arg(items)),
             QStringLiteral("staging,prod,analytics"));
}

void TestCore::listsort_foldsCaseAndAccents()
{
    // A list of connection names as someone here would actually type them:
    // mixed case, and accents that must not exile a name to the end.
    const QString items = QStringLiteral(
        "[{name:'Zebra'},{name:'analytics'},{name:'Produção'},{name:'producao_2'}]");
    QCOMPARE(namesOf(m_js, QStringLiteral("sortItems(%1,'name',true)").arg(items)),
             QStringLiteral("analytics,Produção,producao_2,Zebra"));

    // And the same folding drives the filter, so the accented name is reachable
    // from an unaccented keyboard.
    QCOMPARE(namesOf(m_js, QStringLiteral("filterItems(%1,'producao',['name'])").arg(items)),
             QStringLiteral("Produção,producao_2"));
    QCOMPARE(namesOf(m_js, QStringLiteral("filterItems(%1,'PRODUÇÃO',['name'])").arg(items)),
             QStringLiteral("Produção,producao_2"));
}

void TestCore::listsort_breaksTiesOnName()
{
    // Two workspaces opened in the same minute. Without a tiebreak their order
    // would depend on the sort's stability and could change between reloads.
    const QString items = QStringLiteral(
        "[{name:'beta',tabCount:3},{name:'alpha',tabCount:3},{name:'gamma',tabCount:1}]");

    QCOMPARE(namesOf(m_js, QStringLiteral("sortItems(%1,'tabCount',false)").arg(items)),
             QStringLiteral("alpha,beta,gamma"));
    // The tiebreak stays ascending even when the sort is descending, so the tied
    // pair does not reshuffle when the direction flips.
    QCOMPARE(namesOf(m_js, QStringLiteral("sortItems(%1,'tabCount',true)").arg(items)),
             QStringLiteral("gamma,alpha,beta"));
}

void TestCore::listsort_sortsDatesAndNumbers()
{
    const QString items = QStringLiteral(
        "[{name:'old',t:new Date(2020,0,1)},"
        " {name:'new',t:new Date(2026,0,1)},"
        " {name:'mid',t:new Date(2023,0,1)}]");
    QCOMPARE(namesOf(m_js, QStringLiteral("sortItems(%1,'t',false)").arg(items)),
             QStringLiteral("new,mid,old"));

    // Numbers must not compare as text, or 10 would sort before 9.
    const QString nums = QStringLiteral("[{name:'a',n:9},{name:'b',n:10},{name:'c',n:1}]");
    QCOMPARE(namesOf(m_js, QStringLiteral("sortItems(%1,'n',true)").arg(nums)),
             QStringLiteral("c,a,b"));
}

void TestCore::listsort_filtersAcrossFields()
{
    // A data source is findable by what it connects to, not only by what it is
    // called — typing the host or the database name has to reach it.
    const QString items = QStringLiteral(
        "[{name:'reports',host:'db1.internal',database:'analytics'},"
        " {name:'billing',host:'db2.internal',database:'invoices'}]");
    const QString fields = QStringLiteral("['name','host','database']");

    QCOMPARE(namesOf(m_js, QStringLiteral("filterItems(%1,'db2',%2)").arg(items, fields)),
             QStringLiteral("billing"));
    QCOMPARE(namesOf(m_js, QStringLiteral("filterItems(%1,'analytics',%2)").arg(items, fields)),
             QStringLiteral("reports"));
    QCOMPARE(namesOf(m_js, QStringLiteral("filterItems(%1,'internal',%2)").arg(items, fields)),
             QStringLiteral("reports,billing"));
    QCOMPARE(namesOf(m_js, QStringLiteral("filterItems(%1,'nothing',%2)").arg(items, fields)),
             QString());
}

void TestCore::listsort_blankQueryKeepsEverything()
{
    // A cleared search box must restore the list, not empty it.
    const QString items = QStringLiteral("[{name:'a'},{name:'b'}]");
    QCOMPARE(namesOf(m_js, QStringLiteral("filterItems(%1,'',['name'])").arg(items)),
             QStringLiteral("a,b"));
    QCOMPARE(namesOf(m_js, QStringLiteral("filterItems(%1,'   ',['name'])").arg(items)),
             QStringLiteral("a,b"));
    QCOMPARE(namesOf(m_js, QStringLiteral("arrange(%1,'',['name'],'name',true)").arg(items)),
             QStringLiteral("a,b"));

    // A missing list is empty, not a crash.
    QCOMPARE(m_js.evaluate(QStringLiteral("arrange(null,'',['name'],'name',true).length")).toInt(), 0);
}

void TestCore::listsort_groupsSnippetsByFolder()
{
    const QString items = QStringLiteral(
        "[{name:'zed',folder:''},"
        " {name:'ratio',folder:'metrics'},"
        " {name:'churn',folder:'metrics'},"
        " {name:'vacuum',folder:'admin'},"
        " {name:'apex',folder:''}]");
    const QString f = QStringLiteral("['name','folder']");

    // Unfoldered snippets stay at the top in both directions; folders and their
    // contents both follow the chosen direction.
    QCOMPARE(namesOf(m_js, QStringLiteral("arrangeGrouped(%1,'',%2,'name',true)").arg(items, f)),
             QStringLiteral("apex,zed,vacuum,churn,ratio"));
    QCOMPARE(namesOf(m_js, QStringLiteral("arrangeGrouped(%1,'',%2,'name',false)").arg(items, f)),
             QStringLiteral("zed,apex,ratio,churn,vacuum"));

    // Filtering runs before grouping, so a folder with no surviving member
    // disappears entirely rather than leaving an empty header behind.
    QCOMPARE(namesOf(m_js, QStringLiteral("arrangeGrouped(%1,'metrics',%2,'name',true)").arg(items, f)),
             QStringLiteral("churn,ratio"));
}

// A stamp is only meaningful if it distinguishes a database whose shape is
// known from one whose shape nobody recorded. Both halves matter: the fresh
// file has to come out stamped, and the pre-existing one has to stay at 0.
void TestCore::schemaVersion_stampsOnlyAFreshDatabase()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());

    {
        QSqlDatabase db = QSqlDatabase::addDatabase("QSQLITE", "stamp_fresh");
        db.setDatabaseName(dir.filePath("fresh.db"));
        QVERIFY(db.open());
        QCOMPARE(AppDatabase::schemaVersion(db), 0);

        AppDatabase::stampIfNew(db);
        QCOMPARE(AppDatabase::schemaVersion(db), AppDatabase::kSchemaVersion);

        // Idempotent: a second manager opening the same file must not disturb
        // what the first one recorded.
        AppDatabase::stampIfNew(db);
        QCOMPARE(AppDatabase::schemaVersion(db), AppDatabase::kSchemaVersion);
    }
    QSqlDatabase::removeDatabase("stamp_fresh");

    {
        QSqlDatabase db = QSqlDatabase::addDatabase("QSQLITE", "stamp_legacy");
        db.setDatabaseName(dir.filePath("legacy.db"));
        QVERIFY(db.open());

        // Stands in for a database written before any of this existed: it has
        // tables and no version.
        QSqlQuery(db).exec("CREATE TABLE snippets (id INTEGER PRIMARY KEY)");

        AppDatabase::stampIfNew(db);
        QCOMPARE(AppDatabase::schemaVersion(db), 0);
    }
    QSqlDatabase::removeDatabase("stamp_legacy");
}

QTEST_GUILESS_MAIN(TestCore)
#include "tst_core.moc"
