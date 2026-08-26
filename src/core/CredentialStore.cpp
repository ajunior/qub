#include "CredentialStore.h"
#include <keychain.h>
#include <QCoreApplication>

CredentialStore::CredentialStore(QObject *parent)
    : QObject(parent)
{}

void CredentialStore::store(const QString &connectionName, const QString &password)
{
    auto *job = new QKeychain::WritePasswordJob(kService, this);
    job->setKey(connectionName);
    job->setTextData(password);
    job->start();
}

void CredentialStore::retrieve(const QString &connectionName,
                                std::function<void(const QString &, const QString &)> callback)
{
    auto *job = new QKeychain::ReadPasswordJob(kService, this);
    job->setKey(connectionName);
    connect(job, &QKeychain::ReadPasswordJob::finished, this, [job, callback]() {
        if (job->error() == QKeychain::NoError)
            callback(job->textData(), {});
        else
            callback({}, job->errorString());
        job->deleteLater();
    });
    job->start();
}

void CredentialStore::remove(const QString &connectionName)
{
    auto *job = new QKeychain::DeletePasswordJob(kService, this);
    job->setKey(connectionName);
    job->start();
}
