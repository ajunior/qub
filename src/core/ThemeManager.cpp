#include "ThemeManager.h"
#include <QSettings>
#include <QJsonDocument>
#include <QJsonArray>
#include <QJsonObject>
#include <QFile>
#include <QUuid>
#include <algorithm>

static QVariantMap makeLight(const QString &bg, const QString &panel, const QString &surface,
                              const QString &surfaceVar, const QString &overlay,
                              const QString &border, const QString &borderStrong,
                              const QString &tp, const QString &ts, const QString &td,
                              const QString &shadow)
{
    return {
        {"background",    bg},          {"panel",        panel},
        {"surface",       surface},     {"surfaceVariant", surfaceVar},
        {"overlay",       overlay},     {"border",        border},
        {"borderStrong",  borderStrong},{"textPrimary",   tp},
        {"textSecondary", ts},          {"textDisabled",  td},
        {"shadowColor",   shadow}
    };
}

static QVariantMap makeDark(const QString &bg, const QString &panel, const QString &surface,
                             const QString &surfaceVar, const QString &overlay,
                             const QString &border, const QString &borderStrong,
                             const QString &tp, const QString &ts, const QString &td,
                             const QString &shadow)
{
    return makeLight(bg, panel, surface, surfaceVar, overlay, border, borderStrong, tp, ts, td, shadow);
}

// qub used to ship its overlay and shadow colours CSS-style (#RRGGBBAA). Qt
// reads 8-digit hex as #AARRGGBB, so the alpha landed in the blue channel and
// the leading byte became the alpha: the dark-mode scrim behind dialogs was
// fully transparent. Themes saved or exported back then still carry those
// values; flip exactly those. Anything picked in the theme editor came from
// Qt and is already in Qt's order, so it is left alone.
static bool fixLegacyArgb(QVariantMap &theme)
{
    static const QStringList legacy = {
        "#00000040", "#00000066", "#0000003D",
        "#1E203014", "#1A081014", "#07364214", "#28293614",
    };
    bool changed = false;
    for (const char *mode : {"light", "dark"}) {
        QVariantMap m = theme.value(mode).toMap();
        for (const char *key : {"overlay", "shadowColor"}) {
            const QString c = m.value(key).toString();
            if (legacy.contains(c, Qt::CaseInsensitive)) {
                m[key] = QString(u'#' + c.mid(7, 2) + c.mid(1, 6)).toUpper();
                changed = true;
            }
        }
        if (changed) theme[mode] = m;
    }
    return changed;
}

static QVariantMap variantFromJson(const QJsonObject &obj);

static QVariantMap variantFromJson(const QJsonObject &obj)
{
    QVariantMap map;
    for (auto it = obj.constBegin(); it != obj.constEnd(); ++it) {
        if (it.value().isObject())
            map[it.key()] = variantFromJson(it.value().toObject());
        else
            map[it.key()] = it.value().toVariant();
    }
    return map;
}

static QJsonObject jsonFromVariant(const QVariantMap &map)
{
    QJsonObject obj;
    for (auto it = map.cbegin(); it != map.cend(); ++it) {
        if (it.value().typeId() == QMetaType::QVariantMap)
            obj[it.key()] = jsonFromVariant(it.value().toMap());
        else
            obj[it.key()] = QJsonValue::fromVariant(it.value());
    }
    return obj;
}

ThemeManager::ThemeManager(QObject *parent)
    : QObject(parent)
{
    initBuiltins();
    load();
    if (m_activeId.isEmpty())
        m_activeId = "builtin-default";
    if (m_custom.isEmpty())
        seedPresets();
}

void ThemeManager::initBuiltins()
{
    // ── Default (Mahina defaults) — the only fixed, non-editable theme ────────
    m_builtins << QVariantMap{
        {"id", "builtin-default"}, {"name", "Default"}, {"builtin", true},
        {"primary", "#5B8DF6"}, {"primaryHover", "#4878E8"},
        {"primaryActive", "#3A66D0"}, {"primarySubtle", "#EEF3FD"},
        {"textOnPrimary", "#FFFFFF"},
        {"success", "#59A14F"}, {"successSubtle", "#EEF8ED"},
        {"warning", "#F28E2B"}, {"warningSubtle", "#FEF4E7"},
        {"error",   "#E15759"}, {"errorSubtle",   "#FEF0F0"},
        {"info",    "#2196E8"}, {"infoSubtle",    "#EFF7FE"},
        {"light", makeLight("#EDEEF6","#F4F4FA","#FFFFFF","#F8F8FD","#40000000",
                            "#E2E5F0","#C8CEDF","#1E2030","#697180","#9AA3AF","#141E2030")},
        {"dark",  makeDark ("#151922","#171D27","#1E2430","#222A36","#66000000",
                            "#313B4C","#475569","#F4F7FB","#AAB4C4","#7F8A9A","#3D000000")}
    };
}

void ThemeManager::seedPresets()
{
    // Pre-installed custom themes — shipped with the app but fully editable by the user.
    // Only seeded once, when no custom themes exist (first run or after a reset).

    // ── WoMakersCode ─────────────────────────────────────────────────────────
    m_custom << QVariantMap{
        {"id", "preset-womakerscode"}, {"name", "WoMakersCode"}, {"builtin", false},
        {"primary", "#CB1169"}, {"primaryHover", "#A80D56"},
        {"primaryActive", "#860A44"}, {"primarySubtle", "#FCEAF4"},
        {"textOnPrimary", "#FFFFFF"},
        {"success", "#8DC21A"}, {"successSubtle", "#EEF7D5"},
        {"warning", "#E07820"}, {"warningSubtle", "#FEF0E3"},
        {"error",   "#C01818"}, {"errorSubtle",   "#FAE8E8"},
        {"info",    "#7B52D8"}, {"infoSubtle",    "#EEE8FA"},
        {"light", makeLight("#FFF7FB","#FFFFFF","#FFFFFF","#FEF0F8","#40000000",
                            "#F8D8EC","#EDAAD0","#1A0810","#6B3550","#C4A0B5","#141A0810")},
        {"dark",  makeDark ("#140A10","#1C101A","#251624","#2E1C2C","#66000000",
                            "#4A2844","#6A3860","#FFF0F8","#E8AACB","#9B6B85","#3D000000")}
    };

    // ── Solarized ─────────────────────────────────────────────────────────────
    m_custom << QVariantMap{
        {"id", "preset-solarized"}, {"name", "Solarized"}, {"builtin", false},
        {"primary", "#268BD2"}, {"primaryHover", "#1E7CBF"},
        {"primaryActive", "#1668A6"}, {"primarySubtle", "#DDF0FA"},
        {"textOnPrimary", "#FDF6E3"},
        {"success", "#859900"}, {"successSubtle", "#ECF0D5"},
        {"warning", "#B58900"}, {"warningSubtle", "#F5EDD5"},
        {"error",   "#DC322F"}, {"errorSubtle",   "#F5E0DF"},
        {"info",    "#2AA198"}, {"infoSubtle",    "#DDF0EE"},
        {"light", makeLight("#EEE8D5","#FDF6E3","#FDF6E3","#EEE8D5","#40000000",
                            "#D3CCB8","#B8B0A0","#073642","#586E75","#93A1A1","#14073642")},
        {"dark",  makeDark ("#002B36","#073642","#073642","#0A3D4A","#66000000",
                            "#1E4D5C","#2E6375","#FDF6E3","#839496","#657B83","#3D000000")}
    };

    // ── Dracula ───────────────────────────────────────────────────────────────
    m_custom << QVariantMap{
        {"id", "preset-dracula"}, {"name", "Dracula"}, {"builtin", false},
        {"primary", "#BD93F9"}, {"primaryHover", "#A475F7"},
        {"primaryActive", "#8A5AF5"}, {"primarySubtle", "#383A59"},
        {"textOnPrimary", "#F8F8F2"},
        {"success", "#50FA7B"}, {"successSubtle", "#1E3D2A"},
        {"warning", "#FFB86C"}, {"warningSubtle", "#3D2E1A"},
        {"error",   "#FF5555"}, {"errorSubtle",   "#3D1A1A"},
        {"info",    "#8BE9FD"}, {"infoSubtle",    "#1A2F3D"},
        {"light", makeLight("#F0EFF5","#E8E7F0","#FFFFFF","#F4F3FA","#40000000",
                            "#D8D7E8","#C0BED8","#282A36","#6272A4","#9BA7C8","#14282936")},
        {"dark",  makeDark ("#282A36","#21222C","#313244","#44475A","#66000000",
                            "#44475A","#6272A4","#F8F8F2","#BFBFBF","#6272A4","#3D000000")}
    };

    save();
}

QVariantList ThemeManager::themes() const
{
    QVariantList list;
    for (const auto &t : m_builtins) list << t;
    for (const auto &t : m_custom)   list << t;
    return list;
}

QString ThemeManager::activeThemeId() const
{
    return m_activeId;
}

QVariantMap ThemeManager::themeById(const QString &id) const
{
    for (const auto &t : m_builtins)
        if (t.value("id").toString() == id) return t;
    for (const auto &t : m_custom)
        if (t.value("id").toString() == id) return t;
    return {};
}

QVariantMap ThemeManager::activeThemeColors() const
{
    return themeById(m_activeId);
}

void ThemeManager::setActiveTheme(const QString &id)
{
    if (m_activeId == id) return;
    m_activeId = id;
    QSettings settings("qub", "qub");
    settings.setValue("activeThemeId", id);
    emit activeThemeChanged();
}

void ThemeManager::addTheme(const QVariantMap &data)
{
    QVariantMap t = data;
    t["id"]      = QUuid::createUuid().toString(QUuid::WithoutBraces);
    t["builtin"] = false;
    m_custom << t;
    save();
    emit themesChanged();
}

void ThemeManager::updateTheme(const QString &id, const QVariantMap &data)
{
    for (auto &t : m_custom) {
        if (t.value("id").toString() == id) {
            QVariantMap updated = data;
            updated["id"]      = id;
            updated["builtin"] = false;
            t = updated;
            save();
            emit themesChanged();
            if (m_activeId == id) emit activeThemeChanged();
            return;
        }
    }
}

void ThemeManager::removeTheme(const QString &id)
{
    m_custom.removeIf([&id](const QVariantMap &t) {
        return t.value("id").toString() == id;
    });
    if (m_activeId == id) {
        m_activeId = "builtin-default";
        QSettings settings("qub", "qub");
        settings.setValue("activeThemeId", m_activeId);
        emit activeThemeChanged();
    }
    save();
    emit themesChanged();
}

bool ThemeManager::exportTheme(const QString &id, const QUrl &fileUrl)
{
    const QVariantMap t = themeById(id);
    if (t.isEmpty()) return false;
    QFile f(fileUrl.toLocalFile());
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate)) return false;
    QJsonObject obj = jsonFromVariant(t);
    obj["version"] = 1;
    f.write(QJsonDocument(obj).toJson(QJsonDocument::Indented));
    return true;
}

QVariantMap ThemeManager::importTheme(const QUrl &fileUrl)
{
    QFile f(fileUrl.toLocalFile());
    if (!f.open(QIODevice::ReadOnly))
        return {{"success", false}, {"message", "Cannot open file."}};

    QJsonParseError err;
    const auto doc = QJsonDocument::fromJson(f.readAll(), &err);
    if (err.error != QJsonParseError::NoError)
        return {{"success", false}, {"message", "Invalid JSON: " + err.errorString()}};

    if (!doc.isObject())
        return {{"success", false}, {"message", "Expected a JSON object."}};

    QVariantMap t = variantFromJson(doc.object());
    const QString name = t.value("name").toString().trimmed();
    if (name.isEmpty())
        return {{"success", false}, {"message", "Theme must have a name."}};

    const auto sameName = [&name](const QVariantMap &existing) {
        return existing.value("name").toString().compare(name, Qt::CaseInsensitive) == 0;
    };
    if (std::any_of(m_builtins.cbegin(), m_builtins.cend(), sameName) ||
        std::any_of(m_custom.cbegin(),   m_custom.cend(),   sameName))
        return {{"success", false},
                {"message", "Theme \"" + name + "\" already exists. Nothing imported."}};

    fixLegacyArgb(t);
    t["builtin"] = false;
    t.remove("id");
    t.remove("version");
    addTheme(t);
    return {{"success", true}, {"message", "Theme \"" + name + "\" imported."}};
}

void ThemeManager::save()
{
    QJsonArray arr;
    for (const auto &t : m_custom)
        arr.append(jsonFromVariant(t));
    QSettings settings("qub", "qub");
    settings.setValue("themes", QString::fromUtf8(QJsonDocument(arr).toJson(QJsonDocument::Compact)));
}

void ThemeManager::load()
{
    QSettings settings("qub", "qub");
    m_activeId = settings.value("activeThemeId").toString();

    const QString raw = settings.value("themes").toString();
    if (raw.isEmpty()) return;

    QJsonParseError err;
    const auto doc = QJsonDocument::fromJson(raw.toUtf8(), &err);
    if (err.error != QJsonParseError::NoError) return;

    bool migrated = false;
    for (const auto &v : doc.array()) {
        if (!v.isObject()) continue;
        QVariantMap t = variantFromJson(v.toObject());
        migrated |= fixLegacyArgb(t);
        m_custom << t;
    }
    if (migrated) save();
}
