#include "AiClient.h"
#include "CredentialStore.h"
#include "LogManager.h"

#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QRegularExpression>
#include <QUrl>

AiClient::AiClient(CredentialStore *credentials, LogManager *log, QObject *parent)
    : QObject(parent)
    , m_credentials(credentials)
    , m_log(log)
    , m_nam(new QNetworkAccessManager(this))
{
    // Abort stalled requests instead of leaving the panel in "loading"
    // forever. Generous because local Ollama models on CPU can be slow to
    // produce the (non-streamed) response.
    m_nam->setTransferTimeout(120000); // 2 min
}

bool    AiClient::loading()   const { return m_loading; }
QString AiClient::provider()  const { return m_provider; }
QString AiClient::model()     const { return m_model; }
QString AiClient::ollamaUrl() const { return m_ollamaUrl; }

void AiClient::setProvider(const QString &v) {
    if (m_provider == v) return;
    m_provider = v;
    emit providerChanged();
}

void AiClient::setModel(const QString &v) {
    if (m_model == v) return;
    m_model = v;
    emit modelChanged();
}

void AiClient::setOllamaUrl(const QString &v) {
    if (m_ollamaUrl == v) return;
    m_ollamaUrl = v;
    emit ollamaUrlChanged();
}

void AiClient::generate(const QString &prompt, const QString &schema,
                        const QString &dialect)
{
    if (m_loading) return;
    m_loading       = true;
    m_pendingPrompt = prompt;
    m_dialect       = dialect;
    emit loadingChanged();

    const QString prov = m_provider.toLower();

    if (prov == QStringLiteral("ollama")) {
        callOllama(prompt, schema);
        return;
    }

    m_credentials->retrieve(QStringLiteral("ai_") + prov,
        [this, prompt, schema](const QString &key, const QString &error) {
            if (!error.isEmpty() || key.isEmpty()) {
                finishWithError(key.isEmpty()
                    ? QStringLiteral("No API key saved for ") + m_provider + QStringLiteral(". Add it in Settings → AI.")
                    : error);
                return;
            }
            doGenerate(key, prompt, schema);
        });
}

void AiClient::saveApiKey(const QString &key)
{
    m_credentials->store(QStringLiteral("ai_") + m_provider.toLower(), key);
}

void AiClient::checkApiKey()
{
    const QString prov = m_provider.toLower();
    if (prov == QStringLiteral("ollama")) {
        emit apiKeyPresent(true);
        return;
    }
    m_credentials->retrieve(QStringLiteral("ai_") + prov,
        [this](const QString &key, const QString &) {
            emit apiKeyPresent(!key.isEmpty());
        });
}

void AiClient::doGenerate(const QString &apiKey, const QString &prompt, const QString &schema)
{
    const QString prov = m_provider.toLower();
    if (prov == QStringLiteral("anthropic"))
        callAnthropic(apiKey, prompt, schema);
    else if (prov == QStringLiteral("openai"))
        callOpenAI(apiKey, prompt, schema);
    else
        finishWithError(QStringLiteral("Unknown provider: ") + m_provider);
}

// ── Provider implementations ──────────────────────────────────────────────────

void AiClient::callAnthropic(const QString &apiKey, const QString &prompt, const QString &schema)
{
    const QString mdl = m_model.isEmpty() ? QStringLiteral("claude-haiku-4-5-20251001") : m_model;

    QNetworkRequest req{QUrl{QStringLiteral("https://api.anthropic.com/v1/messages")}};
    req.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    req.setRawHeader("x-api-key",          apiKey.toUtf8());
    req.setRawHeader("anthropic-version",  "2023-06-01");

    const QJsonObject body {
        { "model",      mdl },
        { "max_tokens", 1024 },
        { "system",     buildSystemPrompt(schema) },
        { "messages",   QJsonArray { QJsonObject { {"role","user"}, {"content", prompt} } } }
    };

    auto *reply = m_nam->post(req, QJsonDocument(body).toJson(QJsonDocument::Compact));
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        if (reply->error() != QNetworkReply::NoError) {
            finishWithError(reply->errorString());
            return;
        }
        const QJsonObject resp = QJsonDocument::fromJson(reply->readAll()).object();
        const QJsonArray  content = resp["content"].toArray();
        if (content.isEmpty()) {
            finishWithError(QStringLiteral("Empty response from Anthropic"));
            return;
        }
        const QString sql = cleanSql(content.first().toObject()["text"].toString());
        m_loading = false;
        emit loadingChanged();
        if (m_log) m_log->post("info", "AI", "",
                               "Generated SQL · " + (m_model.isEmpty() ? QStringLiteral("claude-haiku-4-5-20251001") : m_model),
                               {{"prompt", m_pendingPrompt}, {"provider", m_provider}, {"model", m_model}, {"sql", sql}});
        emit resultReady(sql);
    });
}

void AiClient::callOpenAI(const QString &apiKey, const QString &prompt, const QString &schema)
{
    const QString mdl = m_model.isEmpty() ? QStringLiteral("gpt-4o-mini") : m_model;

    QNetworkRequest req{QUrl{QStringLiteral("https://api.openai.com/v1/chat/completions")}};
    req.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    req.setRawHeader("Authorization", QByteArrayLiteral("Bearer ") + apiKey.toUtf8());

    const QJsonObject body {
        { "model", mdl },
        { "messages", QJsonArray {
            QJsonObject { {"role","system"}, {"content", buildSystemPrompt(schema)} },
            QJsonObject { {"role","user"},   {"content", prompt} }
        }}
    };

    auto *reply = m_nam->post(req, QJsonDocument(body).toJson(QJsonDocument::Compact));
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        if (reply->error() != QNetworkReply::NoError) {
            finishWithError(reply->errorString());
            return;
        }
        const QJsonObject resp    = QJsonDocument::fromJson(reply->readAll()).object();
        const QJsonArray  choices = resp["choices"].toArray();
        if (choices.isEmpty()) {
            finishWithError(QStringLiteral("Empty response from OpenAI"));
            return;
        }
        const QString sql = cleanSql(
            choices.first().toObject()["message"].toObject()["content"].toString());
        m_loading = false;
        emit loadingChanged();
        if (m_log) m_log->post("info", "AI", "",
                               "Generated SQL · " + (m_model.isEmpty() ? QStringLiteral("gpt-4o-mini") : m_model),
                               {{"prompt", m_pendingPrompt}, {"provider", m_provider}, {"model", m_model}, {"sql", sql}});
        emit resultReady(sql);
    });
}

void AiClient::callOllama(const QString &prompt, const QString &schema)
{
    const QString mdl = m_model.isEmpty() ? QStringLiteral("llama3.2") : m_model;
    const QString url = m_ollamaUrl.endsWith('/')
        ? m_ollamaUrl + QStringLiteral("api/chat")
        : m_ollamaUrl + QStringLiteral("/api/chat");

    QNetworkRequest req{QUrl{url}};
    req.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");

    const QJsonObject body {
        { "model",  mdl },
        { "stream", false },
        { "messages", QJsonArray {
            QJsonObject { {"role","system"}, {"content", buildSystemPrompt(schema)} },
            QJsonObject { {"role","user"},   {"content", prompt} }
        }}
    };

    auto *reply = m_nam->post(req, QJsonDocument(body).toJson(QJsonDocument::Compact));
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        if (reply->error() != QNetworkReply::NoError) {
            finishWithError(reply->errorString());
            return;
        }
        const QJsonObject resp = QJsonDocument::fromJson(reply->readAll()).object();
        const QString sql = cleanSql(
            resp["message"].toObject()["content"].toString());
        m_loading = false;
        emit loadingChanged();
        if (m_log) m_log->post("info", "AI", "",
                               "Generated SQL · " + (m_model.isEmpty() ? QStringLiteral("llama3.2") : m_model),
                               {{"prompt", m_pendingPrompt}, {"provider", m_provider}, {"model", m_model}, {"sql", sql}});
        emit resultReady(sql);
    });
}

// ── Helpers ───────────────────────────────────────────────────────────────────

void AiClient::finishWithError(const QString &message)
{
    m_loading = false;
    emit loadingChanged();
    if (m_log) m_log->post("error", "AI", "",
                           "AI error: " + message,
                           {{"message", message}, {"provider", m_provider}, {"model", m_model}});
    emit errorOccurred(message);
}

QString AiClient::cleanSql(const QString &raw)
{
    QString s = raw.trimmed();
    static const QRegularExpression fence(
        QStringLiteral("^```(?:sql)?\\s*\\n?([\\s\\S]*?)\\n?```$"),
        QRegularExpression::CaseInsensitiveOption);
    const auto m = fence.match(s);
    if (m.hasMatch())
        s = m.captured(1).trimmed();
    return s;
}

QString AiClient::buildSystemPrompt(const QString &schema) const
{
    QString prompt =
        QStringLiteral("You are an expert SQL assistant. Generate a SQL query based on the user's natural language request.\n\n"
                        "IMPORTANT: Return ONLY the raw SQL query. No markdown, no code blocks, no explanations, "
                        "no comments — just the SQL statement itself.\n");
    if (!m_dialect.isEmpty())
        prompt += QStringLiteral("\nTarget database: ") + m_dialect
                + QStringLiteral(". Write the query in this database's SQL dialect and "
                                 "avoid constructs it does not support.\n");
    if (!schema.isEmpty())
        prompt += QStringLiteral("\nDatabase schema:\n") + schema;
    return prompt;
}
