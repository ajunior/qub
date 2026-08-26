#include "SqlUtils.h"

namespace SqlUtils {

QStringList splitStatements(const QString &sql, const QString &driver)
{
    const bool dollarQuoting    = driver == QLatin1String("QPSQL");
    const bool backslashEscapes = driver == QLatin1String("QMYSQL")
                               || driver == QLatin1String("QMARIADB");

    QStringList stmts;
    QString     current;
    QString     dollarTag;   // active delimiter ($$ or $tag$) while in a dollar quote
    enum State { Normal, InString, InLineComment, InBlockComment, InDollarQuote } state = Normal;

    // Length of a dollar-quote delimiter ($$ or $tag$) starting at `pos`, or 0
    // if there is none. Tags cannot start with a digit, so $1-style positional
    // parameters are never mistaken for a delimiter.
    const auto dollarDelimLen = [&sql](int pos) -> int {
        int j = pos + 1;
        if (j < sql.size() && sql[j].isDigit()) return 0;
        while (j < sql.size() && (sql[j].isLetterOrNumber() || sql[j] == '_'))
            ++j;
        return (j < sql.size() && sql[j] == '$') ? j - pos + 1 : 0;
    };

    for (int i = 0; i < sql.size(); ++i) {
        const QChar ch = sql[i];

        switch (state) {
        case Normal:
            if (ch == '\'') {
                state = InString;
                current += ch;
            } else if (ch == '-' && i + 1 < sql.size() && sql[i + 1] == '-') {
                state = InLineComment;
                current += ch;
            } else if (ch == '/' && i + 1 < sql.size() && sql[i + 1] == '*') {
                state = InBlockComment;
                current += ch;
            } else if (dollarQuoting && ch == '$' && dollarDelimLen(i) > 0) {
                const int len = dollarDelimLen(i);
                dollarTag = sql.mid(i, len);
                current  += dollarTag;
                i        += len - 1;
                state     = InDollarQuote;
            } else if (ch == ';') {
                const QString stmt = current.trimmed();
                if (!stmt.isEmpty())
                    stmts << stmt;
                current.clear();
            } else {
                current += ch;
            }
            break;

        case InString:
            current += ch;
            if (backslashEscapes && ch == '\\') {
                if (i + 1 < sql.size())
                    current += sql[++i];  // escaped \' (or any \x)
            } else if (ch == '\'') {
                if (i + 1 < sql.size() && sql[i + 1] == '\'')
                    current += sql[++i];  // escaped ''
                else
                    state = Normal;
            }
            break;

        case InLineComment:
            current += ch;
            if (ch == '\n') state = Normal;
            break;

        case InBlockComment:
            current += ch;
            if (ch == '*' && i + 1 < sql.size() && sql[i + 1] == '/') {
                current += sql[++i];
                state = Normal;
            }
            break;

        case InDollarQuote:
            if (ch == '$' && sql.mid(i, dollarTag.size()) == dollarTag) {
                current += dollarTag;
                i       += dollarTag.size() - 1;
                state    = Normal;
            } else {
                current += ch;
            }
            break;
        }
    }
    const QString last = current.trimmed();
    if (!last.isEmpty())
        stmts << last;
    return stmts;
}

} // namespace SqlUtils
