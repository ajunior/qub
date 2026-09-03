#include "DockerDiscovery.h"

#include <QHash>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonValue>
#include <QProcess>
#include <QStandardPaths>

#include <initializer_list>

namespace {

struct Engine {
    QString driver;   // Qt SQL driver key (matches drivers.js MAP keys)
    int     port;     // default container-internal port
};

// The Postgres distributions whose image name does not contain "postgres".
// Each is a Postgres server on 5432 speaking the ordinary wire protocol —
// stock Postgres with an extension already built in — so QPSQL connects to
// them exactly as it does to the official image. The list is names, not a
// pattern, because there is no shape they share: "postgis" is not a prefix of
// "postgres", it is a different word.
static const char *POSTGRES_DISTRIBUTIONS[] = {
    "postgis", "timescale", "pgvector", "citus", "supabase"
};

// Map a container image to a supported database engine, or return false.
// Checked most-specific first so a "mysql" substring cannot swallow mariadb.
bool engineForImage(const QString &image, Engine *out)
{
    const QString img = image.toLower();
    // "postgresql" contains "postgres", so bitnami/postgresql lands here too.
    if (img.contains("postgres")) { *out = { QStringLiteral("QPSQL"),    5432 }; return true; }
    for (const char *distro : POSTGRES_DISTRIBUTIONS)
        if (img.contains(QLatin1String(distro))) {
            *out = { QStringLiteral("QPSQL"), 5432 };
            return true;
        }
    if (img.contains("mariadb"))  { *out = { QStringLiteral("QMARIADB"), 3306 }; return true; }
    if (img.contains("mysql"))    { *out = { QStringLiteral("QMYSQL"),   3306 }; return true; }
    return false;
}

// Container env is a JSON array of "KEY=value" strings.
QHash<QString, QString> envMap(const QJsonArray &env)
{
    QHash<QString, QString> m;
    for (const QJsonValue &v : env) {
        const QString s = v.toString();
        const int eq = s.indexOf('=');
        if (eq > 0) m.insert(s.left(eq), s.mid(eq + 1));
    }
    return m;
}

QString firstNonEmpty(const QHash<QString, QString> &env,
                      std::initializer_list<const char *> keys)
{
    for (const char *k : keys) {
        const auto it = env.constFind(QString::fromLatin1(k));
        if (it != env.constEnd() && !it.value().isEmpty()) return it.value();
    }
    return {};
}

// The published host port bound to `internalPort`/tcp, or 0 when the port is
// not published to the host (container only reachable on a Docker network, so
// unreachable from qub). This reads the *actual* mapped port — a container's
// 5432 published as 49154 returns 49154, which is the whole point of
// inspecting rather than assuming the default.
int publishedPort(const QJsonObject &ports, int internalPort)
{
    const QJsonValue bindings = ports.value(QString::number(internalPort) + "/tcp");
    if (!bindings.isArray()) return 0;
    const QJsonArray arr = bindings.toArray();
    if (arr.isEmpty()) return 0;
    // Prefer a loopback / all-interfaces binding; fall back to the first entry.
    for (const QJsonValue &b : arr) {
        const QJsonObject o = b.toObject();
        const QString ip = o.value(QStringLiteral("HostIp")).toString();
        if (ip.isEmpty() || ip == QLatin1String("0.0.0.0") || ip == QLatin1String("127.0.0.1"))
            return o.value(QStringLiteral("HostPort")).toString().toInt();
    }
    return arr.first().toObject().value(QStringLiteral("HostPort")).toString().toInt();
}

} // namespace

DockerDiscovery::DockerDiscovery(QObject *parent) : QObject(parent) {}

bool DockerDiscovery::available() const
{
    return !QStandardPaths::findExecutable(QStringLiteral("docker")).isEmpty();
}

QVariantList DockerDiscovery::parseContainers(const QByteArray &inspectJson)
{
    QVariantList out;
    QJsonParseError err{};
    const QJsonDocument doc = QJsonDocument::fromJson(inspectJson, &err);
    if (err.error != QJsonParseError::NoError || !doc.isArray())
        return out;

    for (const QJsonValue &cv : doc.array()) {
        const QJsonObject c      = cv.toObject();
        const QJsonObject config = c.value(QStringLiteral("Config")).toObject();

        Engine eng;
        const QString image = config.value(QStringLiteral("Image")).toString();
        if (!engineForImage(image, &eng))
            continue;

        const QJsonObject netPorts = c.value(QStringLiteral("NetworkSettings"))
                                         .toObject().value(QStringLiteral("Ports")).toObject();
        const int hostPort = publishedPort(netPorts, eng.port);
        if (hostPort == 0)
            continue;   // not reachable from the host — skip

        const QHash<QString, QString> env = envMap(config.value(QStringLiteral("Env")).toArray());

        // Container name is returned as "/my-postgres" — strip the slash.
        QString name = c.value(QStringLiteral("Name")).toString();
        if (name.startsWith('/')) name = name.mid(1);

        QString user, pass, db;
        if (eng.driver == QLatin1String("QPSQL")) {
            user = firstNonEmpty(env, { "POSTGRES_USER" });
            if (user.isEmpty()) user = QStringLiteral("postgres");
            pass = firstNonEmpty(env, { "POSTGRES_PASSWORD" });
            db   = firstNonEmpty(env, { "POSTGRES_DB" });
            if (db.isEmpty()) db = user;
        } else {
            // MySQL / MariaDB share env conventions (MARIADB_* alias MYSQL_*).
            user = firstNonEmpty(env, { "MYSQL_USER", "MARIADB_USER" });
            if (!user.isEmpty()) {
                pass = firstNonEmpty(env, { "MYSQL_PASSWORD", "MARIADB_PASSWORD" });
            } else {
                user = QStringLiteral("root");
                pass = firstNonEmpty(env, { "MYSQL_ROOT_PASSWORD", "MARIADB_ROOT_PASSWORD" });
            }
            db = firstNonEmpty(env, { "MYSQL_DATABASE", "MARIADB_DATABASE" });
        }

        QVariantMap m;
        m[QStringLiteral("name")]     = name;
        m[QStringLiteral("image")]    = image;
        m[QStringLiteral("driver")]   = eng.driver;
        m[QStringLiteral("host")]     = QStringLiteral("127.0.0.1");
        m[QStringLiteral("port")]     = hostPort;
        m[QStringLiteral("database")] = db;
        m[QStringLiteral("username")] = user;
        m[QStringLiteral("password")] = pass;
        out.append(m);
    }
    return out;
}

QVariantList DockerDiscovery::discover() const
{
    if (!available()) return {};

    // 1. Running container IDs.
    QProcess ps;
    ps.start(QStringLiteral("docker"),
             { QStringLiteral("ps"), QStringLiteral("--no-trunc"),
               QStringLiteral("--format"), QStringLiteral("{{.ID}}") });
    if (!ps.waitForFinished(3000) || ps.exitStatus() != QProcess::NormalExit
        || ps.exitCode() != 0)
        return {};

    QStringList ids;
    const QList<QByteArray> lines = ps.readAllStandardOutput().split('\n');
    for (const QByteArray &l : lines) {
        const QByteArray t = l.trimmed();
        if (!t.isEmpty()) ids << QString::fromLatin1(t);
    }
    if (ids.isEmpty()) return {};

    // 2. Full inspect JSON for those containers.
    QProcess inspect;
    inspect.start(QStringLiteral("docker"), QStringList{ QStringLiteral("inspect") } + ids);
    if (!inspect.waitForFinished(3000) || inspect.exitStatus() != QProcess::NormalExit
        || inspect.exitCode() != 0)
        return {};

    return parseContainers(inspect.readAllStandardOutput());
}
