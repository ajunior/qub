pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Mahina
import Qub

// Renders a normalised query plan from DatabaseInspector.explain() as an indented
// tree of operation nodes, with per-node metric chips, hot-node highlighting and
// tuning warnings. The tree is flattened to a depth-tagged list so a plain
// Repeater can draw it (QML recursion is avoided). See project memory for shape.
Rectangle {
    id: root

    property var    plan:    null    // explain() result map, or null
    property bool   loading: false
    // The raw statement the plan is for; drives whether ANALYZE is offered
    // (it *executes* the query, so read-only statements only).
    property string sql:     ""

    // Ask the host to (re-)run EXPLAIN; analyze=true uses EXPLAIN ANALYZE.
    signal runRequested(bool analyze)

    color: Theme.surface

    readonly property bool _ok:      plan && plan.success === true
    readonly property var  _warns:   _ok && plan.warnings ? plan.warnings : []
    readonly property bool _analyzeable: {
        const s = root.sql.trim()
        return /^\s*(select|with)\b/i.test(s)
    }

    // Flatten the plan tree into [{depth, node}] for a flat Repeater.
    readonly property var _flat: {
        if (!root._ok || !plan.root) return []
        const out = []
        const walk = (n, depth) => {
            out.push({ depth: depth, node: n })
            const kids = n.children || []
            for (var i = 0; i < kids.length; ++i) walk(kids[i], depth + 1)
        }
        walk(plan.root, 0)
        return out
    }

    // ── Empty / error states ────────────────────────────────────────────────
    EmptyState {
        anchors.centerIn: parent
        visible: !root._ok && !(root.plan && root.plan.success === false)
        icon:    Icons.lightning
        title:   "Explain a query"
        description: "Press " + KeyLabels.sequence("Ctrl+E")
                     + " (or the Explain button) to see how the database will run "
                     + "the current statement — scan types, join order, costs and hot spots."
    }

    Alert {
        anchors { left: parent.left; right: parent.right; top: parent.top
                  margins: Theme.sp3 }
        visible: root.plan && root.plan.success === false
        type:    Alert.Type.Error
        message: root.plan && root.plan.error ? root.plan.error : ""
    }

    // ── Plan ────────────────────────────────────────────────────────────────
    ColumnLayout {
        anchors.fill: parent
        visible: root._ok
        spacing: 0

        // Toolbar
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 34
            color: Theme.panel
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.border }

            RowLayout {
                anchors { fill: parent; leftMargin: Theme.sp3; rightMargin: Theme.sp2 }
                spacing: Theme.sp2

                Badge {
                    text: root._ok ? root.plan.driver : ""
                    colorScheme: Badge.Color.Default
                }
                Badge {
                    text: root._ok && root.plan.analyzed ? "measured" : "estimated"
                    colorScheme: root._ok && root.plan.analyzed ? Badge.Color.Success : Badge.Color.Info
                }

                Item { Layout.fillWidth: true }

                Tooltip {
                    text: root._analyzeable
                          ? "Run EXPLAIN ANALYZE — executes the query for real timings"
                          : "ANALYZE runs the statement, so it's limited to SELECT/WITH"
                    Button {
                        text:     "Analyze"
                        size:     Button.Size.Sm
                        variant:  Button.Variant.Outlined
                        enabled:  root._analyzeable && !root.loading
                        onClicked: root.runRequested(true)
                    }
                }
                Tooltip {
                    text: "Re-run EXPLAIN"
                    Button {
                        iconOnly: true
                        iconName: Icons.arrowClockwise
                        size:     Button.Size.Sm
                        variant:  Button.Variant.Ghost
                        enabled:  !root.loading
                        onClicked: root.runRequested(false)
                    }
                }
            }
        }

        ScrollArea {
            id: _scroll
            Layout.fillWidth:  true
            Layout.fillHeight: true

            ColumnLayout {
                width: _scroll.width
                spacing: 0

                // Tuning warnings
                Repeater {
                    model: root._warns
                    delegate: RowLayout {
                        id: _warnRow
                        required property var modelData
                        Layout.fillWidth:  true
                        Layout.leftMargin: Theme.sp3
                        Layout.rightMargin: Theme.sp3
                        Layout.topMargin:  Theme.sp2
                        spacing: Theme.sp2

                        Icon {
                            name:  Icons.warning
                            size:  14
                            color: Theme.warning
                        }
                        Text {
                            Layout.fillWidth: true
                            text:  _warnRow.modelData
                            color: Theme.textSecondary
                            wrapMode: Text.WordWrap
                            font { family: Theme.fontFamily; pixelSize: Theme.textXs }
                        }
                    }
                }

                Item { Layout.preferredHeight: Theme.sp2 }

                // Plan nodes (flattened, depth-indented)
                Repeater {
                    model: root._flat

                    delegate: Rectangle {
                        id: _row
                        required property var modelData
                        readonly property var  node:  modelData.node
                        readonly property int  depth: modelData.depth
                        readonly property bool hot:   node.hot === true

                        Layout.fillWidth: true
                        Layout.preferredHeight: _rowContent.implicitHeight + Theme.sp3
                        color: hot ? Qt.rgba(Theme.warning.r, Theme.warning.g, Theme.warning.b, 0.07)
                                   : "transparent"

                        // Hot-node accent bar
                        Rectangle {
                            visible: _row.hot
                            anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
                            width: 2
                            color: Theme.warning
                        }

                        RowLayout {
                            id: _rowContent
                            anchors {
                                left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter
                                leftMargin: Theme.sp3 + _row.depth * Theme.sp4
                                rightMargin: Theme.sp3
                            }
                            spacing: Theme.sp2

                            // Tree branch marker
                            Text {
                                visible: _row.depth > 0
                                text:  "└"
                                color: Theme.textDisabled
                                font { family: Theme.fontFamilyMono; pixelSize: Theme.textSm }
                            }

                            Text {
                                text:  _row.node.label
                                color: _row.hot ? Theme.warning : Theme.textPrimary
                                font { family: Theme.fontFamilyMono; pixelSize: Theme.textSm; weight: Theme.weightSemibold }
                            }
                            Text {
                                visible: (_row.node.detail || "") !== ""
                                text:  _row.node.detail
                                color: Theme.textSecondary
                                elide: Text.ElideRight
                                Layout.maximumWidth: 260
                                font { family: Theme.fontFamilyMono; pixelSize: Theme.textXs }
                            }

                            Item { Layout.fillWidth: true }

                            // Metric chips
                            Repeater {
                                model: _row.node.metrics || []
                                delegate: Rectangle {
                                    id: _chipCell
                                    required property var modelData
                                    implicitWidth:  _chip.implicitWidth + Theme.sp3
                                    implicitHeight: 18
                                    radius: Theme.radiusSm
                                    color:  Theme.surfaceVariant
                                    Row {
                                        id: _chip
                                        anchors.centerIn: parent
                                        spacing: 3
                                        Text {
                                            text:  _chipCell.modelData.key
                                            color: Theme.textDisabled
                                            font { family: Theme.fontFamilyMono; pixelSize: Theme.textXs }
                                        }
                                        Text {
                                            text:  _chipCell.modelData.value
                                            color: Theme.textSecondary
                                            font { family: Theme.fontFamilyMono; pixelSize: Theme.textXs; weight: Theme.weightMedium }
                                        }
                                    }
                                }
                            }
                        }

                        Rectangle {
                            anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
                            height: 1
                            color: Theme.border
                            opacity: 0.5
                        }
                    }
                }

                Item { Layout.preferredHeight: Theme.sp3 }
            }
        }
    }
}
