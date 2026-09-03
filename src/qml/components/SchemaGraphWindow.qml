pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Mahina
import Qub

Window {
    id: root

    // ── API ──────────────────────────────────────────────────────────────────
    property string connectionName: ""
    property string schemaName:     ""

    // One schema at a time. A whole connection was the old scope and it is the
    // one that cannot be drawn: a database with hundreds of tables produces a
    // picture with no readable label in it, laid out by a simulation that
    // compares every table against every other table on the GUI thread.
    function openFor(connection: var, schema: var): void {
        connectionName = connection
        schemaName     = schema
        _relatedOnly   = false
        _graph.resetView()
        _buildGraph()
        show()
        raise()
        requestActivate()
    }

    // ── Internal state ────────────────────────────────────────────────────────
    property var  _nodes:        []
    property var  _edges:        []
    property int  _tableCount:   0   // tables in the schema, drawn or not
    property int  _relatedCount: 0   // of those, the ones with a foreign key
    property bool _relatedOnly:  false
    property bool _tooMany:      false

    // Past this the graph stops being a diagram and becomes a texture, and the
    // layout — quadratic in the node count, on the GUI thread — makes the
    // window stop repainting while it settles.
    readonly property int _maxNodes: 150

    function _buildGraph(): void {
        _nodes        = []
        _edges        = []
        _tableCount   = 0
        _relatedCount = 0
        _tooMany      = false
        if (!connectionName || !schemaName) return

        const schemas = ConnectionManager.schemas(connectionName)
        const entry   = schemas.find(s => s.name === root.schemaName)
        const tables  = entry ? (entry.tables ?? []) : []
        _tableCount   = tables.length
        if (tables.length === 0) return

        const inSchema = {}
        tables.forEach(t => { inSchema[t.name] = true })

        // Foreign keys with both ends in this schema. One pair of tables can be
        // joined by several columns; the graph only says "related", so those
        // collapse into one line rather than a bundle of identical ones.
        const related = {}
        const pairs   = {}
        DatabaseInspector.foreignKeys(connectionName).forEach(fk => {
            if (fk.fromSchema !== root.schemaName || fk.toSchema !== root.schemaName) return
            if (!inSchema[fk.fromTable] || !inSchema[fk.toTable]) return
            if (fk.fromTable === fk.toTable) return
            related[fk.fromTable] = true
            related[fk.toTable]   = true
            pairs[fk.fromTable + " " + fk.toTable] = true
        })
        _relatedCount = Object.keys(related).length

        const drawn = _relatedOnly ? tables.filter(t => related[t.name]) : tables
        if (drawn.length > _maxNodes) { _tooMany = true; return }

        const idx = {}
        drawn.forEach((t, i) => { idx[t.name] = i })

        _nodes = drawn.map(t => ({
            id:    idx[t.name],
            label: t.name,
            color: related[t.name] ? Theme.primary : Theme.textDisabled
        }))
        _edges = Object.keys(pairs)
            .map(key => {
                const ends = key.split(" ")
                return { source: idx[ends[0]], target: idx[ends[1]] }
            })
            .filter(e => e.source !== undefined && e.target !== undefined)
    }

    // ── Window chrome ─────────────────────────────────────────────────────────
    title:        "Schema Graph" + (schemaName ? " — " + schemaName : "")
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
                    text:  root.schemaName
                    color: Theme.textPrimary
                    font { family: Theme.fontFamily; pixelSize: Theme.textSm; weight: Theme.weightSemibold }
                }

                Text {
                    text:  root.connectionName
                    color: Theme.textDisabled
                    font { family: Theme.fontFamily; pixelSize: Theme.textXs }
                }

                Rectangle { width: 1; height: 16; color: Theme.border; Layout.alignment: Qt.AlignVCenter }

                // Legend
                Row {
                    spacing: 16
                    Layout.alignment: Qt.AlignVCenter
                    visible: root._nodes.length > 0

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
                    text:    root._nodes.length + " tables · " + root._edges.length + " relations"
                    visible: root._nodes.length > 0
                    color:   Theme.textDisabled
                    font { family: Theme.fontFamily; pixelSize: Theme.textXs }
                }

                Rectangle {
                    width: 1; height: 16
                    color: Theme.border
                    visible: root._nodes.length > 0
                    Layout.alignment: Qt.AlignVCenter
                }

                // Zoom. The graph pans by dragging and zooms on the wheel; these
                // are for the people who look for buttons.
                Button {
                    iconOnly: true
                    iconName: Icons.magnifyingGlassMinus
                    size:     Button.Size.Sm
                    variant:  Button.Variant.Ghost
                    visible:  root._nodes.length > 0
                    onClicked: _graph.zoomBy(1 / 1.25)
                }
                Button {
                    iconOnly: true
                    iconName: Icons.magnifyingGlassPlus
                    size:     Button.Size.Sm
                    variant:  Button.Variant.Ghost
                    visible:  root._nodes.length > 0
                    onClicked: _graph.zoomBy(1.25)
                }
                Button {
                    text:     "Fit"
                    size:     Button.Size.Sm
                    variant:  Button.Variant.Ghost
                    visible:  root._nodes.length > 0
                    onClicked: _graph.resetView()
                }

                Button {
                    text:     "Refresh"
                    iconName: Icons.arrowClockwise
                    size:     Button.Size.Sm
                    variant:  Button.Variant.Ghost
                    onClicked: root._buildGraph()
                }
            }
        }

        // ── Graph area ────────────────────────────────────────────────────────
        Item {
            Layout.fillWidth:  true
            Layout.fillHeight: true

            // Empty state — no tables at all
            EmptyState {
                anchors.centerIn: parent
                visible:     root._tableCount === 0
                icon:        Icons.graph
                title:       "No tables in this schema"
                description: "Nothing to relate: " + root.schemaName + " holds no tables."
            }

            // Empty state — too many to draw. Refusing is the useful answer: a
            // graph of several hundred tables is a grey texture, and drawing it
            // costs the window seconds of not repainting. Where the tables that
            // do have foreign keys would fit, that subset is offered instead —
            // it is usually the part anybody wanted to see.
            EmptyState {
                anchors.centerIn: parent
                visible:     root._tooMany
                icon:        Icons.graph
                title:       "Too many tables to draw"
                description: root.schemaName + " has " + root._tableCount + " tables. Above "
                             + root._maxNodes + " the graph is unreadable and slow to lay out."
                action:      root._relatedCount > 0 && root._relatedCount <= root._maxNodes
                             ? "Show only the " + root._relatedCount + " related tables" : ""
                onActionClicked: { root._relatedOnly = true; root._buildGraph() }
            }

            // Graph
            NetworkGraph {
                id: _graph
                anchors.fill: parent
                visible:  root._nodes.length > 0
                nodes:    root._nodes
                edges:    root._edges
                nodeRadius: 18
                edgeColor:  Theme.border
                onNodeSelected: (node) => _tooltip.show(node.label)
            }

            // Drawing the related subset says so, and offers the way back.
            Rectangle {
                visible: root._relatedOnly && root._nodes.length > 0
                anchors { top: parent.top; horizontalCenter: parent.horizontalCenter; topMargin: 12 }
                width:  _subsetRow.implicitWidth + 24
                height: 32
                radius: Theme.radiusSm
                color:  Theme.surface
                border.color: Theme.border

                RowLayout {
                    id: _subsetRow
                    anchors.centerIn: parent
                    spacing: 10

                    Text {
                        text:  "Showing the " + root._nodes.length + " tables that have foreign keys, of "
                               + root._tableCount
                        color: Theme.textSecondary
                        font { family: Theme.fontFamily; pixelSize: Theme.textXs }
                    }
                    Button {
                        text:    "Show all"
                        size:    Button.Size.Sm
                        variant: Button.Variant.Ghost
                        onClicked: { root._relatedOnly = false; root._buildGraph() }
                    }
                }
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
