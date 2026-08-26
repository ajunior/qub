#pragma once

#include <QString>
#include <QStringList>

namespace SqlUtils {

// Splits SQL text on ';' while ignoring occurrences inside string literals,
// line comments and block comments. Empty statements are dropped.
//
// `driver` (a Qt driver name such as "QPSQL") enables dialect-specific rules:
// PostgreSQL dollar-quoted bodies ($$ … $$ / $tag$ … $tag$) and MySQL/MariaDB
// backslash-escaped quotes. Empty driver keeps the generic behaviour.
QStringList splitStatements(const QString &sql, const QString &driver = QString());

} // namespace SqlUtils
