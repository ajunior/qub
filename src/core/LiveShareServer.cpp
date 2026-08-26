#include "LiveShareServer.h"

#include <QHttpServer>
#include <QHttpServerRequest>
#include <QHttpServerResponse>
#include <QHttpServerWebSocketUpgradeResponse>
#include <QTcpServer>
#include <QSslServer>
#include <QSslConfiguration>
#include <QSslCertificate>
#include <QSslKey>
#include <QWebSocket>
#include <QUrlQuery>
#include <QJsonObject>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonValue>
#include <QFile>
#include <QUuid>
#include <QHostAddress>
#include <QNetworkInterface>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QAbstractSocket>
#include <QStandardPaths>
#include <QDir>
#include <QCryptographicHash>

#include <openssl/bio.h>
#include <openssl/evp.h>
#include <openssl/x509.h>
#include <openssl/pem.h>

LiveShareServer::LiveShareServer(QObject *parent) : QObject(parent) {}

LiveShareServer::~LiveShareServer() { stop(); }

bool    LiveShareServer::isActive()     const { return m_active; }
bool    LiveShareServer::usingTls()     const { return m_useTls; }
QString LiveShareServer::url()          const { return m_url; }
QString LiveShareServer::publicUrl()    const { return m_publicUrl; }
int     LiveShareServer::clientCount()  const { return m_clients.size(); }
bool    LiveShareServer::allowDownload() const { return m_allowDownload; }
bool    LiveShareServer::lanVisible()   const { return m_lanVisible; }

bool LiveShareServer::tokenMatches(const QString &provided) const
{
    // Compare fixed-length digests so the comparison cannot leak how many
    // leading characters of the token were correct (timing attack).
    const QByteArray a = QCryptographicHash::hash(m_token.toUtf8(),  QCryptographicHash::Sha256);
    const QByteArray b = QCryptographicHash::hash(provided.toUtf8(), QCryptographicHash::Sha256);
    char diff = 0;
    for (int i = 0; i < a.size(); ++i)
        diff |= a[i] ^ b[i];
    return diff == 0;
}

void LiveShareServer::setAllowDownload(bool value)
{
    if (m_allowDownload == value) return;
    m_allowDownload = value;
    emit allowDownloadChanged();
    // Push the updated config to all connected viewers immediately.
    broadcast(QJsonDocument(QJsonObject{
        {"type", "config"}, {"allowDownload", m_allowDownload}
    }).toJson(QJsonDocument::Compact));
}

QStringList LiveShareServer::lanUrls() const
{
    if (!m_active || !m_lanVisible) return {};
    QStringList urls;
    for (const QNetworkInterface &iface : QNetworkInterface::allInterfaces()) {
        const auto flags = iface.flags();
        if (!(flags & QNetworkInterface::IsUp))      continue;
        if (!(flags & QNetworkInterface::IsRunning)) continue;
        if (flags  & QNetworkInterface::IsLoopBack)  continue;
        for (const QNetworkAddressEntry &entry : iface.addressEntries()) {
            const QHostAddress addr = entry.ip();
            if (addr.protocol() == QAbstractSocket::IPv4Protocol)
                urls << QStringLiteral("%1://%2:%3/live?token=%4")
                        .arg(m_useTls ? "https" : "http")
                        .arg(addr.toString()).arg(m_port).arg(m_token);
        }
    }
    return urls;
}

void LiveShareServer::fetchPublicIp()
{
    // Pointless (and misleading) when bound to 127.0.0.1 only.
    if (!m_active || !m_lanVisible) return;
    auto *nam   = new QNetworkAccessManager(this);
    auto *reply = nam->get(QNetworkRequest(QUrl(QStringLiteral("https://api.ipify.org"))));
    connect(reply, &QNetworkReply::finished, this, [this, reply, nam]() {
        if (reply->error() == QNetworkReply::NoError) {
            const QString ip = QString::fromUtf8(reply->readAll()).trimmed();
            if (!ip.isEmpty())
                m_publicUrl = QStringLiteral("%1://%2:%3/live?token=%4")
                                  .arg(m_useTls ? "https" : "http")
                                  .arg(ip).arg(m_port).arg(m_token);
        }
        emit publicUrlChanged();
        reply->deleteLater();
        nam->deleteLater();
    });
}

bool LiveShareServer::generateSelfSignedCert(const QString &certFile, const QString &keyFile)
{
    EVP_PKEY *pkey = EVP_RSA_gen(2048);
    if (!pkey) return false;

    X509 *x509 = X509_new();
    if (!x509) { EVP_PKEY_free(pkey); return false; }

    ASN1_INTEGER_set(X509_get_serialNumber(x509), 1);
    X509_gmtime_adj(X509_getm_notBefore(x509), 0);
    X509_gmtime_adj(X509_getm_notAfter(x509),  60L * 60 * 24 * 365 * 10); // 10 years

    X509_set_pubkey(x509, pkey);

    X509_NAME *name = X509_get_subject_name(x509);
    X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC,
        reinterpret_cast<const unsigned char *>("qub Live Share"), -1, -1, 0);
    X509_set_issuer_name(x509, name);

    if (!X509_sign(x509, pkey, EVP_sha256())) {
        X509_free(x509); EVP_PKEY_free(pkey); return false;
    }

    // Render both PEMs to memory so the key file can be created with
    // owner-only permissions before any secret bytes touch the disk.
    BIO *cb = BIO_new(BIO_s_mem());
    BIO *kb = BIO_new(BIO_s_mem());
    const bool rendered = cb && kb
        && PEM_write_bio_X509(cb, x509) == 1
        && PEM_write_bio_PrivateKey(kb, pkey, nullptr, nullptr, 0, nullptr, nullptr) == 1;

    QByteArray certPem, keyPem;
    if (rendered) {
        char *data = nullptr;
        long  n    = BIO_get_mem_data(cb, &data);
        certPem = QByteArray(data, static_cast<int>(n));
        n = BIO_get_mem_data(kb, &data);
        keyPem  = QByteArray(data, static_cast<int>(n));
    }
    if (cb) BIO_free(cb);
    if (kb) BIO_free(kb);
    X509_free(x509);
    EVP_PKEY_free(pkey);
    if (!rendered) return false;

    const auto writeFile = [](const QString &path, const QByteArray &pem, bool ownerOnly) {
        QFile f(path);
        if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate)) return false;
        if (ownerOnly)
            f.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner);
        return f.write(pem) == pem.size();
    };
    return writeFile(certFile, certPem, false)
        && writeFile(keyFile,  keyPem,  true);
}

void LiveShareServer::start(bool useTls, const QString &certPath, const QString &keyPath,
                            bool lanVisible)
{
    if (m_active) return;

    // Exposing the server on the LAN in plaintext would broadcast every query,
    // its result rows, and the bearer token across the network in the clear.
    // Refuse: LAN visibility requires TLS. (Localhost-only plaintext is fine —
    // it never leaves the machine.)
    if (lanVisible && !useTls) {
        emit startFailed("LAN visibility requires TLS. Enable \"Use TLS\" in "
                         "Live Share settings, or keep the session on this "
                         "machine only.");
        return;
    }

    m_lanVisible = lanVisible;
    m_token = QUuid::createUuid().toString(QUuid::WithoutBraces);
    m_http  = new QHttpServer(this);

    // ── Serve the live page ───────────────────────────────────────────────────
    m_http->route("/live", [this](const QHttpServerRequest &req) {
        if (!tokenMatches(req.query().queryItemValue("token")))
            return QHttpServerResponse(QHttpServerResponse::StatusCode::Forbidden);

        QFile f(QStringLiteral(":/qt/qml/Qub/resources/live/index.html"));
        if (!f.open(QIODevice::ReadOnly))
            return QHttpServerResponse(QHttpServerResponse::StatusCode::InternalServerError);
        return QHttpServerResponse("text/html; charset=utf-8", f.readAll());
    });

    // ── WebSocket upgrade on /live/ws ─────────────────────────────────────────
    m_http->addWebSocketUpgradeVerifier(this, [this](const QHttpServerRequest &req) {
        if (req.url().path() != QStringLiteral("/live/ws"))
            return QHttpServerWebSocketUpgradeResponse::deny();
        if (!tokenMatches(req.query().queryItemValue("token")))
            return QHttpServerWebSocketUpgradeResponse::deny();
        return QHttpServerWebSocketUpgradeResponse::accept();
    });

    connect(m_http, &QHttpServer::newWebSocketConnection, this, [this]() {
        auto ws = m_http->nextPendingWebSocketConnection();
        if (!ws) return;
        auto *client = ws.release();
        client->setParent(this);
        m_clients.append(client);
        emit clientCountChanged();
        // Tell the new viewer about server-side capabilities.
        client->sendTextMessage(QString::fromUtf8(
            QJsonDocument(QJsonObject{
                {"type", "init"}, {"allowDownload", m_allowDownload}
            }).toJson(QJsonDocument::Compact)));
        connect(client, &QWebSocket::disconnected, this, [this, client]() {
            m_clients.removeOne(client);
            client->deleteLater();
            emit clientCountChanged();
        });
    });

    // ── Bind ──────────────────────────────────────────────────────────────────
    // Only expose the server beyond this machine when explicitly requested.
    const QHostAddress bindAddr = m_lanVisible ? QHostAddress(QHostAddress::AnyIPv4)
                                               : QHostAddress(QHostAddress::LocalHost);

    const auto fail = [this](const QString &message) {
        m_http->deleteLater();
        m_http       = nullptr;
        m_lanVisible = false;
        emit startFailed(message);
    };

    if (useTls) {
        QString resolvedCert = certPath;
        QString resolvedKey  = keyPath;

        // Fall back to auto-generated cert when no custom paths provided
        if (resolvedCert.isEmpty() || resolvedKey.isEmpty()) {
            const QString dir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
            QDir().mkpath(dir);
            resolvedCert = dir + "/liveshare.crt";
            resolvedKey  = dir + "/liveshare.key";
            if (!QFile::exists(resolvedCert) || !QFile::exists(resolvedKey)) {
                if (!generateSelfSignedCert(resolvedCert, resolvedKey)) {
                    fail("Could not generate a self-signed TLS certificate.");
                    return;
                }
            }
        }

        QFile cf(resolvedCert), kf(resolvedKey);
        (void)cf.open(QIODevice::ReadOnly);
        (void)kf.open(QIODevice::ReadOnly);
        const QSslCertificate cert(&cf, QSsl::Pem);
        QSslKey key;
        key = QSslKey(&kf, QSsl::Rsa, QSsl::Pem);
        if (key.isNull()) { kf.seek(0); key = QSslKey(&kf, QSsl::Ec, QSsl::Pem); }
        cf.close(); kf.close();

        // TLS was requested: never downgrade to plaintext on failure.
        if (cert.isNull() || key.isNull()) {
            fail("Could not load the TLS certificate or key from:\n"
                 + resolvedCert + "\n" + resolvedKey);
            return;
        }

        QSslConfiguration sslCfg;
        sslCfg.setLocalCertificate(cert);
        sslCfg.setPrivateKey(key);

        auto *ssl = new QSslServer(this);
        ssl->setSslConfiguration(sslCfg);
        if (!ssl->listen(bindAddr, 0)) {
            delete ssl;
            fail("Could not start the TLS server.");
            return;
        }
        m_http->bind(ssl);
        m_port   = ssl->serverPort();
        m_useTls = true;
    } else {
        auto *tcp = new QTcpServer(this);
        if (!tcp->listen(bindAddr, 0)) {
            delete tcp;
            fail("Could not start the Live Share server.");
            return;
        }
        m_http->bind(tcp);
        m_port = tcp->serverPort();
    }

    const QString scheme = m_useTls ? "https" : "http";
    m_url    = QStringLiteral("%1://localhost:%2/live?token=%3").arg(scheme).arg(m_port).arg(m_token);
    m_active = true;
    emit activeChanged();
    emit clientCountChanged();
}

void LiveShareServer::stop()
{
    if (!m_active) return;

    for (auto *client : std::as_const(m_clients))
        client->close();
    m_clients.clear();

    m_http->deleteLater();
    m_http       = nullptr;
    m_active     = false;
    m_useTls     = false;
    m_lanVisible = false;
    m_port       = 0;
    m_url.clear();
    m_publicUrl.clear();

    emit activeChanged();
    emit clientCountChanged();
}

void LiveShareServer::broadcast(const QByteArray &json)
{
    const QString text = QString::fromUtf8(json);
    for (auto *client : std::as_const(m_clients))
        client->sendTextMessage(text);
}

void LiveShareServer::onExecutionStarted(const QString &, const QString &sql)
{
    if (!m_active) return;
    broadcast(QJsonDocument(QJsonObject{
        {"type", "query"}, {"sql", sql}
    }).toJson(QJsonDocument::Compact));
}

void LiveShareServer::onExecutionFinished(bool success, qint64 elapsedMs, int rowCount, int rowsAffected)
{
    if (!m_active) return;
    broadcast(QJsonDocument(QJsonObject{
        {"type",         "done"},
        {"success",      success},
        {"elapsedMs",    elapsedMs},
        {"rowCount",     rowCount},
        {"rowsAffected", rowsAffected}
    }).toJson(QJsonDocument::Compact));
}

void LiveShareServer::onExecutionError(const QString &message)
{
    if (!m_active) return;
    broadcast(QJsonDocument(QJsonObject{
        {"type", "error"}, {"message", message}
    }).toJson(QJsonDocument::Compact));
}

void LiveShareServer::onResultsReady(const QStringList &columns, const QVariantList &rows, bool truncated)
{
    if (!m_active) return;

    QJsonArray colArr;
    for (const auto &c : columns) colArr.append(c);
    broadcast(QJsonDocument(QJsonObject{
        {"type", "columns"}, {"columns", colArr}
    }).toJson(QJsonDocument::Compact));

    QJsonArray rowsArr;
    for (const auto &rowVar : rows) {
        const QVariantList row = rowVar.toList();
        QJsonArray rowArr;
        for (const auto &cell : row)
            rowArr.append(cell.isNull() ? QJsonValue::Null : QJsonValue::fromVariant(cell));
        rowsArr.append(rowArr);
    }
    broadcast(QJsonDocument(QJsonObject{
        {"type",      "rows"},
        {"rows",      rowsArr},
        {"truncated", truncated}
    }).toJson(QJsonDocument::Compact));
}
