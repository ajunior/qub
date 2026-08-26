pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Mahina
import Qub

Window {
    id: root

    // ── API ──────────────────────────────────────────────────────────────────
    property string connectionName: ""

    function openFor(name: var): void {
        connectionName = name
        _buildGraph()
        show()
        raise()
        requestActivate()
    }

    // ── Internal state ────────────────────────────────────────────────────────
    property var _nodes: []
    property var _edges: []

    function _buildGraph(): void {
        const schema = ConnectionManager.schema(connectionName)
        if (!schema || schema.length === 0) {
            _nodes = []
            _edges = []
            return
        }

        // Map table name → index for edge building
        const tableIdx = {}
        schema.forEach((t, i) => { tableIdx[t.name] = i })

        // Edges from FK relationships
        const fks = DatabaseInspector.foreignKeys(connectionName)
        const connected = new Set()
        const edgeList  = []
        fks.forEach(fk => {
            const s = tableIdx[fk.fromTable]
            const t = tableIdx[fk.toTable]
            if (s !== undefined && t !== undefined && s !== t) {
                edgeList.push({ source: s, target: t })
                connected.add(s)
                connected.add(t)
            }
        })

        // Nodes — connected tables get primary colour, isolated ones are muted
        const nodeList = schema.map((t, i) => ({
            id:    i,
            label: t.name,
            color: connected.has(i) ? Theme.primary : Theme.textDisabled
        }))

        _nodes = nodeList
        _edges = edgeList
    }

    // ── Window chrome ─────────────────────────────────────────────────────────
    title:        "Schema Graph" + (connectionName ? " — " + connectionName : "")
    width:        1000
    height:       680
    minimumWidth: 640
    minimumHeight:440
    color:        Theme.background
    flags:        Qt.Window | Qt.WindowCloseButtonHint | Qt.WindowMinMaxButtonsHint

    // ── Layout ────────────────────────────────────────────────────────────────
    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ── Header bar ────────────────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            height: 44
            color:  Theme.surface
            border.color: Theme.border

            RowLayout {
                anchors { fill: parent; leftMargin: 16; rightMargin: 16 }
                spacing: 12

                Icon {
                    name:             Icons.graph
                    size:             16
                    color:            Theme.textSecondary
                    Layout.alignment: Qt.AlignVCenter
                }

                Text {
                    text:  root.connectionName
                    color: Theme.textPrimary
                    font { family: Theme.fontFamily; pixelSize: Theme.textSm; weight: Theme.weightSemibold }
                }

                Rectangle { width: 1; height: 16; color: Theme.border; Layout.alignment: Qt.AlignVCenter }

                // Legend
                Row {
                    spacing: 16
                    Layout.alignment: Qt.AlignVCenter

                    Row {
                        spacing: 6
                        Rectangle {
                            width: 10; height: 10; radius: 5
                            color: Theme.primary
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        Text {
                            text:  "Connected"
                            color: Theme.textSecondary
                            font { family: Theme.fontFamily; pixelSize: Theme.textXs }
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    Row {
                        spacing: 6
                        Rectangle {
                            width: 10; height: 10; radius: 5
                            color: Theme.textDisabled
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        Text {
                            text:  "No relations"
                            color: Theme.textSecondary
                            font { family: Theme.fontFamily; pixelSize: Theme.textXs }
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                }

                Item { Layout.fillWidth: true }

                Text {
                    text:  root._nodes.length + " tables · " + root._edges.length + " relations"
                    color: Theme.textDisabled
                    font { family: Theme.fontFamily; pixelSize: Theme.textXs }
                }

                Rectangle { width: 1; height: 16; color: Theme.border; Layout.alignment: Qt.AlignVCenter }

                Button {
                    text:    "Refresh"
                    iconName: Icons.arrowClockwise
                    size:    Button.Size.Sm
                    variant: Button.Variant.Ghost
                    onClicked: root._buildGraph()
                }
            }
        }

        // ── Graph area ────────────────────────────────────────────────────────
        Item {
            Layout.fillWidth:  true
            Layout.fillHeight: true

            // Empty state — no tables
            EmptyState {
                anchors.centerIn: parent
                visible:     root._nodes.length === 0
                icon:        Icons.graph
                title:       "No tables found"
                description: "Connect to a database with tables to see the schema graph."
            }

            // Graph
            NetworkGraph {
                anchors.fill: parent
                visible:  root._nodes.length > 0
                nodes:    root._nodes
                edges:    root._edges
                nodeRadius: 18
                edgeColor:  Theme.border
                onNodeSelected: (node) => _tooltip.show(node.label)
            }

            // Node label tooltip on click
            Rectangle {
                id: _tooltip
                visible:      false
                color:        Theme.surface
                border.color: Theme.border
                radius:       Theme.radiusSm
                width:  _tooltipText.implicitWidth + 16
                height: 28
                anchors { bottom: parent.bottom; horizontalCenter: parent.horizontalCenter; bottomMargin: 12 }

                property string _label: ""
                function show(label: var): void {
                    _label   = label
                    visible  = true
                    _hideTimer.restart()
                }

                Timer {
                    id:       _hideTimer
                    interval: 2000
                    onTriggered: _tooltip.visible = false
                }

                Text {
                    id:   _tooltipText
                    anchors.centerIn: parent
                    text:  _tooltip._label
                    color: Theme.textPrimary
                    font { family: Theme.fontFamilyMono; pixelSize: Theme.textSm }
                }
            }
        }
    }
}
