#include "SshTunnel.h"
#include <QProcess>
#include <QTcpSocket>
#include <QTcpServer>
#include <QThread>
#include <QElapsedTimer>
#include <QHostAddress>
#include <QDir>
#include <QFile>
#include <QFileDevice>

SshTunnel::SshTunnel(QObject *parent)
    : QObject(parent)
{}

SshTunnel::~SshTunnel()
{
    stop();
}

int SshTunnel::findFreePort()
{
    QTcpServer srv;
    if (srv.listen(QHostAddress::LocalHost, 0))
        return static_cast<int>(srv.serverPort());
    return -1;
}

bool SshTunnel::waitForPort(int port, int timeoutMs)
{
    QElapsedTimer timer;
    timer.start();

    while (!timer.hasExpired(timeoutMs)) {
        // Exit early if the ssh process died
        if (m_process && m_process->state() == QProcess::NotRunning)
            return false;

        QTcpSocket sock;
        sock.connectToHost(QHostAddress::LocalHost, static_cast<quint16>(port));
        if (sock.waitForConnected(150)) {
            sock.abort();
            return true;
        }

        QThread::msleep(250);
    }
    return false;
}

int SshTunnel::start(const QVariantMap &sshConfig,
                     const QString     &remoteHost,
                     int                remotePort,
                     QString           &errorMsg)
{
    stop();

    const QString sshHost = sshConfig.value("host").toString();
    const int     sshPort = sshConfig.value("port", 22).toInt();
    const QString sshUser = sshConfig.value("username").toString();

    // The UI stores the key under "keyPath"; accept the legacy "keyFile" too.
    // Ignore it when password auth is selected (the field may hold stale text).
    QString keyFile = sshConfig.value("keyPath",
                                      sshConfig.value("keyFile")).toString().trimmed();
    if (sshConfig.value("authMethod").toString() == QLatin1String("password"))
        keyFile.clear();
    if (keyFile == "~")
        keyFile = QDir::homePath();
    else if (keyFile.startsWith("~/"))
        keyFile = QDir::homePath() + keyFile.mid(1);

    if (sshHost.isEmpty()) {
        errorMsg = "SSH config has no host set.";
        return -1;
    }

    m_localPort = findFreePort();
    if (m_localPort < 0) {
        errorMsg = "Could not find a free local port.";
        return -1;
    }

    const QString fwdSpec = QString("%1:127.0.0.1:%2").arg(m_localPort).arg(remotePort);
    const QString target  = sshUser.isEmpty() ? sshHost
                                               : (sshUser + "@" + sshHost);

    QStringList args;
    args << "-N"
         << "-o" << "BatchMode=yes"
         // Unknown hosts are confirmed by the user beforehand (scanHostKey /
         // trustHostKey), so an unrecognized or changed key is a hard failure.
         << "-o" << "StrictHostKeyChecking=yes"
         << "-o" << "ExitOnForwardFailure=yes"
         << "-o" << "ServerAliveInterval=15"
         << "-p" << QString::number(sshPort)
         << "-L" << fwdSpec;
    if (!keyFile.isEmpty())
        args << "-i" << keyFile;
    args << target;

    m_process = new QProcess(nullptr);
    m_process->setProcessChannelMode(QProcess::MergedChannels);
    m_process->start("ssh", args);

    if (!m_process->waitForStarted(5000)) {
        errorMsg = "Could not start ssh: " + m_process->errorString()
                   + ". Make sure 'ssh' is on your PATH.";
        delete m_process;
        m_process  = nullptr;
        m_localPort = -1;
        return -1;
    }

    if (!waitForPort(m_localPort, 10000)) {
        const QString sshOutput = m_process->readAll();
        errorMsg = "SSH tunnel did not become ready within 10 s.";
        if (!sshOutput.isEmpty())
            errorMsg += "\nssh output: " + sshOutput.trimmed();
        stop();
        return -1;
    }

    return m_localPort;
}

void SshTunnel::stop()
{
    if (!m_process) return;

    if (m_process->state() != QProcess::NotRunning) {
        m_process->terminate();
        if (!m_process->waitForFinished(2000))
            m_process->kill();
    }
    delete m_process;
    m_process   = nullptr;
    m_localPort  = -1;
}

bool SshTunnel::isRunning() const
{
    return m_process && m_process->state() != QProcess::NotRunning;
}

// ── Host key verification ─────────────────────────────────────────────────────

// known_hosts uses "[host]:port" for non-default ports, plain host for 22.
static QString hostPattern(const QString &host, int port)
{
    return port == 22 ? host
                      : QStringLiteral("[%1]:%2").arg(host).arg(port);
}

bool SshTunnel::isHostKnown(const QString &host, int port)
{
    QProcess p;
    p.start("ssh-keygen", {"-F", hostPattern(host, port)});
    if (!p.waitForFinished(5000)) {
        p.kill();
        return false;
    }
    // ssh-keygen -F exits 0 and prints the entry when the host is known.
    return p.exitCode() == 0 && !p.readAllStandardOutput().trimmed().isEmpty();
}

bool SshTunnel::scanHostKey(const QString &host, int port,
                            QString &keyLines, QString &fingerprints,
                            QString &error)
{
    QProcess scan;
    scan.start("ssh-keyscan", {"-T", "5", "-p", QString::number(port), host});
    if (!scan.waitForFinished(15000)) {
        scan.kill();
        error = "ssh-keyscan timed out.";
        return false;
    }
    keyLines = QString::fromUtf8(scan.readAllStandardOutput()).trimmed();
    if (keyLines.isEmpty()) {
        const QString err = QString::fromUtf8(scan.readAllStandardError()).trimmed();
        error = "Could not fetch the host key from " + host + ":" + QString::number(port)
                + (err.isEmpty() ? "." : ".\n" + err);
        return false;
    }

    QProcess fp;
    fp.start("ssh-keygen", {"-lf", "-"});
    if (!fp.waitForStarted(5000)) {
        error = "Could not start ssh-keygen: " + fp.errorString();
        return false;
    }
    fp.write(keyLines.toUtf8() + "\n");
    fp.closeWriteChannel();
    if (!fp.waitForFinished(5000)) {
        fp.kill();
        error = "ssh-keygen timed out while computing fingerprints.";
        return false;
    }
    fingerprints = QString::fromUtf8(fp.readAllStandardOutput()).trimmed();
    if (fingerprints.isEmpty()) {
        error = "Could not compute the host key fingerprint.";
        return false;
    }
    return true;
}

bool SshTunnel::trustHostKey(const QString &keyLines)
{
    if (keyLines.trimmed().isEmpty())
        return false;

    const QString sshDir = QDir::homePath() + "/.ssh";
    QDir().mkpath(sshDir);
    QFile::setPermissions(sshDir, QFileDevice::ReadOwner | QFileDevice::WriteOwner |
                                  QFileDevice::ExeOwner);

    QFile f(sshDir + "/known_hosts");
    const bool existed = f.exists();
    if (!f.open(QIODevice::WriteOnly | QIODevice::Append | QIODevice::Text))
        return false;
    if (!existed)
        f.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner);
    f.write(keyLines.trimmed().toUtf8() + "\n");
    return true;
}
