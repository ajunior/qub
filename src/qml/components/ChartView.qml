pragma ComponentBehavior: Bound


import QtQuick
import QtQuick.Layouts
import Mahina

// Plots the active result set. Pick a chart type plus X (category / x-axis) and
// Y (numeric) columns; the data comes straight from the tab's ResultModel and
// tracks the current filter. Reuses Mahina's chart primitives.
Rectangle {
    id: root

    property var  model:  null   // ResultModel
    property bool hasRun: false

    color: Theme.surface

    // 0 = Bar, 1 = Line, 2 = Area, 3 = Scatter
    property int _type: 0
    property int _xCol: -1
    property int _yCol: -1

    readonly property var _cols: root.model ? root.model.columnNames : []
    // Reactive trigger: re-read column values whenever the result set changes.
    readonly property int _rows: root.model ? root.model.count : 0

    readonly property bool _ready: root.model && _cols.length > 0
                                   && root._rows > 0 && _xCol >= 0 && _yCol >= 0

    // Default axes for a freshly loaded result: X wants a label, Y wants numbers.
    // Picking X=0 / Y=1 blindly opens a `select country, tier, count(*) …` on a
    // text column for Y, which draws every bar at zero and looks broken. Returns
    // [x, y]; either may be -1 when there is nothing to plot.
    function _defaultCols(): var {
        const n = root._cols.length
        if (n === 0) return [-1, -1]
        if (n === 1) return [0, 0]

        // numericColumns() answers "is every visible value in this column a
        // number?" per column in one pass, over the rows the filter leaves.
        const num = root.model ? root.model.numericColumns() : []

        // X: the first column that is *not* numeric — the categories. All
        // numeric (a plot of two measures) falls back to the first column.
        let x = 0
        for (let i = 0; i < n; ++i) {
            if (!num[i]) { x = i; break }
        }

        // Y: the first numeric column that isn't already on X. Nothing numeric
        // at all keeps the old neighbour-column behaviour rather than blanking
        // the chart — the user can still pick by hand.
        let y = -1
        for (let j = 0; j < n; ++j) {
            if (num[j] && j !== x) { y = j; break }
        }
        if (y < 0) y = (x === 0) ? 1 : 0

        return [x, y]
    }

    function _resetCols(): void {
        // May be called before the child controls exist (during construction);
        // Component.onCompleted re-runs it once they do.
        if (!_typeSeg || !_xDrop || !_yDrop) return
        const pick = root._defaultCols()
        _typeSeg.currentIndex = 0
        root._type = 0
        root._xCol = pick[0]
        root._yCol = pick[1]
        _xDrop.currentIndex = Math.max(pick[0], 0)
        _yDrop.currentIndex = Math.max(pick[1], 0)
    }

    onModelChanged: _resetCols()
    Component.onCompleted: _resetCols()
    Connections {
        target: root.model
        function onColumnNamesChanged() { root._resetCols() }
    }

    // ── Derived chart data ────────────────────────────────────────────────────
    function _num(v: var): var { const n = Number(v); return isNaN(n) ? 0 : n }

    readonly property var _xLabels: {
        void root._rows                     // depend on data
        if (!root.model || root._xCol < 0) return []
        return root.model.columnValues(root._xCol)
                   .map(v => (v === undefined || v === null) ? "" : String(v))
    }

    readonly property var _series: {
        void root._rows
        if (!root.model || root._yCol < 0) return []
        const vals = root.model.columnValues(root._yCol).map(root._num)
        return [{ label: root._cols[root._yCol] ?? "", color: Theme.primary, values: vals }]
    }

    readonly property var _scatterSeries: {
        void root._rows
        if (!root.model || root._xCol < 0 || root._yCol < 0) return []
        const xs = root.model.columnValues(root._xCol)
        const ys = root.model.columnValues(root._yCol)
        const pts = []
        const n = Math.min(xs.length, ys.length)
        for (let i = 0; i < n; i++) {
            const xn = Number(xs[i]), yn = Number(ys[i])
            if (!isNaN(xn) && !isNaN(yn)) pts.push({ x: xn, y: yn })
        }
        return [{ label: root._cols[root._yCol] ?? "", color: Theme.primary, points: pts }]
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ── Controls ──────────────────────────────────────────────────────────
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

                SegmentedControl {
                    id: _typeSeg
                    model: ["Bar", "Line", "Area", "Scatter"]
                    currentIndex: 0
                    onSelectionChanged: (index) => root._type = index
                }

                Item { Layout.fillWidth: true }

                Text {
                    text: "X"
                    color: Theme.textSecondary
                    font { family: Theme.fontFamily; pixelSize: Theme.textSm; weight: Theme.weightMedium }
                }
                Dropdown {
                    id: _xDrop
                    Layout.preferredWidth: 160
                    model: root._cols
                    onCurrentIndexChanged: root._xCol = currentIndex
                }

                Text {
                    text: "Y"
                    color: Theme.textSecondary
                    font { family: Theme.fontFamily; pixelSize: Theme.textSm; weight: Theme.weightMedium }
                }
                Dropdown {
                    id: _yDrop
                    Layout.preferredWidth: 160
                    model: root._cols
                    onCurrentIndexChanged: root._yCol = currentIndex
                }
            }
        }

        // ── Plot ──────────────────────────────────────────────────────────────
        Item {
            Layout.fillWidth:  true
            Layout.fillHeight: true

            // Chart (only when we have data)
            Loader {
                anchors.fill:    parent
                anchors.margins: Theme.sp4
                active:  root._ready
                visible: root._ready
                sourceComponent: root._type === 0 ? _barComp
                               : root._type === 3 ? _scatterComp
                               : _areaComp
            }

            // Empty / prompt state
            EmptyState {
                anchors.centerIn: parent
                visible: !root._ready
                icon:    Icons.chartBar
                title:   root.hasRun ? "Nothing to plot" : "Run a query to chart it"
                description: root.hasRun
                    ? "This result has no rows. Charts plot the rows currently in view."
                    : "Results become a chart here — pick an X and Y column above."
            }
        }
    }

    // ── Chart component variants ──────────────────────────────────────────────
    Component {
        id: _barComp
        BarChart { series: root._series; xLabels: root._xLabels }
    }
    Component {
        id: _areaComp
        AreaChart {
            series:      root._series
            xLabels:     root._xLabels
            fillOpacity: root._type === 2 ? 0.25 : 0.0   // Area vs Line
        }
    }
    Component {
        id: _scatterComp
        ScatterPlot {
            series: root._scatterSeries
            xLabel: root._cols[root._xCol] ?? ""
            yLabel: root._cols[root._yCol] ?? ""
        }
    }
}
