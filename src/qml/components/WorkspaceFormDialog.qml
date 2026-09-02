pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Mahina
import Qub

// Create / rename / manage-connections dialog for workspaces. A workspace's
// connections are an explicit subset of the global pool (its safety
// boundary), so the checklist is the single place where membership is
// granted or revoked. Shared by WorkspaceScreen (switcher, "Add connection
// to workspace…") and the Home screen's Workspaces panel.
Dialog {
    id: root

    // "create" | "rename" | "connections"
    property string mode:     "create"
    property int    targetId: -1

    signal done(int workspaceId)

    // preselected: connections ticked from the start. A workspace created from a
    // data source's Open menu arrives with that source already in it, because it
    // is about to be added anyway — an empty list would say otherwise.
    function openCreate(preselected: var): void {
        mode = "create"; targetId = -1
        _nameInput.text = ""
        _buildConnList(preselected ?? [])
        _errorText = ""
        open()
        _nameInput.forceActiveFocus()
    }

    function openRename(id: var): void {
        mode = "rename"; targetId = id
        _nameInput.text = WorkspaceManager.workspace(id).name ?? ""
        _errorText = ""
        open()
        _nameInput.selectAll()
        _nameInput.forceActiveFocus()
    }

    function openConnections(id: var): void {
        mode = "connections"; targetId = id
        _buildConnList(WorkspaceManager.connections(id))
        _errorText = ""
        open()
    }

    title: mode === "create" ? "New workspace"
         : mode === "rename" ? "Rename workspace"
         :                     "Workspace connections"
    subtitle: mode === "connections"
        ? "Only connections in this workspace can be used by its tabs."
        : ""
    preferredWidth: 440

    property string _errorText: ""
    // [{ name, stale }] — stale = in the workspace but no longer in the global pool
    property var _connList: []
    property var _checked:  ({})

    function _buildConnList(members: var): void {
        const names = ConnectionManager.connections.map(c => c.name)
        const list  = names.map(n => ({ name: n, stale: false }))
        members.forEach(p => {
            if (names.indexOf(p) === -1) list.push({ name: p, stale: true })
        })
        const checks = {}
        members.forEach(p => checks[p] = true)
        _connList = list
        _checked  = checks
    }

    function _selectedConnections(): var {
        return _connList.filter(c => _checked[c.name] === true).map(c => c.name)
    }

    function _save(): void {
        if (mode === "create") {
            const id = WorkspaceManager.createWorkspace(_nameInput.text, _selectedConnections())
            if (id < 0) { _errorText = "A workspace with this name already exists."; return }
            root.done(id)
        } else if (mode === "rename") {
            if (!WorkspaceManager.renameWorkspace(targetId, _nameInput.text)) {
                _errorText = "A workspace with this name already exists."
                return
            }
            root.done(targetId)
        } else {
            WorkspaceManager.setConnections(targetId, _selectedConnections())
            root.done(targetId)
        }
        close()
    }

    ColumnLayout {
        width: parent.width
        spacing: Theme.sp3

        Input {
            id: _nameInput
            Layout.fillWidth: true
            visible:         root.mode !== "connections"
            label:           "Name"
            placeholderText: "e.g. Staging, Prod hotfix…"
            maximumLength:   40
            errorText:       root._errorText
            onTextEdited:    root._errorText = ""
            onAccepted:      root._save()
        }

        // Connection checklist (create + connections modes)
        ColumnLayout {
            Layout.fillWidth: true
            visible: root.mode !== "rename"
            spacing: Theme.sp1

            Text {
                text:  "CONNECTIONS"
                color: Theme.textDisabled
                font { family: Theme.fontFamily; pixelSize: Theme.textXs
                       weight: Theme.weightSemibold; letterSpacing: 1 }
            }

            Text {
                Layout.fillWidth: true
                visible:  root._connList.length === 0
                text:     "No connections defined yet — you can add them later."
                color:    Theme.textDisabled
                wrapMode: Text.WordWrap
                font { family: Theme.fontFamily; pixelSize: Theme.textSm }
            }

            Repeater {
                model: root._connList
                delegate: RowLayout {
                    id: delegateItem
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: Theme.sp2

                    Checkbox {
                        text:    delegateItem.modelData.name
                        checked: root._checked[delegateItem.modelData.name] === true
                        onToggled: {
                            const m = Object.assign({}, root._checked)
                            m[delegateItem.modelData.name] = checked
                            root._checked = m
                        }
                    }

                    Badge {
                        visible:     delegateItem.modelData.stale
                        text:        "no longer exists"
                        colorScheme: Badge.Color.Warning
                    }

                    Item { Layout.fillWidth: true }
                }
            }
        }
    }

    // Content-sized: the Dialog right-aligns the footer row itself. Binding
    // width: parent.width here deadlocks against the footer Row's implicit
    // sizing and collapses the buttons to zero width.
    footer: RowLayout {
        spacing: Theme.sp2

        Button {
            text:    "Cancel"
            variant: Button.Variant.Ghost
            onClicked: root.close()
        }
        Button {
            text: root.mode === "create" ? "Create"
                : root.mode === "rename" ? "Rename"
                :                          "Save"
            variant: Button.Variant.Filled
            enabled: root.mode === "connections" || _nameInput.text.trim() !== ""
            onClicked: root._save()
        }
    }
}
