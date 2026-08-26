pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Mahina
import Qub

Dialog {
    id: root

    // ── API ──────────────────────────────────────────────────────────────────
    property string connectionName: ""
    property string tableName:      ""

    function openFor(conn: var, table: var): void {
        connectionName = conn
        tableName      = table
        _stats         = {}
        _load()
        open()
    }

    // ── State ─────────────────────────────────────────────────────────────────
    property var _stats: ({})

    function _load(): void {
        _stats = DatabaseInspector.tableStats(connectionName, tableName)
    }

    // ── Derived helpers ───────────────────────────────────────────────────────
    readonly property bool _isPg:      (_stats.driver || "").indexOf("PSQL")    >= 0
    readonly property bool _isMysql:   (_stats.driver || "").indexOf("MYSQL")   >= 0 ||
                                       (_stats.driver || "").indexOf("MARIADB")  >= 0
    readonly property bool _isSqlite:  (_stats.driver || "").indexOf("SQLITE")  >= 0
    readonly property bool _hasCols:   Array.isArray(_stats.columns) && _stats.columns.length > 0

    readonly property var _statCards: {
        const s = _stats
        const base = []
        if (s.rowEstimate !== undefined)
            base.push({ label: "Row estimate", value: s.rowEstimate?.toLocaleString() ?? "—", icon: Icons.rows })
        if (_isPg) {
            if (s.liveRows   !== undefined) base.push({ label: "Live rows",    value: s.liveRows?.toLocaleString()  ?? "—", icon: Icons.check    })
            if (s.deadRows   !== undefined) base.push({ label: "Dead rows",    value: s.deadRows?.toLocaleString()  ?? "—", icon: Icons.warning  })
            if (s.pages      !== undefined) base.push({ label: "Pages",        value: s.pages?.toLocaleString()     ?? "—", icon: Icons.database })
            if (s.totalSize  !== undefined) base.push({ label: "Total size",   value: s.totalSize  ?? "—",                 icon: Icons.storage  })
            if (s.tableSize  !== undefined) base.push({ label: "Table size",   value: s.tableSize  ?? "—",                 icon: Icons.table    })
            if (s.indexesSize !== undefined) base.push({ label: "Indexes size", value: s.indexesSize ?? "—",               icon: Icons.lightning})
        } else if (_isMysql) {
            if (s.totalSize    !== undefined) base.push({ label: "Total size",    value: s.totalSize    ?? "—", icon: Icons.storage  })
            if (s.tableSize    !== undefined) base.push({ label: "Table size",    value: s.tableSize    ?? "—", icon: Icons.table    })
            if (s.indexesSize  !== undefined) base.push({ label: "Indexes size",  value: s.indexesSize  ?? "—", icon: Icons.lightning})
            if (s.avgRowLength !== undefined) base.push({ label: "Avg row size",  value: s.avgRowLength ?? "—", icon: Icons.rows     })
        } else if (_isSqlite) {
            if (s.tableSize    !== undefined) base.push({ label: "Table size",  value: s.tableSize    ?? "—",                icon: Icons.storage  })
            if (s.indexCount   !== undefined) base.push({ label: "Indexes",     value: s.indexCount?.toLocaleString() ?? "—", icon: Icons.lightning})
        }
        return base
    }

    readonly property var _metaRows: {
        const s = _stats
        const rows = []
        if (_isPg) {
            if (s.lastVacuum  && s.lastVacuum  !== "null") rows.push({ key: "Last vacuum",  value: s.lastVacuum  })
            if (s.lastAnalyze && s.lastAnalyze !== "null") rows.push({ key: "Last analyze", value: s.lastAnalyze })
        } else if (_isMysql) {
            if (s.engine)      rows.push({ key: "Engine",       value: s.engine      })
            if (s.createTime && s.createTime !== "null") rows.push({ key: "Created",   value: s.createTime  })
            if (s.lastAnalyze && s.lastAnalyze !== "null") rows.push({ key: "Updated", value: s.lastAnalyze })
        }
        return rows
    }

    // ── Dialog chrome ─────────────────────────────────────────────────────────
    title:          root.tableName
    subtitle:       root.connectionName
    preferredWidth: 680

    // ── Content ───────────────────────────────────────────────────────────────
    ColumnLayout {
        width: parent.width
        spacing: 16

        // Stat cards
        GridLayout {
            Layout.fillWidth: true
            columns:          Math.min(root._statCards.length, (root._statCards.length <= 3 ? 3 : (root._isPg ? 4 : 3)))
            rowSpacing:       8
            columnSpacing:    8
            visible:          root._statCards.length > 0

            Repeater {
                model: root._statCards
                delegate: Stat {
                    id: delegateItem
                    required property var modelData
                    Layout.fillWidth: true
                    label: modelData.label
                    value: modelData.value
                    icon:  modelData.icon || ""
                }
            }
        }

        // Metadata rows
        PropertyGrid {
            Layout.fillWidth: true
            keyWidth: 100
            model:    root._metaRows
            visible:  root._metaRows.length > 0
        }

        // Column stats (PostgreSQL only)
        Item {
            Layout.fillWidth:  true
            Layout.preferredHeight: _colGrid.implicitHeight
            visible: root._hasCols

            ColumnLayout {
                width: parent.width
                spacing: 6

                Text {
                    text:  "Column Statistics"
                    color: Theme.textPrimary
                    font {
                        family:    Theme.fontFamily
                        pixelSize: Theme.textSm
                        weight:    Theme.weightSemibold
                    }
                }

                DataGrid {
                    id: _colGrid
                    Layout.fillWidth: true
                    Layout.preferredHeight: Math.min(implicitHeight, 300)

                    columns: [
                        { key: "column",      label: "Column",      width: 160 },
                        { key: "distinct",    label: "Distinct",    width: 120 },
                        { key: "nullFrac",    label: "Null %",      width:  80 },
                        { key: "avgWidth",    label: "Avg Width",   width:  90 },
                        { key: "correlation", label: "Correlation", width:  100 },
                    ]
                    rows: root._hasCols ? root._stats.columns : []
                }
            }
        }

        // Empty state — no data yet
        EmptyState {
            visible:     Object.keys(root._stats).length === 0
            icon:        Icons.table
            title:       "No statistics"
            description: "Statistics not available for this table."
        }
    }

    // ── Footer ────────────────────────────────────────────────────────────────
    footer: RowLayout {
        Button {
            text:    "Refresh"
            iconName: Icons.arrowClockwise
            size:    Button.Size.Sm
            variant: Button.Variant.Ghost
            onClicked: root._load()
        }
        Item { Layout.fillWidth: true }
        Button {
            text:    "Close"
            size:    Button.Size.Sm
            variant: Button.Variant.Ghost
            onClicked: root.close ? root.close() : root.visible = false
        }
    }
}
