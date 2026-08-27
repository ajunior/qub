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
#include <QRegularExpression>

namespace {

// The UI stores the key under "keyPath"; accept the legacy "keyFile" too.
// Ignore it when password auth is selected (the field may hold stale text).
QString resolveKeyPath(const QVariantMap &sshConfig)
{
    QString keyFile = sshConfig.value("keyPath",
                                      sshConfig.value("keyFile")).toString().trimmed();
    if (sshConfig.value("authMethod").toString() == QLatin1String("password"))
        keyFile.clear();
    if (keyFile == "~")
        keyFile = QDir::homePath();
    else if (keyFile.startsWith("~/"))
        keyFile = QDir::homePath() + keyFile.mid(1);
    return keyFile;
}

// -L takes host:port, so a bare IPv6 literal would be unparseable. ssh accepts
// it in brackets.
QString bracketIfIpv6(const QString &host)
{
    return host.contains(QLatin1Char(':')) && !host.startsWith(QLatin1Char('['))
               ? QLatin1Char('[') + host + QLatin1Char(']')
               : host;
}

// Both the readiness check and the forward probe open a connection, so ssh
// reports a broken forward once per probe — same sentence, different channel
// number. Show it once.
QString uniqueLines(const QString &output)
{
    QStringList out;
    const auto lines = output.split(QLatin1Char('\n'), Qt::SkipEmptyParts);
    for (const QString &line : lines) {
        // Drop the leading "channel N: " so repeats compare equal.
        static const QRegularExpression channelPrefix(
            QStringLiteral("^channel \\d+: "));
        const QString trimmed = line.trimmed().remove(channelPrefix);
        if (!trimmed.isEmpty() && !out.contains(trimmed))
            out << trimmed;
    }
    return out.join(QLatin1Char('\n'));
}

// Boils ssh -v output down to something worth showing. The debug lines are the
// bulk of it and say nothing a user can act on; the reason ("Permission
// denied", "Connection refused", "Host key verification failed") is on the
// plain lines at the end.
QString sshFailureMessage(const QString &output)
{
    QStringList lines;
    const auto raw = output.split(QLatin1Char('\n'), Qt::SkipEmptyParts);
    for (const QString &line : raw) {
        const QString trimmed = line.trimmed();
        if (trimmed.isEmpty() || trimmed.startsWith(QLatin1String("debug")))
            continue;
        lines << trimmed;
    }
    if (lines.isEmpty())
        return QStringLiteral("ssh did not authenticate within 20 s.");
    return lines.mid(qMax(0, lines.size() - 4)).join(QLatin1Char('\n'));
}

} // namespace

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

    const QString keyFile = resolveKeyPath(sshConfig);

    if (sshHost.isEmpty()) {
        errorMsg = "SSH config has no host set.";
        return -1;
    }

    m_localPort = findFreePort();
    if (m_localPort < 0) {
        errorMsg = "Could not find a free local port.";
        return -1;
    }

    // The forward target is resolved by the SSH host, not by us: "localhost"
    // here means the far end's loopback. Using the database host as configured
    // is what makes a bastion work at all — the database is rarely on the
    // bastion itself.
    const QString fwdHost = remoteHost.trimmed().isEmpty()
                                ? QStringLiteral("127.0.0.1")
                                : bracketIfIpv6(remoteHost.trimmed());
    const QString fwdSpec = QString("%1:%2:%3").arg(m_localPort)
                                               .arg(fwdHost)
                                               .arg(remotePort);
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

    // A listening local port proves nothing: ssh binds it whether or not the
    // far end is reachable, and only opens the channel once something
    // connects. If that fails it closes the connection it just accepted, and
    // the driver reports it as the *database* hanging up — which sends the
    // user looking at the wrong machine entirely. Find out here instead.
    if (!probeForward(m_localPort, 1200)) {
        // ssh names the reason ("Connection refused", "Name or service not
        // known"), which is the difference between a wrong port and a wrong
        // host. It writes it as the channel fails, so give it a moment.
        m_process->waitForReadyRead(300);
        const QString sshOutput = uniqueLines(QString::fromUtf8(m_process->readAll()));
        errorMsg = QString("SSH is connected, but forwarding to %1:%2 failed. "
                           "Check that the database host and port are correct "
                           "as seen from %3.")
                       .arg(fwdHost).arg(remotePort).arg(sshHost);
        if (!sshOutput.isEmpty())
            errorMsg += "\nssh: " + sshOutput;
        stop();
        return -1;
    }

    return m_localPort;
}

bool SshTunnel::verify(const QVariantMap &sshConfig, QString &message)
{
    const QString sshHost = sshConfig.value("host").toString();
    const int     sshPort = sshConfig.value("port", 22).toInt();
    const QString sshUser = sshConfig.value("username").toString();
    const QString keyFile = resolveKeyPath(sshConfig);

    if (sshHost.isEmpty()) {
        message = "SSH config has no host set.";
        return false;
    }

    const QString target = sshUser.isEmpty() ? sshHost : (sshUser + "@" + sshHost);

    QStringList args;
    args << "-v" << "-N"
         << "-o" << "BatchMode=yes"
         << "-o" << "StrictHostKeyChecking=yes"
         << "-o" << "ConnectTimeout=10"
         << "-p" << QString::number(sshPort);
    if (!keyFile.isEmpty())
        args << "-i" << keyFile;
    args << target;

    QProcess p;
    p.setProcessChannelMode(QProcess::MergedChannels);
    p.start("ssh", args);

    if (!p.waitForStarted(5000)) {
        message = "Could not start ssh: " + p.errorString()
                  + ". Make sure 'ssh' is on your PATH.";
        return false;
    }

    // -N asks for no channel, so a successful ssh just sits there: waiting for
    // it to exit would mean waiting out the timeout on every success. What it
    // does say is the verbose "Authenticated to ..." line, and that is the
    // answer. Running a remote command instead (ssh ... true) would report a
    // failure on bastions that forbid one, even though the login worked.
    QString       output;
    bool          authenticated = false;
    QElapsedTimer timer;
    timer.start();

    while (!timer.hasExpired(20000)) {
        if (p.waitForReadyRead(500))
            output += QString::fromUtf8(p.readAll());
        if (output.contains(QLatin1String("Authenticated to"))
            || output.contains(QLatin1String("Authentication succeeded"))) {
            authenticated = true;
            break;
        }
        if (p.state() == QProcess::NotRunning) {
            output += QString::fromUtf8(p.readAll());
            break;
        }
    }

    if (p.state() != QProcess::NotRunning) {
        p.terminate();
        if (!p.waitForFinished(2000))
            p.kill();
    }

    if (authenticated) {
        message = "Authenticated to " + target + " on port "
                  + QString::number(sshPort) + ".";
        return true;
    }

    message = sshFailureMessage(output);
    return false;
}

// A working forward leaves the probe connection open and silent — every
// protocol qub tunnels has the client speak first, and even the ones that
// greet (MySQL) do not hang up. A refused target is closed by ssh at once, so
// an early disconnect is the signal. A target that black-holes packets instead
// of refusing them still times out here and is let through: the alternative is
// stalling every good connection for the length of ssh's own connect timeout.
bool SshTunnel::probeForward(int port, int timeoutMs)
{
    QTcpSocket sock;
    sock.connectToHost(QHostAddress::LocalHost, static_cast<quint16>(port));
    if (!sock.waitForConnected(2000))
        return false;

    const bool closedByPeer = sock.waitForDisconnected(timeoutMs);
    sock.abort();
    return !closedByPeer;
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
