#pragma once

#include <QObject>
#include "QmlSingleton.h"
#include <QVariantList>
#include <QVariantMap>
#include <QMap>
#include <QSet>
#include <QUrl>
#include "Types.h"
#include "AdapterProvider.h"

class CredentialStore;
class DatabaseAdapter;
class LogManager;
class SshManager;

class ConnectionManager : public QObject, public AdapterProvider {
    Q_OBJECT
    QUB_QML_SINGLETON(ConnectionManager)

public:
    Q_PROPERTY(QVariantList connections READ connections NOTIFY connectionsChanged)

    // Qt driver keys this build can actually load ("QPSQL", "QSQLITE", …).
    // Constant: Qt resolves its sqldrivers plugins once, at first use, and the
    // set cannot change while the app is running.
    Q_PROPERTY(QStringList availableDrivers READ availableDrivers CONSTANT)

public:
    explicit ConnectionManager(CredentialStore *credentials,
                               SshManager      *ssh     = nullptr,
                               LogManager      *log     = nullptr,
                               QObject         *parent  = nullptr);
    ~ConnectionManager() override;

    QVariantList connections() const;
    QStringList  availableDrivers() const;

    Q_INVOKABLE void        addConnection(const QVariantMap &params);
    Q_INVOKABLE void        removeConnection(const QString &name);
    Q_INVOKABLE void        closeAllConnections();
    Q_INVOKABLE void        closeConnection(const QString &name);
    Q_INVOKABLE void        testConnection(const QVariantMap &params);
    Q_INVOKABLE bool        isConnected(const QString &name) const;
    Q_INVOKABLE void        reconnect(const QString &name);
    Q_INVOKABLE void        updateConnection(const QString &oldName, const QVariantMap &params);
    Q_INVOKABLE bool        exportConnections(const QUrl &fileUrl);
    Q_INVOKABLE QVariantMap importConnections(const QUrl &fileUrl);
    Q_INVOKABLE QStringList  tables(const QString &connectionName) const;
    Q_INVOKABLE QVariantList columns(const QString &connectionName, const QString &table) const;
    Q_INVOKABLE QVariantList schema(const QString &connectionName) const;
    Q_INVOKABLE QVariantList schemas(const QString &connectionName) const;

    // Nudge the UI to re-read a connection's schema after the database changed
    // out-of-band (e.g. a CSV imported into it as a new table). SchemaTree and
    // other schema views reload on connectionsChanged().
    Q_INVOKABLE void refreshSchema(const QString &connectionName);

    // True when the connection's database file was created by qub (a CSV import
    // living under the app's imports dir), so removeConnection will delete it —
    // lets the UI warn that deletion destroys the data, not just the entry.
    Q_INVOKABLE bool ownsDatabaseFile(const QString &connectionName) const;

    // Host key confirmation: when connecting through SSH to a host that is not
    // in known_hosts yet, hostKeyConfirmationRequired is emitted instead of
    // opening the tunnel. Call acceptHostKey / rejectHostKey to resolve it.
    Q_INVOKABLE void acceptHostKey(const QString &connectionName);
    Q_INVOKABLE void rejectHostKey(const QString &connectionName);

    DatabaseAdapter *adapter(const QString &name) const override;

signals:
    void connectionsChanged();
    void connectionAdded(const QString &name);      // saved (the open attempt follows)
    void connectionOpened(const QString &name);     // adapter actually opened
    void connectionRenamed(const QString &oldName, const QString &newName);
    void connectionRemoved(const QString &name);
    void connectionPending(const QString &name, bool pending);
    void connectionError(const QString &name, const QString &error);
    void testResult(bool success, const QString &message);
    void hostKeyConfirmationRequired(const QString &connectionName,
                                     const QString &host,
                                     const QString &fingerprints);

private:
    struct PendingHostKey {
        ConnectionParams params;      // reconnect flow
        QVariantMap      testParams;  // test flow (re-runs testConnection)
        QString          keyLines;
        bool             isTest = false;
    };

    CredentialStore                   *m_credentials;
    SshManager                        *m_ssh = nullptr;
    LogManager                        *m_log = nullptr;
    QMap<QString, DatabaseAdapter *>   m_adapters;
    QList<ConnectionParams>            m_params;
    QSet<QString>                      m_pendingNames;
    QMap<QString, PendingHostKey>      m_pendingHostKeys;

    ConnectionParams paramsFromMap(const QVariantMap &map) const;
    void             registerConnection(const ConnectionParams &p);
    void             openAdapter(const ConnectionParams &p);
    void             save();
    void             load();
    void             tryReopen(ConnectionParams p);
};

QUB_QML_SINGLETON_FOREIGN(ConnectionManager)
