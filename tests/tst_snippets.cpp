// Unit tests for SnippetManager: CRUD round-trips, ordering, validation,
// and persistence across re-open.
//
// Run with: ctest --test-dir build  (or ./build/qub_snippet_tests)

#include <QtTest>
#include <QTemporaryDir>
#include <QFile>

#include "core/SnippetManager.h"

class TestSnippets : public QObject {
    Q_OBJECT

private slots:
    void initTestCase();

    void saveAndList();
    void updateSnippet();
    void removeSnippet();
    void persistsAcrossReopen();
    void duplicateNamesRejected();
    void exportImportRoundTrip();
    void importSkipsDuplicates();
    void importRejectsBadFiles();

private:
    QString freshDbPath(const QString &name);
    QTemporaryDir m_dir;
};

void TestSnippets::initTestCase()
{
    QVERIFY(m_dir.isValid());
}

QString TestSnippets::freshDbPath(const QString &name)
{
    return m_dir.path() + "/" + name + ".db";
}

void TestSnippets::saveAndList()
{
    SnippetManager mgr(freshDbPath("list"));
    QVERIFY(mgr.snippets().isEmpty());

    QVERIFY(mgr.save("Zeta", "", "SELECT 1") > 0);
    QVERIFY(mgr.save("alpha", "", "SELECT 2") > 0);
    QVERIFY(mgr.save("Mid", "Reports", "SELECT 3") > 0);

    // Blank names are rejected.
    QCOMPARE(mgr.save("   ", "", "SELECT 4"), qint64(-1));

    const QVariantList list = mgr.snippets();
    QCOMPARE(list.size(), 3);

    // Ordered by folder first, then name case-insensitively.
    QCOMPARE(list[0].toMap().value("name").toString(), QString("alpha"));
    QCOMPARE(list[1].toMap().value("name").toString(), QString("Zeta"));
    QCOMPARE(list[2].toMap().value("folder").toString(), QString("Reports"));

    QCOMPARE(list[1].toMap().value("sql").toString(), QString("SELECT 1"));
}

void TestSnippets::updateSnippet()
{
    SnippetManager mgr(freshDbPath("update"));
    const qint64 id = mgr.save("Orig", "A", "SELECT 1");
    QVERIFY(id > 0);

    QVERIFY(mgr.update(id, "Renamed", "B", "SELECT 99"));
    const QVariantMap entry = mgr.snippets().first().toMap();
    QCOMPARE(entry.value("name").toString(),   QString("Renamed"));
    QCOMPARE(entry.value("folder").toString(), QString("B"));
    QCOMPARE(entry.value("sql").toString(),    QString("SELECT 99"));

    QVERIFY(!mgr.update(id, "  ", "B", "SELECT 99"));   // blank name rejected
    QVERIFY(!mgr.update(9999, "Ghost", "", ""));        // unknown id
}

void TestSnippets::removeSnippet()
{
    SnippetManager mgr(freshDbPath("remove"));
    const qint64 id = mgr.save("Doomed", "", "SELECT 1");
    QVERIFY(mgr.remove(id));
    QVERIFY(mgr.snippets().isEmpty());
    QVERIFY(!mgr.remove(id));   // already gone
}

void TestSnippets::persistsAcrossReopen()
{
    const QString path = freshDbPath("reopen");
    qint64 id = -1;
    {
        SnippetManager mgr(path);
        id = mgr.save("Keep", "Folder", "SELECT 42");
        QVERIFY(id > 0);
    }
    SnippetManager reopened(path);
    const QVariantList list = reopened.snippets();
    QCOMPARE(list.size(), 1);
    QCOMPARE(list.first().toMap().value("id").toLongLong(), id);
    QCOMPARE(list.first().toMap().value("sql").toString(), QString("SELECT 42"));
}

void TestSnippets::duplicateNamesRejected()
{
    SnippetManager mgr(freshDbPath("dupnames"));
    const qint64 daily = mgr.save("Daily", "Reports", "SELECT 1");
    QVERIFY(daily > 0);

    // Same name+folder is rejected, case-insensitively and trimmed.
    QCOMPARE(mgr.save("daily", "reports", "SELECT 2"), qint64(-1));
    QCOMPARE(mgr.save("  Daily  ", "Reports", "SELECT 2"), qint64(-1));

    // Same name in a different folder is fine.
    const qint64 loose = mgr.save("Daily", "", "SELECT 3");
    QVERIFY(loose > 0);

    QVERIFY(mgr.nameInUse("DAILY", "REPORTS"));
    QVERIFY(!mgr.nameInUse("Daily", "Archive"));
    // A snippet does not collide with itself (edit keeping the name).
    QVERIFY(!mgr.nameInUse("Daily", "Reports", daily));
    QVERIFY(mgr.update(daily, "Daily", "Reports", "SELECT 99"));

    // Renaming onto an existing name+folder is rejected.
    QVERIFY(!mgr.update(loose, "daily", "Reports", "SELECT 3"));
    QCOMPARE(mgr.snippets().size(), 2);
}

void TestSnippets::exportImportRoundTrip()
{
    const QString jsonPath = m_dir.path() + "/snips.json";

    SnippetManager src(freshDbPath("exp-src"));
    QVERIFY(src.save("Daily", "Reports", "SELECT day") > 0);
    QVERIFY(src.save("Loose", "", "SELECT 1") > 0);
    QVERIFY(src.exportSnippets(QUrl::fromLocalFile(jsonPath)));

    SnippetManager dst(freshDbPath("exp-dst"));
    const QVariantMap result = dst.importSnippets(QUrl::fromLocalFile(jsonPath));
    QVERIFY(result.value("success").toBool());
    QCOMPARE(result.value("message").toString(), QString("Imported 2 snippet(s)."));

    const QVariantList list = dst.snippets();
    QCOMPARE(list.size(), 2);
    QCOMPARE(list[0].toMap().value("name").toString(),   QString("Loose"));
    QCOMPARE(list[0].toMap().value("sql").toString(),    QString("SELECT 1"));
    QCOMPARE(list[1].toMap().value("name").toString(),   QString("Daily"));
    QCOMPARE(list[1].toMap().value("folder").toString(), QString("Reports"));
    QCOMPARE(list[1].toMap().value("sql").toString(),    QString("SELECT day"));
}

void TestSnippets::importSkipsDuplicates()
{
    const QString jsonPath = m_dir.path() + "/dups.json";

    SnippetManager src(freshDbPath("dup-src"));
    QVERIFY(src.save("Daily", "Reports", "SELECT day") > 0);
    QVERIFY(src.save("Fresh", "", "SELECT new") > 0);
    QVERIFY(src.exportSnippets(QUrl::fromLocalFile(jsonPath)));

    SnippetManager dst(freshDbPath("dup-dst"));
    // Same name+folder counts as a duplicate even if the SQL differs...
    QVERIFY(dst.save("Daily", "Reports", "SELECT other") > 0);
    // ...but the same name in another folder does not.
    QVERIFY(dst.save("Fresh", "Archive", "SELECT old") > 0);

    const QVariantMap result = dst.importSnippets(QUrl::fromLocalFile(jsonPath));
    QVERIFY(result.value("success").toBool());
    QCOMPARE(result.value("message").toString(),
             QString("Imported 1 snippet(s). Skipped 1 duplicate(s)."));
    QCOMPARE(dst.snippets().size(), 3);

    // Re-importing the same file is a full no-op.
    const QVariantMap again = dst.importSnippets(QUrl::fromLocalFile(jsonPath));
    QVERIFY(!again.value("success").toBool());
    QCOMPARE(again.value("message").toString(),
             QString("All snippets already exist. Nothing imported."));
    QCOMPARE(dst.snippets().size(), 3);
}

void TestSnippets::importRejectsBadFiles()
{
    SnippetManager mgr(freshDbPath("bad"));

    QVERIFY(!mgr.importSnippets(QUrl::fromLocalFile(m_dir.path() + "/missing.json"))
                 .value("success").toBool());

    const QString garbledPath = m_dir.path() + "/garbled.json";
    {
        QFile f(garbledPath);
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.write("{not json");
    }
    const QVariantMap garbled = mgr.importSnippets(QUrl::fromLocalFile(garbledPath));
    QVERIFY(!garbled.value("success").toBool());
    QVERIFY(garbled.value("message").toString().startsWith("Invalid file:"));

    // Valid JSON without usable snippets (blank names are skipped).
    const QString emptyPath = m_dir.path() + "/empty.json";
    {
        QFile f(emptyPath);
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.write(R"({"version":1,"snippets":[{"name":"  ","sql":"SELECT 1"}]})");
    }
    const QVariantMap empty = mgr.importSnippets(QUrl::fromLocalFile(emptyPath));
    QVERIFY(!empty.value("success").toBool());
    QCOMPARE(empty.value("message").toString(), QString("No valid snippets found in file."));
    QVERIFY(mgr.snippets().isEmpty());
}

QTEST_GUILESS_MAIN(TestSnippets)
#include "tst_snippets.moc"
