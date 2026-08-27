#pragma once

#include <QObject>
#include <QVariantMap>

class QProcess;

// Manages a single `ssh -L` port-forwarding process.
// Call start() from any thread (blocks until the tunnel port is ready or times out).
// Call stop() from the main thread.
class SshTunnel : public QObject {
    Q_OBJECT
public:
    explicit SshTunnel(QObject *parent = nullptr);
    ~SshTunnel() override;

    // Opens the tunnel and blocks until the forwarded port accepts connections.
    // Returns the local port on success, -1 on failure (errorMsg is set).
    int  start(const QVariantMap &sshConfig,
               const QString     &remoteHost,
               int                remotePort,
               QString           &errorMsg);

    // Checks that ssh can log in to the host in a config, without forwarding
    // anything. Blocks (up to ~20 s); safe to call from a worker thread.
    // Returns true on success; message always carries something to show.
    static bool verify(const QVariantMap &sshConfig, QString &message);

    void stop();
    bool isRunning() const;
    int  localPort() const { return m_localPort; }

    // ── Host key verification (all safe to call from worker threads) ─────────
    // start() runs ssh with StrictHostKeyChecking=yes, so unknown hosts must be
    // confirmed by the user and trusted via trustHostKey() first.

    // True if the host already has an entry in ~/.ssh/known_hosts.
    static bool isHostKnown(const QString &host, int port);

    // Fetches the host's public keys with ssh-keyscan. On success fills
    // keyLines (known_hosts format) and fingerprints (human-readable, one per
    // line). Returns false and sets error on failure.
    static bool scanHostKey(const QString &host, int port,
                            QString &keyLines, QString &fingerprints,
                            QString &error);

    // Appends previously scanned keyLines to ~/.ssh/known_hosts.
    static bool trustHostKey(const QString &keyLines);

private:
    bool waitForPort(int port, int timeoutMs);
    int  findFreePort();

    QProcess *m_process  = nullptr;
    int       m_localPort = -1;
};
