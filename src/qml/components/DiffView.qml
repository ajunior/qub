pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Mahina
import Qub

// Result-set diff pane. Snapshot the current result as a baseline, re-run (or
// switch to) another query, and see which rows were added / removed / changed.
// Baseline persists per query tab (owned by WorkspaceScreen). Diffing is done
// by ResultModel.diffAgainst() → ResultDiff::compare().
Item {
    id: root

    property var  model:    null   // ResultModel for the active tab
    property bool hasRun:   false
    property var  baselineSnap: null   // snapshot map from model.snapshot(), or null
    property string connectionName: ""  // for naming/scoping durable saved baselines
    property string sql:            ""  // SQL that produced the current result (stored w/ snapshot)
    signal baselineRequested(var snap)   // null = clear the baseline

    // Durable saved baselines for this connection (ResultSnapshotManager).
    readonly property var _savedForConn: {
        var all = ResultSnapshotManager.snapshots
        var out = []
        for (var i = 0; i < all.length; i++)
            if (all[i].connectionName === root.connectionName) out.push(all[i])
        return out
    }

    property int  _keyColumn: -1    // -1 = whole-row match
    property bool _diffOnly:  true
    readonly property int _cap: 2000

    readonly property var _cols: root.model ? root.model.columnNames : []
    // Guard a stale key index against a differently-shaped current result.
    readonly property int _safeKey: (_keyColumn >= 0 && _keyColumn < _cols.length) ? _keyColumn : -1

    readonly property var _diff: {
        if (!root.model || !root.hasRun || !root.baselineSnap) return null
        root.model.count // dependency: re-diff when the current result changes
        return root.model.diffAgainst(root.baselineSnap, root._safeKey)
    }

    property bool _capped: false
    readonly property var _flat: {
        var d = root._diff
        if (!d) { root._capped = false; return [] }
        var rows = d.rows || []
        var out = []
        var capped = false
        for (var i = 0; i < rows.length; i++) {
            if (root._diffOnly && rows[i].status === "same") continue
            if (out.length >= root._cap) { capped = true; break }
            out.push(rows[i])
        }
        root._capped = capped
        return out
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
    function _rowText(r: var): var {
        if (r.status === "added")   return (r.cells  || []).join("   |   ")
        if (r.status === "removed") return (r.before || []).join("   |   ")
        if (r.status === "changed") {
            var parts = [], cc = r.changedCols || []
            for (var i = 0; i < cc.length; i++) {
                var c = cc[i]
                parts.push((root._cols[c] ?? ("col " + c)) + ": " +
                           r.before[c] + " → " + r.cells[c])
            }
            var keyPart = (r.key !== undefined ? "[" + r.key + "]  " : "")
            return keyPart + parts.join(",    ")
        }
        return (r.cells || []).join("   |   ")
    }

    ColumnLayout {
        anchors.fill: parent
        spacing:      0
        visible:      root.hasRun

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

                // Baseline capture / status
                Button {
                    text:     root.baselineSnap ? "Update baseline" : "Set baseline"
                    iconName: Icons.camera
                    size:     Button.Size.Sm
                    variant:  root.baselineSnap ? Button.Variant.Ghost : Button.Variant.Outlined
                    onClicked: root.baselineRequested(root.model.snapshot())
                    Layout.alignment: Qt.AlignVCenter
                }
                Text {
                    visible: root.baselineSnap !== null
                    text:    "baseline · " + (root.baselineSnap ? root.baselineSnap.rowCount : 0) + " rows"
                    color:   Theme.textDisabled
                    font { family: Theme.fontFamily; pixelSize: Theme.textXs }
                    Layout.alignment: Qt.AlignVCenter
                }
                Button {
                    visible:  root.baselineSnap !== null
                    iconOnly: true
                    iconName: Icons.x
                    size:     Button.Size.Sm
                    variant:  Button.Variant.Ghost
                    onClicked: root.baselineRequested(null)
                    Layout.alignment: Qt.AlignVCenter
                }

                // Save the current result as a durable baseline
                Button {
                    text:     "Save…"
                    iconName: Icons.floppyDisk
                    size:     Button.Size.Sm
                    variant:  Button.Variant.Ghost
                    enabled:  root.hasRun && root.model && root.model.count > 0
                    onClicked: {
                        _saveName.text = "result " + Qt.formatDateTime(new Date(), "MMM d HH:mm")
                        _saveDialog.open()
                    }
                    Layout.alignment: Qt.AlignVCenter
                }
                // Load a saved baseline
                Button {
                    text:     "Load…"
                    iconName: Icons.folderOpen
                    size:     Button.Size.Sm
                    variant:  Button.Variant.Ghost
                    enabled:  root._savedForConn.length > 0
                    onClicked: _loadMenu.open()
                    Layout.alignment: Qt.AlignVCenter

                    Menu {
                        id:       _loadMenu
                        anchor:   parent
                        position: Menu.Position.Bottom
                        model:    root._savedForConn.map(function (s) {
                            return { label: s.name + "  ·  " + s.rowCount + " rows", icon: Icons.gitDiff }
                        })
                        onTriggered: function (index) {
                            var s = root._savedForConn[index]
                            root.baselineRequested(ResultSnapshotManager.snapshotOf(s.id))
                        }
                    }
                }

                Rectangle { visible: root.baselineSnap !== null
                            width: 1; height: 20; color: Theme.border; Layout.alignment: Qt.AlignVCenter }

                // Match-by key column
                Text {
                    visible: root.baselineSnap !== null
                    text: "Match by"
                    color: Theme.textDisabled
                    font { family: Theme.fontFamily; pixelSize: Theme.textXs }
                    Layout.alignment: Qt.AlignVCenter
                }
                Dropdown {
                    visible:       root.baselineSnap !== null
                    implicitWidth: 150
                    model:         ["Whole row"].concat(root._cols)
                    currentIndex:  root._safeKey + 1
                    Layout.alignment: Qt.AlignVCenter
                    onCurrentIndexChanged: root._keyColumn = currentIndex - 1
                }

                Item { Layout.fillWidth: true }

                // Summary badges
                Badge {
                    visible: root._diff && root._diff.summary.added > 0
                    text: (root._diff ? root._diff.summary.added : 0) + " added"
                    colorScheme: Badge.Color.Success
                }
                Badge {
                    visible: root._diff && root._diff.summary.removed > 0
                    text: (root._diff ? root._diff.summary.removed : 0) + " removed"
                    colorScheme: Badge.Color.Error
                }
                Badge {
                    visible: root._diff && root._diff.summary.changed > 0
                    text: (root._diff ? root._diff.summary.changed : 0) + " changed"
                    colorScheme: Badge.Color.Warning
                }

                Toggle {
                    visible:   root.baselineSnap !== null
                    checked:   root._diffOnly
                    onToggled: root._diffOnly = checked
                    text:      "Differences only"
                    Layout.alignment: Qt.AlignVCenter
                }
            }
        }

        // Column-mismatch warning
        Rectangle {
            Layout.fillWidth: true
            height:  28
            visible: root._diff !== null && !root._diff.columnsMatch
            color:   Qt.rgba(Theme.warning.r, Theme.warning.g, Theme.warning.b, 0.12)
            RowLayout {
                anchors { fill: parent; leftMargin: Theme.sp3 }
                spacing: Theme.sp2
                Icon { name: Icons.warning; size: 14; color: Theme.warning }
                Text {
                    text: "Baseline and current result have different columns — showing no rows."
                    color: Theme.warning
                    font { family: Theme.fontFamily; pixelSize: Theme.textXs }
                }
            }
        }

        // Truncation notice
        Rectangle {
            Layout.fillWidth: true
            height:  24
            visible: root._capped
            color:   Theme.surfaceVariant
            Text {
                anchors { left: parent.left; leftMargin: Theme.sp3; verticalCenter: parent.verticalCenter }
                text:  "Showing the first " + root._cap + " differing rows."
                color: Theme.textDisabled
                font { family: Theme.fontFamily; pixelSize: Theme.textXs }
            }
        }

        // ── Diff rows ─────────────────────────────────────────────────────────
        ListView {
            id: _list
            Layout.fillWidth:  true
            Layout.fillHeight: true
            clip:              true
            model:             root._flat
            visible:           root._flat.length > 0
            boundsBehavior:    Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar {}

            delegate: Rectangle {
                id: rowItem
                required property var modelData
                required property int index
                width:  _list.width
                height: 26
                color: {
                    var c = root._statusColor(modelData.status)
                    return modelData.status === "same" ? (index % 2 ? Theme.panel : Theme.surface)
                                                       : Qt.rgba(c.r, c.g, c.b, 0.08)
                }

                RowLayout {
                    anchors { fill: parent; leftMargin: Theme.sp3; rightMargin: Theme.sp3 }
                    spacing: Theme.sp2

                    Text {
                        text:  root._statusMark(rowItem.modelData.status)
                        color: root._statusColor(rowItem.modelData.status)
                        font { family: Theme.fontFamilyMono; pixelSize: Theme.textSm; weight: Theme.weightBold }
                        Layout.preferredWidth: 12
                        horizontalAlignment: Text.AlignHCenter
                    }
                    Text {
                        text:  root._rowText(rowItem.modelData)
                        color: rowItem.modelData.status === "removed" ? Theme.textSecondary : Theme.textPrimary
                        font { family: Theme.fontFamilyMono; pixelSize: Theme.textSm }
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignVCenter
                    }
                }
            }
        }

        // No baseline yet
        EmptyState {
            Layout.fillWidth:  true
            Layout.fillHeight: true
            visible:  root.baselineSnap === null
            icon:     Icons.gitDiff
            iconSize: 40
            title:    "Set a baseline to compare"
            description: "Capture the current result as a baseline, then re-run this query (or edit and run again) to see which rows were added, removed, or changed."
        }

        // Baseline set, but no differences
        EmptyState {
            Layout.fillWidth:  true
            Layout.fillHeight: true
            visible:  root.baselineSnap !== null && root._flat.length === 0 &&
                      (root._diff === null || root._diff.columnsMatch)
            icon:     Icons.check
            iconSize: 40
            title:    "No differences"
            description: "The current result matches the baseline. Toggle off “Differences only” to see unchanged rows too."
        }
    }

    // Nothing run in this tab
    EmptyState {
        anchors.fill: parent
        visible:  !root.hasRun
        icon:     Icons.gitDiff
        iconSize: 40
        title:    "Run a query to diff results"
        description: "Result diffing compares a saved baseline against the current result set."
    }

    // ── Save-as-baseline dialog ────────────────────────────────────────────────
    Dialog {
        id:             _saveDialog
        title:          "Save result snapshot"
        subtitle:       "Store the current result so a later run can be diffed against it."
        preferredWidth: 440

        ColumnLayout {
            width:   parent.width
            spacing: Theme.sp2

            Text {
                text:  "Name"
                color: Theme.textSecondary
                font { family: Theme.fontFamily; pixelSize: Theme.textXs }
            }
            Input {
                id:               _saveName
                Layout.fillWidth: true
                placeholderText:  "e.g. before migration"
                onAccepted:       if (_saveConfirm.enabled) _saveConfirm.clicked()
            }
            Text {
                text:  (root.model ? root.model.count : 0) + " rows"
                       + (root.connectionName ? "  ·  " + root.connectionName : "")
                color: Theme.textDisabled
                font { family: Theme.fontFamily; pixelSize: Theme.textXs }
            }
        }

        footer: Row {
            spacing: Theme.sp2
            Button { text: "Cancel"; variant: Button.Variant.Ghost; onClicked: _saveDialog.close() }
            Button {
                id:       _saveConfirm
                text:     "Save"
                iconName: Icons.floppyDisk
                variant:  Button.Variant.Filled
                enabled:  _saveName.text.trim().length > 0
                onClicked: {
                    ResultSnapshotManager.capture(_saveName.text, root.connectionName,
                                                  root.sql, root.model.snapshot())
                    _saveDialog.close()
                }
            }
        }
    }
}
