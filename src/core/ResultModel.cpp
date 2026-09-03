#include "ResultModel.h"
#include <QFile>
#include <QTextStream>
#include <QUrl>
#include <QJsonDocument>
#include <QJsonArray>
#include <QJsonObject>
#include <QJsonValue>
#include <QHash>
#include <QSet>
#include <QRegularExpression>
#include <QDateTime>
#include "ResultDiff.h"
#include <algorithm>
#include <array>
#include <numeric>
#include <cmath>

namespace {

// The text of one cell, for every surface a person reads: the grid, the
// filter, the sort key, a copied cell, an exported file.
//
// QVariant::toString() renders a date through Qt::TextDate — "Fri Aug 28
// 21:00:00 2026". That is wide, it leads with the one field nobody sorts by,
// and it does not sort: ordered as text, a date column comes out by weekday
// name, Fri before Mon before Sat. Databases print dates ISO-first and so does
// every other SQL client, so the grid does too — and because filtering and
// sorting read the same function, typing "2026-08" now matches what is on
// screen instead of the string it used to be compared against.
static QString cellText(const QVariant &v)
{
    switch (v.userType()) {
    case QMetaType::QDate:
        return v.toDate().toString(QStringLiteral("yyyy-MM-dd"));
    case QMetaType::QTime:
        return v.toTime().toString(QStringLiteral("HH:mm:ss"));
    case QMetaType::QDateTime: {
        const QDateTime dt = v.toDateTime();
        return dt.toString(dt.time().msec() != 0 ? QStringLiteral("yyyy-MM-dd HH:mm:ss.zzz")
                                                 : QStringLiteral("yyyy-MM-dd HH:mm:ss"));
    }
    default:
        return v.toString();
    }
}

} // namespace

// ── Minimal ZIP + XLSX writer (no external dependency) ──────────────────────
namespace {

static void u16le(QByteArray &o, quint16 v) {
    o.append(char(v & 0xFF)); o.append(char(v >> 8));
}
static void u32le(QByteArray &o, quint32 v) {
    o.append(char(v & 0xFF)); o.append(char((v>>8)&0xFF));
    o.append(char((v>>16)&0xFF)); o.append(char(v>>24));
}

struct ZipEntry { QByteArray name; QByteArray data; quint32 crc32 = 0; quint32 offset = 0; };

// CRC-32 (IEEE 802.3) — the one checksum a STORE-only ZIP needs. It used to come
// from zlib, which meant the whole project carried a native dependency for two
// calls; that only ever linked because Qt drags libz in on Linux and macOS, and
// on Windows the build stopped at a missing zlib.h.
static quint32 crc32Of(const QByteArray &data)
{
    static const std::array<quint32, 256> table = [] {
        std::array<quint32, 256> t{};
        for (quint32 i = 0; i < 256; ++i) {
            quint32 c = i;
            for (int k = 0; k < 8; ++k)
                c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
            t[i] = c;
        }
        return t;
    }();

    quint32 c = 0xFFFFFFFFu;
    for (const char byte : data)
        c = table[(c ^ quint8(byte)) & 0xFF] ^ (c >> 8);
    return c ^ 0xFFFFFFFFu;
}

static QByteArray buildZip(QList<ZipEntry> &es)
{
    QByteArray out;
    for (auto &e : es) {
        e.crc32  = crc32Of(e.data);
        e.offset = out.size();
        out.append("PK\x03\x04", 4);
        u16le(out, 20); u16le(out, 0); u16le(out, 0);   // need / flags / method=STORE
        u16le(out, 0); u16le(out, 0);                    // mod time / date
        u32le(out, e.crc32);
        u32le(out, e.data.size()); u32le(out, e.data.size());
        u16le(out, e.name.size()); u16le(out, 0);
        out.append(e.name); out.append(e.data);
    }
    const quint32 cdOff = out.size();
    for (const auto &e : es) {
        out.append("PK\x01\x02", 4);
        u16le(out, 0x0314); u16le(out, 20); u16le(out, 0); u16le(out, 0);
        u16le(out, 0); u16le(out, 0);
        u32le(out, e.crc32);
        u32le(out, e.data.size()); u32le(out, e.data.size());
        u16le(out, e.name.size()); u16le(out, 0); u16le(out, 0);
        u16le(out, 0); u16le(out, 0); u32le(out, 0); u32le(out, e.offset);
        out.append(e.name);
    }
    const quint32 cdSize = out.size() - cdOff;
    out.append("PK\x05\x06", 4);
    u16le(out, 0); u16le(out, 0);
    u16le(out, es.size()); u16le(out, es.size());
    u32le(out, cdSize); u32le(out, cdOff); u16le(out, 0);
    return out;
}

static QString xmlEsc(const QString &s) {
    QString r; r.reserve(s.size());
    for (const QChar c : s) {
        if      (c == '<')  r += "&lt;";
        else if (c == '>')  r += "&gt;";
        else if (c == '&')  r += "&amp;";
        else if (c == '"')  r += "&quot;";
        else                r += c;
    }
    return r;
}

static QString colName(int col) {   // 0-based → "A", "B", … "AA"
    QString r; ++col;
    while (col > 0) { r.prepend(QChar('A' + (col-1) % 26)); col = (col-1) / 26; }
    return r;
}

// MySQL/MariaDB quote identifiers with backticks; everyone else (PostgreSQL,
// SQLite, the SQL standard) uses double quotes. The quote char is doubled to
// escape it inside the identifier.
static bool usesBacktick(const QString &driver) {
    return driver == QLatin1String("QMYSQL") || driver == QLatin1String("QMARIADB");
}

static QString sqlIdent(const QString &id, const QString &driver) {
    const QChar q = usesBacktick(driver) ? QChar('`') : QChar('"');
    return q + QString(id).replace(q, QString(2, q)) + q;
}

// Render one result value as a SQL literal for the given driver.
static QString sqlLiteral(const QVariant &v, const QString &driver) {
    if (v.isNull() || !v.isValid())
        return QStringLiteral("NULL");

    switch (v.metaType().id()) {
    case QMetaType::Bool:
        // PostgreSQL has a real boolean type; SQLite/MySQL take 1/0.
        if (driver == QLatin1String("QPSQL"))
            return v.toBool() ? QStringLiteral("TRUE") : QStringLiteral("FALSE");
        return v.toBool() ? QStringLiteral("1") : QStringLiteral("0");

    case QMetaType::Int:      case QMetaType::UInt:
    case QMetaType::LongLong: case QMetaType::ULongLong:
    case QMetaType::Short:    case QMetaType::UShort:
        return v.toString();

    case QMetaType::Double:   case QMetaType::Float: {
        // Avoid NaN/Inf sneaking through as bare tokens.
        const double d = v.toDouble();
        if (!std::isfinite(d)) return QStringLiteral("NULL");
        return v.toString();
    }

    case QMetaType::QDate:
        return QChar('\'') + v.toDate().toString(Qt::ISODate) + QChar('\'');
    case QMetaType::QTime:
        return QChar('\'') + v.toTime().toString(Qt::ISODate) + QChar('\'');
    case QMetaType::QDateTime:
        return QChar('\'') + v.toDateTime().toString(Qt::ISODateWithMs) + QChar('\'');

    case QMetaType::QByteArray: {
        const QByteArray hex = v.toByteArray().toHex();
        // PostgreSQL bytea hex form differs from the X'..' form used elsewhere.
        if (driver == QLatin1String("QPSQL"))
            return QStringLiteral("'\\x") + QString::fromLatin1(hex) + QChar('\'');
        return QStringLiteral("X'") + QString::fromLatin1(hex) + QChar('\'');
    }

    default: {
        QString s = v.toString();
        s.replace(QChar('\''), QStringLiteral("''"));
        // MySQL treats backslash as an escape character inside string literals
        // by default, so it must be doubled; standard SQL does not.
        if (usesBacktick(driver))
            s.replace(QChar('\\'), QStringLiteral("\\\\"));
        return QChar('\'') + s + QChar('\'');
    }
    }
}

} // namespace

ResultModel::ResultModel(QObject *parent)
    : QAbstractTableModel(parent)
{}

int ResultModel::rowCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0
         : (m_rowsFiltered ? m_visibleRows.size() : m_rows.size());
}

int ResultModel::columnCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : m_columns.size();
}

QHash<int, QByteArray> ResultModel::roleNames() const
{
    return {
        {Qt::DisplayRole, "display"},
        {IsNullRole,      "isNull"}
    };
}

QVariant ResultModel::data(const QModelIndex &index, int role) const
{
    if (!index.isValid()) return {};
    if (index.row() >= rowCount() || index.column() >= m_columns.size()) return {};

    const QVariant &val = m_rows.at(_row(index.row())).at(index.column());

    if (role == Qt::DisplayRole)
        return (!val.isValid() || val.isNull()) ? QString() : cellText(val);
    if (role == IsNullRole)
        return !val.isValid() || val.isNull();
    return {};
}

QVariant ResultModel::headerData(int section, Qt::Orientation orientation, int role) const
{
    if (role != Qt::DisplayRole) return {};
    if (orientation == Qt::Horizontal && section < m_columns.size())
        return m_columns.at(section);
    if (orientation == Qt::Vertical)
        return section + 1;
    return {};
}

// ── Internal rebuild ──────────────────────────────────────────────────────────
// Recomputes m_visibleRows from the current filter text and sort column/order.
// Must be called inside beginResetModel()/endResetModel().
void ResultModel::_rebuild()
{
    const bool hasFilter = !m_filterText.isEmpty();
    const bool hasSort   = (m_sortColumn >= 0 && m_sortColumn < m_columns.size());

    m_rowsFiltered = hasFilter || hasSort;
    if (!m_rowsFiltered) {
        m_visibleRows.clear();
        return;
    }

    m_visibleRows.resize(m_rows.size());
    std::iota(m_visibleRows.begin(), m_visibleRows.end(), 0);

    if (hasFilter) {
        const QString f = m_filterText.toLower();
        auto end = std::remove_if(m_visibleRows.begin(), m_visibleRows.end(), [&](int i) {
            for (const QVariant &v : m_rows.at(i))
                if (cellText(v).contains(f, Qt::CaseInsensitive))
                    return false;
            return true;
        });
        m_visibleRows.erase(end, m_visibleRows.end());
    }

    if (hasSort) {
        const int col = m_sortColumn;
        const Qt::SortOrder order = m_sortOrder;
        std::stable_sort(m_visibleRows.begin(), m_visibleRows.end(), [&](int a, int b) {
            const QString sa = cellText(m_rows.at(a).at(col));
            const QString sb = cellText(m_rows.at(b).at(col));
            bool okA, okB;
            const double da = sa.toDouble(&okA);
            const double db = sb.toDouble(&okB);
            const bool less = (okA && okB) ? (da < db)
                                           : sa.compare(sb, Qt::CaseInsensitive) < 0;
            return order == Qt::AscendingOrder ? less : !less;
        });
    }
}

// ── Data mutation ─────────────────────────────────────────────────────────────
void ResultModel::setResult(const QueryResult &result)
{
    beginResetModel();
    m_columns     = result.columns;
    m_rows        = result.rows;
    m_truncated   = result.truncated;
    m_filterText.clear();
    m_sortColumn  = -1;
    m_visibleRows.clear();
    m_rowsFiltered = false;
    endResetModel();
    emit truncatedChanged();
    emit columnNamesChanged();
    emit filterTextChanged();
    emit sortColumnChanged();
    emit totalRowCountChanged();
    emit countChanged();
}

void ResultModel::clear()
{
    beginResetModel();
    m_columns.clear();
    m_rows.clear();
    m_truncated  = false;
    m_filterText.clear();
    m_sortColumn = -1;
    m_visibleRows.clear();
    m_rowsFiltered = false;
    endResetModel();
    emit truncatedChanged();
    emit columnNamesChanged();
    emit filterTextChanged();
    emit sortColumnChanged();
    emit totalRowCountChanged();
    emit countChanged();
}

void ResultModel::sort(int column, Qt::SortOrder order)
{
    if (column < 0 || column >= m_columns.size()) return;

    const bool colChanged = (m_sortColumn != column);
    m_sortColumn = column;
    m_sortOrder  = order;

    beginResetModel();
    _rebuild();
    endResetModel();

    if (colChanged) emit sortColumnChanged();
    emit sortOrderChanged();
}

void ResultModel::clearSort()
{
    if (m_sortColumn == -1) return;
    m_sortColumn = -1;

    beginResetModel();
    _rebuild();
    endResetModel();

    emit sortColumnChanged();
}

void ResultModel::setFilterText(const QString &text)
{
    if (m_filterText == text) return;
    m_filterText = text;

    beginResetModel();
    _rebuild();
    endResetModel();

    emit filterTextChanged();
    emit countChanged();
}

void ResultModel::setCellValue(int displayRow, int col, const QVariant &value)
{
    if (displayRow < 0 || displayRow >= rowCount()) return;
    if (col < 0 || col >= m_columns.size()) return;
    m_rows[_row(displayRow)][col] = value;
    const QModelIndex idx = index(displayRow, col);
    emit dataChanged(idx, idx, {Qt::DisplayRole, IsNullRole});
}

// ── Export / accessors ────────────────────────────────────────────────────────
QString ResultModel::cellValue(int row, int column) const
{
    if (row < 0 || row >= rowCount()) return {};
    const QVariantList &r = m_rows.at(_row(row));
    if (column < 0 || column >= r.size()) return {};
    return cellText(r.at(column));
}

QString ResultModel::rowAsTsv(int row) const
{
    if (row < 0 || row >= rowCount()) return {};
    QStringList fields;
    for (const QVariant &v : m_rows.at(_row(row)))
        fields << cellText(v);
    return fields.join('\t');
}

// Spreadsheets execute cells starting with = + - @ (or tab/CR) as formulas,
// so DB-sourced text gets a leading apostrophe. Values that parse as plain
// numbers (e.g. "-42.5") are harmless and left untouched.
QString ResultModel::spreadsheetSafe(const QString &v)
{
    if (v.isEmpty())
        return v;
    const QChar c = v.at(0);
    if (c == '=' || c == '+' || c == '-' || c == '@' || c == '\t' || c == '\r') {
        bool numeric = false;
        v.toDouble(&numeric);
        if (!numeric)
            return QChar('\'') + v;
    }
    return v;
}

bool ResultModel::exportCsv(const QUrl &fileUrl) const
{
    QFile file(fileUrl.toLocalFile());
    if (!file.open(QIODevice::WriteOnly | QIODevice::Text))
        return false;

    QTextStream out(&file);

    auto quote = [](const QString &raw) -> QString {
        const QString v = spreadsheetSafe(raw);
        if (v.contains(',') || v.contains('"') || v.contains('\n'))
            return '"' + QString(v).replace('"', "\"\"") + '"';
        return v;
    };

    QStringList headerFields;
    for (const QString &col : m_columns)
        headerFields << quote(col);
    out << headerFields.join(',') << '\n';

    const int n = rowCount();
    for (int i = 0; i < n; ++i) {
        QStringList fields;
        for (const QVariant &val : m_rows.at(_row(i)))
            fields << quote(cellText(val));
        out << fields.join(',') << '\n';
    }

    return true;
}

QString ResultModel::toMarkdown(int maxRows) const
{
    if (m_columns.isEmpty())
        return {};

    auto cell = [](const QString &raw) {
        // Pipes and newlines break markdown tables.
        return QString(raw).replace('|', QStringLiteral("\\|"))
                           .replace('\n', ' ').replace('\r', ' ');
    };

    QString out = "| " ;
    QStringList header, sep;
    for (const QString &col : m_columns) {
        header << cell(col);
        sep    << QStringLiteral("---");
    }
    out = "| " + header.join(" | ") + " |\n"
        + "| " + sep.join(" | ")    + " |\n";

    const int n     = rowCount();
    const int shown = maxRows > 0 ? qMin(n, maxRows) : n;
    for (int i = 0; i < shown; ++i) {
        QStringList fields;
        for (const QVariant &val : m_rows.at(_row(i)))
            fields << cell(cellText(val));
        out += "| " + fields.join(" | ") + " |\n";
    }
    if (shown < n)
        out += QStringLiteral("\n_… %1 more rows not shown_\n").arg(n - shown);
    return out;
}

QVariantMap ResultModel::columnStats(int column) const
{
    QVariantMap out;
    if (column < 0 || column >= m_columns.size())
        return out;

    const int n = rowCount(); // visible rows only — respects the active filter

    int          count = 0;   // non-null values
    int          nulls = 0;
    bool         allNumeric = (n > 0); // vacuously false for an empty column
    bool         haveNum = false;
    double       sum = 0.0, mn = 0.0, mx = 0.0;
    QSet<QString> distinct;

    for (int i = 0; i < n; ++i) {
        const QVariant &v = m_rows.at(_row(i)).at(column);
        if (!v.isValid() || v.isNull()) {
            ++nulls;
            continue;
        }
        ++count;
        const QString s = cellText(v);
        distinct.insert(s);

        bool ok = false;
        const double d = s.toDouble(&ok);
        if (ok) {
            sum += d;
            if (!haveNum) { mn = mx = d; haveNum = true; }
            else          { mn = qMin(mn, d); mx = qMax(mx, d); }
        } else {
            allNumeric = false;
        }
    }

    out["column"]   = m_columns.at(column);
    out["count"]    = count;
    out["nulls"]    = nulls;
    out["distinct"] = distinct.size();
    // Numeric only when there is at least one value and every one parsed.
    out["numeric"]  = allNumeric && haveNum;

    if (allNumeric && haveNum) {
        out["sum"] = sum;
        out["avg"] = sum / count;
        out["min"] = mn;
        out["max"] = mx;
    }
    return out;
}

QVariantList ResultModel::columnValues(int column) const
{
    QVariantList out;
    if (column < 0 || column >= m_columns.size())
        return out;

    const int n = rowCount();
    out.reserve(n);
    for (int i = 0; i < n; ++i)
        out.append(m_rows.at(_row(i)).at(column));
    return out;
}

QVariantList ResultModel::numericColumns() const
{
    const int cols = m_columns.size();
    const int n    = rowCount(); // visible rows only — respects the active filter

    // A column starts out a candidate and is disqualified by the first value
    // that will not parse; `haveValue` keeps an all-NULL column from passing
    // vacuously, matching columnStats(). Once every column has been decided
    // there is nothing left to learn from the remaining rows.
    QList<bool> candidate(cols, true);
    QList<bool> haveValue(cols, false);
    int undecided = cols;

    for (int i = 0; i < n && undecided > 0; ++i) {
        const QVariantList &row = m_rows.at(_row(i));
        for (int c = 0; c < cols; ++c) {
            if (!candidate.at(c) || c >= row.size())
                continue;
            const QVariant &v = row.at(c);
            if (!v.isValid() || v.isNull())
                continue;

            bool ok = false;
            v.toString().toDouble(&ok);
            if (ok)
                haveValue[c] = true;
            else {
                candidate[c] = false;
                --undecided;
            }
        }
    }

    QVariantList out;
    out.reserve(cols);
    for (int c = 0; c < cols; ++c)
        out.append(candidate.at(c) && haveValue.at(c));
    return out;
}

QVariantList ResultModel::checkExpectations(const QVariantList &rules) const
{
    // Sentinel key for NULL/invalid values in the uniqueness bucket — chosen so
    // it cannot collide with a real cell's string form.
    static const QString kNullKey = QStringLiteral("\x01__qub_null__");

    QVariantList out;
    const int n = rowCount(); // visible rows only — respects the active filter

    for (const QVariant &rv : rules) {
        const QVariantMap rule = rv.toMap();
        const QString colName = rule.value("column").toString();
        const QString check   = rule.value("check").toString();
        const QString arg     = rule.value("arg").toString();

        QVariantMap res;
        res["column"] = colName;
        res["check"]  = check;
        res["arg"]    = arg;

        const int col = m_columns.indexOf(colName);
        if (col < 0) {
            res["error"]      = QStringLiteral("Unknown column");
            res["passed"]     = false;
            res["violations"] = 0;
            res["checked"]    = 0;
            out << res;
            continue;
        }

        int     violations = 0;
        QString sample;
        bool    haveSample = false;
        auto flag = [&](const QString &s) {
            ++violations;
            if (!haveSample) { sample = s; haveSample = true; }
        };
        auto cellStr = [&](int i, bool &isNull) -> QString {
            const QVariant &v = m_rows.at(_row(i)).at(col);
            isNull = !v.isValid() || v.isNull();
            return isNull ? QString() : cellText(v);
        };

        if (check == QLatin1String("unique")) {
            QHash<QString, int> counts;
            QVector<QString>    keys;
            keys.reserve(n);
            for (int i = 0; i < n; ++i) {
                bool isNull = false;
                const QString s = cellStr(i, isNull);
                const QString key = isNull ? kNullKey : s;
                keys << key;
                counts[key]++;
            }
            for (int i = 0; i < n; ++i) {
                if (counts.value(keys.at(i)) > 1)
                    flag(keys.at(i) == kNullKey ? QStringLiteral("(null)") : keys.at(i));
            }
        } else {
            // Parse arguments for the checks that take one.
            double rmin = 0, rmax = 0; bool rangeOk = false;
            int    maxLen = -1;
            QRegularExpression rx;

            if (check == QLatin1String("range")) {
                const QStringList parts = arg.split(',');
                if (parts.size() == 2) {
                    bool a = false, b = false;
                    rmin = parts.at(0).trimmed().toDouble(&a);
                    rmax = parts.at(1).trimmed().toDouble(&b);
                    rangeOk = a && b;
                }
                if (!rangeOk) res["error"] = QStringLiteral("Range needs min,max");
            } else if (check == QLatin1String("max_length")) {
                bool ok = false;
                maxLen = arg.trimmed().toInt(&ok);
                if (!ok || maxLen < 0) { maxLen = -1; res["error"] = QStringLiteral("Length needs a number"); }
            } else if (check == QLatin1String("matches")) {
                rx.setPattern(QRegularExpression::anchoredPattern(arg));
                if (arg.isEmpty() || !rx.isValid()) res["error"] = QStringLiteral("Invalid pattern");
            }

            const bool hasError = res.contains("error");

            for (int i = 0; i < n && !hasError; ++i) {
                bool isNull = false;
                const QString s = cellStr(i, isNull);
                bool bad = false;

                if (check == QLatin1String("not_null")) {
                    bad = isNull;
                } else if (check == QLatin1String("not_empty")) {
                    bad = isNull || s.trimmed().isEmpty();
                } else if (check == QLatin1String("positive") ||
                           check == QLatin1String("non_negative")) {
                    bool ok = false;
                    const double d = s.toDouble(&ok);
                    bad = isNull || !ok ||
                          (check == QLatin1String("positive") ? !(d > 0) : !(d >= 0));
                } else if (check == QLatin1String("range")) {
                    bool ok = false;
                    const double d = s.toDouble(&ok);
                    bad = isNull || !ok || d < rmin || d > rmax;
                } else if (check == QLatin1String("max_length")) {
                    bad = !isNull && s.length() > maxLen; // a missing value isn't "too long"
                } else if (check == QLatin1String("matches")) {
                    bad = isNull || !rx.match(s).hasMatch();
                }

                if (bad) flag(isNull ? QStringLiteral("(null)") : s);
            }
        }

        res["checked"]    = n;
        res["violations"] = violations;
        res["passed"]     = res.contains("error") ? false : (violations == 0);
        if (haveSample) res["sample"] = sample;
        out << res;
    }
    return out;
}

QVariantMap ResultModel::snapshot() const
{
    const int n = rowCount();
    QVariantList rows;
    rows.reserve(n);
    for (int i = 0; i < n; ++i)
        rows << QVariant(m_rows.at(_row(i)));

    QVariantMap m;
    m["columns"]  = m_columns;
    m["rows"]     = rows;
    m["rowCount"] = n;
    return m;
}

QVariantMap ResultModel::diffAgainst(const QVariantMap &baseline, int keyColumn) const
{
    const QStringList baseCols = baseline.value("columns").toStringList();
    QList<QVariantList> baseRows;
    const QVariantList rawBase = baseline.value("rows").toList();
    baseRows.reserve(rawBase.size());
    for (const QVariant &r : rawBase)
        baseRows << r.toList();

    const int n = rowCount();
    QList<QVariantList> curRows;
    curRows.reserve(n);
    for (int i = 0; i < n; ++i)
        curRows << m_rows.at(_row(i));

    return ResultDiff::compare(baseCols, baseRows, m_columns, curRows, keyColumn);
}

QVariantList ResultModel::profile() const
{
    const int cols = m_columns.size();
    const int n    = rowCount();

    struct ColAcc {
        int                  count      = 0;    // non-null
        int                  nulls      = 0;
        bool                 allNumeric = true;
        double               sum        = 0.0;
        QVector<double>      nums;              // parsed numeric values
        QHash<QString, int>  freq;             // value → occurrences
    };
    QVector<ColAcc> acc(cols);

    for (int i = 0; i < n; ++i) {
        const QVariantList &row = m_rows.at(_row(i));
        for (int c = 0; c < cols; ++c) {
            const QVariant &v = row.at(c);
            ColAcc &a = acc[c];
            if (!v.isValid() || v.isNull()) {
                ++a.nulls;
                continue;
            }
            ++a.count;
            const QString s = cellText(v);
            a.freq[s] += 1;

            bool ok = false;
            const double d = s.toDouble(&ok);
            if (ok) { a.nums.append(d); a.sum += d; }
            else    { a.allNumeric = false; }
        }
    }

    QVariantList out;
    out.reserve(cols);
    for (int c = 0; c < cols; ++c) {
        ColAcc &a = acc[c];
        QVariantMap m;
        m["column"]   = m_columns.at(c);
        m["count"]    = a.count;
        m["nulls"]    = a.nulls;
        m["distinct"] = a.freq.size();

        const bool numeric = a.count > 0 && a.allNumeric && !a.nums.isEmpty();
        m["type"] = (a.count == 0) ? QStringLiteral("empty")
                  : numeric        ? QStringLiteral("numeric")
                                    : QStringLiteral("text");

        if (numeric) {
            std::sort(a.nums.begin(), a.nums.end());
            const int k = a.nums.size();
            const double median = (k % 2) ? a.nums.at(k / 2)
                                          : (a.nums.at(k / 2 - 1) + a.nums.at(k / 2)) / 2.0;
            m["min"]    = a.nums.first();
            m["max"]    = a.nums.last();
            m["mean"]   = a.sum / a.count;
            m["median"] = median;
        } else if (a.count > 0) {
            // Top values by frequency (desc), up to 5 — the categorical distribution.
            QList<QPair<QString, int>> pairs;
            pairs.reserve(a.freq.size());
            for (auto it = a.freq.constBegin(); it != a.freq.constEnd(); ++it)
                pairs.append({ it.key(), it.value() });
            std::sort(pairs.begin(), pairs.end(),
                      [](const auto &x, const auto &y) { return x.second > y.second; });

            QVariantList top;
            for (int i = 0; i < pairs.size() && i < 5; ++i)
                top.append(QVariantMap{ { "value", pairs.at(i).first },
                                        { "count", pairs.at(i).second } });
            m["topValues"] = top;
        }
        out.append(m);
    }
    return out;
}

namespace {

// Running aggregate for one pivot cell / row / column / grand total.
struct PivotAcc {
    double sum = 0.0, mn = 0.0, mx = 0.0;
    int    cnt = 0;   // rows seen (for count)
    int    num = 0;   // numeric values seen (for sum/avg/min/max)
    void tally() { ++cnt; }
    void add(double d) {
        sum += d;
        if (num == 0) { mn = mx = d; }
        else          { mn = qMin(mn, d); mx = qMax(mx, d); }
        ++num;
    }
};

// Collapse an accumulator to the requested aggregate. count always yields a
// number; the numeric aggregates yield an invalid QVariant (→ null/blank cell)
// when the group had no numeric values.
QVariant finalizePivot(const PivotAcc &a, const QString &agg) {
    if (agg == QLatin1String("count")) return a.cnt;
    if (a.num == 0)                    return QVariant();
    if (agg == QLatin1String("sum"))   return a.sum;
    if (agg == QLatin1String("avg"))   return a.sum / a.num;
    if (agg == QLatin1String("min"))   return a.mn;
    if (agg == QLatin1String("max"))   return a.mx;
    return QVariant();
}

// Order keys numerically when both look like numbers, else lexically; numbers
// sort before text.
bool pivotKeyLess(const QString &a, const QString &b) {
    bool oka = false, okb = false;
    const double da = a.toDouble(&oka);
    const double db = b.toDouble(&okb);
    if (oka && okb) return da < db;
    if (oka != okb) return oka;
    return a < b;
}

} // namespace

QVariantMap ResultModel::pivot(int rowCol, int colCol, int valueCol,
                               const QString &agg) const
{
    QVariantMap out;
    const int ncols = m_columns.size();
    if (rowCol < 0 || rowCol >= ncols || colCol < 0 || colCol >= ncols)
        return out;
    const bool needsValue = (agg != QLatin1String("count"));
    if (needsValue && (valueCol < 0 || valueCol >= ncols))
        return out;

    const int  maxRows = 200;
    const int  maxCols = 50;
    const auto nullKey = QStringLiteral("(null)");

    QList<QString>                     rowKeys, colKeys;   // first-seen order
    QSet<QString>                      rowSeen, colSeen;
    QHash<QString, QHash<QString, PivotAcc>> cell;
    QHash<QString, PivotAcc>           rowTot, colTot;
    PivotAcc                           grand;
    bool rowsTruncated = false, colsTruncated = false;

    const int n = rowCount();   // visible rows only — respects the active filter
    for (int i = 0; i < n; ++i) {
        const QVariantList &r = m_rows.at(_row(i));
        const QVariant &rv = r.at(rowCol);
        const QVariant &cv = r.at(colCol);
        const QString rk = (!rv.isValid() || rv.isNull()) ? nullKey : cellText(rv);
        const QString ck = (!cv.isValid() || cv.isNull()) ? nullKey : cellText(cv);

        if (!rowSeen.contains(rk)) {
            if (rowKeys.size() >= maxRows) { rowsTruncated = true; continue; }
            rowSeen.insert(rk); rowKeys.append(rk);
        }
        if (!colSeen.contains(ck)) {
            if (colKeys.size() >= maxCols) { colsTruncated = true; continue; }
            colSeen.insert(ck); colKeys.append(ck);
        }

        PivotAcc &c  = cell[rk][ck];
        PivotAcc &rt = rowTot[rk];
        PivotAcc &ct = colTot[ck];
        c.tally(); rt.tally(); ct.tally(); grand.tally();

        if (needsValue) {
            const QVariant &vv = r.at(valueCol);
            if (vv.isValid() && !vv.isNull()) {
                bool ok = false;
                const double d = vv.toString().toDouble(&ok);
                if (ok) { c.add(d); rt.add(d); ct.add(d); grand.add(d); }
            }
        }
    }

    std::sort(rowKeys.begin(), rowKeys.end(), pivotKeyLess);
    std::sort(colKeys.begin(), colKeys.end(), pivotKeyLess);

    QVariantList colKeyList;
    for (const QString &ck : colKeys) colKeyList.append(ck);

    QVariantList rows;
    for (const QString &rk : rowKeys) {
        QVariantList cells;
        for (const QString &ck : colKeys) {
            const auto rit = cell.constFind(rk);
            if (rit != cell.constEnd() && rit->contains(ck))
                cells.append(finalizePivot(rit->value(ck), agg));
            else
                cells.append(QVariant());   // no rows for this combo → blank
        }
        rows.append(QVariantMap{
            { QStringLiteral("key"),   rk },
            { QStringLiteral("cells"), cells },
            { QStringLiteral("total"), finalizePivot(rowTot.value(rk), agg) },
        });
    }

    QVariantList colTotals;
    for (const QString &ck : colKeys)
        colTotals.append(finalizePivot(colTot.value(ck), agg));

    out[QStringLiteral("rowField")]      = m_columns.at(rowCol);
    out[QStringLiteral("colField")]      = m_columns.at(colCol);
    out[QStringLiteral("valueField")]    = needsValue ? m_columns.at(valueCol) : QString();
    out[QStringLiteral("agg")]           = agg;
    out[QStringLiteral("colKeys")]       = colKeyList;
    out[QStringLiteral("rows")]          = rows;
    out[QStringLiteral("colTotals")]     = colTotals;
    out[QStringLiteral("grandTotal")]    = finalizePivot(grand, agg);
    out[QStringLiteral("rowsTruncated")] = rowsTruncated;
    out[QStringLiteral("colsTruncated")] = colsTruncated;
    return out;
}

bool ResultModel::exportTsv(const QUrl &fileUrl) const
{
    QFile file(fileUrl.toLocalFile());
    if (!file.open(QIODevice::WriteOnly | QIODevice::Text))
        return false;

    QTextStream out(&file);

    out << m_columns.join('\t') << '\n';

    const int n = rowCount();
    for (int i = 0; i < n; ++i) {
        QStringList fields;
        for (const QVariant &val : m_rows.at(_row(i)))
            fields << spreadsheetSafe(cellText(val).replace('\t', ' ').replace('\n', ' '));
        out << fields.join('\t') << '\n';
    }

    return true;
}

bool ResultModel::exportJson(const QUrl &fileUrl) const
{
    QJsonArray array;
    const int n = rowCount();
    for (int i = 0; i < n; ++i) {
        const QVariantList &row = m_rows.at(_row(i));
        QJsonObject obj;
        for (int c = 0; c < m_columns.size() && c < row.size(); ++c) {
            const QVariant &val = row.at(c);
            obj[m_columns.at(c)] = val.isNull() ? QJsonValue::Null
                                                 : QJsonValue::fromVariant(val);
        }
        array.append(obj);
    }

    QFile file(fileUrl.toLocalFile());
    if (!file.open(QIODevice::WriteOnly | QIODevice::Text))
        return false;

    file.write(QJsonDocument(array).toJson(QJsonDocument::Indented));
    return true;
}

QString ResultModel::toSqlInserts(const QString &tableName, const QString &driver,
                                  int maxRows) const
{
    if (m_columns.isEmpty())
        return {};

    const QString table = sqlIdent(tableName.trimmed().isEmpty()
                                       ? QStringLiteral("table_name") : tableName.trimmed(),
                                   driver);
    QStringList idents;
    for (const QString &col : m_columns)
        idents << sqlIdent(col, driver);
    const QString prefix = QStringLiteral("INSERT INTO ") + table
                         + QStringLiteral(" (") + idents.join(QStringLiteral(", "))
                         + QStringLiteral(") VALUES (");

    const int n     = rowCount();
    const int shown = maxRows > 0 ? qMin(n, maxRows) : n;
    QString out;
    for (int i = 0; i < shown; ++i) {
        const QVariantList &row = m_rows.at(_row(i));
        QStringList vals;
        for (int c = 0; c < m_columns.size(); ++c)
            vals << sqlLiteral(c < row.size() ? row.at(c) : QVariant(), driver);
        out += prefix + vals.join(QStringLiteral(", ")) + QStringLiteral(");\n");
    }
    return out;
}

bool ResultModel::exportSql(const QUrl &fileUrl, const QString &tableName,
                            const QString &driver) const
{
    QFile file(fileUrl.toLocalFile());
    if (!file.open(QIODevice::WriteOnly | QIODevice::Text))
        return false;

    const QString table = sqlIdent(tableName.trimmed().isEmpty()
                                       ? QStringLiteral("table_name") : tableName.trimmed(),
                                   driver);
    QStringList idents;
    for (const QString &col : m_columns)
        idents << sqlIdent(col, driver);
    const QString prefix = QStringLiteral("INSERT INTO ") + table
                         + QStringLiteral(" (") + idents.join(QStringLiteral(", "))
                         + QStringLiteral(") VALUES (");

    QTextStream out(&file);
    // Stream row by row so a large (up to 500k-row) result never has to be
    // materialised into one giant string.
    const int n = rowCount();
    for (int i = 0; i < n; ++i) {
        const QVariantList &row = m_rows.at(_row(i));
        QStringList vals;
        for (int c = 0; c < m_columns.size(); ++c)
            vals << sqlLiteral(c < row.size() ? row.at(c) : QVariant(), driver);
        out << prefix << vals.join(QStringLiteral(", ")) << ");\n";
    }
    return true;
}

bool ResultModel::exportXlsx(const QUrl &fileUrl) const
{
    // ── Shared strings table ────────────────────────────────────────────────
    QStringList strings;
    QHash<QString, int> idx;
    auto addStr = [&](const QString &s) -> int {
        auto it = idx.find(s);
        if (it != idx.end()) return it.value();
        const int i = strings.size();
        strings.append(s); idx[s] = i; return i;
    };
    for (const QString &col : m_columns) addStr(col);
    const int n = rowCount();
    for (int r = 0; r < n; ++r)
        for (const QVariant &v : m_rows.at(_row(r))) {
            if (v.isNull()) continue;
            const int tid = v.metaType().id();
            const bool numeric = (tid == QMetaType::Int    || tid == QMetaType::UInt  ||
                                  tid == QMetaType::Double || tid == QMetaType::Float  ||
                                  tid == QMetaType::LongLong || tid == QMetaType::ULongLong);
            if (!numeric) addStr(cellText(v));
        }

    // ── sharedStrings.xml ───────────────────────────────────────────────────
    QString ssXml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
                    "<sst xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\""
                    " count=\"" + QString::number(strings.size()) +
                    "\" uniqueCount=\"" + QString::number(strings.size()) + "\">\n";
    for (const QString &s : strings)
        ssXml += "  <si><t>" + xmlEsc(s) + "</t></si>\n";
    ssXml += "</sst>";

    // ── sheet1.xml ─────────────────────────────────────────────────────────
    QString shXml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
                    "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
                    "<sheetData>";

    // header row — style 1 (bold)
    shXml += "<row r=\"1\">";
    for (int c = 0; c < m_columns.size(); ++c) {
        const QString ref = colName(c) + "1";
        shXml += "<c r=\"" + ref + "\" t=\"s\" s=\"1\"><v>"
              +  QString::number(idx.value(m_columns.at(c))) + "</v></c>";
    }
    shXml += "</row>";

    for (int r = 0; r < n; ++r) {
        const QString rowNum = QString::number(r + 2);
        shXml += "<row r=\"" + rowNum + "\">";
        const QVariantList &row = m_rows.at(_row(r));
        for (int c = 0; c < row.size(); ++c) {
            const QVariant &val = row.at(c);
            if (val.isNull()) continue;
            const QString ref = colName(c) + rowNum;
            const int tid = val.metaType().id();
            const bool numeric = (tid == QMetaType::Int    || tid == QMetaType::UInt  ||
                                  tid == QMetaType::Double || tid == QMetaType::Float  ||
                                  tid == QMetaType::LongLong || tid == QMetaType::ULongLong);
            if (numeric) {
                shXml += "<c r=\"" + ref + "\"><v>" + val.toString() + "</v></c>";
            } else {
                shXml += "<c r=\"" + ref + "\" t=\"s\"><v>"
                      +  QString::number(idx.value(cellText(val))) + "</v></c>";
            }
        }
        shXml += "</row>";
    }
    shXml += "</sheetData></worksheet>";

    // ── Static XML parts ────────────────────────────────────────────────────
    static const QByteArray kCT =
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
        "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
        "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
        "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>"
        "<Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        "<Override PartName=\"/xl/sharedStrings.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml\"/>"
        "<Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>"
        "</Types>";

    static const QByteArray kRels =
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/>"
        "</Relationships>";

    static const QByteArray kWb =
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\""
        " xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">"
        "<sheets><sheet name=\"Sheet1\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>";

    static const QByteArray kWbRels =
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/>"
        "<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings\" Target=\"sharedStrings.xml\"/>"
        "<Relationship Id=\"rId3\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"
        "</Relationships>";

    static const QByteArray kStyles =
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        "<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
        "<fonts count=\"2\">"
          "<font><sz val=\"11\"/><name val=\"Calibri\"/></font>"
          "<font><b/><sz val=\"11\"/><name val=\"Calibri\"/></font>"
        "</fonts>"
        "<fills count=\"2\">"
          "<fill><patternFill patternType=\"none\"/></fill>"
          "<fill><patternFill patternType=\"gray125\"/></fill>"
        "</fills>"
        "<borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders>"
        "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>"
        "<cellXfs count=\"2\">"
          "<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/>"
          "<xf numFmtId=\"0\" fontId=\"1\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyFont=\"1\"/>"
        "</cellXfs>"
        "</styleSheet>";

    // ── Assemble ZIP ────────────────────────────────────────────────────────
    QList<ZipEntry> entries = {
        { "[Content_Types].xml",        kCT },
        { "_rels/.rels",                kRels },
        { "xl/workbook.xml",            kWb },
        { "xl/_rels/workbook.xml.rels", kWbRels },
        { "xl/styles.xml",              kStyles },
        { "xl/sharedStrings.xml",       ssXml.toUtf8() },
        { "xl/worksheets/sheet1.xml",   shXml.toUtf8() },
    };

    QFile file(fileUrl.toLocalFile());
    if (!file.open(QIODevice::WriteOnly)) return false;
    file.write(buildZip(entries));
    return true;
}
