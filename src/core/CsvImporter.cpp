#include "CsvImporter.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QRegularExpression>
#include <QSqlDatabase>
#include <QSqlError>
#include <QSqlQuery>
#include <QStandardPaths>
#include <QTextStream>
#include <QUuid>

// ── Delimiter sniffing ──────────────────────────────────────────────────────
QChar CsvImporter::sniffDelimiter(const QString &sampleLine)
{
    // Count candidates outside of quotes; the most frequent wins.
    const QList<QChar> candidates = { ',', '\t', ';', '|' };
    QChar   best  = ',';
    int     bestN = -1;
    for (const QChar c : candidates) {
        int   n      = 0;
        bool  inQ    = false;
        for (const QChar ch : sampleLine) {
            if (ch == '"') inQ = !inQ;
            else if (ch == c && !inQ) ++n;
        }
        if (n > bestN) { bestN = n; best = c; }
    }
    return best;
}

// ── RFC 4180-ish parser ─────────────────────────────────────────────────────
bool CsvImporter::parseFile(const QString &path, QChar delimiter,
                            QVector<QStringList> &rows, QString &error)
{
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) {
        error = QStringLiteral("Could not open file: %1").arg(f.errorString());
        return false;
    }

    QTextStream in(&f);
    in.setEncoding(QStringConverter::Utf8);
    const QString text = in.readAll();

    QStringList field;
    QString     cur;
    bool        inQuotes = false;
    QStringList current;   // fields of the row being built

    auto endField = [&] { current.append(cur); cur.clear(); };
    auto endRow   = [&] {
        endField();
        // Skip a stray empty trailing line.
        if (!(current.size() == 1 && current.first().isEmpty()))
            rows.append(current);
        current.clear();
    };

    const int len = text.size();
    for (int i = 0; i < len; ++i) {
        const QChar ch = text.at(i);
        if (inQuotes) {
            if (ch == '"') {
                if (i + 1 < len && text.at(i + 1) == '"') { cur.append('"'); ++i; }
                else inQuotes = false;
            } else {
                cur.append(ch);
            }
        } else {
            if (ch == '"') {
                inQuotes = true;
            } else if (ch == delimiter) {
                endField();
            } else if (ch == '\n') {
                endRow();
            } else if (ch == '\r') {
                // swallow; \r\n handled by the \n branch, lone \r ends the row
                if (!(i + 1 < len && text.at(i + 1) == '\n')) endRow();
            } else {
                cur.append(ch);
            }
        }
    }
    // Flush a final row with no trailing newline.
    if (!cur.isEmpty() || !current.isEmpty())
        endRow();

    return true;
}

// ── Type inference ──────────────────────────────────────────────────────────
QString CsvImporter::inferType(const QStringList &values)
{
    bool anyValue = false;
    bool allInt   = true;
    bool allReal  = true;
    for (const QString &raw : values) {
        const QString v = raw.trimmed();
        if (v.isEmpty()) continue;   // blanks become NULL, don't constrain type
        anyValue = true;

        bool ok = false;
        v.toLongLong(&ok);
        if (!ok) allInt = false;

        ok = false;
        v.toDouble(&ok);
        if (!ok) allReal = false;

        if (!allInt && !allReal) break;
    }
    if (!anyValue) return QStringLiteral("TEXT");
    if (allInt)    return QStringLiteral("INTEGER");
    if (allReal)   return QStringLiteral("REAL");
    return QStringLiteral("TEXT");
}

// ── Identifier hygiene ──────────────────────────────────────────────────────
QString CsvImporter::sanitizeIdent(const QString &raw, const QString &fallback)
{
    QString s = raw.trimmed();
    // Collapse whitespace runs to a single underscore, drop other oddities.
    static const QRegularExpression ws(QStringLiteral("\\s+"));
    s.replace(ws, QStringLiteral("_"));
    static const QRegularExpression bad(QStringLiteral("[^A-Za-z0-9_]"));
    s.remove(bad);
    if (s.isEmpty()) s = fallback;
    if (s.at(0).isDigit()) s.prepend('_');
    return s;
}

QString CsvImporter::quoteIdent(const QString &ident)
{
    QString s = ident;
    s.replace('"', QStringLiteral("\"\""));
    return '"' + s + '"';
}

// ── Preview ─────────────────────────────────────────────────────────────────
QVariantMap CsvImporter::preview(const QUrl &fileUrl, bool hasHeader, int sampleRows) const
{
    QVariantMap out;
    const QString path = fileUrl.isLocalFile() ? fileUrl.toLocalFile() : fileUrl.toString();

    QFile f(path);
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) {
        out["success"] = false;
        out["error"]   = QStringLiteral("Could not open file: %1").arg(f.errorString());
        return out;
    }
    // Sniff the delimiter from the first non-empty line.
    QTextStream in(&f);
    in.setEncoding(QStringConverter::Utf8);
    QString firstLine;
    while (!in.atEnd()) { firstLine = in.readLine(); if (!firstLine.isEmpty()) break; }
    f.close();
    const QChar delim = sniffDelimiter(firstLine);

    QVector<QStringList> rows;
    QString error;
    if (!parseFile(path, delim, rows, error)) {
        out["success"] = false;
        out["error"]   = error;
        return out;
    }
    if (rows.isEmpty()) {
        out["success"] = false;
        out["error"]   = QStringLiteral("The file has no rows.");
        return out;
    }

    const QStringList &header   = rows.first();
    const int          nCols    = header.size();

    // Column names from the header, deduped.
    QStringList names;
    QSet<QString> seen;
    for (int c = 0; c < nCols; ++c) {
        QString name = sanitizeIdent(hasHeader ? header.at(c) : QString(),
                                     QStringLiteral("col%1").arg(c + 1));
        QString base = name;
        int      n   = 2;
        while (seen.contains(name.toLower())) name = base + '_' + QString::number(n++);
        seen.insert(name.toLower());
        names.append(name);
    }

    // Gather per-column values (data rows only) for type inference + preview.
    const int firstData = hasHeader ? 1 : 0;
    QVector<QStringList> colValues(nCols);
    for (int r = firstData; r < rows.size(); ++r) {
        const QStringList &row = rows.at(r);
        for (int c = 0; c < nCols; ++c)
            colValues[c].append(c < row.size() ? row.at(c) : QString());
    }

    QVariantList columns;
    for (int c = 0; c < nCols; ++c)
        columns.append(QVariantMap{ { "name", names.at(c) },
                                    { "type", inferType(colValues.at(c)) } });

    // A few sample data rows for display.
    QVariantList sample;
    for (int r = firstData; r < rows.size() && sample.size() < sampleRows; ++r) {
        const QStringList &row = rows.at(r);
        QVariantList cells;
        for (int c = 0; c < nCols; ++c)
            cells.append(c < row.size() ? row.at(c) : QString());
        sample.append(QVariant(cells));   // wrap: append(QVariantList) would concatenate
    }

    out["success"]     = true;
    out["delimiter"]   = QString(delim);
    out["hasHeader"]   = hasHeader;
    out["table"]       = sanitizeIdent(QFileInfo(path).completeBaseName(), QStringLiteral("imported"));
    out["columns"]     = columns;
    out["rows"]        = sample;
    out["sampledRows"] = sample.size();
    return out;
}

// ── Delimiter resolution (explicit choice, else sniff) ──────────────────────
QChar CsvImporter::resolveDelimiter(const QString &filePath, const QString &delimiter)
{
    if (!delimiter.isEmpty())
        return delimiter.at(0);
    QChar delim = ',';
    QFile f(filePath);
    if (f.open(QIODevice::ReadOnly | QIODevice::Text)) {
        QTextStream in(&f);
        in.setEncoding(QStringConverter::Utf8);
        QString firstLine;
        while (!in.atEnd()) { firstLine = in.readLine(); if (!firstLine.isEmpty()) break; }
        delim = sniffDelimiter(firstLine);
    }
    return delim;
}

// ── Parse + CREATE TABLE + bulk INSERT into an already-open db ──────────────
bool CsvImporter::writeTable(QSqlDatabase &db, const QString &path,
                             const QString &tableNameReq, bool hasHeader,
                             const QString &delimiter, QVariantMap &out)
{
    const QChar delim = resolveDelimiter(path, delimiter);

    QVector<QStringList> rows;
    QString error;
    if (!parseFile(path, delim, rows, error)) { out["error"] = error; return false; }
    if (rows.isEmpty()) { out["error"] = QStringLiteral("The file has no rows."); return false; }

    const QStringList &header = rows.first();
    const int          nCols  = header.size();

    QString table = sanitizeIdent(tableNameReq.isEmpty()
                                      ? QFileInfo(path).completeBaseName() : tableNameReq,
                                  QStringLiteral("imported"));

    // A table of this name may already exist (importing into a shared database).
    if (db.tables().contains(table, Qt::CaseInsensitive)) {
        out["error"] = QStringLiteral("A table named \"%1\" already exists in this database.").arg(table);
        return false;
    }

    // Column names (deduped) + inferred types.
    QStringList names;
    QSet<QString> seen;
    for (int c = 0; c < nCols; ++c) {
        QString name = sanitizeIdent(hasHeader ? header.at(c) : QString(),
                                     QStringLiteral("col%1").arg(c + 1));
        QString base = name;
        int      n   = 2;
        while (seen.contains(name.toLower())) name = base + '_' + QString::number(n++);
        seen.insert(name.toLower());
        names.append(name);
    }

    const int firstData = hasHeader ? 1 : 0;
    QVector<QStringList> colValues(nCols);
    for (int r = firstData; r < rows.size(); ++r) {
        const QStringList &row = rows.at(r);
        for (int c = 0; c < nCols; ++c)
            colValues[c].append(c < row.size() ? row.at(c) : QString());
    }
    QStringList types;
    for (int c = 0; c < nCols; ++c) types.append(inferType(colValues.at(c)));

    QStringList colDefs;
    for (int c = 0; c < nCols; ++c)
        colDefs.append(quoteIdent(names.at(c)) + ' ' + types.at(c));
    const QString createSql = QStringLiteral("CREATE TABLE %1 (%2)")
                              .arg(quoteIdent(table), colDefs.join(QStringLiteral(", ")));

    QSqlQuery q(db);
    if (!q.exec(createSql)) {
        out["error"] = QStringLiteral("CREATE TABLE failed: %1").arg(q.lastError().text());
        return false;
    }

    QStringList placeholders;
    for (int c = 0; c < nCols; ++c) placeholders.append(QStringLiteral("?"));
    const QString insertSql = QStringLiteral("INSERT INTO %1 VALUES (%2)")
                              .arg(quoteIdent(table), placeholders.join(QStringLiteral(", ")));

    int rowCount = 0;
    db.transaction();
    q.prepare(insertSql);
    for (int r = firstData; r < rows.size(); ++r) {
        const QStringList &row = rows.at(r);
        for (int c = 0; c < nCols; ++c) {
            const QString raw = c < row.size() ? row.at(c) : QString();
            const QString v   = raw.trimmed();
            if (v.isEmpty()) { q.addBindValue(QVariant()); continue; }   // NULL
            if (types.at(c) == QLatin1String("INTEGER")) {
                q.addBindValue(v.toLongLong());
            } else if (types.at(c) == QLatin1String("REAL")) {
                q.addBindValue(v.toDouble());
            } else {
                q.addBindValue(raw);   // keep text as-is (untrimmed)
            }
        }
        if (!q.exec()) {
            out["error"] = QStringLiteral("Row %1 failed to insert: %2")
                           .arg(r).arg(q.lastError().text());
            db.rollback();
            return false;
        }
        ++rowCount;
    }
    db.commit();

    out["table"]       = table;
    out["rowCount"]    = rowCount;
    out["columnCount"] = nCols;
    return true;
}

// ── Import into a fresh SQLite file ─────────────────────────────────────────
QVariantMap CsvImporter::import(const QUrl &fileUrl, const QString &tableName,
                                bool hasHeader, const QString &delimiter) const
{
    QVariantMap out;
    const QString path = fileUrl.isLocalFile() ? fileUrl.toLocalFile() : fileUrl.toString();

    // A stable-ish base name for the new file (the final table name is settled
    // inside writeTable, but this only affects the file name on disk).
    const QString hint = sanitizeIdent(tableName.isEmpty()
                                           ? QFileInfo(path).completeBaseName() : tableName,
                                       QStringLiteral("imported"));

    const QString dir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation)
                        + QStringLiteral("/imports");
    QDir().mkpath(dir);
    const QString dbPath = QStringLiteral("%1/%2-%3.sqlite")
                           .arg(dir, hint,
                                QUuid::createUuid().toString(QUuid::WithoutBraces).left(8));

    const QString connId = QStringLiteral("csvimport-")
                           + QUuid::createUuid().toString(QUuid::WithoutBraces);
    bool ok = false;
    {
        QSqlDatabase db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), connId);
        db.setDatabaseName(dbPath);
        if (!db.open()) {
            out["success"] = false;
            out["error"]   = QStringLiteral("Could not create SQLite file: %1").arg(db.lastError().text());
            QSqlDatabase::removeDatabase(connId);
            return out;
        }
        ok = writeTable(db, path, tableName, hasHeader, delimiter, out);
        db.close();
    }
    QSqlDatabase::removeDatabase(connId);

    if (!ok) {
        QFile::remove(dbPath);       // no orphan on failure
        out["success"] = false;
        return out;
    }
    out["success"]  = true;
    out["database"] = dbPath;
    return out;
}

// ── Import into an existing SQLite file as a new table ──────────────────────
QVariantMap CsvImporter::importInto(const QString &databasePath, const QUrl &fileUrl,
                                    const QString &tableName, bool hasHeader,
                                    const QString &delimiter) const
{
    QVariantMap out;
    const QString path = fileUrl.isLocalFile() ? fileUrl.toLocalFile() : fileUrl.toString();

    if (!QFile::exists(databasePath)) {
        out["success"] = false;
        out["error"]   = QStringLiteral("The database file no longer exists: %1").arg(databasePath);
        return out;
    }

    const QString connId = QStringLiteral("csvimport-")
                           + QUuid::createUuid().toString(QUuid::WithoutBraces);
    bool ok = false;
    {
        QSqlDatabase db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), connId);
        db.setDatabaseName(databasePath);
        if (!db.open()) {
            out["success"] = false;
            out["error"]   = QStringLiteral("Could not open the database: %1").arg(db.lastError().text());
            QSqlDatabase::removeDatabase(connId);
            return out;
        }
        ok = writeTable(db, path, tableName, hasHeader, delimiter, out);
        db.close();
    }
    QSqlDatabase::removeDatabase(connId);

    out["success"] = ok;
    if (ok) out["database"] = databasePath;
    return out;
}
