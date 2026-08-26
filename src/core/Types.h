#pragma once

#include <QDateTime>
#include <QList>
#include <QString>
#include <QStringList>
#include <QVariantList>

struct ConnectionParams {
    QString name;
    QString driver;
    QString host;
    int     port      = 0;
    QString database;
    QString username;
    QString password;  // populated from CredentialStore at connect time, never persisted
    QString profileId;   // links to a ConnectionProfile in ProfileManager
    QString sshConfigId; // links to an SSH config in SshManager ("" = no tunnel)
    bool      ssl          = false;
    QString   sslCaCert;
    QString   sslClientCert;
    QString   sslClientKey;
    int       timeout      = 30;
    QString   schema;
    QDateTime lastModified;
};

struct QueryResult {
    bool              success      = false;
    QString           error;
    QStringList       columns;
    QList<QVariantList> rows;
    int               rowsAffected = 0;
    qint64            elapsedMs    = 0;
    bool              truncated    = false;  // true when row limit was hit
};

struct HistoryEntry {
    qint64    id = 0;
    QString   connectionName;
    QString   sql;
    QDateTime executedAt;
    bool      success   = false;
    int       rowCount  = 0;
    qint64    elapsedMs = 0;
};

struct SavedQuery {
    qint64    id = 0;
    QString   name;
    QString   folder;
    QString   sql;
    QString   connectionName;
    QDateTime createdAt;
    QDateTime updatedAt;
};

struct SessionTab {
    QString connectionName;
    QString sql;
    int     cursorPosition = 0;
    QString title;
};

struct Session {
    qint64            id           = 0;
    QDateTime         savedAt;
    QList<SessionTab> tabs;
    int               activeTabIndex = 0;
};
