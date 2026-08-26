pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Mahina
import Qub

// Detached schema comparison window. Compares the live schema of two connected
// connections (base "A" vs compare "B") via DatabaseInspector.schemaDiff() and shows
// an add/remove/change tree. Opened from the workspace toolbar.
Window {
    id: root

    title: "Compare Schemas · qub"
    width: 940; height: 640
    minimumWidth: 640; minimumHeight: 420
    color: Theme.background
    flags: Qt.Window

    property string _connA:    ""
    property string _connB:    ""
    property bool   _diffOnly: true

    // Names of currently-connected connections (schemas() needs an open adapter).
    readonly property var _connNames: {
        var out = []
        var all = ConnectionManager.connections
        for (var i = 0; i < all.length; i++)
            if (all[i].connected) out.push(all[i].name)
        return out
    }

    function openWith(baseConn: var): void {
        var names = root._connNames
        root._connA = (baseConn && names.indexOf(baseConn) !== -1) ? baseConn
                                                                   : (names[0] ?? "")
        // Default B to the first connection that isn't A.
        root._connB = ""
        for (var i = 0; i < names.length; i++)
            if (names[i] !== root._connA) { root._connB = names[i]; break }
        show()
        raise()
        requestActivate()
    }

    readonly property var _diff: {
        if (root._connA === "" || root._connB === "" || root._connA === root._connB)
            return null
        return DatabaseInspector.schemaDiff(root._connA, root._connB)
    }

    // ── Flatten the diff tree into renderable rows ────────────────────────────
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

    // Summary badges (non-zero counts only).
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

    ColumnLayout {
        anchors.fill: parent
        spacing:      0

        // ── Toolbar: connection pickers + options ─────────────────────────────
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
                    text: "Base"
                    color: Theme.textDisabled
                    font { family: Theme.fontFamily; pixelSize: Theme.textXs }
                    Layout.alignment: Qt.AlignVCenter
                }
                Dropdown {
                    implicitWidth: 190
                    placeholder:   "Connection A"
                    model:         root._connNames
                    currentIndex:  root._connNames.indexOf(root._connA)
                    Layout.alignment: Qt.AlignVCenter
                    onCurrentIndexChanged: root._connA = root._connNames[currentIndex] ?? ""
                }

                Button {
                    iconOnly: true
                    iconName: Icons.arrowsLeftRight
                    size:     Button.Size.Sm
                    variant:  Button.Variant.Ghost
                    Layout.alignment: Qt.AlignVCenter
                    onClicked: { var a = root._connA; root._connA = root._connB; root._connB = a }
                }

                Text {
                    text: "Compare"
                    color: Theme.textDisabled
                    font { family: Theme.fontFamily; pixelSize: Theme.textXs }
                    Layout.alignment: Qt.AlignVCenter
                }
                Dropdown {
                    implicitWidth: 190
                    placeholder:   "Connection B"
                    model:         root._connNames
                    currentIndex:  root._connNames.indexOf(root._connB)
                    Layout.alignment: Qt.AlignVCenter
                    onCurrentIndexChanged: root._connB = root._connNames[currentIndex] ?? ""
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

        // ── Summary strip ─────────────────────────────────────────────────────
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

        // ── Diff tree ─────────────────────────────────────────────────────────
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
                id: delegateItem
                required property var modelData
                width:  _tree.width
                height: modelData.kind === "column" ? 26 : 30
                color:  modelData.kind === "schema" ? Theme.surfaceVariant
                      : (modelData.kind === "column" ? "transparent" : Theme.surface)

                RowLayout {
                    anchors {
                        fill: parent
                        leftMargin:  Theme.sp3 + delegateItem.modelData.level * 22
                        rightMargin: Theme.sp3
                    }
                    spacing: Theme.sp2

                    // Status mark
                    Text {
                        text:  root._statusMark(delegateItem.modelData.status)
                        color: root._statusColor(delegateItem.modelData.status)
                        font { family: Theme.fontFamilyMono; pixelSize: Theme.textSm;
                               weight: Theme.weightBold }
                        Layout.preferredWidth: 12
                        horizontalAlignment: Text.AlignHCenter
                    }

                    Text {
                        text:  delegateItem.modelData.name
                        color: delegateItem.modelData.status === "removed" ? Theme.textSecondary : Theme.textPrimary
                        font {
                            family:    delegateItem.modelData.kind === "column" ? Theme.fontFamilyMono : Theme.fontFamily
                            pixelSize: delegateItem.modelData.kind === "schema" ? Theme.textSm : Theme.textSm
                            weight:    delegateItem.modelData.kind === "column" ? Theme.weightRegular : Theme.weightSemibold
                        }
                        Layout.alignment: Qt.AlignVCenter
                    }

                    // View badge for view tables
                    Badge {
                        visible:     delegateItem.modelData.kind === "view"
                        text:        "view"
                        colorScheme: Badge.Color.Default
                    }

                    Text {
                        text:  delegateItem.modelData.detail
                        color: root._statusColor(delegateItem.modelData.status)
                        visible: delegateItem.modelData.kind === "column" && delegateItem.modelData.detail !== ""
                        font { family: Theme.fontFamilyMono; pixelSize: Theme.textXs }
                        Layout.alignment: Qt.AlignVCenter
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }
                    Item { Layout.fillWidth: true; visible: delegateItem.modelData.kind !== "column" }
                }

                Rectangle { anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                            height: 1; color: Theme.border
                            opacity: delegateItem.modelData.kind === "schema" ? 1 : 0.4 }
            }
        }

        // ── Empty / identical states ──────────────────────────────────────────
        EmptyState {
            Layout.fillWidth:  true
            Layout.fillHeight: true
            visible: root._flat.length === 0
            icon:    Icons.gitDiff
            iconSize: 40
            title: {
                if (root._connNames.length < 2)
                    return "Connect at least two databases"
                if (root._connA === "" || root._connB === "")
                    return "Pick two connections to compare"
                if (root._connA === root._connB)
                    return "Choose two different connections"
                if (root._diff && !root._diff.differs)
                    return "Schemas are identical"
                return "No differences to show"
            }
            description: {
                if (root._connNames.length < 2)
                    return "Schema comparison needs two open connections."
                if (root._diff && !root._diff.differs)
                    return "Base and compare expose the same tables and columns."
                if (root._diffOnly && root._diff && root._diff.differs)
                    return "Toggle off “Differences only” to view the full schema."
                return "Select a base (A) and a comparison (B) connection above."
            }
        }
    }
}
