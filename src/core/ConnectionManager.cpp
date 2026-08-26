#include "ConnectionManager.h"
#include "CredentialStore.h"
#include "LogManager.h"
#include "SshManager.h"
#include "SshTunnel.h"
#include "adapters/QtSqlAdapter.h"
#include <QVariantMap>
#include <QFile>
#include <QFileInfo>
#include <QDir>
#include <QJsonDocument>
#include <QJsonArray>
#include <QJsonObject>
#include <QStandardPaths>
#include <QtConcurrent/QtConcurrent>
#include <QFutureWatcher>
#include <algorithm>

namespace {
// True when `database` is a SQLite file qub created under the app's imports dir
// (a CSV import), so it's ours to delete. A user's own .db opened from anywhere
// else never matches.
bool isManagedImportFile(const QString &driver, const QString &database)
{
    if (driver != QLatin1String("QSQLITE") || database.isEmpty())
        return false;
    const QString importsDir =
        QDir(QStandardPaths::writableLocation(QStandardPaths::AppDataLocation)
             + QStringLiteral("/imports")).absolutePath();
    const QString dbPath = QFileInfo(database).absoluteFilePath();
    return dbPath.startsWith(importsDir + QLatin1Char('/'));
}

struct TunnelResult {
    int        port   = -1;
    SshTunnel *tunnel = nullptr;
    QString    error;

    // Set when the SSH host is not in known_hosts: the tunnel is not opened
    // and the user must confirm the key first.
    bool       hostKeyUnknown = false;
    QString    sshEndpoint;   // "host:port" for display
    QString    fingerprints;
    QString    keyLines;
};

// Runs on the worker thread. Returns a hostKeyUnknown result (or a scan error)
// for hosts missing from known_hosts; otherwise opens the tunnel.
TunnelResult openTunnelChecked(const QVariantMap &sshCfg,
                               const QString &remoteHost, int remotePort)
{
    TunnelResult r;
    const QString sshHost = sshCfg.value("host").toString();
    const int     sshPort = sshCfg.value("port", 22).toInt();

    if (!sshHost.isEmpty() && !SshTunnel::isHostKnown(sshHost, sshPort)) {
        r.sshEndpoint = sshHost + ":" + QString::number(sshPort);
        if (SshTunnel::scanHostKey(sshHost, sshPort, r.keyLines, r.fingerprints, r.error))
            r.hostKeyUnknown = true;
        return r;
    }

    auto *t = new SshTunnel(nullptr);
    const int port = t->start(sshCfg, remoteHost, remotePort, r.error);
    if (port < 0) { delete t; return r; }
    r.port   = port;
    r.tunnel = t;
    return r;
}
}

ConnectionManager::ConnectionManager(CredentialStore *credentials,
                                     SshManager      *ssh,
                                     LogManager      *log,
                                     QObject         *parent)
    : QObject(parent)
    , m_credentials(credentials)
    , m_ssh(ssh)
    , m_log(log)
{
    load();
}

ConnectionManager::~ConnectionManager()
{
    qDeleteAll(m_adapters);
}

QVariantList ConnectionManager::connections() const
{
    QVariantList list;
    for (const auto &p : m_params) {
        QVariantMap map;
        map["name"]         = p.name;
        map["driver"]       = p.driver;
        map["host"]         = p.host;
        map["port"]         = p.port;
        map["database"]     = p.database;
        map["username"]     = p.username;
        map["profileId"]    = p.profileId;
        map["sshConfigId"]  = p.sshConfigId;
        map["ssl"]          = p.ssl;
        map["sslCaCert"]    = p.sslCaCert;
        map["sslClientCert"]= p.sslClientCert;
        map["sslClientKey"] = p.sslClientKey;
        map["timeout"]      = p.timeout;
        map["schema"]       = p.schema;
        map["connected"]    = isConnected(p.name);
        map["pending"]      = m_pendingNames.contains(p.name);
        map["lastModified"] = p.lastModified;
        list << map;
    }
    return list;
}

void ConnectionManager::addConnection(const QVariantMap &params)
{
    ConnectionParams p = paramsFromMap(params);
    p.name = p.name.trimmed();

    const bool duplicateSaved =
        std::any_of(m_params.cbegin(), m_params.cend(),
                    [&p](const ConnectionParams &stored) { return stored.name == p.name; });
    if (p.name.isEmpty()) {
        emit connectionError(p.name, "Give the connection a name.");
        return;
    }
    if (m_adapters.contains(p.name) || duplicateSaved) {
        emit connectionError(p.name, "A connection named \"" + p.name + "\" already exists.");
        return;
    }

    if (!p.password.isEmpty())
        m_credentials->store(p.name, p.password);

    p.lastModified = QDateTime::currentDateTime();
    m_params << p;
    save();
    emit connectionAdded(p.name);
    emit connectionsChanged();

    tryReopen(p);
}

void ConnectionManager::closeAllConnections()
{
    for (auto *adapter : std::as_const(m_adapters))
        adapter->close();
    emit connectionsChanged();
}

void ConnectionManager::closeConnection(const QString &name)
{
    auto *adapter = m_adapters.take(name);
    const bool wasPending = m_pendingNames.remove(name);
    if (!adapter && !wasPending)
        return;

    if (adapter) {
        adapter->close();
        delete adapter;
    }
    if (m_ssh)
        m_ssh->closeTunnel(name);
    if (m_log) m_log->post("info", "CONN", name, "Disconnected");
    emit connectionsChanged();
}

void ConnectionManager::removeConnection(const QString &name)
{
    if (auto *adapter = m_adapters.take(name)) {
        adapter->close();
        delete adapter;
    }
    m_pendingNames.remove(name);

    // If this was a CSV import (a SQLite file qub itself created under the app's
    // imports dir), delete the file too — otherwise it lingers forever. A user's
    // own .db opened from elsewhere is never touched: isManagedImportFile only
    // matches files inside our imports dir.
    auto it = std::find_if(m_params.cbegin(), m_params.cend(),
                           [&name](const ConnectionParams &p) { return p.name == name; });
    if (it != m_params.cend() && isManagedImportFile(it->driver, it->database))
        QFile::remove(QFileInfo(it->database).absoluteFilePath());

    m_params.removeIf([&name](const ConnectionParams &p) { return p.name == name; });
    m_credentials->remove(name);
    if (m_ssh)
        m_ssh->closeTunnel(name);
    save();
    if (m_log) m_log->post("info", "CONN", name, "Connection removed");
    emit connectionRemoved(name);
    emit connectionsChanged();
}

void ConnectionManager::reconnect(const QString &name)
{
    if (isConnected(name)) return;

    auto it = std::find_if(m_params.cbegin(), m_params.cend(),
                           [&name](const ConnectionParams &p) { return p.name == name; });
    if (it == m_params.cend()) return;

    if (auto *old = m_adapters.take(name)) {
        old->close();
        delete old;
    }

    tryReopen(*it);
}

void ConnectionManager::updateConnection(const QString &oldName, const QVariantMap &params)
{
    ConnectionParams p = paramsFromMap(params);
    p.name = p.name.trimmed();
    if (p.name.isEmpty()) {
        emit connectionError(oldName, "Give the connection a name.");
        return;
    }

    const bool renamed = (p.name != oldName);
    if (renamed) {
        const bool duplicateAdapter = m_adapters.contains(p.name);
        const bool duplicateSaved =
            std::any_of(m_params.cbegin(), m_params.cend(),
                        [&oldName, &p](const ConnectionParams &stored) {
                            return stored.name != oldName && stored.name == p.name;
                        });
        if (duplicateAdapter || duplicateSaved) {
            emit connectionError(oldName, "A connection named \"" + p.name + "\" already exists.");
            return;
        }
    }

    if (auto *old = m_adapters.take(oldName)) {
        old->close();
        delete old;
    }
    m_pendingNames.remove(oldName);
    if (m_ssh)
        m_ssh->closeTunnel(oldName);

    for (auto &stored : m_params) {
        if (stored.name == oldName) {
            const QDateTime ts  = stored.lastModified;
            stored              = p;
            stored.lastModified = ts;
            break;
        }
    }
    save();

    if (!p.password.isEmpty()) {
        m_credentials->store(p.name, p.password);
        if (renamed)
            m_credentials->remove(oldName);
        if (renamed)
            emit connectionRenamed(oldName, p.name);
        emit connectionsChanged();
        tryReopen(p);
    } else if (renamed) {
        // No new password typed: carry the stored one over to the new name so
        // the connection doesn't silently lose its credential.
        m_credentials->retrieve(oldName, [this, oldName, p](const QString &pw, const QString &) mutable {
            if (!pw.isEmpty()) {
                m_credentials->store(p.name, pw);
                p.password = pw;   // seed reopen; the async store may still be in flight
            }
            m_credentials->remove(oldName);
            emit connectionRenamed(oldName, p.name);
            emit connectionsChanged();
            tryReopen(p);
        });
    } else {
        emit connectionsChanged();
        tryReopen(p);
    }
}

void ConnectionManager::testConnection(const QVariantMap &params)
{
    ConnectionParams p = paramsFromMap(params);

    m_credentials->retrieve(p.name, [this, p, params](const QString &password, const QString &) mutable {
        // A password typed in the dialog wins over the stored one — the user
        // is likely testing a credential change.
        if (p.password.isEmpty())
            p.password = password;

        if (!p.sshConfigId.isEmpty() && m_ssh) {
            const QVariantMap sshCfg = m_ssh->configById(p.sshConfigId);
            if (sshCfg.isEmpty()) {
                emit testResult(false, "SSH config not found.");
                return;
            }
            const QString remoteHost = p.host;
            const int     remotePort = p.port;

            auto *watcher = new QFutureWatcher<TunnelResult>(this);
            connect(watcher, &QFutureWatcher<TunnelResult>::finished, this,
                    [this, watcher, p, params]() mutable {
                const TunnelResult r = watcher->result();
                watcher->deleteLater();

                if (r.hostKeyUnknown) {
                    PendingHostKey pending;
                    pending.testParams = params;
                    pending.keyLines   = r.keyLines;
                    pending.isTest     = true;
                    m_pendingHostKeys.insert(p.name, pending);
                    emit hostKeyConfirmationRequired(p.name, r.sshEndpoint, r.fingerprints);
                    return;
                }

                if (r.port < 0) {
                    if (r.tunnel) delete r.tunnel;
                    emit testResult(false, "SSH tunnel failed: " + r.error);
                    return;
                }

                ConnectionParams tp = p;
                tp.host = "127.0.0.1";
                tp.port = r.port;

                QString errorMsg;
                auto *adapter = new QtSqlAdapter(this);
                connect(adapter, &DatabaseAdapter::errorOccurred, this,
                        [&errorMsg](const QString &msg) { errorMsg = msg; });

                const bool ok = adapter->open(tp);
                adapter->close();
                delete adapter;

                r.tunnel->stop();
                delete r.tunnel;

                emit testResult(ok, ok ? "Connection successful." : errorMsg);
            });

            watcher->setFuture(QtConcurrent::run([sshCfg, remoteHost, remotePort]() -> TunnelResult {
                return openTunnelChecked(sshCfg, remoteHost, remotePort);
            }));

        } else {
            QString errorMsg;
            auto *adapter = new QtSqlAdapter(this);
            connect(adapter, &DatabaseAdapter::errorOccurred, this,
                    [&errorMsg](const QString &msg) { errorMsg = msg; });

            const bool ok = adapter->open(p);
            adapter->close();
            delete adapter;

            emit testResult(ok, ok ? "Connection successful." : errorMsg);
        }
    });
}

bool ConnectionManager::isConnected(const QString &name) const
{
    auto *adapter = m_adapters.value(name, nullptr);
    return adapter && adapter->isOpen();
}

DatabaseAdapter *ConnectionManager::adapter(const QString &name) const
{
    return m_adapters.value(name, nullptr);
}

bool ConnectionManager::exportConnections(const QUrl &fileUrl)
{
    const QString path = fileUrl.toLocalFile();
    QJsonArray arr;
    for (const auto &p : m_params) {
        QJsonObject obj;
        obj["name"]          = p.name;
        obj["driver"]        = p.driver;
        obj["host"]          = p.host;
        obj["port"]          = p.port;
        obj["database"]      = p.database;
        obj["username"]      = p.username;
        obj["profileId"]     = p.profileId;
        obj["sshConfigId"]   = p.sshConfigId;
        obj["ssl"]           = p.ssl;
        obj["sslCaCert"]     = p.sslCaCert;
        obj["sslClientCert"] = p.sslClientCert;
        obj["sslClientKey"]  = p.sslClientKey;
        obj["timeout"]       = p.timeout;
        obj["schema"]        = p.schema;
        arr.append(obj);
    }
    QJsonObject root;
    root["version"]     = 1;
    root["connections"] = arr;

    QFile file(path);
    if (!file.open(QIODevice::WriteOnly))
        return false;
    file.write(QJsonDocument(root).toJson());
    return true;
}

QVariantMap ConnectionManager::importConnections(const QUrl &fileUrl)
{
    const QString path = fileUrl.toLocalFile();
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly))
        return {{"success", false}, {"message", QString("Could not open file.")}};

    QJsonParseError err;
    const auto doc = QJsonDocument::fromJson(file.readAll(), &err);
    if (err.error != QJsonParseError::NoError)
        return {{"success", false}, {"message", QString("Invalid file: ") + err.errorString()}};

    const auto arr = doc.object()["connections"].toArray();
    int added = 0, skipped = 0;
    for (const auto &v : arr) {
        const auto obj     = v.toObject();
        const QString name = obj["name"].toString();
        if (name.isEmpty()) continue;

        const bool exists = m_adapters.contains(name) ||
                            std::any_of(m_params.cbegin(), m_params.cend(),
                                        [&name](const ConnectionParams &p) { return p.name == name; });
        if (exists) { ++skipped; continue; }

        ConnectionParams p;
        p.name          = name;
        p.driver        = obj["driver"].toString();
        p.host          = obj["host"].toString();
        p.port          = obj["port"].toInt();
        p.database      = obj["database"].toString();
        p.username      = obj["username"].toString();
        p.profileId     = obj["profileId"].toString();
        p.sshConfigId   = obj["sshConfigId"].toString();
        p.ssl           = obj["ssl"].toBool();
        p.sslCaCert     = obj["sslCaCert"].toString();
        p.sslClientCert = obj["sslClientCert"].toString();
        p.sslClientKey  = obj["sslClientKey"].toString();
        p.timeout       = obj["timeout"].toInt(30);
        p.schema        = obj["schema"].toString();
        registerConnection(p);
        ++added;
    }

    QString msg;
    if (added == 0 && skipped == 0)
        msg = "No valid connections found in file.";
    else if (added == 0)
        msg = "All connections already exist. Nothing imported.";
    else {
        msg = QString("Imported %1 connection(s).").arg(added);
        if (skipped > 0)
            msg += QString(" Skipped %1 duplicate(s).").arg(skipped);
        msg += " Passwords must be re-entered to connect.";
    }
    return {{"success", added > 0}, {"message", msg}};
}

QStringList ConnectionManager::tables(const QString &connectionName) const
{
    auto *a = m_adapters.value(connectionName, nullptr);
    return a ? a->tables() : QStringList{};
}

QVariantList ConnectionManager::columns(const QString &connectionName, const QString &table) const
{
    auto *a = m_adapters.value(connectionName, nullptr);
    return a ? a->columns(table) : QVariantList{};
}

QVariantList ConnectionManager::schema(const QString &connectionName) const
{
    auto *a = m_adapters.value(connectionName, nullptr);
    return a ? a->schema() : QVariantList{};
}

QVariantList ConnectionManager::schemas(const QString &connectionName) const
{
    auto *a = m_adapters.value(connectionName, nullptr);
    return a ? a->schemas() : QVariantList{};
}

void ConnectionManager::refreshSchema(const QString &connectionName)
{
    Q_UNUSED(connectionName)   // schema views reload for whichever connection they show
    emit connectionsChanged();
}

bool ConnectionManager::ownsDatabaseFile(const QString &connectionName) const
{
    auto it = std::find_if(m_params.cbegin(), m_params.cend(),
                           [&connectionName](const ConnectionParams &p) {
                               return p.name == connectionName;
                           });
    return it != m_params.cend() && isManagedImportFile(it->driver, it->database);
}

void ConnectionManager::registerConnection(const ConnectionParams &p)
{
    m_params << p;
    emit connectionsChanged();
}

void ConnectionManager::openAdapter(const ConnectionParams &p)
{
    auto *adapter = new QtSqlAdapter(this);
    connect(adapter, &DatabaseAdapter::errorOccurred,
            this, [this, name = p.name](const QString &msg) {
                if (m_log) m_log->post("error", "CONN", name, "Connection error: " + msg, {{"error", msg}});
                emit connectionError(name, msg);
            });

    if (adapter->open(p)) {
        m_adapters.insert(p.name, adapter);
        if (m_log) m_log->post("info", "CONN", p.name,
                               "Connected · " + p.driver + " · " + p.database,
                               {{"driver",    p.driver},
                                {"host",      p.host},
                                {"port",      p.port},
                                {"database",  p.database},
                                {"user",      p.username},
                                {"ssl",       p.ssl}});
        emit connectionOpened(p.name);
        emit connectionsChanged();
    } else {
        delete adapter;
    }
}

static QString storagePath()
{
    const QString dir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    QDir().mkpath(dir);
    return dir + "/connections.json";
}

void ConnectionManager::save()
{
    QJsonArray arr;
    for (const auto &p : m_params) {
        QJsonObject obj;
        obj["name"]          = p.name;
        obj["driver"]        = p.driver;
        obj["host"]          = p.host;
        obj["port"]          = p.port;
        obj["database"]      = p.database;
        obj["username"]      = p.username;
        obj["profileId"]     = p.profileId;
        obj["sshConfigId"]   = p.sshConfigId;
        obj["ssl"]           = p.ssl;
        obj["sslCaCert"]     = p.sslCaCert;
        obj["sslClientCert"] = p.sslClientCert;
        obj["sslClientKey"]  = p.sslClientKey;
        obj["timeout"]       = p.timeout;
        obj["schema"]        = p.schema;
        obj["lastModified"]  = p.lastModified.toString(Qt::ISODate);
        arr.append(obj);
    }
    QJsonObject root;
    root["version"]     = 1;
    root["connections"] = arr;

    QFile file(storagePath());
    if (file.open(QIODevice::WriteOnly))
        file.write(QJsonDocument(root).toJson());
}

void ConnectionManager::load()
{
    QFile file(storagePath());
    if (!file.open(QIODevice::ReadOnly))
        return;

    const auto doc = QJsonDocument::fromJson(file.readAll());
    const auto arr = doc.object()["connections"].toArray();

    for (const auto &v : arr) {
        const auto obj     = v.toObject();
        const QString name = obj["name"].toString();
        if (name.isEmpty()) continue;

        ConnectionParams p;
        p.name          = name;
        p.driver        = obj["driver"].toString();
        p.host          = obj["host"].toString();
        p.port          = obj["port"].toInt();
        p.database      = obj["database"].toString();
        p.username      = obj["username"].toString();
        p.profileId     = obj["profileId"].toString();
        p.sshConfigId   = obj["sshConfigId"].toString();
        p.ssl           = obj["ssl"].toBool();
        p.sslCaCert     = obj["sslCaCert"].toString();
        p.sslClientCert = obj["sslClientCert"].toString();
        p.sslClientKey  = obj["sslClientKey"].toString();
        p.timeout       = obj["timeout"].toInt(30);
        p.schema        = obj["schema"].toString();
        p.lastModified  = QDateTime::fromString(obj["lastModified"].toString(), Qt::ISODate);

        registerConnection(p);
        tryReopen(p);
    }
}

void ConnectionManager::tryReopen(ConnectionParams p)
{
    m_credentials->retrieve(p.name, [this, p](const QString &password, const QString &) mutable {
        // Keep a caller-seeded password if the keychain has nothing (yet) —
        // a just-issued async store may still be in flight.
        if (!password.isEmpty())
            p.password = password;

        if (!p.sshConfigId.isEmpty() && m_ssh) {
            const QVariantMap sshCfg = m_ssh->configById(p.sshConfigId);
            if (sshCfg.isEmpty()) {
                emit connectionError(p.name, "SSH config not found for \"" + p.name + "\".");
                return;
            }

            const QString remoteHost = p.host;
            const int     remotePort = p.port;
            const QString connName   = p.name;

            m_pendingNames.insert(connName);
            emit connectionPending(connName, true);
            emit connectionsChanged();
            if (m_log) m_log->post("info", "SSH", connName,
                                   "Opening SSH tunnel → " + remoteHost + ":" + QString::number(remotePort),
                                   {{"remoteHost",  remoteHost},
                                    {"remotePort",  remotePort},
                                    {"sshConfigId", p.sshConfigId}});

            auto *watcher = new QFutureWatcher<TunnelResult>(this);
            connect(watcher, &QFutureWatcher<TunnelResult>::finished, this,
                    [this, watcher, p, connName, remoteHost, remotePort]() mutable {
                const TunnelResult r = watcher->result();
                watcher->deleteLater();

                m_pendingNames.remove(connName);
                emit connectionPending(connName, false);

                if (r.hostKeyUnknown) {
                    PendingHostKey pending;
                    pending.params   = p;
                    pending.keyLines = r.keyLines;
                    m_pendingHostKeys.insert(connName, pending);
                    if (m_log) m_log->post("warn", "SSH", connName,
                                           "Unknown SSH host key for " + r.sshEndpoint + " — confirmation required",
                                           {{"host", r.sshEndpoint}, {"fingerprints", r.fingerprints}});
                    emit hostKeyConfirmationRequired(connName, r.sshEndpoint, r.fingerprints);
                    emit connectionsChanged();
                    return;
                }

                if (r.port < 0) {
                    if (r.tunnel) delete r.tunnel;
                    if (m_log) m_log->post("error", "SSH", connName,
                                           "SSH tunnel failed: " + r.error,
                                           {{"error", r.error}, {"remoteHost", remoteHost}, {"remotePort", remotePort}});
                    emit connectionError(connName, "SSH tunnel failed: " + r.error);
                    emit connectionsChanged();
                    return;
                }

                if (m_log) m_log->post("info", "SSH", connName,
                                       "SSH tunnel established on :" + QString::number(r.port),
                                       {{"localPort",  r.port},
                                        {"remoteHost", remoteHost},
                                        {"remotePort", remotePort}});
                m_ssh->registerTunnel(connName, r.tunnel);
                p.host = "127.0.0.1";
                p.port = r.port;
                openAdapter(p);
            });

            watcher->setFuture(QtConcurrent::run([sshCfg, remoteHost, remotePort]() -> TunnelResult {
                return openTunnelChecked(sshCfg, remoteHost, remotePort);
            }));

        } else {
            openAdapter(p);
        }
    });
}

void ConnectionManager::acceptHostKey(const QString &connectionName)
{
    if (!m_pendingHostKeys.contains(connectionName)) return;
    const PendingHostKey pending = m_pendingHostKeys.take(connectionName);

    if (!SshTunnel::trustHostKey(pending.keyLines)) {
        const QString msg = "Could not save the host key to ~/.ssh/known_hosts.";
        if (pending.isTest) emit testResult(false, msg);
        else                emit connectionError(connectionName, msg);
        return;
    }

    if (m_log) m_log->post("info", "SSH", connectionName,
                           "Host key trusted and saved to known_hosts");
    if (pending.isTest)
        testConnection(pending.testParams);
    else
        tryReopen(pending.params);
}

void ConnectionManager::rejectHostKey(const QString &connectionName)
{
    if (!m_pendingHostKeys.contains(connectionName)) return;
    const PendingHostKey pending = m_pendingHostKeys.take(connectionName);

    const QString msg = "SSH host key was not trusted — connection cancelled.";
    if (m_log) m_log->post("warn", "SSH", connectionName, msg);
    if (pending.isTest) emit testResult(false, msg);
    else                emit connectionError(connectionName, msg);
}

ConnectionParams ConnectionManager::paramsFromMap(const QVariantMap &map) const
{
    ConnectionParams p;
    p.name          = map.value("name").toString();
    p.driver        = map.value("driver").toString();
    p.host          = map.value("host").toString();
    p.port          = map.value("port").toInt();
    p.database      = map.value("database").toString();
    p.username      = map.value("username").toString();
    p.password      = map.value("password").toString();
    p.profileId     = map.value("profileId").toString();
    p.sshConfigId   = map.value("sshConfigId").toString();
    p.ssl           = map.value("ssl", false).toBool();
    p.sslCaCert     = map.value("sslCaCert").toString();
    p.sslClientCert = map.value("sslClientCert").toString();
    p.sslClientKey  = map.value("sslClientKey").toString();
    p.timeout       = map.value("timeout", 30).toInt();
    p.schema        = map.value("schema").toString();
    return p;
}
