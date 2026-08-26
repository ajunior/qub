#include "DatabaseInspector.h"
#include "ConnectionManager.h"
#include "adapters/DatabaseAdapter.h"
#include "ExplainPlan.h"
#include "SchemaDiff.h"
#include "Types.h"
#include <QFutureWatcher>
#include <QHash>
#include <QSet>
#include <QStringBuilder>
#include <QtConcurrent/QtConcurrent>
#include <QJsonDocument>
#include <QJsonArray>
#include <QJsonObject>

DatabaseInspector::DatabaseInspector(ConnectionManager *cm, QObject *parent)
    : QObject(parent), m_cm(cm)
{}

// ── Helpers ──────────────────────────────────────────────────────────────────

static QVariant firstVal(const QueryResult &r) {
    if (r.rows.isEmpty() || r.rows.first().isEmpty()) return {};
    return r.rows.first().first();
}

static QString fmtBytes(qint64 bytes) {
    if (bytes < 0) return QStringLiteral("—");
    if (bytes < 1024LL)               return QString::number(bytes) + " B";
    if (bytes < 1024LL * 1024)        return QString::number(bytes / 1024.0, 'f', 1) + " KB";
    if (bytes < 1024LL * 1024 * 1024) return QString::number(bytes / (1024.0 * 1024), 'f', 1) + " MB";
    return QString::number(bytes / (1024.0 * 1024 * 1024), 'f', 2) + " GB";
}

// ── Postgres ─────────────────────────────────────────────────────────────────

QVariantMap DatabaseInspector::inspectPostgres(const QString &connectionName) const
{
    auto *a = m_cm->adapter(connectionName);
    QVariantMap m;
    m[QStringLiteral("driver")] = QStringLiteral("postgres");

    // One round trip for everything available in scalar form
    const QString sql = QStringLiteral(
        "SELECT"
        "  version()                                                                     AS ver,"
        "  current_database()                                                            AS db,"
        "  pg_size_pretty(pg_database_size(current_database()))                         AS sz,"
        "  (SELECT count(*) FROM information_schema.tables"
        "   WHERE table_schema NOT IN ('pg_catalog','information_schema')"
        "     AND table_type='BASE TABLE')                                               AS tbl,"
        "  (SELECT count(*) FROM information_schema.views"
        "   WHERE table_schema NOT IN ('pg_catalog','information_schema'))               AS vw,"
        "  (SELECT count(*) FROM pg_indexes"
        "   WHERE schemaname NOT IN ('pg_catalog','information_schema'))                 AS idx,"
        "  (SELECT count(*) FROM information_schema.triggers"
        "   WHERE trigger_schema NOT IN ('pg_catalog','information_schema'))             AS trg,"
        "  (SELECT count(*) FROM information_schema.routines"
        "   WHERE routine_schema NOT IN ('pg_catalog','information_schema'))             AS fn,"
        "  (SELECT count(*) FROM pg_stat_activity WHERE datname = current_database())   AS conns,"
        "  (SELECT pg_encoding_to_char(encoding)"
        "     FROM pg_database WHERE datname = current_database())                       AS enc,"
        "  (SELECT datcollate FROM pg_database WHERE datname = current_database())       AS coll"
    );

    const QueryResult r = a->execute(sql);
    if (r.rows.isEmpty()) return m;
    const QVariantList &row = r.rows.first();
    auto col = [&](int i) -> QVariant { return i < row.size() ? row[i] : QVariant{}; };

    m[QStringLiteral("version")]            = col(0);
    m[QStringLiteral("databaseName")]       = col(1);
    m[QStringLiteral("size")]               = col(2);
    m[QStringLiteral("tableCount")]         = col(3);
    m[QStringLiteral("viewCount")]          = col(4);
    m[QStringLiteral("indexCount")]         = col(5);
    m[QStringLiteral("triggerCount")]       = col(6);
    m[QStringLiteral("functionCount")]      = col(7);
    m[QStringLiteral("activeConnections")]  = col(8);
    m[QStringLiteral("encoding")]           = col(9);
    m[QStringLiteral("collation")]          = col(10);

    return m;
}

// ── MySQL / MariaDB ───────────────────────────────────────────────────────────

QVariantMap DatabaseInspector::inspectMysql(const QString &connectionName) const
{
    auto *a = m_cm->adapter(connectionName);
    QVariantMap m;
    m[QStringLiteral("driver")] = QStringLiteral("mysql");

    const QueryResult basics = a->execute(QStringLiteral(
        "SELECT VERSION(), DATABASE(),"
        "  @@character_set_database, @@collation_database"
    ));
    if (!basics.rows.isEmpty()) {
        const QVariantList &r = basics.rows.first();
        m[QStringLiteral("version")]      = r.value(0);
        m[QStringLiteral("databaseName")] = r.value(1);
        m[QStringLiteral("encoding")]     = r.value(2);
        m[QStringLiteral("collation")]    = r.value(3);
    }

    const QueryResult counts = a->execute(QStringLiteral(
        "SELECT"
        "  ROUND(COALESCE(SUM(DATA_LENGTH + INDEX_LENGTH), 0))   AS sz,"
        "  SUM(TABLE_TYPE = 'BASE TABLE')                        AS tbl,"
        "  SUM(TABLE_TYPE = 'VIEW')                              AS vw"
        " FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE()"
    ));
    if (!counts.rows.isEmpty()) {
        const QVariantList &r = counts.rows.first();
        m[QStringLiteral("size")]       = fmtBytes(r.value(0).toLongLong());
        m[QStringLiteral("tableCount")] = r.value(1);
        m[QStringLiteral("viewCount")]  = r.value(2);
    }

    m[QStringLiteral("indexCount")]   = firstVal(a->execute(
        "SELECT COUNT(*) FROM information_schema.STATISTICS"
        " WHERE TABLE_SCHEMA = DATABASE() AND INDEX_NAME != 'PRIMARY'"));
    m[QStringLiteral("triggerCount")] = firstVal(a->execute(
        "SELECT COUNT(*) FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA = DATABASE()"));
    m[QStringLiteral("functionCount")] = firstVal(a->execute(
        "SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = DATABASE()"));

    return m;
}

// ── SQLite ────────────────────────────────────────────────────────────────────

QVariantMap DatabaseInspector::inspectSqlite(const QString &connectionName) const
{
    auto *a = m_cm->adapter(connectionName);
    QVariantMap m;
    m[QStringLiteral("driver")] = QStringLiteral("sqlite");

    m[QStringLiteral("version")]      = "SQLite " + firstVal(a->execute("SELECT sqlite_version()")).toString();
    m[QStringLiteral("databaseName")] = firstVal(a->execute("SELECT name FROM pragma_database_list WHERE seq=0"));
    m[QStringLiteral("encoding")]     = firstVal(a->execute("PRAGMA encoding"));
    m[QStringLiteral("tableCount")]   = firstVal(a->execute(
        "SELECT count(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"));
    m[QStringLiteral("viewCount")]    = firstVal(a->execute(
        "SELECT count(*) FROM sqlite_master WHERE type='view'"));
    m[QStringLiteral("indexCount")]   = firstVal(a->execute(
        "SELECT count(*) FROM sqlite_master WHERE type='index' AND name NOT LIKE 'sqlite_%'"));
    m[QStringLiteral("triggerCount")] = firstVal(a->execute(
        "SELECT count(*) FROM sqlite_master WHERE type='trigger'"));

    // File size: page_count × page_size
    const qint64 pages    = firstVal(a->execute("PRAGMA page_count")).toLongLong();
    const qint64 pageSize = firstVal(a->execute("PRAGMA page_size")).toLongLong();
    m[QStringLiteral("size")] = fmtBytes(pages * pageSize);

    // File path
    const QueryResult dbList = a->execute("PRAGMA database_list");
    if (!dbList.rows.isEmpty() && dbList.rows.first().size() >= 3)
        m[QStringLiteral("filePath")] = dbList.rows.first().at(2);

    return m;
}

// ── Foreign keys ─────────────────────────────────────────────────────────────

QVariantList DatabaseInspector::foreignKeys(const QString &connectionName) const
{
    auto *a = m_cm->adapter(connectionName);
    if (!a || !a->isOpen()) return {};

    const QString driver = a->driverName();
    QVariantList result;

    auto appendRows = [&](const QueryResult &r, int fromCol, int toCol, int fromCCol, int toCCol) {
        for (const QVariantList &row : r.rows) {
            QVariantMap m;
            m[QStringLiteral("fromTable")]  = row.value(fromCol);
            m[QStringLiteral("toTable")]    = row.value(toCol);
            m[QStringLiteral("fromColumn")] = row.value(fromCCol);
            m[QStringLiteral("toColumn")]   = row.value(toCCol);
            result.append(m);
        }
    };

    if (driver == QLatin1String("QPSQL")) {
        appendRows(a->execute(QStringLiteral(
            "SELECT tc.table_name, ccu.table_name, kcu.column_name, ccu.column_name"
            " FROM information_schema.table_constraints tc"
            " JOIN information_schema.key_column_usage kcu"
            "   ON tc.constraint_name = kcu.constraint_name"
            "  AND tc.table_schema    = kcu.table_schema"
            " JOIN information_schema.constraint_column_usage ccu"
            "   ON ccu.constraint_name = tc.constraint_name"
            "  AND ccu.table_schema    = tc.table_schema"
            " WHERE tc.constraint_type = 'FOREIGN KEY'"
            "   AND tc.table_schema NOT IN ('pg_catalog','information_schema')"
            " ORDER BY tc.table_name"
        )), 0, 1, 2, 3);

    } else if (driver == QLatin1String("QMYSQL") || driver == QLatin1String("QMARIADB")) {
        appendRows(a->execute(QStringLiteral(
            "SELECT TABLE_NAME, REFERENCED_TABLE_NAME, COLUMN_NAME, REFERENCED_COLUMN_NAME"
            " FROM information_schema.KEY_COLUMN_USAGE"
            " WHERE TABLE_SCHEMA = DATABASE()"
            "   AND REFERENCED_TABLE_NAME IS NOT NULL"
            " ORDER BY TABLE_NAME"
        )), 0, 1, 2, 3);

    } else if (driver == QLatin1String("QSQLITE")) {
        // SQLite requires PRAGMA per table; iterate all user tables
        const QueryResult tables = a->execute(QStringLiteral(
            "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
        ));
        for (const QVariantList &trow : tables.rows) {
            const QString tbl = trow.value(0).toString();
            const QueryResult fkr = a->execute(
                QStringLiteral("PRAGMA foreign_key_list(\"%1\")").arg(tbl));
            // columns: id, seq, table, from, to, on_update, on_delete, match
            for (const QVariantList &row : fkr.rows) {
                QVariantMap m;
                m[QStringLiteral("fromTable")]  = tbl;
                m[QStringLiteral("toTable")]    = row.value(2);
                m[QStringLiteral("fromColumn")] = row.value(3);
                m[QStringLiteral("toColumn")]   = row.value(4);
                result.append(m);
            }
        }
    }

    return result;
}

// ── Table stats ───────────────────────────────────────────────────────────────

static QString fmtDistinct(double v) {
    if (v == -1.0)  return QStringLiteral("All unique");
    if (v < -0.005) return QString::number(qAbs(v) * 100.0, 'f', 0) + "% unique";
    return QString::number(static_cast<qint64>(v));
}
static QString fmtNullFrac(double v)  { return QString::number(v * 100.0, 'f', 1) + "%"; }
static QString fmtCorr(double v) {
    const QString s = QString::number(v, 'f', 2);
    if (v >=  0.99) return s + " ↑";
    if (v <= -0.99) return s + " ↓";
    return s;
}
static QString esc(const QString &s)  { return QString(s).replace('\'', "''"); }

QVariantMap DatabaseInspector::tableStats(const QString &connectionName, const QString &tableName) const
{
    auto *a = m_cm->adapter(connectionName);
    if (!a || !a->isOpen()) return {};

    const QString driver = a->driverName();
    const QString t      = esc(tableName);
    QVariantMap   m;
    m[QStringLiteral("driver")]    = driver;
    m[QStringLiteral("tableName")] = tableName;

    if (driver == QLatin1String("QPSQL")) {
        const QueryResult r = a->execute(QStringLiteral(
            "SELECT c.reltuples::bigint, c.relpages,"
            "  pg_size_pretty(pg_total_relation_size(c.oid)),"
            "  pg_size_pretty(pg_relation_size(c.oid)),"
            "  pg_size_pretty(pg_indexes_size(c.oid)),"
            "  s.n_live_tup, s.n_dead_tup,"
            "  to_char(COALESCE(s.last_vacuum,    s.last_autovacuum),   'YYYY-MM-DD HH24:MI'),"
            "  to_char(COALESCE(s.last_analyze,   s.last_autoanalyze),  'YYYY-MM-DD HH24:MI')"
            " FROM pg_class c"
            " JOIN pg_namespace n ON n.oid = c.relnamespace"
            " LEFT JOIN pg_stat_user_tables s ON s.relname = c.relname AND s.schemaname = n.nspname"
            " WHERE c.relname = '") % t % QStringLiteral("'"
            "   AND n.nspname NOT IN ('pg_catalog','information_schema','pg_toast')"
            " LIMIT 1"));

        if (!r.rows.isEmpty()) {
            const QVariantList &row = r.rows.first();
            m[QStringLiteral("rowEstimate")]  = row.value(0);
            m[QStringLiteral("pages")]        = row.value(1);
            m[QStringLiteral("totalSize")]    = row.value(2);
            m[QStringLiteral("tableSize")]    = row.value(3);
            m[QStringLiteral("indexesSize")]  = row.value(4);
            m[QStringLiteral("liveRows")]     = row.value(5);
            m[QStringLiteral("deadRows")]     = row.value(6);
            m[QStringLiteral("lastVacuum")]   = row.value(7);
            m[QStringLiteral("lastAnalyze")]  = row.value(8);
        }

        // Per-column stats from pg_stats
        const QueryResult cs = a->execute(
            QStringLiteral("SELECT attname, n_distinct, null_frac, avg_width, correlation"
                           " FROM pg_stats"
                           " WHERE tablename = '") % t %
            QStringLiteral("' AND schemaname NOT IN ('pg_catalog','information_schema','pg_toast')"
                           " ORDER BY attname"));
        QVariantList cols;
        for (const QVariantList &row : cs.rows) {
            QVariantMap col;
            col[QStringLiteral("column")]      = row.value(0);
            col[QStringLiteral("distinct")]    = fmtDistinct(row.value(1).toDouble());
            col[QStringLiteral("nullFrac")]    = fmtNullFrac(row.value(2).toDouble());
            col[QStringLiteral("avgWidth")]    = row.value(3).toString() + " B";
            col[QStringLiteral("correlation")] = row.value(4).isNull()
                                                 ? QStringLiteral("—")
                                                 : fmtCorr(row.value(4).toDouble());
            cols.append(col);
        }
        m[QStringLiteral("columns")] = cols;

    } else if (driver == QLatin1String("QMYSQL") || driver == QLatin1String("QMARIADB")) {
        const QueryResult r = a->execute(
            QStringLiteral("SELECT TABLE_ROWS, DATA_LENGTH + INDEX_LENGTH,"
                           " DATA_LENGTH, INDEX_LENGTH, AVG_ROW_LENGTH, ENGINE,"
                           " DATE_FORMAT(CREATE_TIME,'%Y-%m-%d %H:%i'),"
                           " DATE_FORMAT(UPDATE_TIME,'%Y-%m-%d %H:%i')"
                           " FROM information_schema.TABLES"
                           " WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = '") % t %
            QStringLiteral("'"));

        if (!r.rows.isEmpty()) {
            const QVariantList &row = r.rows.first();
            m[QStringLiteral("rowEstimate")]  = row.value(0);
            m[QStringLiteral("totalSize")]    = fmtBytes(row.value(1).toLongLong());
            m[QStringLiteral("tableSize")]    = fmtBytes(row.value(2).toLongLong());
            m[QStringLiteral("indexesSize")]  = fmtBytes(row.value(3).toLongLong());
            m[QStringLiteral("avgRowLength")] = row.value(4).toString() + " B";
            m[QStringLiteral("engine")]       = row.value(5);
            m[QStringLiteral("createTime")]   = row.value(6);
            m[QStringLiteral("lastAnalyze")]  = row.value(7);
        }

    } else if (driver == QLatin1String("QSQLITE")) {
        m[QStringLiteral("rowEstimate")] = firstVal(
            a->execute(QStringLiteral("SELECT count(*) FROM \"") % t % QStringLiteral("\"")));

        const qint64 pages    = firstVal(a->execute(QStringLiteral("PRAGMA page_count"))).toLongLong();
        const qint64 pageSize = firstVal(a->execute(QStringLiteral("PRAGMA page_size"))).toLongLong();
        m[QStringLiteral("tableSize")] = fmtBytes(pages * pageSize);

        const QueryResult idxR = a->execute(
            QStringLiteral("SELECT count(*) FROM sqlite_master"
                           " WHERE type='index' AND tbl_name='") % t % QStringLiteral("'"
                           " AND name NOT LIKE 'sqlite_%'"));
        m[QStringLiteral("indexCount")] = firstVal(idxR);
    }

    return m;
}

// ── Table DDL ─────────────────────────────────────────────────────────────────

QString DatabaseInspector::tableDdl(const QString &connectionName, const QString &tableName) const
{
    auto *a = m_cm->adapter(connectionName);
    if (!a || !a->isOpen()) return {};

    const QString driver = a->driverName();
    const QString t      = esc(tableName);

    if (driver == QLatin1String("QMYSQL") || driver == QLatin1String("QMARIADB")) {
        const QueryResult r = a->execute(
            QStringLiteral("SHOW CREATE TABLE `") % t % QStringLiteral("`"));
        if (!r.rows.isEmpty() && r.rows.first().size() >= 2)
            return r.rows.first().at(1).toString();
        return {};
    }

    if (driver == QLatin1String("QSQLITE")) {
        const QueryResult r = a->execute(
            QStringLiteral("SELECT sql FROM sqlite_master WHERE type='table' AND name='") % t %
            QStringLiteral("'"));
        if (!r.rows.isEmpty() && !r.rows.first().isEmpty())
            return r.rows.first().first().toString() + QStringLiteral(";");
        return {};
    }

    // PostgreSQL — reconstruct from information_schema
    // Step 1: columns
    const QueryResult cols = a->execute(
        QStringLiteral(
            "SELECT column_name,"
            "  CASE"
            "    WHEN data_type='character varying' THEN"
            "      CASE WHEN character_maximum_length IS NOT NULL"
            "           THEN 'VARCHAR(' || character_maximum_length || ')'"
            "           ELSE 'VARCHAR' END"
            "    WHEN data_type='character' THEN"
            "      CASE WHEN character_maximum_length IS NOT NULL"
            "           THEN 'CHAR(' || character_maximum_length || ')'"
            "           ELSE 'CHAR' END"
            "    WHEN data_type='numeric' THEN"
            "      CASE WHEN numeric_precision IS NOT NULL"
            "           THEN 'NUMERIC(' || numeric_precision || ',' || COALESCE(numeric_scale,0) || ')'"
            "           ELSE 'NUMERIC' END"
            "    WHEN data_type='ARRAY' THEN udt_name || '[]'"
            "    ELSE UPPER(data_type)"
            "  END,"
            "  column_default,"
            "  is_nullable"
            " FROM information_schema.columns"
            " WHERE table_name = '") % t %
        QStringLiteral("'"
            "   AND table_schema NOT IN ('pg_catalog','information_schema')"
            " ORDER BY ordinal_position"));

    // Step 2: primary key columns
    const QueryResult pkR = a->execute(
        QStringLiteral(
            "SELECT kcu.column_name"
            " FROM information_schema.table_constraints tc"
            " JOIN information_schema.key_column_usage kcu"
            "   ON tc.constraint_name = kcu.constraint_name"
            "  AND tc.table_schema    = kcu.table_schema"
            " WHERE tc.table_name = '") % t %
        QStringLiteral("'"
            "   AND tc.table_schema NOT IN ('pg_catalog','information_schema')"
            "   AND tc.constraint_type = 'PRIMARY KEY'"
            " ORDER BY kcu.ordinal_position"));

    QSet<QString> pkCols;
    for (const QVariantList &r : pkR.rows)
        pkCols.insert(r.value(0).toString());

    // Step 3: build DDL string
    QString ddl = QStringLiteral("CREATE TABLE ") % tableName % QStringLiteral(" (\n");
    QStringList lines;
    for (const QVariantList &row : cols.rows) {
        const QString col  = row.value(0).toString();
        const QString type = row.value(1).toString();
        const QString def  = row.value(2).isNull() ? QString() : row.value(2).toString();
        const bool notNull = row.value(3).toString() == QLatin1String("NO");

        QString line = QStringLiteral("    ") % col % QStringLiteral(" ") % type;
        if (!def.isEmpty())
            line += QStringLiteral(" DEFAULT ") % def;
        if (notNull)
            line += QStringLiteral(" NOT NULL");
        lines.append(line);
    }

    if (!pkCols.isEmpty()) {
        QStringList pkList(pkCols.begin(), pkCols.end());
        lines.append(QStringLiteral("    PRIMARY KEY (") % pkList.join(QStringLiteral(", ")) %
                     QStringLiteral(")"));
    }

    ddl += lines.join(QStringLiteral(",\n"));
    ddl += QStringLiteral("\n);");
    return ddl;
}

// ── Health metrics ─────────────────────────────────────────────────────────────

QVariantMap DatabaseInspector::metricsPostgres(const QString &connectionName) const
{
    auto *a = m_cm->adapter(connectionName);
    QVariantMap m;
    m[QStringLiteral("driver")]        = QStringLiteral("postgres");
    m[QStringLiteral("serverMetrics")] = true;

    // One round trip: cumulative counters + gauges from pg_stat_database.
    const QueryResult r = a->execute(QStringLiteral(
        "SELECT numbackends, xact_commit, xact_rollback, blks_read, blks_hit,"
        "  tup_returned + tup_fetched, pg_database_size(current_database()),"
        "  (SELECT count(*) FROM pg_stat_activity"
        "    WHERE datname = current_database() AND wait_event_type = 'Lock')"
        " FROM pg_stat_database WHERE datname = current_database()"));
    if (r.rows.isEmpty()) return m;

    const QVariantList &row = r.rows.first();
    auto col = [&](int i) -> QVariant { return i < row.size() ? row[i] : QVariant{}; };
    m[QStringLiteral("connections")] = col(0);
    m[QStringLiteral("commits")]     = col(1);
    m[QStringLiteral("rollbacks")]   = col(2);
    m[QStringLiteral("blksRead")]    = col(3);
    m[QStringLiteral("blksHit")]     = col(4);
    m[QStringLiteral("tuples")]      = col(5);
    m[QStringLiteral("dbSize")]      = col(6);
    m[QStringLiteral("blocked")]     = col(7);
    return m;
}

QVariantMap DatabaseInspector::metricsMysql(const QString &connectionName) const
{
    auto *a = m_cm->adapter(connectionName);
    QVariantMap m;
    m[QStringLiteral("driver")]        = QStringLiteral("mysql");
    m[QStringLiteral("serverMetrics")] = true;

    const QueryResult st = a->execute(QStringLiteral("SHOW GLOBAL STATUS"));
    QHash<QString, double> s;
    for (const QVariantList &row : st.rows)
        if (row.size() >= 2)
            s.insert(row.value(0).toString().toLower(), row.value(1).toDouble());

    m[QStringLiteral("connections")] = s.value(QStringLiteral("threads_connected"));
    m[QStringLiteral("queries")]     = s.contains(QStringLiteral("queries"))
                                       ? s.value(QStringLiteral("queries"))
                                       : s.value(QStringLiteral("questions"));
    m[QStringLiteral("commits")]     = s.value(QStringLiteral("com_commit"));
    m[QStringLiteral("rowsRead")]    = s.value(QStringLiteral("innodb_rows_read"));
    m[QStringLiteral("bpReadReq")]   = s.value(QStringLiteral("innodb_buffer_pool_read_requests"));
    m[QStringLiteral("bpReads")]     = s.value(QStringLiteral("innodb_buffer_pool_reads"));

    m[QStringLiteral("dbSize")] = firstVal(a->execute(QStringLiteral(
        "SELECT COALESCE(SUM(DATA_LENGTH + INDEX_LENGTH),0)"
        " FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE()")));
    return m;
}

QVariantMap DatabaseInspector::metricsSqlite(const QString &connectionName) const
{
    auto *a = m_cm->adapter(connectionName);
    QVariantMap m;
    m[QStringLiteral("driver")]        = QStringLiteral("sqlite");
    m[QStringLiteral("serverMetrics")] = false;   // no live server counters

    const qint64 pages    = firstVal(a->execute(QStringLiteral("PRAGMA page_count"))).toLongLong();
    const qint64 pageSize = firstVal(a->execute(QStringLiteral("PRAGMA page_size"))).toLongLong();
    m[QStringLiteral("dbSize")] = QVariant::fromValue<qint64>(pages * pageSize);
    return m;
}

QVariantMap DatabaseInspector::metrics(const QString &connectionName) const
{
    auto *adapter = m_cm->adapter(connectionName);
    if (!adapter || !adapter->isOpen()) return {};

    const QString driver = adapter->driverName();
    if (driver == QLatin1String("QPSQL"))
        return metricsPostgres(connectionName);
    if (driver == QLatin1String("QMYSQL") || driver == QLatin1String("QMARIADB"))
        return metricsMysql(connectionName);
    if (driver == QLatin1String("QSQLITE"))
        return metricsSqlite(connectionName);

    QVariantMap m;
    m[QStringLiteral("driver")]        = driver;
    m[QStringLiteral("serverMetrics")] = false;
    return m;
}

QVariantMap DatabaseInspector::schemaDiff(const QString &connA, const QString &connB) const
{
    return SchemaDiff::compare(m_cm->schemas(connA), m_cm->schemas(connB));
}

// ── Public entry point ────────────────────────────────────────────────────────

void DatabaseInspector::inspect(const QString &connectionName)
{
    auto *adapter = m_cm->adapter(connectionName);
    if (!adapter || !adapter->isOpen()) {
        emit errorOccurred(QStringLiteral("Not connected"));
        return;
    }

    m_loading = true;
    emit loadingChanged();

    const QString driver = adapter->driverName();
    QVariantMap info;

    if (driver == QLatin1String("QPSQL")) {
        info = inspectPostgres(connectionName);
    } else if (driver == QLatin1String("QMYSQL") || driver == QLatin1String("QMARIADB")) {
        info = inspectMysql(connectionName);
    } else if (driver == QLatin1String("QSQLITE")) {
        info = inspectSqlite(connectionName);
    } else {
        info[QStringLiteral("driver")] = driver;
    }

    m_loading = false;
    emit loadingChanged();
    emit resultReady(info);
}

// ── EXPLAIN ────────────────────────────────────────────────────────────────────

namespace {

QVariantMap chip(const QString &key, const QString &value) {
    return { { QStringLiteral("key"), key }, { QStringLiteral("value"), value } };
}

// Recursively turn a Postgres plan JSON object into our normalised node. Postgres
// costs/times are cumulative, so a node's *self* cost is its total minus the sum
// of its children's totals — that's what makes hot-spotting meaningful.
QVariantMap pgBuild(const QJsonObject &plan) {
    QVariantMap node;
    node[QStringLiteral("label")] = plan.value(QStringLiteral("Node Type")).toString();

    QStringList det;
    if (plan.contains(QStringLiteral("Join Type")))
        det << plan.value(QStringLiteral("Join Type")).toString() + QStringLiteral(" join");
    if (plan.contains(QStringLiteral("Relation Name")))
        det << QStringLiteral("on ") + plan.value(QStringLiteral("Relation Name")).toString();
    if (plan.contains(QStringLiteral("Index Name")))
        det << QStringLiteral("using ") + plan.value(QStringLiteral("Index Name")).toString();
    node[QStringLiteral("detail")] = det.join(QLatin1Char(' '));

    const double totalCost = plan.value(QStringLiteral("Total Cost")).toDouble();
    const double estRows   = plan.value(QStringLiteral("Plan Rows")).toDouble();
    const bool   analyzed  = plan.contains(QStringLiteral("Actual Total Time"));
    const double loops     = plan.value(QStringLiteral("Actual Loops")).toDouble();
    const double actualTot = analyzed
        ? plan.value(QStringLiteral("Actual Total Time")).toDouble() * (loops > 0 ? loops : 1)
        : 0.0;
    const double actRows   = plan.value(QStringLiteral("Actual Rows")).toDouble();

    QVariantList metrics;
    metrics << chip(QStringLiteral("cost"), QString::number(totalCost, 'f', 2));
    metrics << chip(QStringLiteral("rows"), QString::number(estRows, 'f', 0));
    if (analyzed) {
        metrics << chip(QStringLiteral("actual"), QString::number(actualTot, 'f', 2) + QStringLiteral(" ms"));
        metrics << chip(QStringLiteral("rows·act"), QString::number(actRows, 'f', 0));
    }

    double childCost = 0, childActual = 0;
    QVariantList children;
    const QJsonArray kids = plan.value(QStringLiteral("Plans")).toArray();
    for (const QJsonValue &cv : kids) {
        const QVariantMap cn = pgBuild(cv.toObject());
        childCost   += cn.value(QStringLiteral("_totalCost")).toDouble();
        childActual += cn.value(QStringLiteral("_totalActual")).toDouble();
        children.append(cn);
    }

    node[QStringLiteral("metrics")]      = metrics;
    node[QStringLiteral("children")]     = children;
    node[QStringLiteral("estRows")]      = estRows;
    node[QStringLiteral("actRows")]      = analyzed ? actRows : -1;
    node[QStringLiteral("_totalCost")]   = totalCost;
    node[QStringLiteral("_totalActual")] = actualTot;
    node[QStringLiteral("self")]         = analyzed ? qMax(0.0, actualTot - childActual)
                                                    : qMax(0.0, totalCost - childCost);
    return node;
}

double maxSelf(const QVariantMap &n) {
    double m = n.value(QStringLiteral("self")).toDouble();
    const QVariantList kids = n.value(QStringLiteral("children")).toList();
    for (const QVariant &c : kids) m = qMax(m, maxSelf(c.toMap()));
    return m;
}

// Mark the single costliest node hot, and collect tuning warnings on the way.
QVariantMap markAndWarn(QVariantMap n, double hotThreshold, QStringList &warnings) {
    const double self = n.value(QStringLiteral("self")).toDouble();
    const bool   hot  = hotThreshold > 0 && self >= hotThreshold - 1e-6;
    n[QStringLiteral("hot")] = hot;

    const QString label  = n.value(QStringLiteral("label")).toString();
    const QString detail = n.value(QStringLiteral("detail")).toString();
    if (label.contains(QStringLiteral("Seq Scan")))
        warnings << QStringLiteral("Sequential scan %1 — an index may help.").arg(detail).trimmed();
    const double est = n.value(QStringLiteral("estRows")).toDouble();
    const double act = n.value(QStringLiteral("actRows")).toDouble();
    if (act >= 0 && est > 0 && (act > est * 10 || est > act * 10))
        warnings << QStringLiteral("Row estimate off at %1 (est %2, actual %3).")
                    .arg(label).arg(est, 0, 'f', 0).arg(act, 0, 'f', 0);

    QVariantList kids;
    const QVariantList in = n.value(QStringLiteral("children")).toList();
    for (const QVariant &c : in) kids.append(markAndWarn(c.toMap(), hotThreshold, warnings));
    n[QStringLiteral("children")] = kids;
    return n;
}

} // namespace

QVariantMap DatabaseInspector::explainPostgres(DatabaseAdapter *a, const QString &sql, bool analyze) const
{
    const QString opts = analyze ? QStringLiteral("(ANALYZE, BUFFERS, FORMAT JSON)")
                                 : QStringLiteral("(FORMAT JSON)");
    const QueryResult r = a->execute(QStringLiteral("EXPLAIN %1 %2").arg(opts, sql));
    if (!r.success)
        return { { QStringLiteral("success"), false }, { QStringLiteral("error"), r.error } };

    const QString json = firstVal(r).toString();
    const QJsonDocument doc = QJsonDocument::fromJson(json.toUtf8());
    if (!doc.isArray() || doc.array().isEmpty())
        return { { QStringLiteral("success"), false },
                 { QStringLiteral("error"), QStringLiteral("Could not parse the plan.") } };

    const QJsonObject planObj = doc.array().first().toObject().value(QStringLiteral("Plan")).toObject();
    QVariantMap root = pgBuild(planObj);
    QStringList warnings;
    root = markAndWarn(root, maxSelf(root), warnings);

    return {
        { QStringLiteral("success"),  true },
        { QStringLiteral("driver"),   QStringLiteral("postgres") },
        { QStringLiteral("analyzed"), analyze },
        { QStringLiteral("root"),     root },
        { QStringLiteral("warnings"), warnings },
        { QStringLiteral("text"),     json },
    };
}

QVariantMap DatabaseInspector::explainSqlite(DatabaseAdapter *a, const QString &sql) const
{
    const QueryResult r = a->execute(QStringLiteral("EXPLAIN QUERY PLAN ") + sql);
    if (!r.success)
        return { { QStringLiteral("success"), false }, { QStringLiteral("error"), r.error } };
    return ExplainPlan::buildSqlite(r.rows);
}

QVariantMap DatabaseInspector::explainMysql(DatabaseAdapter *a, const QString &sql) const
{
    // Classic tabular EXPLAIN — works across all MySQL/MariaDB versions. Each row
    // is one step; we present them as children of a synthetic root.
    const QueryResult r = a->execute(QStringLiteral("EXPLAIN ") + sql);
    if (!r.success)
        return { { QStringLiteral("success"), false }, { QStringLiteral("error"), r.error } };

    auto colIdx = [&](const QString &name) {
        for (int i = 0; i < r.columns.size(); ++i)
            if (r.columns.at(i).compare(name, Qt::CaseInsensitive) == 0) return i;
        return -1;
    };
    const int iTable = colIdx(QStringLiteral("table"));
    const int iType  = colIdx(QStringLiteral("type"));
    const int iKey   = colIdx(QStringLiteral("key"));
    const int iRows  = colIdx(QStringLiteral("rows"));
    const int iExtra = colIdx(QStringLiteral("Extra"));

    QVariantList children;
    QStringList  warnings;
    QString      textDump;
    for (const QVariantList &row : r.rows) {
        const QString table = iTable >= 0 ? row.value(iTable).toString() : QString();
        const QString type  = iType  >= 0 ? row.value(iType).toString()  : QString();
        const QString key   = iKey   >= 0 ? row.value(iKey).toString()   : QString();
        const QString extra = iExtra >= 0 ? row.value(iExtra).toString() : QString();

        QVariantList metrics;
        if (!type.isEmpty()) metrics << chip(QStringLiteral("access"), type);
        metrics << chip(QStringLiteral("key"), key.isEmpty() ? QStringLiteral("none") : key);
        if (iRows >= 0) metrics << chip(QStringLiteral("rows"), row.value(iRows).toString());
        if (!extra.isEmpty()) metrics << chip(QStringLiteral("extra"), extra);

        const bool fullScan = type.compare(QStringLiteral("ALL"), Qt::CaseInsensitive) == 0;
        const bool filesort = extra.contains(QStringLiteral("filesort"), Qt::CaseInsensitive)
                              || extra.contains(QStringLiteral("temporary"), Qt::CaseInsensitive);
        QVariantMap node;
        node[QStringLiteral("label")]    = table.isEmpty() ? QStringLiteral("(step)") : table;
        node[QStringLiteral("detail")]   = type;
        node[QStringLiteral("metrics")]  = metrics;
        node[QStringLiteral("hot")]      = fullScan || filesort;
        node[QStringLiteral("children")] = QVariantList{};
        children.append(node);

        if (fullScan)
            warnings << QStringLiteral("Full table scan on %1 (type=ALL).").arg(table);
        if (filesort)
            warnings << QStringLiteral("%1 uses %2.").arg(table, extra);
        textDump += QStringLiteral("%1  %2  key=%3  rows=%4  %5\n")
                    .arg(table, type, key, iRows >= 0 ? row.value(iRows).toString() : QString(), extra);
    }

    QVariantMap root;
    root[QStringLiteral("label")]    = QStringLiteral("Query plan");
    root[QStringLiteral("detail")]   = QString();
    root[QStringLiteral("metrics")]  = QVariantList{};
    root[QStringLiteral("hot")]      = false;
    root[QStringLiteral("children")] = children;

    return {
        { QStringLiteral("success"),  true },
        { QStringLiteral("driver"),   QStringLiteral("mysql") },
        { QStringLiteral("analyzed"), false },
        { QStringLiteral("root"),     root },
        { QStringLiteral("warnings"), warnings },
        { QStringLiteral("text"),     textDump.trimmed() },
    };
}

QVariantMap DatabaseInspector::explain(const QString &connectionName,
                                       const QString &sql, bool analyze) const
{
    auto *a = m_cm->adapter(connectionName);
    if (!a || !a->isOpen())
        return { { QStringLiteral("success"), false },
                 { QStringLiteral("error"), QStringLiteral("Not connected.") } };

    const QString trimmed = sql.trimmed();
    if (trimmed.isEmpty())
        return { { QStringLiteral("success"), false },
                 { QStringLiteral("error"), QStringLiteral("Nothing to explain.") } };

    const QString driver = a->driverName();
    if (driver == QLatin1String("QPSQL"))
        return explainPostgres(a, trimmed, analyze);
    if (driver == QLatin1String("QMYSQL") || driver == QLatin1String("QMARIADB"))
        return explainMysql(a, trimmed);
    if (driver == QLatin1String("QSQLITE"))
        return explainSqlite(a, trimmed);

    return { { QStringLiteral("success"), false },
             { QStringLiteral("error"), QStringLiteral("EXPLAIN isn't supported for this driver yet.") } };
}
