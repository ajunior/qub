pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Mahina

// df.describe()-style profile of the active result set: one card per column with
// type, null/distinct counts and a distribution (histogram for numeric columns,
// top-value frequency bars for text). Data comes from ResultModel::profile()
// over the rows currently in view, so it tracks the active filter.
Rectangle {
    id: root

    property var  model:  null   // ResultModel
    property bool hasRun: false

    color: Theme.surface

    readonly property int  _rows:    root.model ? root.model.count : 0
    readonly property var  _profile: {
        void root._rows                         // recompute when data/filter changes
        return (root.model && root._rows > 0) ? root.model.profile() : []
    }
    readonly property bool _ready: _profile.length > 0

    function _fmt(x: var): var {
        var n = Number(x)
        if (!isFinite(n)) return String(x)
        if (Math.abs(n - Math.round(n)) < 1e-9)
            return Math.round(n).toLocaleString(Qt.locale(), 'f', 0)
        return (Math.round(n * 1000) / 1000).toString()
    }
    function _pct(part: var, whole: var): var {
        return whole > 0 ? Math.round((part / whole) * 100) : 0
    }

    // ── Empty state ───────────────────────────────────────────────────────────
    EmptyState {
        anchors.centerIn: parent
        visible: !root._ready
        icon:    Icons.chartBar
        title:   root.hasRun ? "Nothing to profile" : "Run a query to profile it"
        description: root.hasRun
            ? "This result has no rows. The profile summarises the rows currently in view."
            : "A per-column summary — types, nulls, distinct counts and distributions — appears here."
    }

    // ── Column cards ──────────────────────────────────────────────────────────
    ScrollArea {
        id: _scroll
        anchors.fill: parent
        visible: root._ready

        ColumnLayout {
            width: _scroll.width
            spacing: Theme.sp3

            Item { Layout.preferredHeight: Theme.sp1 }   // top breathing room

            Repeater {
                model: root._profile

                delegate: Rectangle {
                    id: _card
                    required property var modelData
                    readonly property var  p:         modelData
                    readonly property int  _total:    (p.count ?? 0) + (p.nulls ?? 0)
                    readonly property int  colIndex:  index
                    required property int  index

                    Layout.fillWidth:      true
                    Layout.leftMargin:     Theme.sp3
                    Layout.rightMargin:    Theme.sp3
                    implicitHeight:        _cardCol.implicitHeight + Theme.sp4 * 2
                    color:                 Theme.panel
                    radius:                Theme.radiusMd
                    border.color:          Theme.border
                    border.width:          1

                    ColumnLayout {
                        id: _cardCol
                        anchors { left: parent.left; right: parent.right; top: parent.top
                                  margins: Theme.sp4 }
                        spacing: Theme.sp3

                        // ── Header: name + type + null/distinct ──────────────
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.sp2

                            Text {
                                text: _card.p.column ?? ""
                                color: Theme.textPrimary
                                font { family: Theme.fontFamilyMono; pixelSize: Theme.textBase; weight: Theme.weightSemibold }
                                elide: Text.ElideRight
                                Layout.fillWidth: true
                            }

                            Badge {
                                text: _card.p.type ?? ""
                                pill: true
                                colorScheme: _card.p.type === "numeric" ? Badge.Color.Info
                                           : _card.p.type === "text"    ? Badge.Color.Default
                                           :                              Badge.Color.Warning
                            }
                        }

                        // ── Scalar stats row ─────────────────────────────────
                        Flow {
                            Layout.fillWidth: true
                            spacing: Theme.sp5

                            Repeater {
                                model: _card._statItems()
                                delegate: Column {
                                    id: _st
                                    required property var modelData
                                    spacing: 1
                                    Text {
                                        text: _st.modelData.label
                                        color: Theme.textDisabled
                                        font { family: Theme.fontFamily; pixelSize: Theme.textXs }
                                    }
                                    Text {
                                        text: _st.modelData.value
                                        color: Theme.textPrimary
                                        font { family: Theme.fontFamilyMono; pixelSize: Theme.textSm; weight: Theme.weightMedium }
                                    }
                                }
                            }
                        }

                        // ── Distribution: numeric histogram ──────────────────
                        Histogram {
                            visible: _card.p.type === "numeric"
                            Layout.fillWidth: true
                            Layout.preferredHeight: 110
                            bins: 12
                            color: Theme.primary
                            values: (_card.p.type === "numeric" && root.model)
                                    ? root.model.columnValues(_card.colIndex)
                                          .map(function(v) { return Number(v) })
                                          .filter(function(x) { return !isNaN(x) })
                                    : []
                        }

                        // ── Distribution: text top values ────────────────────
                        ColumnLayout {
                            visible: _card.p.type === "text" && (_card.p.topValues ?? []).length > 0
                            Layout.fillWidth: true
                            spacing: Theme.sp1

                            Text {
                                text: "Top values"
                                color: Theme.textDisabled
                                font { family: Theme.fontFamily; pixelSize: Theme.textXs }
                            }

                            Repeater {
                                model: _card.p.topValues ?? []
                                delegate: RowLayout {
                                    id: _tv
                                    required property var modelData
                                    Layout.fillWidth: true
                                    spacing: Theme.sp2

                                    Text {
                                        text: (_tv.modelData.value === "" ? "(empty)" : _tv.modelData.value)
                                        color: Theme.textSecondary
                                        font { family: Theme.fontFamilyMono; pixelSize: Theme.textXs }
                                        elide: Text.ElideRight
                                        Layout.preferredWidth: 140
                                    }

                                    // Frequency bar
                                    Rectangle {
                                        Layout.fillWidth: true
                                        height: 12
                                        radius: 3
                                        color: Theme.surfaceVariant
                                        Rectangle {
                                            anchors { left: parent.left; verticalCenter: parent.verticalCenter }
                                            height: parent.height
                                            radius: parent.radius
                                            width: parent.width * (_card._total > 0
                                                   ? _tv.modelData.count / _card._total : 0)
                                            color: Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.55)
                                        }
                                    }

                                    Text {
                                        text: root._fmt(_tv.modelData.count)
                                        color: Theme.textDisabled
                                        font { family: Theme.fontFamilyMono; pixelSize: Theme.textXs }
                                        Layout.preferredWidth: 48
                                        horizontalAlignment: Text.AlignRight
                                    }
                                }
                            }
                        }
                    }

                    // Build the scalar-stat chips for this column's type.
                    function _statItems(): var {
                        var items = [
                            { label: "count",    value: root._fmt(p.count ?? 0) },
                            { label: "nulls",    value: root._fmt(p.nulls ?? 0) + " (" + root._pct(p.nulls ?? 0, _total) + "%)" },
                            { label: "distinct", value: root._fmt(p.distinct ?? 0) },
                        ]
                        if (p.type === "numeric") {
                            items.push({ label: "min",    value: root._fmt(p.min) })
                            items.push({ label: "median", value: root._fmt(p.median) })
                            items.push({ label: "mean",   value: root._fmt(p.mean) })
                            items.push({ label: "max",    value: root._fmt(p.max) })
                        }
                        return items
                    }
                }
            }

            Item { Layout.preferredHeight: Theme.sp1 }   // bottom breathing room
        }
    }
}
