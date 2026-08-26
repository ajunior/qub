#include "SqlHighlighter.h"

// ── Keyword lists ─────────────────────────────────────────────────────────────

static const QLatin1String s_keywords[] = {
    // DML
    QLatin1String("SELECT"), QLatin1String("FROM"),   QLatin1String("WHERE"),
    QLatin1String("INSERT"),  QLatin1String("INTO"),   QLatin1String("VALUES"),
    QLatin1String("UPDATE"),  QLatin1String("SET"),    QLatin1String("DELETE"),
    QLatin1String("REPLACE"), QLatin1String("MERGE"),  QLatin1String("TRUNCATE"),
    // Clauses
    QLatin1String("JOIN"),    QLatin1String("LEFT"),   QLatin1String("RIGHT"),
    QLatin1String("INNER"),   QLatin1String("OUTER"),  QLatin1String("FULL"),
    QLatin1String("CROSS"),   QLatin1String("NATURAL"),QLatin1String("ON"),
    QLatin1String("AS"),      QLatin1String("USING"),  QLatin1String("LATERAL"),
    QLatin1String("ORDER"),   QLatin1String("BY"),     QLatin1String("GROUP"),
    QLatin1String("HAVING"),  QLatin1String("LIMIT"),  QLatin1String("OFFSET"),
    QLatin1String("FETCH"),   QLatin1String("FIRST"),  QLatin1String("NEXT"),
    QLatin1String("ROWS"),    QLatin1String("ONLY"),
    QLatin1String("DISTINCT"),QLatin1String("ALL"),
    QLatin1String("UNION"),   QLatin1String("INTERSECT"),QLatin1String("EXCEPT"),
    QLatin1String("RETURNING"),
    // Logical
    QLatin1String("AND"),     QLatin1String("OR"),     QLatin1String("NOT"),
    QLatin1String("IN"),      QLatin1String("EXISTS"), QLatin1String("BETWEEN"),
    QLatin1String("LIKE"),    QLatin1String("ILIKE"),  QLatin1String("IS"),
    QLatin1String("SIMILAR"),
    // Control flow
    QLatin1String("CASE"),    QLatin1String("WHEN"),   QLatin1String("THEN"),
    QLatin1String("ELSE"),    QLatin1String("END"),
    // Window
    QLatin1String("OVER"),    QLatin1String("PARTITION"),QLatin1String("WINDOW"),
    QLatin1String("FILTER"),
    // DDL
    QLatin1String("CREATE"),  QLatin1String("TABLE"),  QLatin1String("VIEW"),
    QLatin1String("INDEX"),   QLatin1String("DATABASE"),QLatin1String("SCHEMA"),
    QLatin1String("SEQUENCE"),QLatin1String("TRIGGER"),QLatin1String("FUNCTION"),
    QLatin1String("PROCEDURE"),QLatin1String("EXTENSION"),
    QLatin1String("DROP"),    QLatin1String("ALTER"),  QLatin1String("ADD"),
    QLatin1String("COLUMN"),  QLatin1String("RENAME"), QLatin1String("MODIFY"),
    QLatin1String("CHANGE"),  QLatin1String("IF"),
    // Constraints
    QLatin1String("PRIMARY"), QLatin1String("KEY"),    QLatin1String("FOREIGN"),
    QLatin1String("REFERENCES"),QLatin1String("CONSTRAINT"),
    QLatin1String("UNIQUE"),  QLatin1String("DEFAULT"),QLatin1String("CHECK"),
    QLatin1String("NULL"),    QLatin1String("WITH"),   QLatin1String("RECURSIVE"),
    // Transactions
    QLatin1String("BEGIN"),   QLatin1String("COMMIT"), QLatin1String("ROLLBACK"),
    QLatin1String("TRANSACTION"),QLatin1String("SAVEPOINT"),
    // Permissions
    QLatin1String("GRANT"),   QLatin1String("REVOKE"),
    // Sort
    QLatin1String("ASC"),     QLatin1String("DESC"),   QLatin1String("NULLS"),
    QLatin1String("LAST"),
    // Literals
    QLatin1String("TRUE"),    QLatin1String("FALSE"),
    // Types
    QLatin1String("INTEGER"), QLatin1String("INT"),    QLatin1String("BIGINT"),
    QLatin1String("SMALLINT"),QLatin1String("TINYINT"),
    QLatin1String("FLOAT"),   QLatin1String("DOUBLE"), QLatin1String("DECIMAL"),
    QLatin1String("NUMERIC"), QLatin1String("REAL"),
    QLatin1String("VARCHAR"), QLatin1String("CHAR"),   QLatin1String("TEXT"),
    QLatin1String("NVARCHAR"),QLatin1String("NCHAR"),
    QLatin1String("BOOLEAN"), QLatin1String("BOOL"),
    QLatin1String("DATE"),    QLatin1String("TIME"),   QLatin1String("DATETIME"),
    QLatin1String("TIMESTAMP"),QLatin1String("INTERVAL"),
    QLatin1String("BLOB"),    QLatin1String("BINARY"), QLatin1String("VARBINARY"),
    QLatin1String("BYTEA"),   QLatin1String("JSON"),   QLatin1String("JSONB"),
    QLatin1String("XML"),     QLatin1String("UUID"),
    QLatin1String("SERIAL"),  QLatin1String("BIGSERIAL"),
};

static const QLatin1String s_functions[] = {
    // Aggregates
    QLatin1String("COUNT"),   QLatin1String("SUM"),    QLatin1String("AVG"),
    QLatin1String("MIN"),     QLatin1String("MAX"),
    QLatin1String("STRING_AGG"),QLatin1String("ARRAY_AGG"),QLatin1String("GROUP_CONCAT"),
    QLatin1String("LISTAGG"),
    // Conditional
    QLatin1String("COALESCE"),QLatin1String("NULLIF"), QLatin1String("IFNULL"),
    QLatin1String("NVL"),     QLatin1String("IIF"),    QLatin1String("GREATEST"),
    QLatin1String("LEAST"),
    // String
    QLatin1String("UPPER"),   QLatin1String("LOWER"),  QLatin1String("TRIM"),
    QLatin1String("LTRIM"),   QLatin1String("RTRIM"),  QLatin1String("LENGTH"),
    QLatin1String("LEN"),     QLatin1String("SUBSTRING"),QLatin1String("SUBSTR"),
    QLatin1String("REPLACE"), QLatin1String("CONCAT"), QLatin1String("CONCAT_WS"),
    QLatin1String("REPEAT"),  QLatin1String("REVERSE"),QLatin1String("SPLIT_PART"),
    QLatin1String("LPAD"),    QLatin1String("RPAD"),   QLatin1String("REGEXP_REPLACE"),
    QLatin1String("REGEXP_MATCHES"),QLatin1String("POSITION"),
    // Date/time
    QLatin1String("NOW"),     QLatin1String("CURRENT_DATE"),QLatin1String("CURRENT_TIME"),
    QLatin1String("CURRENT_TIMESTAMP"),QLatin1String("GETDATE"),
    QLatin1String("DATE_TRUNC"),QLatin1String("DATE_PART"),QLatin1String("EXTRACT"),
    QLatin1String("TO_DATE"), QLatin1String("TO_TIMESTAMP"),
    QLatin1String("DATEDIFF"),QLatin1String("DATEADD"),QLatin1String("DATEPART"),
    QLatin1String("STRFTIME"),QLatin1String("DATE"),   QLatin1String("TIME"),
    // Cast/convert
    QLatin1String("CAST"),    QLatin1String("CONVERT"), QLatin1String("TRY_CAST"),
    QLatin1String("TRY_CONVERT"),QLatin1String("PARSE"),
    // Window
    QLatin1String("ROW_NUMBER"),QLatin1String("RANK"), QLatin1String("DENSE_RANK"),
    QLatin1String("NTILE"),   QLatin1String("CUME_DIST"),QLatin1String("PERCENT_RANK"),
    QLatin1String("LAG"),     QLatin1String("LEAD"),   QLatin1String("FIRST_VALUE"),
    QLatin1String("LAST_VALUE"),QLatin1String("NTH_VALUE"),
    // Math
    QLatin1String("ABS"),     QLatin1String("CEIL"),   QLatin1String("CEILING"),
    QLatin1String("FLOOR"),   QLatin1String("ROUND"),  QLatin1String("TRUNC"),
    QLatin1String("MOD"),     QLatin1String("POWER"),  QLatin1String("POW"),
    QLatin1String("SQRT"),    QLatin1String("EXP"),    QLatin1String("LOG"),
    QLatin1String("LOG10"),   QLatin1String("LN"),     QLatin1String("SIGN"),
    QLatin1String("RANDOM"),  QLatin1String("RAND"),
    // Set/array
    QLatin1String("GENERATE_SERIES"),QLatin1String("UNNEST"),
    QLatin1String("ARRAY_LENGTH"),QLatin1String("ARRAY_APPEND"),
    // JSON
    QLatin1String("JSON_OBJECT"),QLatin1String("JSON_ARRAY"),
    QLatin1String("JSON_EXTRACT"),QLatin1String("JSON_VALUE"),
    QLatin1String("JSON_QUERY"),
};

// ── Helpers ───────────────────────────────────────────────────────────────────

static QStringList toList(const QLatin1String *arr, int n)
{
    QStringList out;
    out.reserve(n);
    for (int i = 0; i < n; ++i)
        out << QString(arr[i]);
    return out;
}

// ── Constructor ───────────────────────────────────────────────────────────────

SqlHighlighter::SqlHighlighter(QObject *parent)
    : QSyntaxHighlighter(parent)
{
    const int kwCount = static_cast<int>(std::size(s_keywords));
    const int fnCount = static_cast<int>(std::size(s_functions));

    const QString kwPat = "\\b(" + toList(s_keywords, kwCount).join('|') + ")\\b";
    m_kwRe = QRegularExpression(kwPat, QRegularExpression::CaseInsensitiveOption);

    // Function names detected when immediately followed (with optional whitespace) by '('
    const QString fnPat = "\\b(" + toList(s_functions, fnCount).join('|') + ")\\b(?=\\s*\\()";
    m_fnRe = QRegularExpression(fnPat, QRegularExpression::CaseInsensitiveOption);

    m_numRe = QRegularExpression("\\b\\d+(\\.\\d+)?([eE][+-]?\\d+)?\\b");

    // Keywords bold so they visually anchor the query structure
    m_keywordFmt.setFontWeight(QFont::Bold);
}

// ── Document property ────────────────────────────────────────────────────────

void SqlHighlighter::setDocument(QQuickTextDocument *doc)
{
    if (m_qdoc == doc) return;
    m_qdoc = doc;
    QSyntaxHighlighter::setDocument(doc ? doc->textDocument() : nullptr);
    emit documentChanged();
}

// ── Color setters ─────────────────────────────────────────────────────────────

void SqlHighlighter::setKeywordColor(const QColor &c) {
    if (m_keywordFmt.foreground().color() == c) return;
    m_keywordFmt.setForeground(c);
    rehighlight();
    emit colorsChanged();
}

void SqlHighlighter::setFunctionColor(const QColor &c) {
    if (m_functionFmt.foreground().color() == c) return;
    m_functionFmt.setForeground(c);
    rehighlight();
    emit colorsChanged();
}

void SqlHighlighter::setStringColor(const QColor &c) {
    if (m_stringFmt.foreground().color() == c) return;
    m_stringFmt.setForeground(c);
    rehighlight();
    emit colorsChanged();
}

void SqlHighlighter::setCommentColor(const QColor &c) {
    if (m_commentFmt.foreground().color() == c) return;
    m_commentFmt.setForeground(c);
    rehighlight();
    emit colorsChanged();
}

void SqlHighlighter::setNumberColor(const QColor &c) {
    if (m_numberFmt.foreground().color() == c) return;
    m_numberFmt.setForeground(c);
    rehighlight();
    emit colorsChanged();
}

// ── Highlight ─────────────────────────────────────────────────────────────────

void SqlHighlighter::highlightBlock(const QString &text)
{
    // Pass 1 — keywords, functions, numbers (may be overridden by strings/comments below)
    {
        auto it = m_kwRe.globalMatch(text);
        while (it.hasNext()) {
            const auto m = it.next();
            setFormat(m.capturedStart(), m.capturedLength(), m_keywordFmt);
        }
    }
    {
        auto it = m_fnRe.globalMatch(text);
        while (it.hasNext()) {
            const auto m = it.next();
            // group 1 = function name only (excludes trailing whitespace / lookahead)
            setFormat(m.capturedStart(1), m.capturedLength(1), m_functionFmt);
        }
    }
    {
        auto it = m_numRe.globalMatch(text);
        while (it.hasNext()) {
            const auto m = it.next();
            setFormat(m.capturedStart(), m.capturedLength(), m_numberFmt);
        }
    }

    // Pass 2 — strings and block/line comments; these always win over keywords
    setCurrentBlockState(0);

    int  pos     = 0;
    bool inBlock = (previousBlockState() == 1);

    while (pos < text.length()) {
        if (inBlock) {
            // We're inside a /* ... */ block comment
            const int end = text.indexOf(QLatin1String("*/"), pos);
            if (end < 0) {
                setFormat(pos, text.length() - pos, m_commentFmt);
                setCurrentBlockState(1);
                return;
            }
            setFormat(pos, end - pos + 2, m_commentFmt);
            pos     = end + 2;
            inBlock = false;

        } else if (pos + 1 < text.length()
                   && text[pos] == QLatin1Char('-')
                   && text[pos + 1] == QLatin1Char('-')) {
            // Line comment: -- to end of line
            setFormat(pos, text.length() - pos, m_commentFmt);
            return;

        } else if (pos + 1 < text.length()
                   && text[pos] == QLatin1Char('/')
                   && text[pos + 1] == QLatin1Char('*')) {
            // Start of block comment
            const int end = text.indexOf(QLatin1String("*/"), pos + 2);
            if (end < 0) {
                setFormat(pos, text.length() - pos, m_commentFmt);
                setCurrentBlockState(1);
                return;
            }
            setFormat(pos, end - pos + 2, m_commentFmt);
            pos = end + 2;

        } else if (text[pos] == QLatin1Char('\'')) {
            // Single-quoted string literal; '' is an escaped quote
            const int start = pos++;
            while (pos < text.length()) {
                if (text[pos] == QLatin1Char('\'')) {
                    ++pos;
                    if (pos < text.length() && text[pos] == QLatin1Char('\''))
                        ++pos; // escaped ''
                    else
                        break; // end of string
                } else {
                    ++pos;
                }
            }
            setFormat(start, pos - start, m_stringFmt);

        } else {
            ++pos;
        }
    }
}
