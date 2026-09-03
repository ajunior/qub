#pragma once

#include <QObject>
#include "QmlSingleton.h"
#include <QVariantList>
#include <QSqlDatabase>
#include <QUrl>

// Global pool of reusable SQL snippets (formerly "saved queries"), stored in
// the shared qub.db. Managed from the Home Snippets page and browsed/saved
// from the workspace sidebar.
class SnippetManager : public QObject {
    Q_OBJECT
    QUB_QML_SINGLETON(SnippetManager)

public:
    Q_PROPERTY(QVariantList snippets READ snippets NOTIFY changed)
public:
    explicit SnippetManager(const QString &dbPath = QString(), QObject *parent = nullptr);
    ~SnippetManager() override;

    QVariantList snippets() const;

    Q_INVOKABLE qint64 save(const QString &name, const QString &folder,
                            const QString &sql);
    Q_INVOKABLE bool   update(qint64 id, const QString &name, const QString &folder,
                              const QString &sql);
    Q_INVOKABLE bool   remove(qint64 id);

    // True when another snippet (excluding excludeId) already uses this
    // name+folder pair (case-insensitive).
    Q_INVOKABLE bool nameInUse(const QString &name, const QString &folder,
                               qint64 excludeId = -1) const;

    Q_INVOKABLE bool        exportSnippets(const QUrl &fileUrl);
    Q_INVOKABLE QVariantMap importSnippets(const QUrl &fileUrl);

signals:
    void changed();

private:
    void initDb(const QString &dbPath);

    QString      m_connectionName;
    QSqlDatabase m_db;
};

QUB_QML_SINGLETON_FOREIGN(SnippetManager)
