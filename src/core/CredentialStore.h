#pragma once

#include <QObject>
#include <functional>

class CredentialStore : public QObject {
    Q_OBJECT
public:
    explicit CredentialStore(QObject *parent = nullptr);

    void store(const QString &connectionName, const QString &password);
    void retrieve(const QString &connectionName, std::function<void(const QString &password, const QString &error)> callback);
    void remove(const QString &connectionName);

private:
    static constexpr char kService[] = "qub";
};
