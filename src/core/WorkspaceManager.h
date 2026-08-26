#pragma once

#include <QObject>
#include "QmlSingleton.h"
#include <QStringList>
#include <QVariantList>
#include <QVariantMap>
#include <QSqlDatabase>

// Named, durable containers for a body of work. A workspace owns query tabs
// and contains an explicit subset of the global connections (a safety boundary:
// a "staging" workspace can never target production). Exactly one workspace
// is active; the app reopens it on start. Tab persistence is invisible
// plumbing — saveTabs() serves both the quit-save and the periodic
// crash-autosave, there is no user-facing session history.
class WorkspaceManager : public QObject {
    Q_OBJECT
    QUB_QML_SINGLETON(WorkspaceManager)

public:
    Q_PROPERTY(QVariantList workspaces READ workspaces NOTIFY workspacesChanged)
    Q_PROPERTY(int activeWorkspaceId READ activeWorkspaceId WRITE setActiveWorkspaceId NOTIFY activeWorkspaceIdChanged)
public:
    // dbPath overrides the database file location — used by tests only;
    // production uses AppDataLocation/qub.db (shared with the other managers).
    explicit WorkspaceManager(const QString &dbPath = QString(), QObject *parent = nullptr);
    ~WorkspaceManager() override;

    // [{id, name, tabCount, connections, lastOpenedAt}], newest-opened first
    QVariantList workspaces() const;
    int  activeWorkspaceId() const;
    void setActiveWorkspaceId(int id);   // flips is_active, bumps last_opened_at

    Q_INVOKABLE int  createWorkspace(const QString &name, const QStringList &connectionNames); // -1 on duplicate name
    Q_INVOKABLE bool renameWorkspace(int id, const QString &name);                  // false on duplicate name
    Q_INVOKABLE void deleteWorkspace(int id);
    Q_INVOKABLE void setConnections(int id, const QStringList &names);
    Q_INVOKABLE void addConnection(int id, const QString &name);
    Q_INVOKABLE void removeConnection(int id, const QString &name);
    Q_INVOKABLE void renameConnectionReferences(const QString &oldName, const QString &newName);
    Q_INVOKABLE QStringList connections(int id) const;
    // {id, name, connections, tabs:[{connectionName, sql, cursorPosition, title, isActive}]}
    Q_INVOKABLE QVariantMap workspace(int id) const;
    // Transactional full replace of a workspace's tabs. No-op for unknown ids.
    Q_INVOKABLE void saveTabs(int id, const QVariantList &tabs);

signals:
    void workspacesChanged();          // CRUD, membership, and saveTabs (keeps Home tab counts live)
    void activeWorkspaceIdChanged();
    void workspaceDeleted(int id);     // lets the workspace screen skip flushing a dead id

private:
    void initDb(const QString &dbPath);
    void ensureDefaultWorkspace();     // guarantees >=1 workspace and exactly one active
    bool nameTaken(const QString &name, int excludeId) const;

    QSqlDatabase m_db;
    QString      m_connectionName;
};

QUB_QML_SINGLETON_FOREIGN(WorkspaceManager)
