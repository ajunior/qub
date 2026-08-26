#pragma once

#include <QObject>
#include "QmlSingleton.h"
#include <QStringList>
#include <QUrl>
#include <QVariantList>
#include <QVariantMap>

class QSqlDatabase;

// Turns a delimited-text file (CSV/TSV) into a queryable SQLite table.
//
// `preview()` sniffs the delimiter, reads the header and a handful of rows and
// infers a SQLite type per column — enough to show the user what they're about
// to import. `import()` does the full parse, writes a standalone SQLite database
// file (under the app data dir, so it survives restarts) and returns the file
// path; the caller then registers it as an ordinary QSQLITE connection, after
// which the data is queryable with plain SQL like any other table.
class CsvImporter : public QObject {
    Q_OBJECT
    QUB_QML_SINGLETON(CsvImporter)

public:
public:
    explicit CsvImporter(QObject *parent = nullptr) : QObject(parent) {}

    // { success, error, delimiter, hasHeader, table,
    //   columns: [{ name, type }], rows: [[string, …]], sampledRows }
    Q_INVOKABLE QVariantMap preview(const QUrl &fileUrl, bool hasHeader = true,
                                    int sampleRows = 20) const;

    // Full import into a fresh SQLite database file.
    // { success, error, database(path), table, rowCount, columnCount }
    // `delimiter` empty ⇒ auto-detect (as in preview). A blank `tableName`
    // falls back to a sanitised version of the file's base name.
    Q_INVOKABLE QVariantMap import(const QUrl     &fileUrl,
                                   const QString  &tableName = QString(),
                                   bool            hasHeader = true,
                                   const QString  &delimiter = QString()) const;

    // Import into an *existing* SQLite database file as a new table (this is
    // how a second CSV joins the first — same database, so plain SQL joins
    // work). Fails if a table of that name already exists.
    // { success, error, database(path), table, rowCount, columnCount }
    Q_INVOKABLE QVariantMap importInto(const QString &databasePath,
                                       const QUrl    &fileUrl,
                                       const QString &tableName,
                                       bool           hasHeader = true,
                                       const QString &delimiter = QString()) const;

private:
    // Parse `filePath` and write it as a new table into the already-open `db`.
    // Populates out with { table, rowCount, columnCount } on success or
    // { error } on failure; returns false on any failure (including a name
    // collision). Does not manage the db's lifetime.
    static bool  writeTable(QSqlDatabase &db, const QString &filePath,
                            const QString &tableName, bool hasHeader,
                            const QString &delimiter, QVariantMap &out);
    static QChar resolveDelimiter(const QString &filePath, const QString &delimiter);

    // Parse the whole file into rows of string fields (RFC 4180-ish: quoted
    // fields, "" escapes, delimiters/newlines inside quotes). Returns false on
    // read failure.
    static bool parseFile(const QString &path, QChar delimiter,
                          QVector<QStringList> &rows, QString &error);
    static QChar   sniffDelimiter(const QString &sampleLine);
    static QString inferType(const QStringList &values); // "INTEGER"|"REAL"|"TEXT"
    static QString sanitizeIdent(const QString &raw, const QString &fallback);
    static QString quoteIdent(const QString &ident);     // "foo""bar"
};

QUB_QML_SINGLETON_FOREIGN(CsvImporter)
