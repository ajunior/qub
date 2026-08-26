#include "MarkdownDoc.h"

#include <QFile>
#include <QRegularExpression>
#include <QVariantMap>

MarkdownDoc::MarkdownDoc(QObject *parent)
    : QObject(parent)
{
}

QVariantList MarkdownDoc::segments(const QString &sql) const
{
    // `/*` + optional whitespace + `@md` as a whole word opens a block; the
    // first `*/` closes it. An unclosed block runs to the end of the buffer
    // (matches how the block reads while it is still being typed).
    static const QRegularExpression open(QStringLiteral(R"(/\*\s*@md\b)"));

    QVariantList out;
    int pos = 0;

    for (;;) {
        const auto m = open.match(sql, pos);
        if (!m.hasMatch())
            break;

        const QString before = sql.mid(pos, m.capturedStart() - pos).trimmed();
        if (!before.isEmpty())
            out << QVariantMap{{"type", "sql"}, {"text", before}};

        const int bodyStart = m.capturedEnd();
        const int end       = sql.indexOf(QLatin1String("*/"), bodyStart);
        const QString body  = (end < 0 ? sql.mid(bodyStart)
                                       : sql.mid(bodyStart, end - bodyStart)).trimmed();
        if (!body.isEmpty())
            out << QVariantMap{{"type", "md"}, {"text", body}};

        if (end < 0)
            return out;
        pos = end + 2;
    }

    const QString rest = sql.mid(pos).trimmed();
    if (!rest.isEmpty())
        out << QVariantMap{{"type", "sql"}, {"text", rest}};
    return out;
}

QString MarkdownDoc::toMarkdown(const QString &sql) const
{
    QString doc;
    const QVariantList segs = segments(sql);
    for (const QVariant &v : segs) {
        const QVariantMap seg = v.toMap();
        if (seg["type"] == QLatin1String("md"))
            doc += seg["text"].toString() + "\n\n";
        else
            doc += "```sql\n" + seg["text"].toString() + "\n```\n\n";
    }
    while (doc.endsWith('\n'))
        doc.chop(1);
    return doc.isEmpty() ? doc : doc + "\n";
}

bool MarkdownDoc::exportMarkdown(const QString &sql, const QUrl &fileUrl,
                                 const QString &resultsTable) const
{
    QString path = fileUrl.isLocalFile() ? fileUrl.toLocalFile() : fileUrl.toString();
    if (!path.endsWith(QLatin1String(".md"), Qt::CaseInsensitive))
        path += QLatin1String(".md");

    QString doc = toMarkdown(sql);
    if (!resultsTable.trimmed().isEmpty())
        doc += QStringLiteral("\n## Latest result\n\n") + resultsTable;

    QFile f(path);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text))
        return false;
    f.write(doc.toUtf8());
    return true;
}
