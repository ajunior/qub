#pragma once

#include <QSyntaxHighlighter>
#include <QTextCharFormat>
#include <QRegularExpression>
#include <QColor>
#include <QQuickTextDocument>
#include <QtQml/qqml.h>

class SqlHighlighter : public QSyntaxHighlighter {
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(QQuickTextDocument* document
               READ document WRITE setDocument NOTIFY documentChanged)
    Q_PROPERTY(QColor keywordColor
               READ keywordColor  WRITE setKeywordColor  NOTIFY colorsChanged)
    Q_PROPERTY(QColor functionColor
               READ functionColor WRITE setFunctionColor NOTIFY colorsChanged)
    Q_PROPERTY(QColor stringColor
               READ stringColor   WRITE setStringColor   NOTIFY colorsChanged)
    Q_PROPERTY(QColor commentColor
               READ commentColor  WRITE setCommentColor  NOTIFY colorsChanged)
    Q_PROPERTY(QColor numberColor
               READ numberColor   WRITE setNumberColor   NOTIFY colorsChanged)

public:
    explicit SqlHighlighter(QObject *parent = nullptr);

    QQuickTextDocument *document()    const { return m_qdoc; }
    QColor keywordColor()             const { return m_keywordFmt.foreground().color(); }
    QColor functionColor()            const { return m_functionFmt.foreground().color(); }
    QColor stringColor()              const { return m_stringFmt.foreground().color(); }
    QColor commentColor()             const { return m_commentFmt.foreground().color(); }
    QColor numberColor()              const { return m_numberFmt.foreground().color(); }

    void setDocument(QQuickTextDocument *doc);
    void setKeywordColor(const QColor &c);
    void setFunctionColor(const QColor &c);
    void setStringColor(const QColor &c);
    void setCommentColor(const QColor &c);
    void setNumberColor(const QColor &c);

signals:
    void documentChanged();
    void colorsChanged();

protected:
    void highlightBlock(const QString &text) override;

private:
    QQuickTextDocument *m_qdoc = nullptr;

    QTextCharFormat m_keywordFmt;
    QTextCharFormat m_functionFmt;
    QTextCharFormat m_stringFmt;
    QTextCharFormat m_commentFmt;
    QTextCharFormat m_numberFmt;

    QRegularExpression m_kwRe;
    QRegularExpression m_fnRe;
    QRegularExpression m_numRe;
};
