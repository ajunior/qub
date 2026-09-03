#include "AppSettings.h"
#include <QFile>
#include <QFont>

AppSettings::AppSettings(QObject *parent)
    : QObject(parent)
    , m_settings("qub", "qub")
{}

QString AppSettings::themeMode() const    { return m_settings.value("themeMode", "system").toString(); }
int     AppSettings::fontSize() const     { return m_settings.value("fontSize", 13).toInt(); }
QString AppSettings::fontFamily() const   { return m_settings.value("fontFamily", "JetBrains Mono").toString(); }
// Qt 6 moved font weights onto the CSS scale, where Font.Normal is 400 and the
// old QFont::Weight value of 50 lands below Font.Thin: the editor shipped in the
// thinnest face the family has. The picker in Settings writes Font.* constants
// and so was always on the new scale, which is why touching it once fixed the
// editor and never touching it did not. Anything under Font.Thin cannot have
// come from the picker, so it is read as unset rather than clamped to hairline.
int     AppSettings::fontWeight() const {
    const int w = m_settings.value("fontWeight", QFont::Normal).toInt();
    return w < QFont::Thin ? QFont::Normal : w;
}
int     AppSettings::historyLimit() const { return m_settings.value("historyLimit", 500).toInt(); }
bool AppSettings::autoCloseOnLeave()  const { return m_settings.value("autoCloseOnLeave", false).toBool(); }

void AppSettings::setThemeMode(const QString &value) {
    if (themeMode() == value) return;
    m_settings.setValue("themeMode", value);
    emit themeModeChanged();
}

void AppSettings::setFontSize(int value) {
    if (fontSize() == value) return;
    m_settings.setValue("fontSize", value);
    emit fontSizeChanged();
}

void AppSettings::setFontFamily(const QString &value) {
    if (fontFamily() == value) return;
    m_settings.setValue("fontFamily", value);
    emit fontFamilyChanged();
}

void AppSettings::setFontWeight(int value) {
    if (fontWeight() == value) return;
    m_settings.setValue("fontWeight", value);
    emit fontWeightChanged();
}

void AppSettings::setHistoryLimit(int value) {
    if (historyLimit() == value) return;
    m_settings.setValue("historyLimit", value);
    emit historyLimitChanged();
}

void AppSettings::setAutoCloseOnLeave(bool value) {
    if (autoCloseOnLeave() == value) return;
    m_settings.setValue("autoCloseOnLeave", value);
    emit autoCloseOnLeaveChanged();
}

bool AppSettings::preserveCursorPosition() const { return m_settings.value("preserveCursorPosition", true).toBool(); }
void AppSettings::setPreserveCursorPosition(bool value) {
    if (preserveCursorPosition() == value) return;
    m_settings.setValue("preserveCursorPosition", value);
    emit preserveCursorPositionChanged();
}

bool AppSettings::schemaInsertOnDoubleClick() const { return m_settings.value("schemaInsertOnDoubleClick", true).toBool(); }
void AppSettings::setSchemaInsertOnDoubleClick(bool value) {
    if (schemaInsertOnDoubleClick() == value) return;
    m_settings.setValue("schemaInsertOnDoubleClick", value);
    emit schemaInsertOnDoubleClickChanged();
}

bool AppSettings::autoComplete() const { return m_settings.value("autoComplete", true).toBool(); }
void AppSettings::setAutoComplete(bool value) {
    if (autoComplete() == value) return;
    m_settings.setValue("autoComplete", value);
    emit autoCompleteChanged();
}

bool AppSettings::schemaQuickBrowse() const { return m_settings.value("schemaQuickBrowse", true).toBool(); }
void AppSettings::setSchemaQuickBrowse(bool value) {
    if (schemaQuickBrowse() == value) return;
    m_settings.setValue("schemaQuickBrowse", value);
    emit schemaQuickBrowseChanged();
}

// On by default: a connection dropping under an idle editor is ordinary, and
// the retry only re-runs the statement the user had already sent.
bool AppSettings::autoReconnect() const { return m_settings.value("autoReconnect", true).toBool(); }
void AppSettings::setAutoReconnect(bool value) {
    if (autoReconnect() == value) return;
    m_settings.setValue("autoReconnect", value);
    emit autoReconnectChanged();
}

bool AppSettings::liveShareWarnOnStart() const { return m_settings.value("liveShareWarnOnStart", true).toBool(); }
void AppSettings::setLiveShareWarnOnStart(bool value) {
    if (liveShareWarnOnStart() == value) return;
    m_settings.setValue("liveShareWarnOnStart", value);
    emit liveShareWarnOnStartChanged();
}

bool AppSettings::liveShareWarnOnStop() const { return m_settings.value("liveShareWarnOnStop", true).toBool(); }
void AppSettings::setLiveShareWarnOnStop(bool value) {
    if (liveShareWarnOnStop() == value) return;
    m_settings.setValue("liveShareWarnOnStop", value);
    emit liveShareWarnOnStopChanged();
}

bool    AppSettings::liveShareUseTls()   const { return m_settings.value("liveShareUseTls",   false).toBool(); }
QString AppSettings::liveShareCertPath() const { return m_settings.value("liveShareCertPath", "").toString(); }
QString AppSettings::liveShareKeyPath()  const { return m_settings.value("liveShareKeyPath",  "").toString(); }

void AppSettings::setLiveShareUseTls(bool value) {
    if (liveShareUseTls() == value) return;
    m_settings.setValue("liveShareUseTls", value);
    emit liveShareUseTlsChanged();
}
void AppSettings::setLiveShareCertPath(const QString &value) {
    if (liveShareCertPath() == value) return;
    m_settings.setValue("liveShareCertPath", value);
    emit liveShareCertPathChanged();
}
void AppSettings::setLiveShareKeyPath(const QString &value) {
    if (liveShareKeyPath() == value) return;
    m_settings.setValue("liveShareKeyPath", value);
    emit liveShareKeyPathChanged();
}

bool AppSettings::liveShareLanVisible() const { return m_settings.value("liveShareLanVisible", false).toBool(); }
void AppSettings::setLiveShareLanVisible(bool value) {
    if (liveShareLanVisible() == value) return;
    m_settings.setValue("liveShareLanVisible", value);
    emit liveShareLanVisibleChanged();
}

// 0 means no timer. Anything else is clamped to a minute at the low end: a
// share that stops before the person it is for has finished opening the link
// is a bug report, not a safeguard.
int AppSettings::liveShareAutoStopMinutes() const {
    const int v = m_settings.value("liveShareAutoStopMinutes", 0).toInt();
    return v <= 0 ? 0 : qBound(1, v, 480);
}
void AppSettings::setLiveShareAutoStopMinutes(int value) {
    if (liveShareAutoStopMinutes() == value) return;
    m_settings.setValue("liveShareAutoStopMinutes", value);
    emit liveShareAutoStopMinutesChanged();
}

bool AppSettings::liveShareButtonPing() const { return m_settings.value("liveShareButtonPing", true).toBool(); }
void AppSettings::setLiveShareButtonPing(bool value) {
    if (liveShareButtonPing() == value) return;
    m_settings.setValue("liveShareButtonPing", value);
    emit liveShareButtonPingChanged();
}

bool AppSettings::liveShareAllowDownload() const { return m_settings.value("liveShareAllowDownload", false).toBool(); }
void AppSettings::setLiveShareAllowDownload(bool value) {
    if (liveShareAllowDownload() == value) return;
    m_settings.setValue("liveShareAllowDownload", value);
    emit liveShareAllowDownloadChanged();
}

int AppSettings::queryLimit() const { return m_settings.value("queryLimit", 1000).toInt(); }
void AppSettings::setQueryLimit(int value) {
    if (queryLimit() == value) return;
    m_settings.setValue("queryLimit", value);
    emit queryLimitChanged();
}

// Anything that is not "lower" reads as "upper", so a settings file carrying
// a value from nowhere lands on the SQL everyone writes rather than on a
// third, undefined behaviour.
QString AppSettings::sqlKeywordCase() const {
    return m_settings.value("sqlKeywordCase", "upper").toString() == QLatin1String("lower")
           ? QStringLiteral("lower") : QStringLiteral("upper");
}
void AppSettings::setSqlKeywordCase(const QString &value) {
    if (sqlKeywordCase() == value) return;
    m_settings.setValue("sqlKeywordCase", value);
    emit sqlKeywordCaseChanged();
}

bool AppSettings::highlightCurrentLine() const { return m_settings.value("highlightCurrentLine", true).toBool(); }
void AppSettings::setHighlightCurrentLine(bool value) {
    if (highlightCurrentLine() == value) return;
    m_settings.setValue("highlightCurrentLine", value);
    emit highlightCurrentLineChanged();
}

// 1.3 is the "Normal" preset on the settings page; at 1.0 a long statement
// packs tight enough to read as one block.
double AppSettings::lineHeight() const { return m_settings.value("lineHeight", 1.3).toDouble(); }
void AppSettings::setLineHeight(double value) {
    if (lineHeight() == value) return;
    m_settings.setValue("lineHeight", value);
    emit lineHeightChanged();
}

QStringList AppSettings::hiddenResultTabs() const {
    return m_settings.value("hiddenResultTabs").toStringList();
}
void AppSettings::setHiddenResultTabs(const QStringList &value) {
    if (hiddenResultTabs() == value) return;
    m_settings.setValue("hiddenResultTabs", value);
    emit hiddenResultTabsChanged();
}

int AppSettings::tabSize() const { return m_settings.value("tabSize", 4).toInt(); }
void AppSettings::setTabSize(int value) {
    if (tabSize() == value) return;
    m_settings.setValue("tabSize", value);
    emit tabSizeChanged();
}

bool AppSettings::insertSpacesForTab() const { return m_settings.value("insertSpacesForTab", true).toBool(); }
void AppSettings::setInsertSpacesForTab(bool value) {
    if (insertSpacesForTab() == value) return;
    m_settings.setValue("insertSpacesForTab", value);
    emit insertSpacesForTabChanged();
}

QString AppSettings::aiProvider()  const { return m_settings.value("aiProvider",  "anthropic").toString(); }
QString AppSettings::aiModel()     const { return m_settings.value("aiModel",     "").toString(); }
QString AppSettings::aiOllamaUrl() const { return m_settings.value("aiOllamaUrl", "http://localhost:11434").toString(); }

void AppSettings::setAiProvider(const QString &value) {
    if (aiProvider() == value) return;
    m_settings.setValue("aiProvider", value);
    emit aiProviderChanged();
}
void AppSettings::setAiModel(const QString &value) {
    if (aiModel() == value) return;
    m_settings.setValue("aiModel", value);
    emit aiModelChanged();
}
void AppSettings::setAiOllamaUrl(const QString &value) {
    if (aiOllamaUrl() == value) return;
    m_settings.setValue("aiOllamaUrl", value);
    emit aiOllamaUrlChanged();
}

QString AppSettings::readFile(const QUrl &url) const
{
    QFile f(url.toLocalFile());
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) return {};
    return QString::fromUtf8(f.readAll());
}

bool AppSettings::writeFile(const QUrl &url, const QString &content) const
{
    QFile f(url.toLocalFile());
    if (!f.open(QIODevice::WriteOnly | QIODevice::Text | QIODevice::Truncate)) return false;
    return f.write(content.toUtf8()) >= 0;
}

// ── Saved-list ordering ──────────────────────────────────────────────────────
//
// Four lists, four defaults, on purpose. Connections and SSH configs used to
// come back in whatever order they had been written to disk, so name ascending
// is a fix rather than a preference. Workspaces default to most recently opened
// first, which is the order the list already had and the one that matches why
// the list is read at all: to get back to what you were doing. Snippets keep
// their folder grouping and sort by name inside it.

QString AppSettings::connectionsSortKey() const { return m_settings.value("sort/connectionsKey", "name").toString(); }
bool    AppSettings::connectionsSortAsc() const { return m_settings.value("sort/connectionsAsc", true).toBool(); }
QString AppSettings::sshSortKey()         const { return m_settings.value("sort/sshKey", "name").toString(); }
bool    AppSettings::sshSortAsc()         const { return m_settings.value("sort/sshAsc", true).toBool(); }
QString AppSettings::workspacesSortKey()  const { return m_settings.value("sort/workspacesKey", "lastOpenedAt").toString(); }
bool    AppSettings::workspacesSortAsc()  const { return m_settings.value("sort/workspacesAsc", false).toBool(); }
QString AppSettings::snippetsSortKey()    const { return m_settings.value("sort/snippetsKey", "name").toString(); }
bool    AppSettings::snippetsSortAsc()    const { return m_settings.value("sort/snippetsAsc", true).toBool(); }

void AppSettings::setConnectionsSortKey(const QString &value) {
    if (connectionsSortKey() == value) return;
    m_settings.setValue("sort/connectionsKey", value);
    emit connectionsSortChanged();
}

void AppSettings::setConnectionsSortAsc(bool value) {
    if (connectionsSortAsc() == value) return;
    m_settings.setValue("sort/connectionsAsc", value);
    emit connectionsSortChanged();
}

void AppSettings::setSshSortKey(const QString &value) {
    if (sshSortKey() == value) return;
    m_settings.setValue("sort/sshKey", value);
    emit sshSortChanged();
}

void AppSettings::setSshSortAsc(bool value) {
    if (sshSortAsc() == value) return;
    m_settings.setValue("sort/sshAsc", value);
    emit sshSortChanged();
}

void AppSettings::setWorkspacesSortKey(const QString &value) {
    if (workspacesSortKey() == value) return;
    m_settings.setValue("sort/workspacesKey", value);
    emit workspacesSortChanged();
}

void AppSettings::setWorkspacesSortAsc(bool value) {
    if (workspacesSortAsc() == value) return;
    m_settings.setValue("sort/workspacesAsc", value);
    emit workspacesSortChanged();
}

void AppSettings::setSnippetsSortKey(const QString &value) {
    if (snippetsSortKey() == value) return;
    m_settings.setValue("sort/snippetsKey", value);
    emit snippetsSortChanged();
}

void AppSettings::setSnippetsSortAsc(bool value) {
    if (snippetsSortAsc() == value) return;
    m_settings.setValue("sort/snippetsAsc", value);
    emit snippetsSortChanged();
}
