#pragma once

#include <QObject>
#include "QmlSingleton.h"
#include <QVariantList>
#include <QVariantMap>
#include <QUrl>

class ThemeManager : public QObject {
    Q_OBJECT
    QUB_QML_SINGLETON(ThemeManager)

public:
    Q_PROPERTY(QVariantList themes       READ themes        NOTIFY themesChanged)
    Q_PROPERTY(QString      activeThemeId READ activeThemeId NOTIFY activeThemeChanged)

public:
    explicit ThemeManager(QObject *parent = nullptr);

    QVariantList themes()        const;
    QString      activeThemeId() const;

    Q_INVOKABLE QVariantMap activeThemeColors()               const;
    Q_INVOKABLE QVariantMap themeById(const QString &id)      const;
    Q_INVOKABLE void        setActiveTheme(const QString &id);
    Q_INVOKABLE void        addTheme(const QVariantMap &data);
    Q_INVOKABLE void        updateTheme(const QString &id, const QVariantMap &data);
    Q_INVOKABLE void        removeTheme(const QString &id);
    Q_INVOKABLE bool        exportTheme(const QString &id, const QUrl &fileUrl);
    Q_INVOKABLE QVariantMap importTheme(const QUrl &fileUrl);

signals:
    void themesChanged();
    void activeThemeChanged();

private:
    QList<QVariantMap> m_builtins;
    QList<QVariantMap> m_custom;
    QString            m_activeId;

    void initBuiltins();
    void seedPresets();
    void save();
    void load();
};

QUB_QML_SINGLETON_FOREIGN(ThemeManager)
