#include "SshManager.h"
#include "SshTunnel.h"
#include "CredentialStore.h"
#include <QSettings>
#include <QJsonDocument>
#include <QJsonArray>
#include <QJsonObject>
#include <QUuid>
#include <QThread>
#include <QFile>
#include <QtConcurrent/QtConcurrent>
#include <QFutureWatcher>

// Keychain entry for an SSH config's password. Passwords live only in the OS
// keychain (and in memory); save() never writes them to QSettings.
static QString sshKeychainKey(const QString &id)
{
    return QStringLiteral("ssh_") + id;
}

namespace {

struct SshTestOutcome {
    bool    ok = false;
    QString message;

    // Set when the host is not in known_hosts: nothing was tried, the user
    // must confirm the key first.
    bool    hostKeyUnknown = false;
    QString endpoint;      // "host:port", for display
    QString fingerprints;
    QString keyLines;
};

// Worker-thread body. An unknown host stops the test before any login attempt,
// the same way the connection path does — otherwise the failure would just be
// "Host key verification failed" with no way forward.
SshTestOutcome verifyChecked(const QVariantMap &cfg)
{
    SshTestOutcome r;
    const QString host = cfg.value("host").toString();
    const int     port = cfg.value("port", 22).toInt();

    if (!host.isEmpty() && !SshTunnel::isHostKnown(host, port)) {
        r.endpoint = host + ":" + QString::number(port);
        if (SshTunnel::scanHostKey(host, port, r.keyLines, r.fingerprints, r.message))
            r.hostKeyUnknown = true;
        return r;
    }

    r.ok = SshTunnel::verify(cfg, r.message);
    return r;
}

} // namespace

SshManager::SshManager(CredentialStore *credentials, QObject *parent)
    : QObject(parent)
    , m_credentials(credentials)
{
    load();
}

SshManager::~SshManager()
{
    closeAllTunnels();
}

QVariantList SshManager::configs() const
{
    QVariantList list;
    for (const auto &c : m_configs)
        list << c;
    return list;
}

QVariantMap SshManager::configById(const QString &id) const
{
    for (const auto &c : m_configs)
        if (c.value("id").toString() == id)
            return c;
    return {};
}

void SshManager::addConfig(const QVariantMap &data)
{
    QVariantMap c = data;
    const QString id = QUuid::createUuid().toString(QUuid::WithoutBraces);
    c["id"] = id;
    storePassword(id, c.value("password").toString());
    m_configs << c;
    save();
    emit configsChanged();
}

void SshManager::updateConfig(const QString &id, const QVariantMap &data)
{
    for (auto &c : m_configs) {
        if (c.value("id").toString() == id) {
            QVariantMap updated = data;
            updated["id"] = id;
            storePassword(id, updated.value("password").toString());
            c = updated;
            save();
            emit configsChanged();
            return;
        }
    }
}

void SshManager::removeConfig(const QString &id)
{
    if (m_credentials)
        m_credentials->remove(sshKeychainKey(id));
    m_configs.removeIf([&id](const QVariantMap &c) {
        return c.value("id").toString() == id;
    });
    save();
    emit configsChanged();
}

void SshManager::testConfig(const QVariantMap &data)
{
    emit testPending(true);

    auto *watcher = new QFutureWatcher<SshTestOutcome>(this);
    connect(watcher, &QFutureWatcher<SshTestOutcome>::finished, this,
            [this, watcher, data]() {
        const SshTestOutcome r = watcher->result();
        watcher->deleteLater();
        emit testPending(false);

        if (r.hostKeyUnknown) {
            m_pendingTestConfig   = data;
            m_pendingTestKeyLines = r.keyLines;
            emit hostKeyConfirmationRequired(r.endpoint, r.fingerprints);
            return;
        }
        emit testResult(r.ok, r.message);
    });

    watcher->setFuture(QtConcurrent::run([data]() -> SshTestOutcome {
        return verifyChecked(data);
    }));
}

void SshManager::acceptTestHostKey()
{
    if (m_pendingTestConfig.isEmpty()) return;
    const QVariantMap cfg      = m_pendingTestConfig;
    const QString     keyLines = m_pendingTestKeyLines;
    m_pendingTestConfig.clear();
    m_pendingTestKeyLines.clear();

    if (!SshTunnel::trustHostKey(keyLines)) {
        emit testResult(false, "Could not save the host key to ~/.ssh/known_hosts.");
        return;
    }
    testConfig(cfg);
}

void SshManager::rejectTestHostKey()
{
    if (m_pendingTestConfig.isEmpty()) return;
    m_pendingTestConfig.clear();
    m_pendingTestKeyLines.clear();
    emit testResult(false, "SSH host key was not trusted — test cancelled.");
}

// Configs are exported with their id so connections referencing them via
// sshConfigId still resolve after an import on another machine. Passwords
// stay in the keychain and never enter the file.
bool SshManager::exportConfigs(const QUrl &fileUrl)
{
    QJsonArray arr;
    for (const auto &c : m_configs) {
        QJsonObject obj;
        for (auto it = c.cbegin(); it != c.cend(); ++it) {
            if (it.key() == QLatin1String("password"))
                continue;
            obj[it.key()] = QJsonValue::fromVariant(it.value());
        }
        arr.append(obj);
    }
    QJsonObject root;
    root["version"]    = 1;
    root["sshConfigs"] = arr;

    QFile file(fileUrl.toLocalFile());
    if (!file.open(QIODevice::WriteOnly))
        return false;
    file.write(QJsonDocument(root).toJson());
    return true;
}

QVariantMap SshManager::importConfigs(const QUrl &fileUrl)
{
    QFile file(fileUrl.toLocalFile());
    if (!file.open(QIODevice::ReadOnly))
        return {{"success", false}, {"message", QString("Could not open file.")}};

    QJsonParseError err;
    const auto doc = QJsonDocument::fromJson(file.readAll(), &err);
    if (err.error != QJsonParseError::NoError)
        return {{"success", false}, {"message", QString("Invalid file: ") + err.errorString()}};

    const auto arr = doc.object()["sshConfigs"].toArray();
    int added = 0, skipped = 0;
    for (const auto &v : arr) {
        const QJsonObject obj = v.toObject();
        QVariantMap c;
        for (auto it = obj.constBegin(); it != obj.constEnd(); ++it) {
            if (it.key() == QLatin1String("password"))
                continue; // never accept secrets from a file
            c[it.key()] = it.value().toVariant();
        }
        if (c.value("name").toString().isEmpty()) continue;

        const QString id = c.value("id").toString();
        if (id.isEmpty())
            c["id"] = QUuid::createUuid().toString(QUuid::WithoutBraces);
        else if (!configById(id).isEmpty()) { ++skipped; continue; }

        m_configs << c;
        ++added;
    }
    if (added > 0) {
        save();
        emit configsChanged();
    }

    QString msg;
    if (added == 0 && skipped == 0)
        msg = "No valid SSH configs found in file.";
    else if (added == 0)
        msg = "All SSH configs already exist. Nothing imported.";
    else {
        msg = QString("Imported %1 SSH config(s).").arg(added);
        if (skipped > 0)
            msg += QString(" Skipped %1 duplicate(s).").arg(skipped);
        msg += " Passwords must be re-entered.";
    }
    return {{"success", added > 0}, {"message", msg}};
}

void SshManager::storePassword(const QString &id, const QString &password)
{
    if (!m_credentials || id.isEmpty())
        return;
    if (password.isEmpty())
        m_credentials->remove(sshKeychainKey(id));
    else
        m_credentials->store(sshKeychainKey(id), password);
}

// Called from the main thread after the tunnel worker finishes successfully.
void SshManager::registerTunnel(const QString &connectionName, SshTunnel *tunnel)
{
    closeTunnel(connectionName);
    tunnel->moveToThread(QThread::currentThread());
    tunnel->setParent(this);
    m_tunnels.insert(connectionName, tunnel);
}

void SshManager::closeTunnel(const QString &connectionName)
{
    if (auto *t = m_tunnels.take(connectionName)) {
        t->stop();
        delete t;
    }
}

void SshManager::closeAllTunnels()
{
    for (auto *t : std::as_const(m_tunnels)) {
        t->stop();
        delete t;
    }
    m_tunnels.clear();
}

void SshManager::save()
{
    QJsonArray arr;
    for (const auto &c : m_configs) {
        QJsonObject obj;
        for (auto it = c.cbegin(); it != c.cend(); ++it) {
            if (it.key() == QLatin1String("password"))
                continue; // secrets go to the keychain, never to QSettings
            obj[it.key()] = QJsonValue::fromVariant(it.value());
        }
        arr.append(obj);
    }
    QSettings settings("qub", "qub");
    settings.setValue("sshConfigs", QString::fromUtf8(QJsonDocument(arr).toJson(QJsonDocument::Compact)));
}

void SshManager::load()
{
    QSettings settings("qub", "qub");
    const QString raw = settings.value("sshConfigs").toString();
    if (raw.isEmpty()) return;

    QJsonParseError err;
    const auto doc = QJsonDocument::fromJson(raw.toUtf8(), &err);
    if (err.error != QJsonParseError::NoError) return;

    bool migrated = false;
    for (const auto &v : doc.array()) {
        const QJsonObject obj = v.toObject();
        QVariantMap c;
        for (auto it = obj.constBegin(); it != obj.constEnd(); ++it)
            c[it.key()] = it.value().toVariant();

        const QString id       = c.value("id").toString();
        const QString password = c.value("password").toString();
        if (!password.isEmpty()) {
            // Legacy config with a plaintext password in QSettings — move it
            // to the keychain and rewrite the settings without it below.
            storePassword(id, password);
            migrated = true;
        } else if (m_credentials && !id.isEmpty()) {
            m_credentials->retrieve(sshKeychainKey(id),
                [this, id](const QString &pw, const QString &) {
                    if (pw.isEmpty()) return;
                    for (auto &cfg : m_configs) {
                        if (cfg.value("id").toString() == id) {
                            cfg["password"] = pw;
                            break;
                        }
                    }
                    emit configsChanged();
                });
        }
        m_configs << c;
    }

    if (migrated)
        save();
}
