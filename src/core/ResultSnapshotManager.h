#pragma once

#include <QObject>
#include "QmlSingleton.h"
#include <QVariantList>
#include <QVariantMap>
#include <QSqlDatabase>

// Persists captured query result sets (as JSON) in the shared qub.db so a later
// run of a query can be diffed against a saved baseline — the durable,
// cross-session counterpart to the in-memory per-tab baseline in DiffView.
// The diff itself is done by ResultModel::diffAgainst() once snapshotOf() feeds
// a saved snapshot back in as the baseline (see [[project_result_diff]]).
class ResultSnapshotManager : public QObject {
    Q_OBJECT
    QUB_QML_SINGLETON(ResultSnapshotManager)

public:
    Q_PROPERTY(QVariantList snapshots READ snapshots NOTIFY changed)
public:
    explicit ResultSnapshotManager(const QString &dbPath = QString(), QObject *parent = nullptr);
    ~ResultSnapshotManager() override;

    // Metadata for every saved snapshot, newest first:
    // { id, name, connectionName, sql, capturedAt, rowCount, colCount }.
    QVariantList snapshots() const;

    // Capture `snapshot` (the { columns, rows, rowCount } map produced by
    // ResultModel::snapshot()) under a name. Returns the new row id, or -1.
    Q_INVOKABLE qint64 capture(const QString &name, const QString &connectionName,
                               const QString &sql, const QVariantMap &snapshot);
    Q_INVOKABLE bool   remove(qint64 id);

    // The stored { columns, rows, rowCount } map for one snapshot, ready to feed
    // to ResultModel::diffAgainst() as a baseline. Empty map for a bad id.
    Q_INVOKABLE QVariantMap snapshotOf(qint64 id) const;

signals:
    void changed();

private:
    void initDb(const QString &dbPath);

    QString      m_connectionName;
    QSqlDatabase m_db;
};

QUB_QML_SINGLETON_FOREIGN(ResultSnapshotManager)
