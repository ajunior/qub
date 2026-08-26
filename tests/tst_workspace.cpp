// Unit tests for WorkspaceManager: CRUD, duplicate-name rejection, connection-membership
// round-trips, and tab persistence.
//
// Run with: ctest --test-dir build  (or ./build/qub_workspace_tests)

#include <QtTest>
#include <QSqlDatabase>
#include <QSqlQuery>
#include <QTemporaryDir>

#include "core/WorkspaceManager.h"

class TestWorkspace : public QObject {
    Q_OBJECT

private slots:
    void initTestCase();

    void firstRunCreatesDefault();
    void createRenameDelete();
    void connectionsPersist();
    void connectionRenameReferences();
    void saveLoadTabsRoundTrip();
    void saveTabsIntoDeletedIdIsNoop();

private:
    QString freshDbPath(const QString &name);
    QTemporaryDir m_dir;
};

void TestWorkspace::initTestCase()
{
    QVERIFY(m_dir.isValid());
}

QString TestWorkspace::freshDbPath(const QString &name)
{
    return m_dir.path() + "/" + name + ".db";
}

void TestWorkspace::firstRunCreatesDefault()
{
    WorkspaceManager mgr(freshDbPath("first"));
    const QVariantList list = mgr.workspaces();
    QCOMPARE(list.size(), 1);
    const QVariantMap ws = list.first().toMap();
    QCOMPARE(ws.value("name").toString(), QString("Default"));
    QCOMPARE(ws.value("tabCount").toInt(), 0);
    QCOMPARE(mgr.activeWorkspaceId(), ws.value("id").toInt());
    QVERIFY(mgr.connections(mgr.activeWorkspaceId()).isEmpty());
}

void TestWorkspace::createRenameDelete()
{
    WorkspaceManager mgr(freshDbPath("crud"));
    const int defaultId = mgr.activeWorkspaceId();

    const int staging = mgr.createWorkspace("Staging", {"stage-db"});
    QVERIFY(staging > 0);

    // Duplicate names are rejected case-insensitively.
    QCOMPARE(mgr.createWorkspace("staging", {}), -1);
    QCOMPARE(mgr.createWorkspace("  ", {}), -1);

    const int prod = mgr.createWorkspace("Production", {});
    QVERIFY(prod > 0);
    QCOMPARE(mgr.workspaces().size(), 3);

    // Rename: to a taken name fails, to a fresh one succeeds.
    QVERIFY(!mgr.renameWorkspace(prod, "STAGING"));
    QVERIFY(mgr.renameWorkspace(prod, "Prod hotfix"));
    QVERIFY(!mgr.renameWorkspace(9999, "Ghost"));

    // Deleting the active workspace promotes the most recently opened one.
    mgr.setActiveWorkspaceId(staging);
    QCOMPARE(mgr.activeWorkspaceId(), staging);
    mgr.setActiveWorkspaceId(prod);          // prod now newest-opened
    mgr.deleteWorkspace(prod);
    QCOMPARE(mgr.workspaces().size(), 2);
    QCOMPARE(mgr.activeWorkspaceId(), staging);

    // Deleting everything recreates the default.
    mgr.deleteWorkspace(staging);
    mgr.deleteWorkspace(defaultId);
    QCOMPARE(mgr.workspaces().size(), 1);
    QCOMPARE(mgr.workspaces().first().toMap().value("name").toString(), QString("Default"));
    QVERIFY(mgr.activeWorkspaceId() > 0);
}

void TestWorkspace::connectionsPersist()
{
    const QString path = freshDbPath("members");
    int id = -1;
    {
        WorkspaceManager mgr(path);
        id = mgr.createWorkspace("Scoped", {"a", "b"});
        QCOMPARE(mgr.connections(id), QStringList({"a", "b"}));

        mgr.addConnection(id, "c");
        mgr.addConnection(id, "c");              // idempotent
        mgr.addConnection(id, "");               // ignored
        mgr.removeConnection(id, "a");
        QCOMPARE(mgr.connections(id), QStringList({"b", "c"}));

        mgr.setConnections(id, {"x"});
        QCOMPARE(mgr.connections(id), QStringList({"x"}));
    }
    // Workspace connections survive a re-open on the same file.
    WorkspaceManager reopened(path);
    QCOMPARE(reopened.connections(id), QStringList({"x"}));
}

void TestWorkspace::connectionRenameReferences()
{
    WorkspaceManager mgr(freshDbPath("rename_refs"));
    const int wsA = mgr.createWorkspace("Staging", {"stage-db", "shared"});
    const int wsB = mgr.createWorkspace("Production", {"prod-db", "stage-db"});

    mgr.saveTabs(wsA, {
        QVariantMap{{"connectionName", "stage-db"}, {"sql", "SELECT 1"},
                    {"cursorPosition", 0}, {"title", "Stage"}, {"isActive", true}},
        QVariantMap{{"connectionName", "other"}, {"sql", "SELECT 2"},
                    {"cursorPosition", 0}, {"title", "Other"}, {"isActive", false}}
    });
    mgr.saveTabs(wsB, {
        QVariantMap{{"connectionName", "stage-db"}, {"sql", "SELECT 3"},
                    {"cursorPosition", 0}, {"title", "Prod"}, {"isActive", true}}
    });

    mgr.renameConnectionReferences("stage-db", "prod-db");

    QCOMPARE(mgr.connections(wsA), QStringList({"prod-db", "shared"}));
    QCOMPARE(mgr.connections(wsB), QStringList({"prod-db"}));
    QCOMPARE(mgr.workspace(wsA).value("tabs").toList().first().toMap()
                 .value("connectionName").toString(),
             QString("prod-db"));
    QCOMPARE(mgr.workspace(wsA).value("tabs").toList().at(1).toMap()
                 .value("connectionName").toString(),
             QString("other"));
    QCOMPARE(mgr.workspace(wsB).value("tabs").toList().first().toMap()
                 .value("connectionName").toString(),
             QString("prod-db"));
}

void TestWorkspace::saveLoadTabsRoundTrip()
{
    WorkspaceManager mgr(freshDbPath("tabs"));
    const int id = mgr.createWorkspace("Tabs", {});

    QVariantList tabs;
    tabs << QVariantMap{{"connectionName", "prod"},  {"sql", "SELECT 1"}, {"cursorPosition", 3},
                        {"title", "Query 1"}, {"isActive", false}};
    tabs << QVariantMap{{"connectionName", "stage"}, {"sql", "SELECT 2"}, {"cursorPosition", 8},
                        {"title", "Audit"},   {"isActive", true}};
    mgr.saveTabs(id, tabs);

    QVariantMap ws = mgr.workspace(id);
    QCOMPARE(ws.value("name").toString(), QString("Tabs"));
    QVariantList out = ws.value("tabs").toList();
    QCOMPARE(out.size(), 2);
    QCOMPARE(out[0].toMap().value("connectionName").toString(), QString("prod"));
    QCOMPARE(out[0].toMap().value("cursorPosition").toInt(), 3);
    QCOMPARE(out[0].toMap().value("isActive").toBool(), false);
    QCOMPARE(out[1].toMap().value("title").toString(), QString("Audit"));
    QCOMPARE(out[1].toMap().value("isActive").toBool(), true);

    // A second save fully replaces the previous tab set.
    mgr.saveTabs(id, {QVariantMap{{"connectionName", "prod"}, {"sql", "SELECT 3"},
                                  {"cursorPosition", 0}, {"title", "Only"}, {"isActive", true}}});
    out = mgr.workspace(id).value("tabs").toList();
    QCOMPARE(out.size(), 1);
    QCOMPARE(out[0].toMap().value("sql").toString(), QString("SELECT 3"));

    QCOMPARE(mgr.workspace(9999).size(), 0);   // unknown id -> empty map
}

void TestWorkspace::saveTabsIntoDeletedIdIsNoop()
{
    const QString path = freshDbPath("noop");
    int id = -1;
    {
        WorkspaceManager mgr(path);
        id = mgr.createWorkspace("Doomed", {});
        mgr.deleteWorkspace(id);

        mgr.saveTabs(id, {QVariantMap{{"connectionName", "x"}, {"sql", "SELECT 1"}}});
        QCOMPARE(mgr.workspace(id).size(), 0);
    }

    // No orphan rows behind the dead id.
    {
        QSqlDatabase db = QSqlDatabase::addDatabase("QSQLITE", "noop_check");
        db.setDatabaseName(path);
        QVERIFY(db.open());
        QSqlQuery q(db);
        q.prepare("SELECT COUNT(*) FROM workspace_tabs WHERE workspace_id = ?");
        q.addBindValue(id);
        q.exec();
        QVERIFY(q.next());
        QCOMPARE(q.value(0).toInt(), 0);
        db.close();
    }
    QSqlDatabase::removeDatabase("noop_check");
}

QTEST_GUILESS_MAIN(TestWorkspace)
#include "tst_workspace.moc"
