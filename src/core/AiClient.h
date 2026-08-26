#pragma once
#include <QObject>
#include "QmlSingleton.h"
#include <QString>

class CredentialStore;
class LogManager;
class QNetworkAccessManager;

class AiClient : public QObject {
    Q_OBJECT
    QUB_QML_SINGLETON(AiClient)

public:
    Q_PROPERTY(bool    loading   READ loading   NOTIFY loadingChanged)
    Q_PROPERTY(QString provider  READ provider  WRITE setProvider  NOTIFY providerChanged)
    Q_PROPERTY(QString model     READ model     WRITE setModel     NOTIFY modelChanged)
    Q_PROPERTY(QString ollamaUrl READ ollamaUrl WRITE setOllamaUrl NOTIFY ollamaUrlChanged)

public:
    explicit AiClient(CredentialStore *credentials, LogManager *log = nullptr, QObject *parent = nullptr);

    bool    loading()   const;
    QString provider()  const;
    QString model()     const;
    QString ollamaUrl() const;

    void setProvider(const QString &v);
    void setModel(const QString &v);
    void setOllamaUrl(const QString &v);

    Q_INVOKABLE void generate(const QString &prompt, const QString &schema,
                              const QString &dialect = QString());
    Q_INVOKABLE void saveApiKey(const QString &key);
    Q_INVOKABLE void checkApiKey();

signals:
    void loadingChanged();
    void providerChanged();
    void modelChanged();
    void ollamaUrlChanged();
    void resultReady(const QString &sql);
    void errorOccurred(const QString &message);
    void apiKeyPresent(bool present);

private:
    void doGenerate(const QString &apiKey, const QString &prompt, const QString &schema);
    void callAnthropic(const QString &apiKey, const QString &prompt, const QString &schema);
    void callOpenAI(const QString &apiKey, const QString &prompt, const QString &schema);
    void callOllama(const QString &prompt, const QString &schema);
    void finishWithError(const QString &message);
    static QString cleanSql(const QString &raw);
    QString buildSystemPrompt(const QString &schema) const;

    CredentialStore       *m_credentials;
    LogManager            *m_log = nullptr;
    QNetworkAccessManager *m_nam;
    bool                   m_loading   = false;
    QString                m_provider  = QStringLiteral("anthropic");
    QString                m_model;
    QString                m_ollamaUrl = QStringLiteral("http://localhost:11434");
    QString                m_pendingPrompt;
    QString                m_dialect;   // e.g. "PostgreSQL"; empty = unknown
};

QUB_QML_SINGLETON_FOREIGN(AiClient)
