#pragma once

#include <QObject>
#include "QmlSingleton.h"
#include <QString>
#include <QUrl>
#include <QVariantList>

// Literate-SQL support: narrative written in `/* @md … */` block comments
// stays invisible to the database (it's just a comment) but is understood by
// qub — the preview panel renders it and the whole buffer can be exported as
// a Markdown document where SQL becomes fenced code blocks.
class MarkdownDoc : public QObject {
    Q_OBJECT
    QUB_QML_SINGLETON(MarkdownDoc)

public:

public:
    explicit MarkdownDoc(QObject *parent = nullptr);

    // Splits `sql` into ordered segments: [{type: "md"|"sql", text}].
    // Markdown bodies and SQL chunks are trimmed; empty segments are dropped.
    Q_INVOKABLE QVariantList segments(const QString &sql) const;

    // Renders the buffer as a Markdown document: @md bodies verbatim, SQL in
    // ```sql fences.
    Q_INVOKABLE QString toMarkdown(const QString &sql) const;

    // Writes toMarkdown(sql) to a local file. A non-empty `resultsTable`
    // (markdown, e.g. ResultModel::toMarkdown()) is appended as a
    // "Latest result" section. Returns false on I/O failure.
    Q_INVOKABLE bool exportMarkdown(const QString &sql, const QUrl &fileUrl,
                                    const QString &resultsTable = QString()) const;
};

QUB_QML_SINGLETON_FOREIGN(MarkdownDoc)
