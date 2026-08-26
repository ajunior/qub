#pragma once

#include <QObject>
#include "QmlSingleton.h"
#include <QVariantList>
#include <QVariantMap>
#include <QList>

class ProfileManager : public QObject {
    Q_OBJECT
    QUB_QML_SINGLETON(ProfileManager)

public:
    Q_PROPERTY(QVariantList profiles READ profiles NOTIFY profilesChanged)

public:
    explicit ProfileManager(QObject *parent = nullptr);

    QVariantList profiles() const;

    Q_INVOKABLE void        addProfile(const QVariantMap &data);
    Q_INVOKABLE void        updateProfile(const QString &id, const QVariantMap &data);
    Q_INVOKABLE void        removeProfile(const QString &id);
    Q_INVOKABLE QVariantMap profile(const QString &id) const;

signals:
    void profilesChanged();

private:
    QList<QVariantMap> m_profiles;
    void save();
    void load();
};

QUB_QML_SINGLETON_FOREIGN(ProfileManager)
