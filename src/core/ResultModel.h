#pragma once

#include <QAbstractTableModel>
#include <QVariantMap>
#include <QVector>
#include "Types.h"

class ResultModel : public QAbstractTableModel {
    Q_OBJECT
    Q_PROPERTY(bool        truncated      READ isTruncated     NOTIFY truncatedChanged)
    Q_PROPERTY(int         sortColumn     READ sortColumn      NOTIFY sortColumnChanged)
    Q_PROPERTY(int         sortOrder      READ sortOrder       NOTIFY sortOrderChanged)
    Q_PROPERTY(QStringList columnNames    READ columnNames     NOTIFY columnNamesChanged)
    Q_PROPERTY(QString     filterText     READ filterText      NOTIFY filterTextChanged)
    Q_PROPERTY(int         totalRowCount  READ totalRowCount   NOTIFY totalRowCountChanged)
    Q_PROPERTY(int         count          READ rowCount        NOTIFY countChanged)

public:
    enum Roles {
        IsNullRole = Qt::UserRole + 1
    };

    explicit ResultModel(QObject *parent = nullptr);

    int rowCount(const QModelIndex &parent = {}) const override;
    int columnCount(const QModelIndex &parent = {}) const override;

    QVariant data(const QModelIndex &index, int role = Qt::DisplayRole) const override;
    QVariant headerData(int section, Qt::Orientation orientation, int role = Qt::DisplayRole) const override;
    QHash<int, QByteArray> roleNames() const override;

    bool        isTruncated()   const { return m_truncated; }
    int         sortColumn()    const { return m_sortColumn; }
    int         sortOrder()     const { return static_cast<int>(m_sortOrder); }
    QStringList columnNames()   const { return m_columns; }
    QString     filterText()    const { return m_filterText; }
    int         totalRowCount() const { return m_rows.size(); }

    void setResult(const QueryResult &result);
    Q_INVOKABLE void clear();
    Q_INVOKABLE void sort(int column, Qt::SortOrder order = Qt::AscendingOrder) override;
    Q_INVOKABLE void clearSort();
    Q_INVOKABLE void setFilterText(const QString &text);
    Q_INVOKABLE void setCellValue(int displayRow, int col, const QVariant &value);

    Q_INVOKABLE bool exportCsv(const QUrl &fileUrl)  const;
    Q_INVOKABLE bool exportTsv(const QUrl &fileUrl)  const;
    Q_INVOKABLE bool exportJson(const QUrl &fileUrl) const;
    Q_INVOKABLE bool exportXlsx(const QUrl &fileUrl) const;

    // SQL INSERT statements for the currently *visible* rows (respects the
    // active filter/sort), one statement per row, for moving data between
    // databases. Identifier quoting and value literals follow `driver` (the Qt
    // driver key, e.g. "QPSQL"/"QMYSQL"/"QSQLITE"): MySQL/MariaDB use backticks,
    // everyone else double quotes; booleans/bytea/backslash handling is
    // dialect-aware. `exportSql` streams to a file; `toSqlInserts` returns the
    // text (with an optional row cap) for clipboard use.
    Q_INVOKABLE bool exportSql(const QUrl &fileUrl, const QString &tableName,
                               const QString &driver) const;
    Q_INVOKABLE QString toSqlInserts(const QString &tableName, const QString &driver,
                                     int maxRows = -1) const;
    Q_INVOKABLE QString cellValue(int row, int column) const;
    Q_INVOKABLE QString rowAsTsv(int row) const;
    Q_INVOKABLE QString toMarkdown(int maxRows = 100) const;

    // Aggregates for one column over the currently *visible* rows (respects the
    // active filter). Returns a map: { column, count, nulls, distinct, numeric,
    // and — when numeric — sum, avg, min, max }. Empty map for a bad column.
    Q_INVOKABLE QVariantMap columnStats(int column) const;

    // Raw values of one column over the currently *visible* rows (respects the
    // active filter/sort). Used to feed the chart view. NULLs come back as an
    // invalid QVariant. Empty list for a bad column.
    Q_INVOKABLE QVariantList columnValues(int column) const;

    // Which columns hold nothing but numbers, over the currently *visible* rows
    // (respects the active filter): one bool per column, in column order. True
    // when the column has at least one non-null value and every one of them
    // parses as a number — the same rule as columnStats()'s `numeric`, but for
    // every column in one pass and without building the distinct-value set.
    // A column stops being read as soon as one value fails to parse. The chart
    // view uses it to choose its default axes.
    Q_INVOKABLE QVariantList numericColumns() const;

    // A df.describe()-style profile of every column over the visible rows: one
    // QVariantMap per column with { column, type("numeric"|"text"|"empty"),
    // count, nulls, distinct; numeric also has min/max/mean/median; text also
    // has topValues: [{ value, count }] (up to 5). Powers the Profile panel.
    Q_INVOKABLE QVariantList profile() const;

    // Cross-tabulate the visible rows (respects the active filter): group by
    // rowCol × colCol and aggregate valueCol with `agg` ∈
    // {count, sum, avg, min, max}. `count` tallies rows and ignores valueCol.
    // Distinct row/column keys are capped (rowsTruncated/colsTruncated flag it).
    // Returns:
    //   { rowField, colField, valueField, agg,
    //     colKeys: [str…],
    //     rows: [ { key, cells: [double|null…], total } ],
    //     colTotals: [double…], grandTotal,
    //     rowsTruncated, colsTruncated }
    // Empty map for out-of-range columns.
    Q_INVOKABLE QVariantMap pivot(int rowCol, int colCol, int valueCol,
                                  const QString &agg) const;

    // Evaluate a list of data-quality expectations against the visible rows
    // (respects the active filter). Each rule is { column (name), check, arg? }
    // with check ∈ { not_null, unique, not_empty, positive, non_negative,
    // range ("min,max"), max_length (int), matches (regex) }. Returns one map
    // per rule: { column, check, arg, checked, violations, passed, sample?,
    // error? }. Unknown column or bad arg → passed=false with an `error`.
    Q_INVOKABLE QVariantList checkExpectations(const QVariantList &rules) const;

    // Capture the current visible rows + columns as a plain baseline map
    // ({ columns, rows: [[cell…]], rowCount }) for later diffing. Respects the
    // active filter/sort.
    Q_INVOKABLE QVariantMap snapshot() const;

    // Diff the current visible rows against a baseline produced by snapshot().
    // `keyColumn` -1 = whole-row multiset diff; >=0 = match rows by that column.
    // See ResultDiff::compare for the returned shape.
    Q_INVOKABLE QVariantMap diffAgainst(const QVariantMap &baseline, int keyColumn) const;

signals:
    void truncatedChanged();
    void sortColumnChanged();
    void sortOrderChanged();
    void columnNamesChanged();
    void filterTextChanged();
    void totalRowCountChanged();
    void countChanged();

private:
    static QString spreadsheetSafe(const QString &v);

    QStringList         m_columns;
    QList<QVariantList> m_rows;
    bool                m_truncated  = false;
    int                 m_sortColumn = -1;
    Qt::SortOrder       m_sortOrder  = Qt::AscendingOrder;
    QString             m_filterText;
    // display row → m_rows index. Only consulted while m_rowsFiltered: an empty
    // vector is a legitimate result (a filter that matched nothing), so it
    // cannot double as the "no filter, show everything" sentinel.
    QVector<int>        m_visibleRows;
    bool                m_rowsFiltered = false;

    int _row(int displayRow) const {
        return m_rowsFiltered ? m_visibleRows.at(displayRow) : displayRow;
    }
    void _rebuild(); // recompute m_visibleRows from current filter + sort state
};
