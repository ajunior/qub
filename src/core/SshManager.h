#pragma once

#include <QObject>
#include "QmlSingleton.h"
#include <QVariantList>
#include <QVariantMap>
#include <QList>
#include <QMap>
#include <QUrl>

class SshTunnel;
class CredentialStore;

class SshManager : public QObject {
    Q_OBJECT
    QUB_QML_SINGLETON(SshManager)

public:
    Q_PROPERTY(QVariantList configs READ configs NOTIFY configsChanged)

public:
    explicit SshManager(CredentialStore *credentials = nullptr, QObject *parent = nullptr);
    ~SshManager() override;

    QVariantList configs() const;
    QVariantMap  configById(const QString &id) const;

    Q_INVOKABLE void addConfig(const QVariantMap &data);
    Q_INVOKABLE void updateConfig(const QString &id, const QVariantMap &data);
    Q_INVOKABLE void removeConfig(const QString &id);

    Q_INVOKABLE bool        exportConfigs(const QUrl &fileUrl);
    Q_INVOKABLE QVariantMap importConfigs(const QUrl &fileUrl);

    // Must be called from the main thread after tunnel is ready.
    void registerTunnel(const QString &connectionName, SshTunnel *tunnel);
    void closeTunnel(const QString &connectionName);
    void closeAllTunnels();

signals:
    void configsChanged();

private:
    CredentialStore        *m_credentials = nullptr;
    QList<QVariantMap>      m_configs;
    QMap<QString, SshTunnel*> m_tunnels;  // connectionName → tunnel (main thread only)

    void save();
    void load();
    void storePassword(const QString &id, const QString &password);
};

QUB_QML_SINGLETON_FOREIGN(SshManager)
