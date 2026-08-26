#include "ProfileManager.h"
#include <QSettings>
#include <QJsonDocument>
#include <QJsonArray>
#include <QJsonObject>
#include <QUuid>

ProfileManager::ProfileManager(QObject *parent)
    : QObject(parent)
{
    load();
}

QVariantList ProfileManager::profiles() const
{
    QVariantList list;
    for (const auto &p : m_profiles)
        list << p;
    return list;
}

QVariantMap ProfileManager::profile(const QString &id) const
{
    if (id.isEmpty()) return {};
    for (const auto &p : m_profiles)
        if (p.value("id").toString() == id)
            return p;
    return {};
}

void ProfileManager::addProfile(const QVariantMap &data)
{
    QVariantMap p = data;
    p["id"] = QUuid::createUuid().toString(QUuid::WithoutBraces);
    m_profiles << p;
    save();
    emit profilesChanged();
}

void ProfileManager::updateProfile(const QString &id, const QVariantMap &data)
{
    for (auto &p : m_profiles) {
        if (p.value("id").toString() == id) {
            QVariantMap updated = data;
            updated["id"] = id;
            p = updated;
            save();
            emit profilesChanged();
            return;
        }
    }
}

void ProfileManager::removeProfile(const QString &id)
{
    m_profiles.removeIf([&id](const QVariantMap &p) {
        return p.value("id").toString() == id;
    });
    save();
    emit profilesChanged();
}

void ProfileManager::save()
{
    QJsonArray arr;
    for (const auto &p : m_profiles) {
        QJsonObject obj;
        for (auto it = p.cbegin(); it != p.cend(); ++it)
            obj[it.key()] = QJsonValue::fromVariant(it.value());
        arr.append(obj);
    }
    QSettings settings("qub", "qub");
    settings.setValue("profiles", QString::fromUtf8(QJsonDocument(arr).toJson(QJsonDocument::Compact)));
}

void ProfileManager::load()
{
    QSettings settings("qub", "qub");
    const QString raw = settings.value("profiles").toString();
    if (raw.isEmpty()) return;

    QJsonParseError err;
    const auto doc = QJsonDocument::fromJson(raw.toUtf8(), &err);
    if (err.error != QJsonParseError::NoError) return;

    for (const auto &v : doc.array()) {
        const QJsonObject obj = v.toObject();
        QVariantMap p;
        for (auto it = obj.constBegin(); it != obj.constEnd(); ++it)
            p[it.key()] = it.value().toVariant();
        m_profiles << p;
    }
}
