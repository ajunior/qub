pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Mahina

// Cross-tabulates the active result set: pick a Rows field, a Columns field, a
// Value field and an aggregation, and the rows currently in view (respects the
// filter) are pivoted into a grid via ResultModel::pivot(). Mirrors ChartView's
// selector pattern; the grid is a fixed-width cell layout so columns align.
Rectangle {
    id: root

    property var  model:  null   // ResultModel
    property bool hasRun: false

    color: Theme.surface

    property int    _rowCol: -1
    property int    _colCol: -1
    property int    _valCol: -1
    property string _agg:    "count"   // count | sum | avg | min | max

    readonly property var _cols: root.model ? root.model.columnNames : []
    readonly property int _rows: root.model ? root.model.count : 0   // reactive trigger

    readonly property bool _needsValue: root._agg !== "count"
    readonly property bool _ready: root.model && _cols.length > 0 && root._rows > 0
                                   && _rowCol >= 0 && _colCol >= 0
                                   && (!_needsValue || _valCol >= 0)

    // Layout metrics
    readonly property int _rhw: 160   // row-header column width
    readonly property int _cw:  104   // data / total column width
    readonly property int _rh:  28    // cell height

    function _resetCols(): void {
        if (!_rowDrop || !_colDrop || !_valDrop || !_aggSeg) return
        const n = root._cols.length
        _rowDrop.currentIndex = 0
        _colDrop.currentIndex = n > 1 ? 1 : 0
        _valDrop.currentIndex = n > 2 ? 2 : (n > 0 ? 0 : 0)
        _aggSeg.currentIndex  = 0
        root._rowCol = n > 0 ? 0 : -1
        root._colCol = n > 1 ? 1 : (n > 0 ? 0 : -1)
        root._valCol = n > 2 ? 2 : (n > 0 ? 0 : -1)
        root._agg    = "count"
    }

    onModelChanged: _resetCols()
    Component.onCompleted: _resetCols()
    Connections {
        target: root.model
        function onColumnNamesChanged() { root._resetCols() }
    }

    // ── Pivot data ──────────────────────────────────────────────────────────
    readonly property var _pivot: {
        void root._rows                          // depend on the data
        if (!root._ready) return null
        const p = root.model.pivot(root._rowCol, root._colCol,
                                   root._needsValue ? root._valCol : -1, root._agg)
        // pivot() answers with an empty map when the chosen columns fall
        // outside the result — which they do for a moment every time a new
        // result arrives while the pickers still point at the old one's
        // columns. An empty QVariantMap reaches QML as {}, which is truthy, so
        // every `_pivot ? …` guard below waved it through and then read
        // undefined off it. Nothing is a pivot until it has a row field.
        return p && p.rowField !== undefined ? p : null
    }

    function _fmt(v: var): var {
        if (v === undefined || v === null) return ""
        const n = Number(v)
        if (isNaN(n)) return String(v)
        return Number.isInteger(n) ? String(n) : n.toFixed(2)
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ── Controls ────────────────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            height: 48
            color:  Theme.panel
            visible: root._cols.length > 0

            Rectangle {
                anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
                height: 1; color: Theme.border
            }

            RowLayout {
                anchors { fill: parent; leftMargin: Theme.sp3; rightMargin: Theme.sp3 }
                spacing: Theme.sp3

                Text {
                    text: "Rows"
                    color: Theme.textSecondary
                    font { family: Theme.fontFamily; pixelSize: Theme.textSm; weight: Theme.weightMedium }
                }
                Dropdown {
                    id: _rowDrop
                    Layout.preferredWidth: 150
                    model: root._cols
                    onCurrentIndexChanged: root._rowCol = currentIndex
                }

                Text {
                    text: "Columns"
                    color: Theme.textSecondary
                    font { family: Theme.fontFamily; pixelSize: Theme.textSm; weight: Theme.weightMedium }
                }
                Dropdown {
                    id: _colDrop
                    Layout.preferredWidth: 150
                    model: root._cols
                    onCurrentIndexChanged: root._colCol = currentIndex
                }

                Item { Layout.fillWidth: true }

                SegmentedControl {
                    id: _aggSeg
                    model: ["Count", "Sum", "Avg", "Min", "Max"]
                    currentIndex: 0
                    onSelectionChanged: (index) =>
                        root._agg = ["count", "sum", "avg", "min", "max"][index]
                }

                Text {
                    text: "of"
                    color: Theme.textDisabled
                    opacity: root._needsValue ? 1 : 0.4
                    font { family: Theme.fontFamily; pixelSize: Theme.textSm }
                }
                Dropdown {
                    id: _valDrop
                    Layout.preferredWidth: 150
                    enabled: root._needsValue   // count ignores the value column
                    opacity: root._needsValue ? 1 : 0.5
                    model: root._cols
                    onCurrentIndexChanged: root._valCol = currentIndex
                }
            }
        }

        // ── Truncation notice ───────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            visible: !!(root._pivot
                        && (root._pivot.rowsTruncated || root._pivot.colsTruncated))
            height: visible ? 26 : 0
            color:  Qt.rgba(Theme.warning.r, Theme.warning.g, Theme.warning.b, 0.08)
            RowLayout {
                anchors { fill: parent; leftMargin: Theme.sp3; rightMargin: Theme.sp3 }
                spacing: Theme.sp2
                Icon { name: Icons.warning; size: 13; color: Theme.warning }
                Text {
                    Layout.fillWidth: true
                    text: {
                        if (!root._pivot) return ""
                        if (root._pivot.rowsTruncated && root._pivot.colsTruncated)
                            return "Too many distinct row and column values — the pivot is capped."
                        if (root._pivot.rowsTruncated)
                            return "Too many distinct row values — extra rows are omitted."
                        return "Too many distinct column values — extra columns are omitted."
                    }
                    color: Theme.textSecondary
                    elide: Text.ElideRight
                    font { family: Theme.fontFamily; pixelSize: Theme.textXs }
                }
            }
        }

        // ── Grid ────────────────────────────────────────────────────────────
        Item {
            Layout.fillWidth:  true
            Layout.fillHeight: true

            ScrollArea {
                id: _scroll
                anchors.fill: parent
                visible:    !!(root._ready && root._pivot)
                horizontal: true
                vertical:   true
                clip:       true

                Column {
                    spacing: 0

                    // Header row: corner + column keys + Total
                    Row {
                        spacing: 0
                        // Corner
                        Rectangle {
                            width: root._rhw; height: root._rh
                            color: Theme.panel; border.width: 1; border.color: Theme.border
                            Text {
                                anchors { fill: parent; leftMargin: Theme.sp2; rightMargin: Theme.sp2 }
                                verticalAlignment: Text.AlignVCenter
                                text: root._pivot ? root._pivot.rowField : ""
                                elide: Text.ElideRight
                                color: Theme.textSecondary
                                font { family: Theme.fontFamily; pixelSize: Theme.textXs; weight: Theme.weightSemibold }
                            }
                        }
                        Repeater {
                            model: root._pivot ? root._pivot.colKeys : []
                            delegate: Rectangle {
                                required property var modelData
                                width: root._cw; height: root._rh
                                color: Theme.panel; border.width: 1; border.color: Theme.border
                                Text {
                                    anchors { fill: parent; leftMargin: 6; rightMargin: 6 }
                                    horizontalAlignment: Text.AlignRight
                                    verticalAlignment: Text.AlignVCenter
                                    text: String(parent.modelData)
                                    elide: Text.ElideRight
                                    color: Theme.textPrimary
                                    font { family: Theme.fontFamily; pixelSize: Theme.textXs; weight: Theme.weightSemibold }
                                }
                            }
                        }
                        Rectangle {
                            width: root._cw; height: root._rh
                            color: Theme.surfaceVariant; border.width: 1; border.color: Theme.border
                            Text {
                                anchors { fill: parent; leftMargin: 6; rightMargin: 6 }
                                horizontalAlignment: Text.AlignRight
                                verticalAlignment: Text.AlignVCenter
                                text: "Total"
                                color: Theme.textSecondary
                                font { family: Theme.fontFamily; pixelSize: Theme.textXs; weight: Theme.weightSemibold }
                            }
                        }
                    }

                    // Body rows
                    Repeater {
                        model: root._pivot ? root._pivot.rows : []
                        delegate: Row {
                            id: _bodyRow
                            required property var modelData
                            spacing: 0

                            Rectangle {
                                width: root._rhw; height: root._rh
                                color: Theme.panel; border.width: 1; border.color: Theme.border
                                Text {
                                    anchors { fill: parent; leftMargin: Theme.sp2; rightMargin: Theme.sp2 }
                                    verticalAlignment: Text.AlignVCenter
                                    text: String(_bodyRow.modelData.key)
                                    elide: Text.ElideRight
                                    color: Theme.textPrimary
                                    font { family: Theme.fontFamily; pixelSize: Theme.textXs; weight: Theme.weightMedium }
                                }
                            }
                            Repeater {
                                model: _bodyRow.modelData.cells
                                delegate: Rectangle {
                                    required property var modelData
                                    width: root._cw; height: root._rh
                                    color: Theme.surface; border.width: 1; border.color: Theme.border
                                    Text {
                                        anchors { fill: parent; leftMargin: 6; rightMargin: 6 }
                                        horizontalAlignment: Text.AlignRight
                                        verticalAlignment: Text.AlignVCenter
                                        text: root._fmt(parent.modelData)
                                        elide: Text.ElideRight
                                        color: Theme.textSecondary
                                        font { family: Theme.fontFamilyMono; pixelSize: Theme.textXs }
                                    }
                                }
                            }
                            Rectangle {
                                width: root._cw; height: root._rh
                                color: Theme.surfaceVariant; border.width: 1; border.color: Theme.border
                                Text {
                                    anchors { fill: parent; leftMargin: 6; rightMargin: 6 }
                                    horizontalAlignment: Text.AlignRight
                                    verticalAlignment: Text.AlignVCenter
                                    text: root._fmt(_bodyRow.modelData.total)
                                    color: Theme.textPrimary
                                    font { family: Theme.fontFamilyMono; pixelSize: Theme.textXs; weight: Theme.weightSemibold }
                                }
                            }
                        }
                    }

                    // Footer: Total + column totals + grand total
                    Row {
                        spacing: 0
                        Rectangle {
                            width: root._rhw; height: root._rh
                            color: Theme.surfaceVariant; border.width: 1; border.color: Theme.border
                            Text {
                                anchors { fill: parent; leftMargin: Theme.sp2; rightMargin: Theme.sp2 }
                                verticalAlignment: Text.AlignVCenter
                                text: "Total"
                                color: Theme.textSecondary
                                font { family: Theme.fontFamily; pixelSize: Theme.textXs; weight: Theme.weightSemibold }
                            }
                        }
                        Repeater {
                            model: root._pivot ? root._pivot.colTotals : []
                            delegate: Rectangle {
                                required property var modelData
                                width: root._cw; height: root._rh
                                color: Theme.surfaceVariant; border.width: 1; border.color: Theme.border
                                Text {
                                    anchors { fill: parent; leftMargin: 6; rightMargin: 6 }
                                    horizontalAlignment: Text.AlignRight
                                    verticalAlignment: Text.AlignVCenter
                                    text: root._fmt(parent.modelData)
                                    color: Theme.textPrimary
                                    font { family: Theme.fontFamilyMono; pixelSize: Theme.textXs; weight: Theme.weightSemibold }
                                }
                            }
                        }
                        Rectangle {
                            width: root._cw; height: root._rh
                            color: Theme.surfaceVariant; border.width: 1; border.color: Theme.border
                            Text {
                                anchors { fill: parent; leftMargin: 6; rightMargin: 6 }
                                horizontalAlignment: Text.AlignRight
                                verticalAlignment: Text.AlignVCenter
                                text: root._pivot ? root._fmt(root._pivot.grandTotal) : ""
                                color: Theme.textPrimary
                                font { family: Theme.fontFamilyMono; pixelSize: Theme.textXs; weight: Theme.weightBold }
                            }
                        }
                    }
                }
            }

            // Empty / prompt state
            EmptyState {
                anchors.centerIn: parent
                visible: !root._ready
                icon:    Icons.table
                title:   root.hasRun ? "Nothing to pivot" : "Run a query to pivot it"
                description: root.hasRun
                    ? "This result has no rows. Pivots summarise the rows currently in view."
                    : "Cross-tabulate results here — pick Rows, Columns and an aggregation above."
            }
        }
    }
}
