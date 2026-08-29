#include "QtSqlAdapter.h"
#include <QSqlQuery>
#include <QSqlRecord>
#include <QSqlField>
#include <QSqlIndex>
#include <QSqlError>
#include <QElapsedTimer>
#include <QUuid>
#include <QSet>
#include <QMap>
#include <QVariant>

QtSqlAdapter::QtSqlAdapter(QObject *parent)
    : DatabaseAdapter(parent)
    , m_connectionId(QUuid::createUuid().toString(QUuid::WithoutBraces))
{}

QtSqlAdapter::~QtSqlAdapter()
{
    close();
    if (QSqlDatabase::contains(m_connectionId)) {
        m_db = QSqlDatabase();   // release member copy before removal
        QSqlDatabase::removeDatabase(m_connectionId);
    }
}

static QString missingLibHint(const QString &driver)
{
    if (driver == "QPSQL")                      return " Make sure libpq (PostgreSQL client library) is installed.";
    if (driver == "QMYSQL" || driver == "QMARIADB") return " Make sure libmysqlclient / libmariadb is installed.";
    if (driver == "QOCI")                       return " Make sure Oracle Instant Client is installed.";
    return {};
}

bool QtSqlAdapter::open(const ConnectionParams &params)
{
    m_params = params;
    m_db = QSqlDatabase::addDatabase(params.driver, m_connectionId);

    if (!m_db.isValid()) {
        emit errorOccurred("The " + params.driver + " driver could not be loaded." + missingLibHint(params.driver));
        return false;
    }

    if (params.driver != "QSQLITE") {
        m_db.setHostName(params.host);
        m_db.setPort(params.port);
        m_db.setUserName(params.username);
        m_db.setPassword(params.password);
    }
    m_db.setDatabaseName(params.database);

    QStringList opts;
    if (params.timeout > 0) {
        if (params.driver == "QPSQL")
            opts << QString("connect_timeout=%1").arg(params.timeout);
        else if (params.driver == "QMYSQL" || params.driver == "QMARIADB")
            opts << QString("MYSQL_OPT_CONNECT_TIMEOUT=%1").arg(params.timeout);
    }
    if (params.ssl) {
        // When the user supplies a CA certificate, verify the server's
        // certificate chain against it — plain "require"/SSL_MODE_REQUIRED only
        // encrypts and will accept ANY certificate, which is defeated by an
        // active MITM. Chain verification (rather than full hostname
        // verification) is used on purpose: an SSH tunnel rewrites the host to
        // 127.0.0.1, which would never match the certificate's hostname, so
        // verify-full/VERIFY_IDENTITY would break TLS-over-tunnel connections.
        const bool haveCa = !params.sslCaCert.isEmpty();
        if (params.driver == "QPSQL") {
            opts << (haveCa ? "sslmode=verify-ca" : "sslmode=require");
            if (haveCa)
                opts << "sslrootcert=" + params.sslCaCert;
            if (!params.sslClientCert.isEmpty())
                opts << "sslcert=" + params.sslClientCert;
            if (!params.sslClientKey.isEmpty())
                opts << "sslkey=" + params.sslClientKey;
        } else if (params.driver == "QMYSQL" || params.driver == "QMARIADB") {
            opts << (haveCa ? "MYSQL_OPT_SSL_MODE=SSL_MODE_VERIFY_CA"
                            : "MYSQL_OPT_SSL_MODE=SSL_MODE_REQUIRED");
            if (haveCa)
                opts << "SSL_CA=" + params.sslCaCert;
            if (!params.sslClientCert.isEmpty())
                opts << "SSL_CERT=" + params.sslClientCert;
            if (!params.sslClientKey.isEmpty())
                opts << "SSL_KEY=" + params.sslClientKey;
        }
    }
    if (!opts.isEmpty())
        m_db.setConnectOptions(opts.join(";"));

    if (!m_db.open()) {
        const QString err = m_db.lastError().text();
        emit errorOccurred(err);
        return false;
    }

    if (!params.schema.isEmpty()) {
        QSqlQuery q(m_db);
        // Identifiers can't be bound as parameters; escape the quoting
        // character by doubling it so the name can't break out.
        if (params.driver == "QPSQL") {
            QString schema = params.schema;
            schema.replace('"', "\"\"");
            q.exec(QString("SET search_path TO \"%1\"").arg(schema));
        } else if (params.driver == "QMYSQL" || params.driver == "QMARIADB") {
            QString schema = params.schema;
            schema.replace('`', "``");
            q.exec(QString("USE `%1`").arg(schema));
        }
    }

    emit opened(params.name);
    return true;
}

void QtSqlAdapter::close()
{
    if (m_db.isOpen()) {
        m_db.close();
        emit closed(m_params.name);
    }
}

bool QtSqlAdapter::isOpen() const
{
    return m_db.isOpen();
}

QueryResult QtSqlAdapter::execute(const QString &sql)
{
    QueryResult result;
    QElapsedTimer timer;
    timer.start();

    QSqlQuery query(m_db);
    if (!query.exec(sql)) {
        result.error     = query.lastError().text().trimmed();
        // Some failures (notably running against a closed connection) come back
        // with an empty driver message, which would surface as a blank error in
        // the UI. Fall back to something actionable.
        if (result.error.isEmpty())
            result.error = m_db.isOpen()
                ? QStringLiteral("Query failed with no error message from the database driver.")
                : QStringLiteral("The database connection is not open.");
        result.elapsedMs = timer.elapsed();
        return result;
    }

    const QSqlRecord record = query.record();
    const int columnCount   = record.count();

    for (int i = 0; i < columnCount; ++i)
        result.columns << record.fieldName(i);

    static constexpr int kRowLimit = 1000;
    int fetched = 0;
    while (query.next() && fetched < kRowLimit + 1) {
        QVariantList row;
        row.reserve(columnCount);
        for (int i = 0; i < columnCount; ++i)
            row << query.value(i);
        result.rows << row;
        ++fetched;
    }
    if (fetched == kRowLimit + 1) {
        result.rows.removeLast();
        result.truncated = true;
    }

    result.rowsAffected = query.numRowsAffected();
    result.elapsedMs    = timer.elapsed();
    result.success      = true;
    return result;
}

QString QtSqlAdapter::driverName() const    { return m_params.driver; }
QString QtSqlAdapter::connectionName() const { return m_params.name; }

QStringList QtSqlAdapter::tables() const
{
    return m_db.tables();
}

QVariantList QtSqlAdapter::columns(const QString &table) const
{
    const QSqlRecord rec = m_db.record(table);
    QVariantList result;
    for (int i = 0; i < rec.count(); ++i) {
        const QSqlField f = rec.field(i);
        result << QVariantMap{{"name", f.name()}, {"type", QString(f.metaType().name())}};
    }
    return result;
}

QStringList QtSqlAdapter::primaryKeys(const QString &table) const
{
    const QSqlIndex pk = m_db.primaryIndex(table);
    QStringList names;
    names.reserve(pk.count());
    for (int i = 0; i < pk.count(); ++i)
        names << pk.fieldName(i);
    return names;
}

static QString toSqlTypeName(const QMetaType &mt)
{
    switch (mt.id()) {
    case QMetaType::Int:      case QMetaType::UInt:
    case QMetaType::Long:     case QMetaType::ULong:
    case QMetaType::LongLong: case QMetaType::ULongLong:
    case QMetaType::Short:    case QMetaType::UShort:
        return "INTEGER";
    case QMetaType::Double: case QMetaType::Float:
        return "REAL";
    case QMetaType::Bool:        return "BOOLEAN";
    case QMetaType::QString:     return "TEXT";
    case QMetaType::QByteArray:  return "BLOB";
    case QMetaType::QDateTime:   return "DATETIME";
    case QMetaType::QDate:       return "DATE";
    case QMetaType::QTime:       return "TIME";
    default: return QString(mt.name());
    }
}

QVariantList QtSqlAdapter::schemas() const
{
    const QString drv = m_db.driverName();

    // SQLite has a single implicit schema — wrap the flat list
    if (drv == "QSQLITE")
        return QVariantList{{ QVariantMap{{"name", "main"}, {"tables", schema()}} }};

    // PostgreSQL / MySQL / MariaDB: query information_schema
    QString excluded;
    if (drv == "QPSQL")
        excluded = "'pg_catalog','information_schema','pg_toast'";
    else
        excluded = "'information_schema','performance_schema','mysql','sys'";

    // Primary key columns
    QSet<QString> pkSet; // "schema::table::column"
    QSqlQuery pkq(m_db);
    pkq.exec(QString(
        "SELECT kcu.table_schema, kcu.table_name, kcu.column_name "
        "FROM information_schema.table_constraints tc "
        "JOIN information_schema.key_column_usage kcu "
        "  ON tc.constraint_name = kcu.constraint_name "
        "  AND tc.table_schema   = kcu.table_schema "
        "WHERE tc.constraint_type = 'PRIMARY KEY' "
        "  AND tc.table_schema NOT IN (%1)").arg(excluded));
    while (pkq.next())
        pkSet.insert(pkq.value(0).toString() + "::" +
                     pkq.value(1).toString() + "::" +
                     pkq.value(2).toString());

    // Columns per table
    QMap<QString, QVariantList> colsMap; // "schema::table" -> columns
    QSqlQuery cq(m_db);
    cq.exec(QString(
        "SELECT table_schema, table_name, column_name, data_type, is_nullable "
        "FROM information_schema.columns "
        "WHERE table_schema NOT IN (%1) "
        "ORDER BY table_schema, table_name, ordinal_position").arg(excluded));
    while (cq.next()) {
        const QString s   = cq.value(0).toString();
        const QString t   = cq.value(1).toString();
        const QString col = cq.value(2).toString();
        colsMap[s + "::" + t] << QVariantMap{
            {"name",     col},
            {"type",     cq.value(3).toString()},
            {"pk",       pkSet.contains(s + "::" + t + "::" + col)},
            {"nullable", cq.value(4).toString() == "YES"},
            {"fk",       false}
        };
    }

    // Tables grouped by schema
    QMap<QString, QVariantList> tableMap;
    QStringList schemaOrder;
    QSqlQuery tq(m_db);
    tq.exec(QString(
        "SELECT table_schema, table_name, table_type "
        "FROM information_schema.tables "
        "WHERE table_schema NOT IN (%1) "
        "ORDER BY table_schema, table_name").arg(excluded));
    while (tq.next()) {
        const QString s   = tq.value(0).toString();
        const QString t   = tq.value(1).toString();
        QString kind      = tq.value(2).toString().toLower();
        if (kind.contains("view")) kind = "view"; else kind = "table";
        if (!schemaOrder.contains(s)) schemaOrder << s;
        tableMap[s] << QVariantMap{
            {"name",    t},
            {"type",    kind},
            {"columns", colsMap.value(s + "::" + t)}
        };
    }

    QVariantList result;
    for (const QString &s : schemaOrder)
        result << QVariantMap{{"name", s}, {"tables", tableMap[s]}};
    return result;
}

QVariantList QtSqlAdapter::schema() const
{
    QVariantList result;

    auto addGroup = [&](QSql::TableType kind, const QString &typeName) {
        for (const QString &tbl : m_db.tables(kind)) {
            const QSqlRecord rec = m_db.record(tbl);
            const QSqlIndex  pk  = m_db.primaryIndex(tbl);

            QSet<QString> pkCols;
            for (int i = 0; i < pk.count(); ++i)
                pkCols.insert(pk.fieldName(i));

            QVariantList cols;
            for (int i = 0; i < rec.count(); ++i) {
                const QSqlField f = rec.field(i);
                cols << QVariantMap{
                    {"name",     f.name()},
                    {"type",     toSqlTypeName(f.metaType())},
                    {"pk",       pkCols.contains(f.name())},
                    {"nullable", f.requiredStatus() != QSqlField::Required},
                    {"fk",       false}
                };
            }

            result << QVariantMap{{"name", tbl}, {"type", typeName}, {"columns", cols}};
        }
    };

    addGroup(QSql::Tables, "table");
    addGroup(QSql::Views,  "view");
    return result;
}
