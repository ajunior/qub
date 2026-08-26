#pragma once

#include <QObject>
#include "QmlSingleton.h"
#include <QSettings>
#include <QUrl>

class AppSettings : public QObject {
    Q_OBJECT
    QUB_QML_SINGLETON(AppSettings)

public:
    Q_PROPERTY(bool    darkTheme          READ darkTheme          WRITE setDarkTheme          NOTIFY darkThemeChanged)
    Q_PROPERTY(int     fontSize           READ fontSize           WRITE setFontSize           NOTIFY fontSizeChanged)
    Q_PROPERTY(QString fontFamily         READ fontFamily         WRITE setFontFamily         NOTIFY fontFamilyChanged)
    Q_PROPERTY(int     fontWeight         READ fontWeight         WRITE setFontWeight         NOTIFY fontWeightChanged)
    Q_PROPERTY(int     historyLimit       READ historyLimit       WRITE setHistoryLimit       NOTIFY historyLimitChanged)
    Q_PROPERTY(bool   autoCloseOnLeave         READ autoCloseOnLeave         WRITE setAutoCloseOnLeave         NOTIFY autoCloseOnLeaveChanged)
    Q_PROPERTY(bool   preserveCursorPosition   READ preserveCursorPosition   WRITE setPreserveCursorPosition   NOTIFY preserveCursorPositionChanged)
    Q_PROPERTY(bool   schemaInsertOnDoubleClick READ schemaInsertOnDoubleClick WRITE setSchemaInsertOnDoubleClick NOTIFY schemaInsertOnDoubleClickChanged)
    Q_PROPERTY(bool   autoComplete              READ autoComplete              WRITE setAutoComplete              NOTIFY autoCompleteChanged)
    Q_PROPERTY(bool   schemaQuickBrowse         READ schemaQuickBrowse         WRITE setSchemaQuickBrowse         NOTIFY schemaQuickBrowseChanged)
    Q_PROPERTY(bool   autoReconnect             READ autoReconnect             WRITE setAutoReconnect             NOTIFY autoReconnectChanged)
    Q_PROPERTY(bool   liveShareWarnOnStart      READ liveShareWarnOnStart      WRITE setLiveShareWarnOnStart      NOTIFY liveShareWarnOnStartChanged)
    Q_PROPERTY(bool   liveShareWarnOnStop       READ liveShareWarnOnStop       WRITE setLiveShareWarnOnStop       NOTIFY liveShareWarnOnStopChanged)
    Q_PROPERTY(bool    liveShareUseTls      READ liveShareUseTls      WRITE setLiveShareUseTls      NOTIFY liveShareUseTlsChanged)
    Q_PROPERTY(QString liveShareCertPath   READ liveShareCertPath   WRITE setLiveShareCertPath   NOTIFY liveShareCertPathChanged)
    Q_PROPERTY(QString liveShareKeyPath    READ liveShareKeyPath    WRITE setLiveShareKeyPath    NOTIFY liveShareKeyPathChanged)
    Q_PROPERTY(bool    liveShareAllowDownload READ liveShareAllowDownload WRITE setLiveShareAllowDownload NOTIFY liveShareAllowDownloadChanged)
    Q_PROPERTY(bool    liveShareLanVisible  READ liveShareLanVisible  WRITE setLiveShareLanVisible  NOTIFY liveShareLanVisibleChanged)
    Q_PROPERTY(int    queryLimit               READ queryLimit               WRITE setQueryLimit               NOTIFY queryLimitChanged)
    Q_PROPERTY(bool   highlightCurrentLine     READ highlightCurrentLine     WRITE setHighlightCurrentLine     NOTIFY highlightCurrentLineChanged)
    Q_PROPERTY(double lineHeight               READ lineHeight               WRITE setLineHeight               NOTIFY lineHeightChanged)
    Q_PROPERTY(int    tabSize                  READ tabSize                  WRITE setTabSize                  NOTIFY tabSizeChanged)
    Q_PROPERTY(bool   insertSpacesForTab       READ insertSpacesForTab       WRITE setInsertSpacesForTab       NOTIFY insertSpacesForTabChanged)
    Q_PROPERTY(QString aiProvider  READ aiProvider  WRITE setAiProvider  NOTIFY aiProviderChanged)
    Q_PROPERTY(QString aiModel     READ aiModel     WRITE setAiModel     NOTIFY aiModelChanged)
    Q_PROPERTY(QString aiOllamaUrl READ aiOllamaUrl WRITE setAiOllamaUrl NOTIFY aiOllamaUrlChanged)

public:
    explicit AppSettings(QObject *parent = nullptr);

    bool    darkTheme()          const;
    int     fontSize()           const;
    QString fontFamily()         const;
    int     fontWeight()         const;
    int     historyLimit()       const;
    bool autoCloseOnLeave()  const;
    bool preserveCursorPosition() const;
    bool schemaInsertOnDoubleClick() const;
    bool autoComplete() const;
    bool schemaQuickBrowse() const;
    bool autoReconnect() const;
    bool    liveShareWarnOnStart() const;
    bool    liveShareWarnOnStop()  const;
    bool    liveShareUseTls()         const;
    QString liveShareCertPath()       const;
    QString liveShareKeyPath()        const;
    bool    liveShareAllowDownload()  const;
    bool    liveShareLanVisible()     const;
    int  queryLimit()           const;
    bool   highlightCurrentLine() const;
    double lineHeight() const;
    int    tabSize()    const;
    bool   insertSpacesForTab() const;
    QString aiProvider()  const;
    QString aiModel()     const;
    QString aiOllamaUrl() const;

    // SECURITY INVARIANT: these give QML arbitrary file read/write with the
    // app's privileges. That is acceptable only while every line of QML ships
    // compiled into the binary. Never expose them to dynamically loaded QML
    // (plugins, remote themes, user scripts) — gate or remove them first.
    Q_INVOKABLE QString readFile(const QUrl &url) const;
    Q_INVOKABLE bool    writeFile(const QUrl &url, const QString &content) const;

    void setDarkTheme(bool value);
    void setFontSize(int value);
    void setFontFamily(const QString &value);
    void setFontWeight(int value);
    void setHistoryLimit(int value);
    void setAutoCloseOnLeave(bool value);
    void setPreserveCursorPosition(bool value);
    void setSchemaInsertOnDoubleClick(bool value);
    void setAutoComplete(bool value);
    void setSchemaQuickBrowse(bool value);
    void setAutoReconnect(bool value);
    void setLiveShareWarnOnStart(bool value);
    void setLiveShareWarnOnStop(bool value);
    void setLiveShareUseTls(bool value);
    void setLiveShareCertPath(const QString &value);
    void setLiveShareKeyPath(const QString &value);
    void setLiveShareAllowDownload(bool value);
    void setLiveShareLanVisible(bool value);
    void setQueryLimit(int value);
    void setHighlightCurrentLine(bool value);
    void setLineHeight(double value);
    void setTabSize(int value);
    void setInsertSpacesForTab(bool value);
    void setAiProvider(const QString &value);
    void setAiModel(const QString &value);
    void setAiOllamaUrl(const QString &value);

signals:
    void darkThemeChanged();
    void fontSizeChanged();
    void fontFamilyChanged();
    void fontWeightChanged();
    void historyLimitChanged();
    void autoCloseOnLeaveChanged();
    void preserveCursorPositionChanged();
    void schemaInsertOnDoubleClickChanged();
    void autoCompleteChanged();
    void schemaQuickBrowseChanged();
    void autoReconnectChanged();
    void liveShareWarnOnStartChanged();
    void liveShareWarnOnStopChanged();
    void liveShareUseTlsChanged();
    void liveShareCertPathChanged();
    void liveShareKeyPathChanged();
    void liveShareAllowDownloadChanged();
    void liveShareLanVisibleChanged();
    void queryLimitChanged();
    void highlightCurrentLineChanged();
    void lineHeightChanged();
    void tabSizeChanged();
    void insertSpacesForTabChanged();
    void aiProviderChanged();
    void aiModelChanged();
    void aiOllamaUrlChanged();

private:
    QSettings m_settings;
};

QUB_QML_SINGLETON_FOREIGN(AppSettings)
