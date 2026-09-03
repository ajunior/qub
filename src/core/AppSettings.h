#pragma once

#include <QObject>
#include "QmlSingleton.h"
#include <QSettings>
#include <QStringList>
#include <QUrl>

class AppSettings : public QObject {
    Q_OBJECT
    QUB_QML_SINGLETON(AppSettings)

public:
    // "light" | "dark" | "system". Not a bool, because following the OS is a
    // third choice and not a second one: "system" already means dark half the
    // time on a machine that switches at sunset.
    Q_PROPERTY(QString themeMode        READ themeMode          WRITE setThemeMode          NOTIFY themeModeChanged)
    Q_PROPERTY(int     fontSize           READ fontSize           WRITE setFontSize           NOTIFY fontSizeChanged)
    Q_PROPERTY(QString fontFamily         READ fontFamily         WRITE setFontFamily         NOTIFY fontFamilyChanged)
    Q_PROPERTY(int     fontWeight         READ fontWeight         WRITE setFontWeight         NOTIFY fontWeightChanged)
    Q_PROPERTY(int     historyLimit       READ historyLimit       WRITE setHistoryLimit       NOTIFY historyLimitChanged)
    Q_PROPERTY(bool   autoCloseOnLeave         READ autoCloseOnLeave         WRITE setAutoCloseOnLeave         NOTIFY autoCloseOnLeaveChanged)
    Q_PROPERTY(bool   preserveCursorPosition   READ preserveCursorPosition   WRITE setPreserveCursorPosition   NOTIFY preserveCursorPositionChanged)
    Q_PROPERTY(bool   schemaInsertOnDoubleClick READ schemaInsertOnDoubleClick WRITE setSchemaInsertOnDoubleClick NOTIFY schemaInsertOnDoubleClickChanged)
    Q_PROPERTY(bool   autoComplete              READ autoComplete              WRITE setAutoComplete              NOTIFY autoCompleteChanged)
    // "upper" or "lower" — how keywords are cased in the SQL qub writes for
    // you (the browse button, a double-clicked table, a foreign-key jump).
    // It never touches SQL you typed, and never an identifier: lowercasing
    // "Users" would change which table it names on a case-sensitive database.
    Q_PROPERTY(QString sqlKeywordCase         READ sqlKeywordCase           WRITE setSqlKeywordCase           NOTIFY sqlKeywordCaseChanged)
    Q_PROPERTY(bool   schemaQuickBrowse         READ schemaQuickBrowse         WRITE setSchemaQuickBrowse         NOTIFY schemaQuickBrowseChanged)
    Q_PROPERTY(bool   autoReconnect             READ autoReconnect             WRITE setAutoReconnect             NOTIFY autoReconnectChanged)
    Q_PROPERTY(bool   liveShareWarnOnStart      READ liveShareWarnOnStart      WRITE setLiveShareWarnOnStart      NOTIFY liveShareWarnOnStartChanged)
    Q_PROPERTY(bool   liveShareWarnOnStop       READ liveShareWarnOnStop       WRITE setLiveShareWarnOnStop       NOTIFY liveShareWarnOnStopChanged)
    Q_PROPERTY(bool    liveShareUseTls      READ liveShareUseTls      WRITE setLiveShareUseTls      NOTIFY liveShareUseTlsChanged)
    Q_PROPERTY(QString liveShareCertPath   READ liveShareCertPath   WRITE setLiveShareCertPath   NOTIFY liveShareCertPathChanged)
    Q_PROPERTY(QString liveShareKeyPath    READ liveShareKeyPath    WRITE setLiveShareKeyPath    NOTIFY liveShareKeyPathChanged)
    Q_PROPERTY(bool    liveShareAllowDownload READ liveShareAllowDownload WRITE setLiveShareAllowDownload NOTIFY liveShareAllowDownloadChanged)
    Q_PROPERTY(bool    liveShareLanVisible  READ liveShareLanVisible  WRITE setLiveShareLanVisible  NOTIFY liveShareLanVisibleChanged)
    // Minutes before a running share shuts itself off; 0 leaves it up until
    // someone stops it. The failure mode of Live Share is not starting it by
    // mistake — it is forgetting it is on.
    Q_PROPERTY(int     liveShareAutoStopMinutes READ liveShareAutoStopMinutes WRITE setLiveShareAutoStopMinutes NOTIFY liveShareAutoStopMinutesChanged)
    Q_PROPERTY(bool    liveShareButtonPing  READ liveShareButtonPing  WRITE setLiveShareButtonPing  NOTIFY liveShareButtonPingChanged)

    // Ordering of the four saved-item lists on the Home screen. Each keeps its
    // own key and direction: they are read side by side but wanted in different
    // orders — a workspace by when it was last opened, a connection by name.
    Q_PROPERTY(QString connectionsSortKey READ connectionsSortKey WRITE setConnectionsSortKey NOTIFY connectionsSortChanged)
    Q_PROPERTY(bool    connectionsSortAsc READ connectionsSortAsc WRITE setConnectionsSortAsc NOTIFY connectionsSortChanged)
    Q_PROPERTY(QString sshSortKey         READ sshSortKey         WRITE setSshSortKey         NOTIFY sshSortChanged)
    Q_PROPERTY(bool    sshSortAsc         READ sshSortAsc         WRITE setSshSortAsc         NOTIFY sshSortChanged)
    Q_PROPERTY(QString workspacesSortKey  READ workspacesSortKey  WRITE setWorkspacesSortKey  NOTIFY workspacesSortChanged)
    Q_PROPERTY(bool    workspacesSortAsc  READ workspacesSortAsc  WRITE setWorkspacesSortAsc  NOTIFY workspacesSortChanged)
    Q_PROPERTY(QString snippetsSortKey    READ snippetsSortKey    WRITE setSnippetsSortKey    NOTIFY snippetsSortChanged)
    Q_PROPERTY(bool    snippetsSortAsc    READ snippetsSortAsc    WRITE setSnippetsSortAsc    NOTIFY snippetsSortChanged)
    Q_PROPERTY(int    queryLimit               READ queryLimit               WRITE setQueryLimit               NOTIFY queryLimitChanged)
    Q_PROPERTY(bool   highlightCurrentLine     READ highlightCurrentLine     WRITE setHighlightCurrentLine     NOTIFY highlightCurrentLineChanged)
    Q_PROPERTY(double lineHeight               READ lineHeight               WRITE setLineHeight               NOTIFY lineHeightChanged)
    Q_PROPERTY(int    tabSize                  READ tabSize                  WRITE setTabSize                  NOTIFY tabSizeChanged)
    Q_PROPERTY(bool   insertSpacesForTab       READ insertSpacesForTab       WRITE setInsertSpacesForTab       NOTIFY insertSpacesForTabChanged)
    // Keys of the optional result panes the user has switched off. Results and
    // Output are not in the vocabulary: a result pane with no way back to the
    // result is not a state worth being able to reach.
    Q_PROPERTY(QStringList hiddenResultTabs    READ hiddenResultTabs         WRITE setHiddenResultTabs         NOTIFY hiddenResultTabsChanged)
    Q_PROPERTY(QString aiProvider  READ aiProvider  WRITE setAiProvider  NOTIFY aiProviderChanged)
    Q_PROPERTY(QString aiModel     READ aiModel     WRITE setAiModel     NOTIFY aiModelChanged)
    Q_PROPERTY(QString aiOllamaUrl READ aiOllamaUrl WRITE setAiOllamaUrl NOTIFY aiOllamaUrlChanged)

public:
    explicit AppSettings(QObject *parent = nullptr);

    QString themeMode()          const;
    int     fontSize()           const;
    QString fontFamily()         const;
    int     fontWeight()         const;
    int     historyLimit()       const;
    bool autoCloseOnLeave()  const;
    bool preserveCursorPosition() const;
    bool schemaInsertOnDoubleClick() const;
    bool autoComplete() const;
    QString sqlKeywordCase() const;
    bool schemaQuickBrowse() const;
    bool autoReconnect() const;
    bool    liveShareWarnOnStart() const;
    bool    liveShareWarnOnStop()  const;
    bool    liveShareUseTls()         const;
    QString liveShareCertPath()       const;
    QString liveShareKeyPath()        const;
    bool    liveShareAllowDownload()  const;
    bool    liveShareLanVisible()     const;
    int     liveShareAutoStopMinutes() const;
    bool    liveShareButtonPing()     const;
    int  queryLimit()           const;
    bool   highlightCurrentLine() const;
    double lineHeight() const;
    int    tabSize()    const;
    bool   insertSpacesForTab() const;
    QStringList hiddenResultTabs() const;
    QString aiProvider()  const;
    QString aiModel()     const;
    QString aiOllamaUrl() const;

    // SECURITY INVARIANT: these give QML arbitrary file read/write with the
    // app's privileges. That is acceptable only while every line of QML ships
    // compiled into the binary. Never expose them to dynamically loaded QML
    // (plugins, remote themes, user scripts) — gate or remove them first.
    Q_INVOKABLE QString readFile(const QUrl &url) const;
    Q_INVOKABLE bool    writeFile(const QUrl &url, const QString &content) const;

    void setThemeMode(const QString &value);
    void setFontSize(int value);
    void setFontFamily(const QString &value);
    void setFontWeight(int value);
    void setHistoryLimit(int value);
    void setAutoCloseOnLeave(bool value);
    void setPreserveCursorPosition(bool value);
    void setSchemaInsertOnDoubleClick(bool value);
    void setAutoComplete(bool value);
    void setSqlKeywordCase(const QString &value);
    void setSchemaQuickBrowse(bool value);
    void setAutoReconnect(bool value);
    void setLiveShareWarnOnStart(bool value);
    void setLiveShareWarnOnStop(bool value);
    void setLiveShareUseTls(bool value);
    void setLiveShareCertPath(const QString &value);
    void setLiveShareKeyPath(const QString &value);
    void setLiveShareAllowDownload(bool value);
    void setLiveShareLanVisible(bool value);
    void setLiveShareAutoStopMinutes(int value);
    void setLiveShareButtonPing(bool value);
    void setQueryLimit(int value);
    void setHighlightCurrentLine(bool value);
    void setLineHeight(double value);
    void setTabSize(int value);
    void setInsertSpacesForTab(bool value);
    void setHiddenResultTabs(const QStringList &value);
    void setAiProvider(const QString &value);
    void setAiModel(const QString &value);
    void setAiOllamaUrl(const QString &value);

    QString connectionsSortKey() const;
    bool    connectionsSortAsc() const;
    QString sshSortKey()         const;
    bool    sshSortAsc()         const;
    QString workspacesSortKey()  const;
    bool    workspacesSortAsc()  const;
    QString snippetsSortKey()    const;
    bool    snippetsSortAsc()    const;

    void setConnectionsSortKey(const QString &value);
    void setConnectionsSortAsc(bool value);
    void setSshSortKey(const QString &value);
    void setSshSortAsc(bool value);
    void setWorkspacesSortKey(const QString &value);
    void setWorkspacesSortAsc(bool value);
    void setSnippetsSortKey(const QString &value);
    void setSnippetsSortAsc(bool value);

signals:
    void themeModeChanged();
    void fontSizeChanged();
    void fontFamilyChanged();
    void fontWeightChanged();
    void historyLimitChanged();
    void autoCloseOnLeaveChanged();
    void preserveCursorPositionChanged();
    void schemaInsertOnDoubleClickChanged();
    void autoCompleteChanged();
    void sqlKeywordCaseChanged();
    void schemaQuickBrowseChanged();
    void autoReconnectChanged();
    void liveShareWarnOnStartChanged();
    void liveShareWarnOnStopChanged();
    void connectionsSortChanged();
    void sshSortChanged();
    void workspacesSortChanged();
    void snippetsSortChanged();
    void liveShareUseTlsChanged();
    void liveShareCertPathChanged();
    void liveShareKeyPathChanged();
    void liveShareAllowDownloadChanged();
    void liveShareLanVisibleChanged();
    void liveShareAutoStopMinutesChanged();
    void liveShareButtonPingChanged();
    void queryLimitChanged();
    void highlightCurrentLineChanged();
    void lineHeightChanged();
    void tabSizeChanged();
    void insertSpacesForTabChanged();
    void hiddenResultTabsChanged();
    void aiProviderChanged();
    void aiModelChanged();
    void aiOllamaUrlChanged();

private:
    QSettings m_settings;
};

QUB_QML_SINGLETON_FOREIGN(AppSettings)
