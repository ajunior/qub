#pragma once

#include <QObject>
#include "QmlSingleton.h"
#include <QVariantList>
#include <QVariantMap>
#include <QSqlDatabase>

// Persists point-in-time snapshots of a connection's schema (as JSON) in the
// shared qub.db, so a live schema can later be diffed against a saved snapshot
// to catch drift over time on a *single* connection. The actual structural
// diff is delegated to the pure SchemaDiff::compare() (see DatabaseInspector /
// SchemaDiffWindow, which diff two *live* connections).
class SchemaSnapshotManager : public QObject {
    Q_OBJECT
    QUB_QML_SINGLETON(SchemaSnapshotManager)

public:
    Q_PROPERTY(QVariantList snapshots READ snapshots NOTIFY changed)
public:
    explicit SchemaSnapshotManager(const QString &dbPath = QString(), QObject *parent = nullptr);
    ~SchemaSnapshotManager() override;

    // Metadata for every saved snapshot, newest first:
    // { id, name, connectionName, capturedAt, tableCount }.
    QVariantList snapshots() const;

    // Capture `schemas` (the shape returned by ConnectionManager::schemas())
    // under a name for `connectionName`. Returns the new row id, or -1.
    Q_INVOKABLE qint64 capture(const QString &name, const QString &connectionName,
                               const QVariantList &schemas);
    Q_INVOKABLE bool   remove(qint64 id);

    // Deserialize the stored schema of one snapshot back into the
    // ConnectionManager::schemas() shape. Empty list for a bad id.
    Q_INVOKABLE QVariantList schemaOf(qint64 id) const;

    // Diff a saved snapshot (baseline) against a live schema. `liveSchemas` is
    // the current ConnectionManager::schemas() output. Returns the map shape of
    // SchemaDiff::compare, or an empty map for a bad id.
    Q_INVOKABLE QVariantMap diffLive(qint64 id, const QVariantList &liveSchemas) const;

signals:
    void changed();

private:
    void initDb(const QString &dbPath);
    static int countTables(const QVariantList &schemas);

    QString      m_connectionName;
    QSqlDatabase m_db;
};

QUB_QML_SINGLETON_FOREIGN(SchemaSnapshotManager)
