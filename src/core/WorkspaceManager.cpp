#include "WorkspaceManager.h"
#include <QSqlQuery>
#include <QSqlError>
#include <QStandardPaths>
#include <QDir>
#include <QDateTime>

// Unique connection name per instance so tests can construct several managers
// (sequentially or on distinct files) without QSqlDatabase name collisions.
static int s_instanceCount = 0;

static QString nowIso()
{
    return QDateTime::currentDateTime().toString(Qt::ISODate);
}

WorkspaceManager::WorkspaceManager(const QString &dbPath, QObject *parent)
    : QObject(parent)
    , m_connectionName(QStringLiteral("qub_workspaces_%1").arg(++s_instanceCount))
{
    initDb(dbPath);
}

WorkspaceManager::~WorkspaceManager()
{
    m_db.close();
    m_db = QSqlDatabase();
    QSqlDatabase::removeDatabase(m_connectionName);
}

void WorkspaceManager::initDb(const QString &dbPath)
{
    QString path = dbPath;
    if (path.isEmpty()) {
        const QString dir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
        QDir().mkpath(dir);
        path = dir + "/qub.db";
    }

    m_db = QSqlDatabase::addDatabase("QSQLITE", m_connectionName);
    m_db.setDatabaseName(path);
    m_db.open();

    QSqlQuery q(m_db);
    q.exec("PRAGMA foreign_keys = ON");
    q.exec(R"(
        CREATE TABLE IF NOT EXISTS workspaces (
            id             INTEGER PRIMARY KEY AUTOINCREMENT,
            name           TEXT    NOT NULL,
            created_at     TEXT    NOT NULL,
            last_opened_at TEXT    NOT NULL,
            is_active      INTEGER NOT NULL DEFAULT 0
        )
    )");
    q.exec("CREATE UNIQUE INDEX IF NOT EXISTS idx_workspaces_name "
           "ON workspaces(name COLLATE NOCASE)");
    q.exec(R"(
        CREATE TABLE IF NOT EXISTS workspace_tabs (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            workspace_id    INTEGER NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
            tab_order       INTEGER NOT NULL,
            connection_name TEXT    NOT NULL DEFAULT '',
            sql             TEXT    NOT NULL DEFAULT '',
            cursor_position INTEGER NOT NULL DEFAULT 0,
            title           TEXT    NOT NULL DEFAULT '',
            is_active       INTEGER NOT NULL DEFAULT 0,
            file_path       TEXT    NOT NULL DEFAULT ''
        )
    )");
    q.exec("CREATE INDEX IF NOT EXISTS idx_workspace_tabs_ws ON workspace_tabs(workspace_id)");
    q.exec(R"(
        CREATE TABLE IF NOT EXISTS workspace_connections (
            workspace_id    INTEGER NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
            connection_name TEXT    NOT NULL,
            PRIMARY KEY (workspace_id, connection_name)
        )
    )");

    ensureDefaultWorkspace();
}

void WorkspaceManager::ensureDefaultWorkspace()
{
    QSqlQuery q(m_db);
    q.exec("SELECT COUNT(*) FROM workspaces");
    if (q.next() && q.value(0).toInt() == 0) {
        q.prepare("INSERT INTO workspaces (name, created_at, last_opened_at, is_active) "
                  "VALUES ('Default', ?, ?, 1)");
        q.addBindValue(nowIso());
        q.addBindValue(nowIso());
        q.exec();
        return;
    }
    // Repair: exactly one workspace must be active.
    q.exec("SELECT COUNT(*) FROM workspaces WHERE is_active = 1");
    if (q.next() && q.value(0).toInt() != 1) {
        q.exec("UPDATE workspaces SET is_active = 0");
        q.exec("UPDATE workspaces SET is_active = 1 WHERE id = "
               "(SELECT id FROM workspaces ORDER BY last_opened_at DESC, id DESC LIMIT 1)");
    }
}

bool WorkspaceManager::nameTaken(const QString &name, int excludeId) const
{
    QSqlQuery q(m_db);
    q.prepare("SELECT id FROM workspaces WHERE name = ? COLLATE NOCASE AND id != ?");
    q.addBindValue(name);
    q.addBindValue(excludeId);
    q.exec();
    return q.next();
}

QVariantList WorkspaceManager::workspaces() const
{
    QVariantList list;
    QSqlQuery q(m_db);
    q.exec(R"(
        SELECT w.id, w.name, w.last_opened_at,
               (SELECT COUNT(*) FROM workspace_tabs t WHERE t.workspace_id = w.id)
        FROM workspaces w ORDER BY w.last_opened_at DESC, w.id DESC
    )");
    while (q.next()) {
        QVariantMap ws;
        ws["id"]                = q.value(0);
        ws["name"]              = q.value(1);
        ws["lastOpenedAt"]      = q.value(2);
        ws["tabCount"]          = q.value(3);
        ws["connections"] = connections(q.value(0).toInt());
        list << ws;
    }
    return list;
}

int WorkspaceManager::activeWorkspaceId() const
{
    QSqlQuery q(m_db);
    q.exec("SELECT id FROM workspaces WHERE is_active = 1 LIMIT 1");
    return q.next() ? q.value(0).toInt() : -1;
}

void WorkspaceManager::setActiveWorkspaceId(int id)
{
    if (id == activeWorkspaceId()) return;
    QSqlQuery q(m_db);
    q.prepare("SELECT id FROM workspaces WHERE id = ?");
    q.addBindValue(id);
    q.exec();
    if (!q.next()) return;

    q.exec("UPDATE workspaces SET is_active = 0");
    q.prepare("UPDATE workspaces SET is_active = 1, last_opened_at = ? WHERE id = ?");
    q.addBindValue(nowIso());
    q.addBindValue(id);
    q.exec();
    emit activeWorkspaceIdChanged();
    emit workspacesChanged();   // last_opened_at ordering changed
}

int WorkspaceManager::createWorkspace(const QString &name, const QStringList &connectionNames)
{
    const QString trimmed = name.trimmed();
    if (trimmed.isEmpty() || nameTaken(trimmed, -1)) return -1;

    QSqlQuery q(m_db);
    q.prepare("INSERT INTO workspaces (name, created_at, last_opened_at, is_active) "
              "VALUES (?, ?, ?, 0)");
    q.addBindValue(trimmed);
    q.addBindValue(nowIso());
    q.addBindValue(nowIso());
    if (!q.exec()) return -1;
    const int id = q.lastInsertId().toInt();

    for (const QString &name : connectionNames) {
        q.prepare("INSERT OR IGNORE INTO workspace_connections (workspace_id, connection_name) VALUES (?, ?)");
        q.addBindValue(id);
        q.addBindValue(name);
        q.exec();
    }
    emit workspacesChanged();
    return id;
}

bool WorkspaceManager::renameWorkspace(int id, const QString &name)
{
    const QString trimmed = name.trimmed();
    if (trimmed.isEmpty() || nameTaken(trimmed, id)) return false;

    QSqlQuery q(m_db);
    q.prepare("UPDATE workspaces SET name = ? WHERE id = ?");
    q.addBindValue(trimmed);
    q.addBindValue(id);
    if (!q.exec() || q.numRowsAffected() == 0) return false;
    emit workspacesChanged();
    return true;
}

void WorkspaceManager::deleteWorkspace(int id)
{
    const bool wasActive = (id == activeWorkspaceId());

    QSqlQuery q(m_db);
    q.exec("PRAGMA foreign_keys = ON");   // CASCADE cleans tabs and connections
    q.prepare("DELETE FROM workspaces WHERE id = ?");
    q.addBindValue(id);
    q.exec();
    if (q.numRowsAffected() == 0) return;

    if (wasActive) {
        // Promote the most recently opened survivor, or recreate the default.
        q.exec("UPDATE workspaces SET is_active = 1 WHERE id = "
               "(SELECT id FROM workspaces ORDER BY last_opened_at DESC, id DESC LIMIT 1)");
        ensureDefaultWorkspace();
    }

    emit workspaceDeleted(id);
    emit workspacesChanged();
    if (wasActive)
        emit activeWorkspaceIdChanged();
}

void WorkspaceManager::setConnections(int id, const QStringList &names)
{
    QSqlQuery q(m_db);
    m_db.transaction();
    q.prepare("DELETE FROM workspace_connections WHERE workspace_id = ?");
    q.addBindValue(id);
    q.exec();
    for (const QString &name : names) {
        q.prepare("INSERT OR IGNORE INTO workspace_connections (workspace_id, connection_name) VALUES (?, ?)");
        q.addBindValue(id);
        q.addBindValue(name);
        q.exec();
    }
    m_db.commit();
    emit workspacesChanged();
}

void WorkspaceManager::addConnection(int id, const QString &name)
{
    if (name.isEmpty()) return;
    QSqlQuery q(m_db);
    q.prepare("INSERT OR IGNORE INTO workspace_connections (workspace_id, connection_name) VALUES (?, ?)");
    q.addBindValue(id);
    q.addBindValue(name);
    q.exec();
    if (q.numRowsAffected() > 0)
        emit workspacesChanged();
}

void WorkspaceManager::removeConnection(int id, const QString &name)
{
    QSqlQuery q(m_db);
    q.prepare("DELETE FROM workspace_connections WHERE workspace_id = ? AND connection_name = ?");
    q.addBindValue(id);
    q.addBindValue(name);
    q.exec();
    if (q.numRowsAffected() > 0)
        emit workspacesChanged();
}

void WorkspaceManager::renameConnectionReferences(const QString &oldName, const QString &newName)
{
    const QString from = oldName.trimmed();
    const QString to   = newName.trimmed();
    if (from.isEmpty() || to.isEmpty() || from == to) return;

    QSqlQuery q(m_db);
    m_db.transaction();

    // Merge membership if the target name was already present in a workspace.
    q.prepare(R"(
        INSERT OR IGNORE INTO workspace_connections (workspace_id, connection_name)
        SELECT workspace_id, ? FROM workspace_connections WHERE connection_name = ?
    )");
    q.addBindValue(to);
    q.addBindValue(from);
    q.exec();

    q.prepare("DELETE FROM workspace_connections WHERE connection_name = ?");
    q.addBindValue(from);
    q.exec();

    q.prepare("UPDATE workspace_tabs SET connection_name = ? WHERE connection_name = ?");
    q.addBindValue(to);
    q.addBindValue(from);
    q.exec();

    m_db.commit();
    emit workspacesChanged();
}

QStringList WorkspaceManager::connections(int id) const
{
    QStringList names;
    QSqlQuery q(m_db);
    q.prepare("SELECT connection_name FROM workspace_connections "
              "WHERE workspace_id = ? ORDER BY connection_name");
    q.addBindValue(id);
    q.exec();
    while (q.next())
        names << q.value(0).toString();
    return names;
}

QVariantMap WorkspaceManager::workspace(int id) const
{
    QSqlQuery q(m_db);
    q.prepare("SELECT name FROM workspaces WHERE id = ?");
    q.addBindValue(id);
    q.exec();
    if (!q.next()) return {};

    QVariantMap ws;
    ws["id"]                = id;
    ws["name"]              = q.value(0);
    ws["connections"] = connections(id);

    q.prepare("SELECT connection_name, sql, cursor_position, title, is_active, file_path "
              "FROM workspace_tabs WHERE workspace_id = ? ORDER BY tab_order");
    q.addBindValue(id);
    q.exec();

    QVariantList tabs;
    while (q.next()) {
        QVariantMap tab;
        tab["connectionName"] = q.value(0);
        tab["sql"]            = q.value(1);
        tab["cursorPosition"] = q.value(2);
        tab["title"]          = q.value(3);
        tab["isActive"]       = q.value(4).toInt() == 1;
        tab["filePath"]       = q.value(5);
        tabs << tab;
    }
    ws["tabs"] = tabs;
    return ws;
}

void WorkspaceManager::saveTabs(int id, const QVariantList &tabs)
{
    QSqlQuery q(m_db);
    q.prepare("SELECT id FROM workspaces WHERE id = ?");
    q.addBindValue(id);
    q.exec();
    if (!q.next()) return;   // deleted workspace: silently drop, never orphan rows

    m_db.transaction();
    q.prepare("DELETE FROM workspace_tabs WHERE workspace_id = ?");
    q.addBindValue(id);
    q.exec();
    // QVariant::toString() on a key the caller omitted yields a *null* QString,
    // which binds as SQL NULL — and every text column here is NOT NULL, so an
    // absent key failed the insert and dropped the tab instead of taking the
    // column default.
    const auto text = [](const QVariantMap &m, const char *key) {
        const QString v = m.value(QLatin1String(key)).toString();
        return v.isNull() ? QString::fromLatin1("") : v;
    };
    for (int i = 0; i < tabs.size(); ++i) {
        const QVariantMap tab = tabs.at(i).toMap();
        q.prepare(R"(
            INSERT INTO workspace_tabs (workspace_id, tab_order, connection_name, sql, cursor_position, title, is_active, file_path)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        )");
        q.addBindValue(id);
        q.addBindValue(i);
        q.addBindValue(text(tab, "connectionName"));
        q.addBindValue(text(tab, "sql"));
        q.addBindValue(tab.value("cursorPosition").toInt());
        q.addBindValue(text(tab, "title"));
        q.addBindValue(tab.value("isActive").toBool() ? 1 : 0);
        q.addBindValue(text(tab, "filePath"));
        q.exec();
    }
    m_db.commit();
    emit workspacesChanged();   // tab counts shown on Home stay live
}
