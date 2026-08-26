#pragma once
#include <QObject>
#include "QmlSingleton.h"
#include <QSqlDatabase>
#include <QVariantList>
#include <QVariantMap>

class LogManager : public QObject {
    Q_OBJECT
    QUB_QML_SINGLETON(LogManager)

public:
    Q_PROPERTY(QVariantList entries    READ entries    NOTIFY entriesChanged)
    Q_PROPERTY(int          errorCount READ errorCount NOTIFY entriesChanged)
    Q_PROPERTY(int          warnCount  READ warnCount  NOTIFY entriesChanged)

public:
    explicit LogManager(QObject *parent = nullptr);
    ~LogManager() override;

    QVariantList entries()    const;
    int          errorCount() const { return m_errorCount; }
    int          warnCount()  const { return m_warnCount;  }

    void post(const QString &level,
              const QString &category,
              const QString &connection,
              const QString &summary,
              const QVariantMap &detail = {});

    Q_INVOKABLE void    clear();
    Q_INVOKABLE QString exportJson() const;
    Q_INVOKABLE QString exportCsv()  const;

signals:
    void entriesChanged();
    void entryAdded(QVariantMap entry);

private:
    static constexpr int    kMaxEntries    = 2000;
    static constexpr qint64 kRetentionDays = 7;

    void initDb();
    void load();

    QSqlDatabase       m_db;
    QList<QVariantMap> m_entries;
    qint64 m_nextId     = 0;
    int    m_errorCount = 0;
    int    m_warnCount  = 0;
};

QUB_QML_SINGLETON_FOREIGN(LogManager)
