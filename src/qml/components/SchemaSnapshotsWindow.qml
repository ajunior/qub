pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Mahina
import Qub

// Detached schema-snapshot window. Capture a connection's schema to disk, then
// diff the *live* schema of a connection against a saved snapshot to catch
// drift over time — the single-connection counterpart to SchemaDiffWindow
// (which diffs two live connections). Reuses SchemaDiff::compare via
// SchemaSnapshotManager.diffLive().
Window {
    id: root

    title: "Schema Snapshots · qub"
    width: 980; height: 660
    minimumWidth: 720; minimumHeight: 440
    color: Theme.background
    flags: Qt.Window

    property int    _selectedId: -1
    property string _liveConn:   ""
    property string _captureConn: ""
    property string _captureName: ""
    property bool   _diffOnly:   true

    // Names of currently-connected connections (schemas() needs an open adapter).
    readonly property var _connNames: {
        var out = []
        var all = ConnectionManager.connections
        for (var i = 0; i < all.length; i++)
            if (all[i].connected) out.push(all[i].name)
        return out
    }

    readonly property var _snapshots: SchemaSnapshotManager.snapshots

    function openWith(baseConn: var): void {
        var names = root._connNames
        var base = (baseConn && names.indexOf(baseConn) !== -1) ? baseConn : (names[0] ?? "")
        root._captureConn = base
        root._liveConn    = base
        root._captureName = base !== "" ? base + " schema" : ""
        // Select the newest snapshot, if any.
        var snaps = root._snapshots
        root._selectedId = snaps.length > 0 ? snaps[0].id : -1
        show()
        raise()
        requestActivate()
    }

    readonly property bool _liveConnected: root._liveConn !== "" &&
                                           root._connNames.indexOf(root._liveConn) !== -1

    readonly property var _diff: {
        if (root._selectedId < 0 || !root._liveConnected) return null
        return SchemaSnapshotManager.diffLive(root._selectedId,
                                              ConnectionManager.schemas(root._liveConn))
    }

    function _relative(iso: var): var {
        if (!iso) return ""
        var t = Date.parse(iso)
        if (isNaN(t)) return iso
        var s = Math.floor((Date.now() - t) / 1000)
        if (s < 60)    return "just now"
        if (s < 3600)  return Math.floor(s / 60) + "m ago"
        if (s < 86400) return Math.floor(s / 3600) + "h ago"
        return Math.floor(s / 86400) + "d ago"
    }

    // ── Flatten the diff tree into renderable rows (same shape as SchemaDiffWindow) ──
    function _colDetail(c: var): var {
        function attr(a: var): var {
            if (!a) return ""
            var s = a.type
            if (a.pk) s += " · PK"
            if (!a.nullable) s += " · NOT NULL"
            return s
        }
        if (c.status === "added")   return attr(c.right)
        if (c.status === "removed") return attr(c.left)
        if (c.status === "changed") {
            var parts = [], ch = c.changes ?? []
            if (ch.indexOf("type") !== -1)
                parts.push(c.left.type + " → " + c.right.type)
            if (ch.indexOf("nullable") !== -1)
                parts.push((c.left.nullable ? "NULL" : "NOT NULL") + " → " +
                           (c.right.nullable ? "NULL" : "NOT NULL"))
            if (ch.indexOf("pk") !== -1)
                parts.push((c.left.pk ? "PK" : "no PK") + " → " + (c.right.pk ? "PK" : "no PK"))
            return parts.join(",  ")
        }
        return attr(c.right ?? c.left)
    }

    readonly property var _flat: {
        var diff = root._diff
        if (!diff) return []
        var only = root._diffOnly
        var rows = []
        var schemas = diff.schemas ?? []
        for (var i = 0; i < schemas.length; i++) {
            var s = schemas[i]
            if (only && s.status === "same") continue
            rows.push({ level: 0, kind: "schema", name: s.name, status: s.status, detail: "" })
            var tables = s.tables ?? []
            for (var j = 0; j < tables.length; j++) {
                var t = tables[j]
                if (only && t.status === "same") continue
                rows.push({ level: 1, kind: (t.type === "view" ? "view" : "table"),
                            name: t.name, status: t.status, detail: t.type ?? "" })
                var cols = t.columns ?? []
                for (var k = 0; k < cols.length; k++) {
                    var c = cols[k]
                    if (only && c.status === "same") continue
                    rows.push({ level: 2, kind: "column", name: c.name,
                                status: c.status, detail: root._colDetail(c) })
                }
            }
        }
        return rows
    }

    function _statusColor(s: var): var {
        if (s === "added")   return Theme.success
        if (s === "removed") return Theme.error
        if (s === "changed") return Theme.warning
        return Theme.textSecondary
    }
    function _statusMark(s: var): var {
        if (s === "added")   return "+"
        if (s === "removed") return "−"
        if (s === "changed") return "~"
        return "·"
    }

    readonly property var _badges: {
        var d = root._diff
        if (!d) return []
        var s = d.summary, out = []
        function add(n: var, label: var, scheme: var): void { if (n > 0) out.push({ text: n + " " + label, scheme: scheme }) }
        add(s.tablesAdded,    "tables +",  Badge.Color.Success)
        add(s.tablesRemoved,  "tables −",  Badge.Color.Error)
        add(s.tablesChanged,  "tables ~",  Badge.Color.Warning)
        add(s.columnsAdded,   "cols +",    Badge.Color.Success)
        add(s.columnsRemoved, "cols −",    Badge.Color.Error)
        add(s.columnsChanged, "cols ~",    Badge.Color.Warning)
        return out
    }

    RowLayout {
        anchors.fill: parent
        spacing:      0

        // ── Left: capture + snapshot list ─────────────────────────────────────
        Rectangle {
            Layout.preferredWidth: 280
            Layout.fillHeight:     true
            color:        Theme.panel
            border.color: Theme.border
            border.width: 1

            ColumnLayout {
                anchors.fill: parent
                spacing:      0

                // Capture controls
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: implicitHeight
                    implicitHeight: _capCol.implicitHeight + Theme.sp3 * 2
                    color:        Theme.surfaceVariant
                    border.color: Theme.border
                    border.width: 1

                    ColumnLayout {
                        id: _capCol
                        anchors { left: parent.left; right: parent.right; top: parent.top
                                  margins: Theme.sp3 }
                        spacing: Theme.sp2

                        Text {
                            text: "Capture snapshot"
                            color: Theme.textPrimary
                            font { family: Theme.fontFamily; pixelSize: Theme.textSm;
                                   weight: Theme.weightSemibold }
                        }
                        Dropdown {
                            Layout.fillWidth: true
                            placeholder:      "Connection"
                            model:            root._connNames
                            currentIndex:     root._connNames.indexOf(root._captureConn)
                            onCurrentIndexChanged: root._captureConn = root._connNames[currentIndex] ?? ""
                        }
                        Input {
                            Layout.fillWidth: true
                            text:             root._captureName
                            placeholderText:  "Snapshot name"
                            onTextChanged:    root._captureName = text
                        }
                        Button {
                            Layout.fillWidth: true
                            text:     "Capture"
                            iconName: Icons.camera
                            size:     Button.Size.Sm
                            enabled:  root._captureConn !== "" && root._captureName.trim() !== ""
                            onClicked: {
                                var id = SchemaSnapshotManager.capture(
                                    root._captureName.trim(), root._captureConn,
                                    ConnectionManager.schemas(root._captureConn))
                                if (id > 0) root._selectedId = id
                            }
                        }
                    }
                }

                // Snapshot list
                ListView {
                    id: _snapList
                    Layout.fillWidth:  true
                    Layout.fillHeight: true
                    clip:              true
                    model:             root._snapshots
                    boundsBehavior:    Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar {}

                    delegate: Rectangle {
                        id: delegateItem
                        required property var modelData
                        width:  _snapList.width
                        height: 52
                        color:  modelData.id === root._selectedId
                                ? Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.12)
                                : (_snapHover.hovered ? Theme.surface : "transparent")

                        HoverHandler { id: _snapHover }
                        TapHandler { onTapped: root._selectedId = delegateItem.modelData.id }

                        RowLayout {
                            anchors { fill: parent; leftMargin: Theme.sp3; rightMargin: Theme.sp2 }
                            spacing: Theme.sp2

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 2
                                Text {
                                    text: delegateItem.modelData.name
                                    color: Theme.textPrimary
                                    font { family: Theme.fontFamily; pixelSize: Theme.textSm;
                                           weight: Theme.weightSemibold }
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                }
                                Text {
                                    text: delegateItem.modelData.connectionName + " · " + delegateItem.modelData.tableCount +
                                          " tables · " + root._relative(delegateItem.modelData.capturedAt)
                                    color: Theme.textDisabled
                                    font { family: Theme.fontFamily; pixelSize: Theme.textXs }
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                }
                            }

                            Button {
                                iconOnly: true
                                iconName: Icons.trash
                                size:     Button.Size.Sm
                                variant:  Button.Variant.Ghost
                                onClicked: {
                                    var wasSel = delegateItem.modelData.id === root._selectedId
                                    SchemaSnapshotManager.remove(delegateItem.modelData.id)
                                    if (wasSel) {
                                        var snaps = root._snapshots
                                        root._selectedId = snaps.length > 0 ? snaps[0].id : -1
                                    }
                                }
                            }
                        }

                        Rectangle { anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                                    height: 1; color: Theme.border; opacity: 0.4 }
                    }

                    EmptyState {
                        anchors.centerIn: parent
                        width: parent.width - Theme.sp4 * 2
                        visible:  root._snapshots.length === 0
                        icon:     Icons.camera
                        iconSize: 32
                        title:    "No snapshots yet"
                        description: "Capture a connection's schema above to start tracking drift."
                    }
                }
            }
        }

        // ── Right: diff of live schema vs selected snapshot ───────────────────
        ColumnLayout {
            Layout.fillWidth:  true
            Layout.fillHeight: true
            spacing:           0

            // Toolbar
            Rectangle {
                Layout.fillWidth: true
                height:           52
                color:            Theme.panel
                border.color:     Theme.border
                border.width:     1

                RowLayout {
                    anchors { fill: parent; leftMargin: Theme.sp3; rightMargin: Theme.sp3 }
                    spacing: Theme.sp2

                    Text {
                        text: "Live"
                        color: Theme.textDisabled
                        font { family: Theme.fontFamily; pixelSize: Theme.textXs }
                        Layout.alignment: Qt.AlignVCenter
                    }
                    Dropdown {
                        implicitWidth: 200
                        placeholder:   "Connection"
                        model:         root._connNames
                        currentIndex:  root._connNames.indexOf(root._liveConn)
                        Layout.alignment: Qt.AlignVCenter
                        onCurrentIndexChanged: root._liveConn = root._connNames[currentIndex] ?? ""
                    }
                    Text {
                        text: "vs snapshot"
                        color: Theme.textDisabled
                        font { family: Theme.fontFamily; pixelSize: Theme.textXs }
                        Layout.alignment: Qt.AlignVCenter
                    }

                    Item { Layout.fillWidth: true }

                    Toggle {
                        checked:   root._diffOnly
                        onToggled: root._diffOnly = checked
                        text:      "Differences only"
                        Layout.alignment: Qt.AlignVCenter
                    }
                }
            }

            // Summary strip
            Rectangle {
                Layout.fillWidth: true
                height:           36
                color:            Theme.surfaceVariant
                border.color:     Theme.border
                border.width:     1
                visible:          root._diff !== null && root._diff.differs

                RowLayout {
                    anchors { fill: parent; leftMargin: Theme.sp3; rightMargin: Theme.sp3 }
                    spacing: Theme.sp2
                    Repeater {
                        model: root._badges
                        Badge {
                            required property var modelData
                            text:        modelData.text
                            colorScheme: modelData.scheme
                        }
                    }
                    Item { Layout.fillWidth: true }
                }
            }

            // Diff tree
            ListView {
                id: _tree
                Layout.fillWidth:  true
                Layout.fillHeight: true
                clip:              true
                model:             root._flat
                visible:           root._flat.length > 0
                boundsBehavior:    Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar {}

                delegate: Rectangle {
                    id: delegateItem2
                    required property var modelData
                    width:  _tree.width
                    height: modelData.kind === "column" ? 26 : 30
                    color:  modelData.kind === "schema" ? Theme.surfaceVariant
                          : (modelData.kind === "column" ? "transparent" : Theme.surface)

                    RowLayout {
                        anchors {
                            fill: parent
                            leftMargin:  Theme.sp3 + delegateItem2.modelData.level * 22
                            rightMargin: Theme.sp3
                        }
                        spacing: Theme.sp2

                        Text {
                            text:  root._statusMark(delegateItem2.modelData.status)
                            color: root._statusColor(delegateItem2.modelData.status)
                            font { family: Theme.fontFamilyMono; pixelSize: Theme.textSm;
                                   weight: Theme.weightBold }
                            Layout.preferredWidth: 12
                            horizontalAlignment: Text.AlignHCenter
                        }
                        Text {
                            text:  delegateItem2.modelData.name
                            color: delegateItem2.modelData.status === "removed" ? Theme.textSecondary : Theme.textPrimary
                            font {
                                family:    delegateItem2.modelData.kind === "column" ? Theme.fontFamilyMono : Theme.fontFamily
                                pixelSize: Theme.textSm
                                weight:    delegateItem2.modelData.kind === "column" ? Theme.weightRegular : Theme.weightSemibold
                            }
                            Layout.alignment: Qt.AlignVCenter
                        }
                        Badge {
                            visible:     delegateItem2.modelData.kind === "view"
                            text:        "view"
                            colorScheme: Badge.Color.Default
                        }
                        Text {
                            text:  delegateItem2.modelData.detail
                            color: root._statusColor(delegateItem2.modelData.status)
                            visible: delegateItem2.modelData.kind === "column" && delegateItem2.modelData.detail !== ""
                            font { family: Theme.fontFamilyMono; pixelSize: Theme.textXs }
                            Layout.alignment: Qt.AlignVCenter
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                        }
                        Item { Layout.fillWidth: true; visible: delegateItem2.modelData.kind !== "column" }
                    }

                    Rectangle { anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                                height: 1; color: Theme.border
                                opacity: delegateItem2.modelData.kind === "schema" ? 1 : 0.4 }
                }
            }

            // Empty / identical states
            EmptyState {
                Layout.fillWidth:  true
                Layout.fillHeight: true
                visible: root._flat.length === 0
                icon:    Icons.camera
                iconSize: 40
                title: {
                    if (root._selectedId < 0)     return "Select a snapshot"
                    if (!root._liveConnected)     return "Connect a database to compare"
                    if (root._diff && !root._diff.differs) return "No drift detected"
                    return "No differences to show"
                }
                description: {
                    if (root._selectedId < 0)
                        return "Pick a saved snapshot on the left, then choose a live connection to diff against it."
                    if (!root._liveConnected)
                        return "The live schema is read from an open connection — connect one above."
                    if (root._diff && !root._diff.differs)
                        return "The live schema matches the saved snapshot exactly."
                    if (root._diffOnly && root._diff && root._diff.differs)
                        return "Toggle off “Differences only” to view the full schema."
                    return "Choose a live connection above to compare against this snapshot."
                }
            }
        }
    }
}
