#pragma once

#include <QObject>
#include "QmlSingleton.h"
#include <QList>
#include <QString>
#include <QStringList>
#include <QVariantList>

class QTimer;
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
    // Seconds left before the share stops itself, or 0 when nothing is counting
    // down. Ticks once a second so the toolbar can show it: a share that will
    // end at some unstated moment is worse than one that never ends, because
    // you cannot plan around it.
    Q_PROPERTY(int         secondsLeft   READ secondsLeft   NOTIFY secondsLeftChanged)

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
    int         secondsLeft()   const;

    void setAllowDownload(bool value);

    // lanVisible=false (default) binds to 127.0.0.1 only. If useTls is
    // requested and the certificate can't be loaded, the server does NOT fall
    // back to plaintext — it emits startFailed() and stays inactive.
    // autoStopSeconds > 0 arms a timer that stops the share on its own. Seconds
    // rather than the minutes the setting is written in: the server has no
    // reason to know the unit a settings field happens to use, and a duration
    // it can only be given sixty of at a time cannot be tested in under a
    // minute.
    Q_INVOKABLE void start(bool useTls = false,
                           const QString &certPath = {},
                           const QString &keyPath  = {},
                           bool lanVisible = false,
                           int autoStopSeconds = 0);
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
    void secondsLeftChanged();
    // The timer ran out and the share is already down. Distinct from
    // activeChanged() because the UI has something to say about this one and
    // nothing to say about a stop the person asked for.
    void autoStopped();

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
    QTimer              *m_countdown     = nullptr;
    int                  m_secondsLeft   = 0;
};

QUB_QML_SINGLETON_FOREIGN(LiveShareServer)
