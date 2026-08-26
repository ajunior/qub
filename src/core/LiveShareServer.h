#pragma once

#include <QObject>
#include "QmlSingleton.h"
#include <QList>
#include <QString>
#include <QStringList>
#include <QVariantList>

class QHttpServer;
class QTcpServer;
class QWebSocket;

class LiveShareServer : public QObject {
    Q_OBJECT
    QUB_QML_SINGLETON(LiveShareServer)

public:
    Q_PROPERTY(bool        active      READ isActive    NOTIFY activeChanged)
    Q_PROPERTY(bool        usingTls    READ usingTls    NOTIFY activeChanged)
    Q_PROPERTY(QString     url         READ url         NOTIFY activeChanged)
    Q_PROPERTY(QStringList lanUrls     READ lanUrls     NOTIFY activeChanged)
    Q_PROPERTY(QString     publicUrl   READ publicUrl   NOTIFY publicUrlChanged)
    Q_PROPERTY(int         clientCount   READ clientCount   NOTIFY clientCountChanged)
    Q_PROPERTY(bool        allowDownload READ allowDownload WRITE setAllowDownload NOTIFY allowDownloadChanged)
    Q_PROPERTY(bool        lanVisible    READ lanVisible    NOTIFY activeChanged)

public:
    explicit LiveShareServer(QObject *parent = nullptr);
    ~LiveShareServer() override;

    bool        isActive()     const;
    bool        usingTls()     const;
    QString     url()          const;
    QStringList lanUrls()      const;
    QString     publicUrl()    const;
    int         clientCount()  const;
    bool        allowDownload() const;
    bool        lanVisible()   const;

    void setAllowDownload(bool value);

    // lanVisible=false (default) binds to 127.0.0.1 only. If useTls is
    // requested and the certificate can't be loaded, the server does NOT fall
    // back to plaintext — it emits startFailed() and stays inactive.
    Q_INVOKABLE void start(bool useTls = false,
                           const QString &certPath = {},
                           const QString &keyPath  = {},
                           bool lanVisible = false);
    Q_INVOKABLE void stop();
    Q_INVOKABLE void fetchPublicIp();

public slots:
    void onExecutionStarted(const QString &connectionName, const QString &sql);
    void onExecutionFinished(bool success, qint64 elapsedMs, int rowCount, int rowsAffected);
    void onExecutionError(const QString &message);
    void onResultsReady(const QStringList &columns, const QVariantList &rows, bool truncated);

signals:
    void activeChanged();
    void clientCountChanged();
    void publicUrlChanged();
    void allowDownloadChanged();
    void startFailed(const QString &message);

private:
    void broadcast(const QByteArray &json);
    bool tokenMatches(const QString &provided) const;
    static bool generateSelfSignedCert(const QString &certFile, const QString &keyFile);

    QHttpServer         *m_http      = nullptr;
    QList<QWebSocket *>  m_clients;
    QString              m_token;
    QString              m_url;
    QString              m_publicUrl;
    quint16              m_port          = 0;
    bool                 m_active        = false;
    bool                 m_useTls        = false;
    bool                 m_allowDownload = false;
    bool                 m_lanVisible    = false;
};

QUB_QML_SINGLETON_FOREIGN(LiveShareServer)
