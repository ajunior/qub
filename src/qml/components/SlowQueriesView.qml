pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Mahina
import Qub

// Slow-query insights: aggregates HistoryManager executions by a normalised
// SQL fingerprint, ranked by total time spent. Hosted as the "Slow queries"
// tab of the detached activity window (Ctrl+L). Sizes to its parent.
Item {
    id: root

    signal openSqlInEditor(string sql)

    // Right-aligned monospace cell for the numeric columns.
    component NumCell: Text {
        horizontalAlignment: Text.AlignRight
        verticalAlignment:   Text.AlignVCenter
        color: Theme.textSecondary
        font { family: Theme.fontFamilyMono; pixelSize: Theme.textSm }
        Layout.alignment: Qt.AlignVCenter
    }

    // Right-aligned header label for the numeric columns.
    component HeadCell: Text {
        color: Theme.textDisabled
        font { family: Theme.fontFamily; pixelSize: Theme.textXs; weight: Theme.weightSemibold }
        horizontalAlignment: Text.AlignRight
        verticalAlignment:   Text.AlignVCenter
        Layout.alignment: Qt.AlignVCenter
    }

    // Bumped on HistoryManager.changed so the aggregate recomputes.
    property int    _rev:        0
    property string _connFilter: ""

    Connections {
        target: HistoryManager
        function onChanged() { root._rev++ }
    }

    // Distinct connections seen across all groups, for the filter dropdown.
    readonly property var _allConns: {
        root._rev
        var names = [], seen = {}
        var groups = HistoryManager.slowQueries(500)
        for (var i = 0; i < groups.length; i++) {
            var n = groups[i].connectionName ?? ""
            if (n !== "" && !seen[n]) { seen[n] = true; names.push(n) }
        }
        return names
    }

    readonly property var _rows: {
        root._rev
        return HistoryManager.slowQueries(50, root._connFilter)
    }

    function _fmtMs(v: var): var {
        var n = Number(v)
        if (n >= 1000) return (n / 1000).toFixed(n >= 10000 ? 0 : 1) + "s"
        return Math.round(n) + "ms"
    }

    function _relative(iso: var): var {
        if (!iso) return "—"
        var then = new Date(iso).getTime()
        if (isNaN(then)) return iso
        var secs = Math.max(0, Math.floor((Date.now() - then) / 1000))
        if (secs < 60)    return secs + "s ago"
        var mins = Math.floor(secs / 60)
        if (mins < 60)    return mins + "m ago"
        var hrs = Math.floor(mins / 60)
        if (hrs < 24)     return hrs + "h ago"
        return Math.floor(hrs / 24) + "d ago"
    }

    // Column widths (Query column flexes; the rest are fixed).
    readonly property int _wCalls:  64
    readonly property int _wTime:   86
    readonly property int _wFail:   64
    readonly property int _wLast:   96
    readonly property int _rowH:    34

    ColumnLayout {
        anchors.fill: parent
        spacing:      0

        // ── Toolbar ───────────────────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            height:           48
            color:            Theme.panel
            border.color:     Theme.border
            border.width:     1

            RowLayout {
                anchors { fill: parent; leftMargin: Theme.sp3; rightMargin: Theme.sp3 }
                spacing: Theme.sp2

                Icon { name: Icons.timer; size: 15; color: Theme.textSecondary }
                Text {
                    text:  "Ranked by total time"
                    color: Theme.textSecondary
                    font { family: Theme.fontFamily; pixelSize: Theme.textXs }
                    Layout.alignment: Qt.AlignVCenter
                }

                Rectangle { width: 1; height: 20; color: Theme.border; Layout.alignment: Qt.AlignVCenter }

                Dropdown {
                    implicitWidth: 160
                    label:         ""
                    placeholder:   "All connections"
                    model:          ["All connections"].concat(root._allConns)
                    currentIndex: {
                        if (root._connFilter === "") return 0
                        var idx = root._allConns.indexOf(root._connFilter)
                        return idx === -1 ? 0 : idx + 1
                    }
                    Layout.alignment: Qt.AlignVCenter
                    onCurrentIndexChanged: {
                        root._connFilter = currentIndex === 0 ? "" : (root._allConns[currentIndex - 1] ?? "")
                    }
                }

                Item { Layout.fillWidth: true }

                Text {
                    text:  root._rows.length + (root._rows.length === 1 ? " group" : " groups")
                    color: Theme.textDisabled
                    font { family: Theme.fontFamily; pixelSize: Theme.textXs }
                    Layout.alignment: Qt.AlignVCenter
                }
            }
        }

        // ── Column header ─────────────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            height:           28
            color:            Theme.surfaceVariant
            border.color:     Theme.border
            border.width:     1
            visible:          root._rows.length > 0

            RowLayout {
                anchors { fill: parent; leftMargin: Theme.sp3; rightMargin: Theme.sp3 }
                spacing: 0

                HeadCell { text: "Query"; horizontalAlignment: Text.AlignLeft; Layout.fillWidth: true }
                HeadCell { text: "Calls"; Layout.preferredWidth: root._wCalls }
                HeadCell { text: "Total"; Layout.preferredWidth: root._wTime  }
                HeadCell { text: "Avg";   Layout.preferredWidth: root._wTime  }
                HeadCell { text: "Max";   Layout.preferredWidth: root._wTime  }
                HeadCell { text: "Fails"; Layout.preferredWidth: root._wFail  }
                HeadCell { text: "Last";  Layout.preferredWidth: root._wLast  }
            }
        }

        // ── Rows ──────────────────────────────────────────────────────────────
        ListView {
            id: _list
            Layout.fillWidth:  true
            Layout.fillHeight: true
            clip:              true
            model:             root._rows
            visible:           root._rows.length > 0
            boundsBehavior:    Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar {}

            delegate: Rectangle {
                id: rowItem
                required property var  modelData
                required property int  index

                width:  _list.width
                height: root._rowH
                color:  _hover.hovered ? Theme.surfaceVariant
                                       : (index % 2 === 0 ? Theme.surface : Theme.panel)

                HoverHandler { id: _hover }
                TapHandler {
                    onTapped: if ((rowItem.modelData.sql ?? "") !== "") root.openSqlInEditor(rowItem.modelData.sql)
                }

                RowLayout {
                    anchors { fill: parent; leftMargin: Theme.sp3; rightMargin: Theme.sp3 }
                    spacing: 0

                    // Query fingerprint (single-line) + connection sub-label
                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignVCenter
                        spacing: 0
                        Text {
                            text:     (rowItem.modelData.sql ?? "").replace(/\s+/g, " ").trim()
                            color:    Theme.textPrimary
                            font { family: Theme.fontFamilyMono; pixelSize: Theme.textSm }
                            elide:    Text.ElideRight
                            maximumLineCount: 1
                            Layout.fillWidth: true
                        }
                        Text {
                            text:     rowItem.modelData.connectionName ?? ""
                            visible:  root._connFilter === "" && (rowItem.modelData.connectionName ?? "") !== ""
                            color:    Theme.textDisabled
                            font { family: Theme.fontFamily; pixelSize: Theme.textXs }
                            elide:    Text.ElideRight
                            Layout.fillWidth: true
                        }
                    }

                    NumCell { text: String(rowItem.modelData.calls ?? 0);      Layout.preferredWidth: root._wCalls }
                    NumCell {
                        text: root._fmtMs(rowItem.modelData.totalMs ?? 0)
                        color: Theme.textPrimary
                        Layout.preferredWidth: root._wTime
                    }
                    NumCell { text: root._fmtMs(rowItem.modelData.avgMs ?? 0);  Layout.preferredWidth: root._wTime }
                    NumCell { text: root._fmtMs(rowItem.modelData.maxMs ?? 0);  Layout.preferredWidth: root._wTime }
                    NumCell {
                        text:  String(rowItem.modelData.failures ?? 0)
                        color: (rowItem.modelData.failures ?? 0) > 0 ? Theme.error : Theme.textDisabled
                        Layout.preferredWidth: root._wFail
                    }
                    NumCell {
                        text:  root._relative(rowItem.modelData.lastExecutedAt ?? "")
                        color: Theme.textDisabled
                        Layout.preferredWidth: root._wLast
                    }
                }

                Rectangle { anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                            height: 1; color: Theme.border; opacity: 0.5 }
            }
        }

        // ── Empty state ───────────────────────────────────────────────────────
        EmptyState {
            Layout.fillWidth:  true
            Layout.fillHeight: true
            visible:     root._rows.length === 0
            icon:        Icons.timer
            iconSize:    40
            title:       root._connFilter === "" ? "No query history yet"
                                                  : "No queries for this connection"
            description: "Run some queries and their timings will be ranked here by total time spent."
        }
    }
}
