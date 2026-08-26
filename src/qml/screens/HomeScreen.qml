pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Dialogs
import QtCore
import QtQuick.Controls.Basic as QQC
import Mahina
import "../drivers.js" as Drivers
import "../guard.js" as Guard
import Qub

Item {
    id: root

    signal connectionSelected(string name)
    signal goToWorkspace()
    signal logsRequested()
    signal workspaceSelected(int workspaceId)

    property int    _tab:          0
    property string _selectedCard: ""

    Component.onCompleted: _selectedCard = "connections"

    readonly property var  _tabs:        ["Home", "Settings", "About"]
    readonly property int  _leftW:       300
    readonly property int  _barH:        72
    readonly property int  _contentMaxW: 900

    // ── White base fills entire page ─────────────────────────────────────────
    Rectangle {
        anchors.fill: parent
        color: Theme.surface

        // ── Top bar (white, right of left panel) ─────────────────────────────
        Rectangle {
            anchors.top:        parent.top
            anchors.left:       parent.left
            anchors.leftMargin: root._leftW
            anchors.right:      parent.right
            height: root._barH
            color:  Theme.surface

            RowLayout {
                anchors.fill:        parent
                anchors.leftMargin:  28
                anchors.rightMargin: 24
                spacing: 4

                Repeater {
                    model: root._tabs

                    Item {
                        id: delegateItem
                        required property var modelData
                        required property int index
                        Layout.preferredWidth:  108
                        Layout.preferredHeight: 44
                        readonly property bool _sel: delegateItem.index === root._tab

                        Text {
                            anchors.centerIn: parent
                            text:            delegateItem.modelData
                            color:           delegateItem._sel ? Theme.primary : Theme.textSecondary
                            font.family:     Theme.fontFamily
                            font.pixelSize:  Theme.textSm
                            font.weight:     delegateItem._sel ? Theme.weightSemibold : Theme.weightRegular
                            Behavior on color { ColorAnimation { duration: Theme.durationFast } }
                        }

                        Rectangle {
                            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                            height: 2
                            color: delegateItem._sel ? Theme.primary : "transparent"
                            Behavior on color { ColorAnimation { duration: Theme.durationFast } }
                        }

                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape:  Qt.PointingHandCursor
                            onClicked: {
                                root._tab = delegateItem.index
                                root._selectedCard = delegateItem.index === 0 ? "connections" : ""
                                _themeAlert.visible = false
                            }
                        }
                    }
                }

                Item { Layout.fillWidth: true }

                Button {
                    text:     "Workspace"
                    iconName: Icons.layout
                    variant:  Button.Variant.Ghost
                    enabled:  ConnectionManager.connections.length > 0
                    onClicked: root.goToWorkspace()
                }

                Tooltip {
                    text: "Activity log"

                    Button {
                        iconOnly: true
                        iconName: Icons.listBullets
                        variant:  Button.Variant.Ghost
                        onClicked: root.logsRequested()
                    }
                }

                Tooltip {
                    text: "Documentation"

                    Button {
                        iconOnly: true
                        iconName: Icons.question
                        variant:  Button.Variant.Ghost
                        onClicked: HelpManager.openHelp()
                    }
                }
            }
        }

        // ── Left panel (white, full height) ──────────────────────────────────
        Rectangle {
            anchors.top:    parent.top
            anchors.bottom: parent.bottom
            anchors.left:   parent.left
            width: root._leftW
            color: Theme.surface

            ColumnLayout {
                anchors.fill:         parent
                anchors.leftMargin:   40
                anchors.rightMargin:  32
                anchors.topMargin:    52
                anchors.bottomMargin: 28
                spacing: 0

                Column {
                    Layout.fillWidth: true
                    spacing: 0

                    Text {
                        text: "Welcome to"
                        color: Theme.textPrimary
                        font.family:    Theme.fontFamily
                        font.pixelSize: 34
                        font.weight:    Theme.weightSemibold
                        lineHeight:     0.92
                    }

                    Row {
                        spacing: 10
                        height: 36

                        Text {
                            text: "qub"
                            color: Theme.textPrimary
                            font.family:    Theme.fontFamily
                            font.pixelSize: 34
                            font.weight:    Theme.weightSemibold
                            anchors.bottom: parent.bottom
                        }

                        Image {
                            source: "qrc:/qt/qml/Qub/assets/cube.svg"
                            width:  26
                            height: 26
                            fillMode: Image.PreserveAspectFit
                            anchors.bottom:       parent.bottom
                            anchors.bottomMargin: 7
                        }
                    }
                }

                Item { Layout.preferredHeight: 14 }

                Text {
                    text: "The SQL editor I built because I needed it. Shared because you might too."
                    color: Theme.textSecondary
                    font.family:    Theme.fontFamily
                    font.pixelSize: Theme.textSm
                    lineHeight:     1.25
                    wrapMode: Text.WordWrap
                    Layout.fillWidth: true
                }

                Item { Layout.fillHeight: true }

                Text {
                    text: "© 2026 Adjamilton Junior"
                    color: Theme.textDisabled
                    font.family:    Theme.fontFamily
                    font.pixelSize: Theme.textXs
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                }

                Item { Layout.preferredHeight: 4 }

                Text {
                    text: "Distributed under the GPL v3 License."
                    color: Theme.textDisabled
                    font.family:    Theme.fontFamily
                    font.pixelSize: Theme.textXs
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                }

                Item { Layout.preferredHeight: 8 }

                Text {
                    text: "github.com/ajunior/qub"
                    color: Theme.primary
                    font.family:    Theme.fontFamily
                    font.pixelSize: Theme.textXs
                    Layout.fillWidth: true
                    elide: Text.ElideRight

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Qt.openUrlExternally("https://github.com/ajunior/qub")
                    }
                }

                Item { Layout.fillHeight: true }

                Text {
                    text: "v" + Qt.application.version
                    color: Theme.textDisabled
                    font.family:    Theme.fontFamily
                    font.pixelSize: Theme.textXs
                }
            }
        }

        // ── Content area (grey, below top bar + right of left panel) ─────────
        Rectangle {
            anchors.top:        parent.top
            anchors.topMargin:  root._barH
            anchors.left:       parent.left
            anchors.leftMargin: root._leftW
            anchors.right:      parent.right
            anchors.bottom:     parent.bottom
            color: Theme.background

            StackLayout {
                anchors.fill: parent
                currentIndex: root._tab

                // ── Connections ──────────────────────────────────────────────
                Flickable {
                    clip: true
                    contentHeight: _connCol.implicitHeight

                    ColumnLayout {
                        id: _connCol
                        width: Math.min(parent.width, root._contentMaxW)
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: 0

                        Item { Layout.preferredHeight: 24 }

                        // ── Action cards ─────────────────────────────────────
                        GridLayout {
                            Layout.fillWidth:    true
                            Layout.leftMargin:   24
                            Layout.rightMargin:  24
                            columns:      4
                            columnSpacing: 14
                            rowSpacing:   14

                            Repeater {
                                model: [
                                    { action: "connections",
                                      category: "DATABASE",
                                      title: "Data Sources",
                                      subtitle: "Open or manage connections",
                                      icon: Icons.database },
                                    { action: "ssh",
                                      category: "NETWORK",
                                      title: "SSH Connections",
                                      subtitle: "Configure SSH tunnels",
                                      icon: Icons.terminal },
                                    { action: "workspaces",
                                      category: "WORKSPACE",
                                      title: "Workspaces",
                                      subtitle: "Open or manage workspaces",
                                      icon: Icons.stack },
                                    { action: "snippets",
                                      category: "LIBRARY",
                                      title: "Snippets",
                                      subtitle: "Manage reusable SQL snippets",
                                      icon: Icons.code }
                                ]

                                delegate: Rectangle {
                                    id: delegateItem2
                                    required property var modelData
                                    Layout.fillWidth: true
                                    height: 118
                                    radius: 6
                                    color: Theme.surface
                                    border.color: (root._selectedCard === delegateItem2.modelData.action || _cm.hovered)
                                                  ? Theme.primary : Theme.border
                                    border.width: (root._selectedCard === delegateItem2.modelData.action || _cm.hovered)
                                                  ? 2 : 1

                                    Behavior on border.color { ColorAnimation { duration: Theme.durationFast } }

                                    HoverHandler { id: _cm }

                                    MouseArea {
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            root._selectedCard = (root._selectedCard === delegateItem2.modelData.action)
                                                                 ? "" : delegateItem2.modelData.action
                                            _connSection._resetForm()
                                            _snipSection._resetForm()
                                            _ioAlert.visible = false
                                            _snipAlert.visible = false
                                            _sshAlert.visible = false
                                        }
                                    }

                                    ColumnLayout {
                                        anchors.fill:    parent
                                        anchors.margins: 16
                                        spacing: 0

                                        RowLayout {
                                            Layout.fillWidth: true

                                            Text {
                                                text: delegateItem2.modelData.category
                                                color: Theme.textDisabled
                                                font.family:      Theme.fontFamily
                                                font.pixelSize:   Theme.textXs
                                                font.weight:      Theme.weightSemibold
                                                font.letterSpacing: 1.2
                                            }

                                            Item { Layout.fillWidth: true }

                                            Icon {
                                                name: delegateItem2.modelData.icon
                                                size: 15
                                                color: root._selectedCard === delegateItem2.modelData.action
                                                       ? Theme.primary : Theme.textSecondary
                                            }
                                        }

                                        Item { Layout.fillHeight: true }

                                        Text {
                                            text: delegateItem2.modelData.title
                                            color: Theme.textPrimary
                                            font.family:    Theme.fontFamily
                                            font.pixelSize: Theme.textSm
                                            font.weight:    Theme.weightSemibold
                                            Layout.fillWidth: true
                                        }

                                        Item { Layout.preferredHeight: 3 }

                                        Text {
                                            text: delegateItem2.modelData.subtitle
                                            color: Theme.primary
                                            font.family:    Theme.fontFamily
                                            font.pixelSize: Theme.textXs
                                            Layout.fillWidth: true
                                        }
                                    }
                                }
                            }
                        }

                        // ── Expanded panel ────────────────────────────────────
                        Item {
                            Layout.fillWidth:    true
                            Layout.leftMargin:   24
                            Layout.rightMargin:  24
                            Layout.topMargin:    16
                            implicitHeight:      _expandedPanel.visible
                                                 ? _expandedPanel.implicitHeight : 0
                            visible:             root._selectedCard !== ""

                            Rectangle {
                                id: _expandedPanel
                                anchors { left: parent.left; right: parent.right; top: parent.top }
                                implicitHeight: _expandedInner.implicitHeight + 40
                                radius: 6
                                color: Theme.surface
                                border.color: Theme.border
                                clip: true

                                ColumnLayout {
                                    id: _expandedInner
                                    anchors { left: parent.left; right: parent.right; top: parent.top }
                                    anchors.margins: 24
                                    spacing: 0

                                    // ── Data Sources ──────────────────────────
                                    ColumnLayout {
                                        id: _connSection
                                        Layout.fillWidth: true
                                        spacing: 0
                                        visible: root._selectedCard === "connections"

                                        property bool _showForm: false

                                        function _openCreate(): void {
                                            _connForm.loadNew()
                                            _showForm = true
                                        }
                                        function _openEdit(conn: var): void {
                                            _connForm.loadEdit(conn)
                                            _showForm = true
                                        }
                                        function _resetForm(): void {
                                            _showForm = false
                                        }

                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: 4
                                            visible: !_connSection._showForm

                                            Text {
                                                text: "DATA SOURCES"
                                                color: Theme.textDisabled
                                                font.family:      Theme.fontFamily
                                                font.pixelSize:   Theme.textXs
                                                font.weight:      Theme.weightSemibold
                                                font.letterSpacing: 1.5
                                            }

                                            Item { Layout.fillWidth: true }

                                            Tooltip {
                                                text: "New connection"

                                                Button {
                                                    iconOnly: true
                                                    iconName: Icons.plus
                                                    variant:  Button.Variant.Ghost
                                                    onClicked: _connSection._openCreate()
                                                }
                                            }

                                            Tooltip {
                                                text: "Import connections"

                                                Button {
                                                    iconOnly: true
                                                    iconName: Icons.downloadSimple
                                                    variant:  Button.Variant.Ghost
                                                    onClicked: _importDialog.open()
                                                }
                                            }

                                            Tooltip {
                                                text: "Export connections"

                                                Button {
                                                    iconOnly: true
                                                    iconName: Icons.uploadSimple
                                                    variant:  Button.Variant.Ghost
                                                    enabled: ConnectionManager.connections.length > 0
                                                    onClicked: _exportDialog.open()
                                                }
                                            }
                                        }

                                        Text {
                                            visible: ConnectionManager.connections.length === 0
                                                     && !_connSection._showForm
                                            text: "No saved connections yet."
                                            color: Theme.textSecondary
                                            font.family:    Theme.fontFamily
                                            font.pixelSize: Theme.textSm
                                            Layout.fillWidth: true
                                        }

                                        Repeater {
                                            model: ConnectionManager.connections
                                            delegate: ListRow {
                                                required property var modelData
                                                id: _connRow
                                                Layout.fillWidth: true
                                                visible: !_connSection._showForm
                                                title: _connRow.modelData.name
                                                subtitle: {
                                                    const isSqlite = _connRow.modelData.driver === "QSQLITE"
                                                    const loc = isSqlite
                                                        ? _connRow.modelData.database
                                                        : (_connRow.modelData.host
                                                            ? _connRow.modelData.host + "/" + _connRow.modelData.database
                                                            : _connRow.modelData.database)
                                                    const ts = _connRow.modelData.lastModified
                                                    const datePart = (ts && !isNaN(new Date(ts)))
                                                        ? Qt.formatDate(ts, "MMM d, yyyy")
                                                        : ""
                                                    return datePart ? loc + " · " + datePart : loc
                                                }
                                                onClicked: root.connectionSelected(_connRow.modelData.name)

                                                ConnectionStatus {
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    showLabel: false
                                                    netStatus: _connRow.modelData.pending ? "reconnecting"
                                                             : _connRow.modelData.connected ? "online" : "offline"
                                                }

                                                Badge {
                                                    text:              Drivers.label(_connRow.modelData.driver)
                                                    colorScheme:       Badge.Color.Default
                                                    backgroundOpacity: _connRow.hovered ? 0.0 : 1.0
                                                    Behavior on backgroundOpacity { NumberAnimation { duration: Theme.durationFast } }
                                                    anchors.verticalCenter: parent.verticalCenter
                                                }
                                                Tooltip {
                                                    text: _connRow.modelData.connected ? "Disconnect" : "Connect"

                                                    Button {
                                                        iconOnly:  true
                                                        iconName:  _connRow.modelData.connected ? Icons.plugs : Icons.plugsConnected
                                                        variant:   Button.Variant.Ghost
                                                        enabled:   !_connRow.modelData.pending
                                                        onClicked: _connRow.modelData.connected
                                                                   ? ConnectionManager.closeConnection(_connRow.modelData.name)
                                                                   : ConnectionManager.reconnect(_connRow.modelData.name)
                                                    }
                                                }
                                                Tooltip {
                                                    text: "Import CSV as table"
                                                    visible: _connRow.modelData.driver === "QSQLITE"

                                                    Button {
                                                        iconOnly:  true
                                                        iconName:  Icons.fileCsv
                                                        variant:   Button.Variant.Ghost
                                                        onClicked: {
                                                            _csvFileDialog.targetConn = _connRow.modelData.name
                                                            _csvFileDialog.targetDb   = _connRow.modelData.database
                                                            _csvFileDialog.open()
                                                        }
                                                    }
                                                }
                                                Tooltip {
                                                    text: "Edit connection"

                                                    Button {
                                                        iconOnly:  true
                                                        iconName:  Icons.pencilSimple
                                                        variant:   Button.Variant.Ghost
                                                        onClicked: _connSection._openEdit(_connRow.modelData)
                                                    }
                                                }
                                                Tooltip {
                                                    text: "Delete connection"

                                                    Button {
                                                        iconOnly:  true
                                                        iconName:  Icons.trash
                                                        variant:   Button.Variant.Ghost
                                                        onClicked: {
                                                            _connDeleteConfirm.connName = _connRow.modelData.name
                                                            _connDeleteConfirm.ownsFile =
                                                                ConnectionManager.ownsDatabaseFile(_connRow.modelData.name)
                                                            _connDeleteConfirm.open()
                                                        }
                                                    }
                                                }
                                            }
                                        }

                                        Alert {
                                            id: _ioAlert
                                            Layout.fillWidth: true
                                            Layout.topMargin: 4
                                            visible: false
                                        }

                                        ConnectionForm {
                                            id: _connForm
                                            Layout.fillWidth: true
                                            visible: _connSection._showForm
                                            onCancelled: _connSection._resetForm()
                                            onUpdated:   _connSection._resetForm()
                                        }

                                        Item { Layout.preferredHeight: 4 }
                                    }

                                    // ── SSH Connections ────────────────────────
                                    ColumnLayout {
                                        id: _sshSection
                                        Layout.fillWidth: true
                                        spacing: 14
                                        visible: root._selectedCard === "ssh"

                                        property bool   _showForm:          false
                                        property string _editingId:         ""
                                        property var    _editingConfig:     ({})
                                        property string _pendingDeleteId:   ""
                                        property string _pendingDeleteName: ""

                                        function _openCreate(): void {
                                            _editingId     = ""
                                            _editingConfig = {}
                                            _showForm      = true
                                        }
                                        function _openEdit(c: var): void {
                                            _editingId     = c.id
                                            _editingConfig = c
                                            _showForm      = true
                                        }
                                        function _resetForm(): void {
                                            _showForm      = false
                                            _editingId     = ""
                                            _editingConfig = {}
                                        }

                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: 4

                                            Text {
                                                text: "SSH CONNECTIONS"
                                                color: Theme.textDisabled
                                                font.family:        Theme.fontFamily
                                                font.pixelSize:     Theme.textXs
                                                font.weight:        Theme.weightSemibold
                                                font.letterSpacing: 1.5
                                            }

                                            Item { Layout.fillWidth: true }

                                            Tooltip {
                                                text: "Import SSH connections"
                                                visible: !_sshSection._showForm

                                                Button {
                                                    iconOnly: true
                                                    iconName: Icons.downloadSimple
                                                    variant:  Button.Variant.Ghost
                                                    onClicked: _sshImportDialog.open()
                                                }
                                            }

                                            Tooltip {
                                                text: "Export SSH connections"
                                                visible: !_sshSection._showForm

                                                Button {
                                                    iconOnly: true
                                                    iconName: Icons.uploadSimple
                                                    variant:  Button.Variant.Ghost
                                                    enabled: SshManager.configs.length > 0
                                                    onClicked: _sshExportDialog.open()
                                                }
                                            }
                                        }

                                        // Empty state
                                        Text {
                                            visible:        SshManager.configs.length === 0 && !_sshSection._showForm
                                            text:           "No SSH connections configured yet."
                                            color:          Theme.textSecondary
                                            font.family:    Theme.fontFamily
                                            font.pixelSize: Theme.textSm
                                            Layout.fillWidth: true
                                        }

                                        // SSH list
                                        Repeater {
                                            model:   SshManager.configs
                                            visible: !_sshSection._showForm
                                            delegate: ListRow {
                                                required property var modelData
                                                id: _sshRow
                                                Layout.fillWidth: true
                                                visible:  !_sshSection._showForm
                                                title:    _sshRow.modelData.name
                                                subtitle: (_sshRow.modelData.username || "") + "@" + (_sshRow.modelData.host || "") + ":" + (_sshRow.modelData.port || 22)

                                                Badge {
                                                    text:              _sshRow.modelData.keyPath ? "Key file" : "Default keys"
                                                    colorScheme:       Badge.Color.Primary
                                                    backgroundOpacity: _sshRow.hovered ? 0.0 : 1.0
                                                    Behavior on backgroundOpacity { NumberAnimation { duration: Theme.durationFast } }
                                                    anchors.verticalCenter: parent.verticalCenter
                                                }
                                                Tooltip {
                                                    text: "Edit SSH connection"

                                                    Button {
                                                        iconOnly: true
                                                        iconName: Icons.pencilSimple
                                                        variant:  Button.Variant.Ghost
                                                        onClicked: _sshSection._openEdit(_sshRow.modelData)
                                                    }
                                                }
                                                Tooltip {
                                                    text: "Delete SSH connection"

                                                    Button {
                                                        iconOnly: true
                                                        iconName: Icons.trash
                                                        variant:  Button.Variant.Ghost
                                                        onClicked: {
                                                            _sshSection._pendingDeleteId   = _sshRow.modelData.id
                                                            _sshSection._pendingDeleteName = _sshRow.modelData.name
                                                            _deleteSshDialog.open()
                                                        }
                                                    }
                                                }
                                            }
                                        }

                                        // Add button
                                        Button {
                                            visible:  !_sshSection._showForm
                                            text:     "Add SSH Connection"
                                            iconName: Icons.plus
                                            variant:  Button.Variant.Outlined
                                            onClicked: _sshSection._openCreate()
                                        }

                                        Alert {
                                            id: _sshAlert
                                            Layout.fillWidth: true
                                            visible: false
                                        }

                                        // Form
                                        ColumnLayout {
                                            visible:          _sshSection._showForm
                                            Layout.fillWidth: true
                                            spacing:          14

                                            onVisibleChanged: if (visible) {
                                                const c          = _sshSection._editingConfig
                                                _sName.text      = c.name     || ""
                                                _sHost.text      = c.host     || ""
                                                _sUser.text      = c.username || ""
                                                _sPort.value     = c.port     || 22
                                                _sKey.text       = c.keyPath  || ""
                                            }

                                            RowLayout {
                                                Layout.fillWidth: true
                                                spacing: 10

                                                Input {
                                                    id:              _sName
                                                    label:           "Name"
                                                    placeholderText: "Production bastion"
                                                    Layout.fillWidth: true
                                                }

                                                NumberInput {
                                                    id:    _sPort
                                                    label: "Port"
                                                    value: 22
                                                    min:   1
                                                    max:   65535
                                                    step:  1
                                                }
                                            }

                                            RowLayout {
                                                Layout.fillWidth: true
                                                spacing: 10

                                                Input {
                                                    id:              _sHost
                                                    label:           "Host"
                                                    placeholderText: "bastion.example.com"
                                                    Layout.fillWidth: true
                                                }

                                                Input {
                                                    id:              _sUser
                                                    label:           "Username"
                                                    placeholderText: "ubuntu"
                                                    Layout.fillWidth: true
                                                }
                                            }

                                            // Key-based auth only: the tunnel runs ssh in BatchMode,
                                            // so interactive password auth is not supported.
                                            RowLayout {
                                                Layout.fillWidth: true
                                                spacing: 8

                                                Input {
                                                    id:              _sKey
                                                    label:           "Private key path (empty = default keys / agent)"
                                                    placeholderText: "~/.ssh/id_rsa"
                                                    Layout.fillWidth: true
                                                }

                                                Button {
                                                    text:     "Browse"
                                                    variant:  Button.Variant.Outlined
                                                    Layout.alignment: Qt.AlignBottom
                                                    onClicked: _sshKeyFileDlg.open()
                                                }
                                            }

                                            Divider {}

                                            RowLayout {
                                                Layout.fillWidth: true
                                                spacing: 8
                                                Item { Layout.fillWidth: true }
                                                Button {
                                                    text:    "Cancel"
                                                    variant: Button.Variant.Ghost
                                                    onClicked: _sshSection._resetForm()
                                                }
                                                Button {
                                                    text:    _sshSection._editingId !== "" ? "Update" : "Save"
                                                    variant: Button.Variant.Filled
                                                    enabled: _sName.text.trim() !== "" && _sHost.text.trim() !== "" && _sUser.text.trim() !== ""
                                                    onClicked: {
                                                        const data = {
                                                            name:     _sName.text.trim(),
                                                            host:     _sHost.text.trim(),
                                                            port:     _sPort.value,
                                                            username: _sUser.text.trim(),
                                                            keyPath:  _sKey.text.trim()
                                                        }
                                                        if (_sshSection._editingId !== "")
                                                            SshManager.updateConfig(_sshSection._editingId, data)
                                                        else
                                                            SshManager.addConfig(data)
                                                        _sshSection._resetForm()
                                                    }
                                                }
                                            }
                                        }

                                        Item { Layout.preferredHeight: 4 }
                                    }

                                    // ── Workspaces ────────────────────────────
                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 0
                                        visible: root._selectedCard === "workspaces"

                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: Theme.sp2

                                            Text {
                                                text: "WORKSPACES"
                                                color: Theme.textDisabled
                                                font.family:      Theme.fontFamily
                                                font.pixelSize:   Theme.textXs
                                                font.weight:      Theme.weightSemibold
                                                font.letterSpacing: 1.5
                                            }

                                            Item { Layout.fillWidth: true }

                                            Button {
                                                text:     "New Workspace"
                                                iconName: Icons.plus
                                                size:     Button.Size.Sm
                                                variant:  Button.Variant.Ghost
                                                onClicked: _wsFormDialog.openCreate()
                                            }
                                        }

                                        Item { Layout.preferredHeight: 8 }

                                        // Live: WorkspaceManager.workspaces is a
                                        // NOTIFYing property (create/rename/delete/save).
                                        Repeater {
                                            model: root._selectedCard === "workspaces"
                                                   ? WorkspaceManager.workspaces : []
                                            delegate: ListRow {
                                                id: delegateItem3
                                                required property var modelData
                                                Layout.fillWidth: true
                                                title: delegateItem3.modelData.name
                                                subtitle: delegateItem3.modelData.tabCount
                                                          + (delegateItem3.modelData.tabCount === 1 ? " tab" : " tabs")
                                                          + " · opened " + Qt.formatDateTime(
                                                                new Date(delegateItem3.modelData.lastOpenedAt), "d MMM · hh:mm")
                                                onClicked: root.workspaceSelected(delegateItem3.modelData.id)

                                                Badge {
                                                    visible:     delegateItem3.modelData.id === WorkspaceManager.activeWorkspaceId
                                                    text:        "active"
                                                    colorScheme: Badge.Color.Primary
                                                }
                                                Repeater {
                                                    model: delegateItem3.modelData.connections.slice(0, 3)
                                                    delegate: Badge {
                                                        id: delegateItem4
                                                        required property string modelData
                                                        text: delegateItem4.modelData
                                                        colorScheme: Badge.Color.Default
                                                    }
                                                }
                                                Badge {
                                                    visible: delegateItem3.modelData.connections.length > 3
                                                    text:    "+" + (delegateItem3.modelData.connections.length - 3)
                                                    colorScheme: Badge.Color.Default
                                                }
                                                Tooltip {
                                                    text: "Rename workspace"

                                                    Button {
                                                        iconOnly: true
                                                        iconName: Icons.pencil
                                                        size:     Button.Size.Sm
                                                        variant:  Button.Variant.Ghost
                                                        onClicked: _wsFormDialog.openRename(delegateItem3.modelData.id)
                                                    }
                                                }
                                                Tooltip {
                                                    text: "Delete workspace"

                                                    Button {
                                                        iconOnly: true
                                                        iconName: Icons.trash
                                                        size:     Button.Size.Sm
                                                        variant:  Button.Variant.Ghost
                                                        enabled:  WorkspaceManager.workspaces.length > 1
                                                        onClicked: {
                                                            _wsDeleteConfirm.wsId = delegateItem3.modelData.id
                                                            _wsDeleteConfirm.dialogMessage =
                                                                "Delete workspace \"" + delegateItem3.modelData.name + "\"? Its tabs and " +
                                                                "their SQL will be permanently deleted. Connections stay in " +
                                                                "the global pool."
                                                            _wsDeleteConfirm.open()
                                                        }
                                                    }
                                                }
                                            }
                                        }

                                        Item { Layout.preferredHeight: 4 }
                                    }

                                    // ── Snippets ──────────────────────────────
                                    ColumnLayout {
                                        id: _snipSection
                                        Layout.fillWidth: true
                                        spacing: 0
                                        visible: root._selectedCard === "snippets"

                                        property bool   _showForm:  false
                                        property var    _editing:   null   // snippet map, or null when creating
                                        property string _nameError: ""

                                        function _openCreate(): void {
                                            _editing         = null
                                            _snipName.text   = ""
                                            _snipFolder.text = ""
                                            _snipSql.text    = ""
                                            _nameError       = ""
                                            _showForm        = true
                                        }
                                        function _openEdit(s: var): void {
                                            _editing         = s
                                            _snipName.text   = s.name
                                            _snipFolder.text = s.folder
                                            _snipSql.text    = s.sql
                                            _nameError       = ""
                                            _showForm        = true
                                        }
                                        function _resetForm(): void {
                                            _showForm  = false
                                            _editing   = null
                                            _nameError = ""
                                        }

                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: 4
                                            visible: !_snipSection._showForm

                                            Text {
                                                text: "SNIPPETS"
                                                color: Theme.textDisabled
                                                font.family:      Theme.fontFamily
                                                font.pixelSize:   Theme.textXs
                                                font.weight:      Theme.weightSemibold
                                                font.letterSpacing: 1.5
                                            }

                                            Item { Layout.fillWidth: true }

                                            Tooltip {
                                                text: "New snippet"

                                                Button {
                                                    iconOnly: true
                                                    iconName: Icons.plus
                                                    variant:  Button.Variant.Ghost
                                                    onClicked: _snipSection._openCreate()
                                                }
                                            }

                                            Tooltip {
                                                text: "Import snippets"

                                                Button {
                                                    iconOnly: true
                                                    iconName: Icons.downloadSimple
                                                    variant:  Button.Variant.Ghost
                                                    onClicked: _snipImportDialog.open()
                                                }
                                            }

                                            Tooltip {
                                                text: "Export snippets"

                                                Button {
                                                    iconOnly: true
                                                    iconName: Icons.uploadSimple
                                                    variant:  Button.Variant.Ghost
                                                    enabled: SnippetManager.snippets.length > 0
                                                    onClicked: _snipExportDialog.open()
                                                }
                                            }
                                        }

                                        Text {
                                            visible: _snipSection._showForm
                                            text: _snipSection._editing ? "EDIT SNIPPET" : "NEW SNIPPET"
                                            color: Theme.textDisabled
                                            font.family:      Theme.fontFamily
                                            font.pixelSize:   Theme.textXs
                                            font.weight:      Theme.weightSemibold
                                            font.letterSpacing: 1.5
                                        }

                                        Text {
                                            visible: SnippetManager.snippets.length === 0
                                                     && !_snipSection._showForm
                                            text: "No snippets yet. Save one here or select SQL in the editor and press Ctrl+Shift+S."
                                            color: Theme.textSecondary
                                            font.family:    Theme.fontFamily
                                            font.pixelSize: Theme.textSm
                                            Layout.fillWidth: true
                                        }

                                        // Rows grouped under folder headers; unfoldered
                                        // snippets first (manager orders by folder, name).
                                        Repeater {
                                            model: {
                                                if (root._selectedCard !== "snippets" || _snipSection._showForm)
                                                    return []
                                                const rows = []
                                                let current = null
                                                for (const s of SnippetManager.snippets) {
                                                    if (s.folder !== "" && s.folder !== current)
                                                        rows.push({ kind: "folder", folder: s.folder })
                                                    current = s.folder
                                                    rows.push({ kind: "snippet", snip: s })
                                                }
                                                return rows
                                            }
                                            delegate: Loader {
                                                id: delegateItem5
                                                required property var modelData
                                                Layout.fillWidth: true
                                                sourceComponent: delegateItem5.modelData.kind === "folder"
                                                                 ? _snipFolderHeader : _snipListRow
                                                onLoaded: item.row = Qt.binding(() => delegateItem5.modelData)
                                            }
                                        }

                                        Alert {
                                            id: _snipAlert
                                            Layout.fillWidth: true
                                            Layout.topMargin: 4
                                            visible: false
                                        }

                                        // Form (create / edit in place)
                                        ColumnLayout {
                                            visible:          _snipSection._showForm
                                            Layout.fillWidth: true
                                            spacing: 14

                                            Item { Layout.preferredHeight: 2 }

                                            RowLayout {
                                                Layout.fillWidth: true
                                                spacing: 12

                                                Input {
                                                    id:              _snipName
                                                    label:           "Name"
                                                    placeholderText: "Monthly revenue"
                                                    Layout.fillWidth: true
                                                    errorText:       _snipSection._nameError
                                                    onTextEdited:    _snipSection._nameError = ""
                                                }

                                                Input {
                                                    id:              _snipFolder
                                                    label:           "Folder (optional)"
                                                    placeholderText: "Reports"
                                                    Layout.preferredWidth: 200
                                                    onTextEdited:    _snipSection._nameError = ""
                                                }
                                            }

                                            // Existing folders, one click to reuse
                                            // (avoids "DDL" vs "ddl" drift).
                                            Flow {
                                                Layout.fillWidth: true
                                                spacing: 6
                                                visible: _snipFolderChips.count > 0

                                                Repeater {
                                                    id: _snipFolderChips
                                                    model: {
                                                        const folders = []
                                                        for (const s of SnippetManager.snippets)
                                                            if (s.folder !== "" && folders.indexOf(s.folder) === -1)
                                                                folders.push(s.folder)
                                                        return folders
                                                    }
                                                    delegate: Chip {
                                                        id: delegateItem6
                                                        required property string modelData
                                                        text:     delegateItem6.modelData
                                                        selected: _snipFolder.text.trim() === delegateItem6.modelData
                                                        onClicked: {
                                                            _snipFolder.text = delegateItem6.modelData
                                                            _snipSection._nameError = ""
                                                        }
                                                    }
                                                }
                                            }

                                            Textarea {
                                                id:              _snipSql
                                                label:           "SQL"
                                                placeholderText: "SELECT …"
                                                rows:            8
                                                Layout.fillWidth: true
                                            }

                                            RowLayout {
                                                Layout.fillWidth: true
                                                spacing: 8

                                                Item { Layout.fillWidth: true }

                                                Button {
                                                    text:    "Cancel"
                                                    variant: Button.Variant.Ghost
                                                    onClicked: _snipSection._resetForm()
                                                }
                                                Button {
                                                    text:    _snipSection._editing ? "Update" : "Save"
                                                    variant: Button.Variant.Filled
                                                    enabled: _snipName.text.trim() !== ""
                                                             && _snipSql.text.trim() !== ""
                                                    onClicked: {
                                                        const editId = _snipSection._editing ? _snipSection._editing.id : -1
                                                        if (SnippetManager.nameInUse(_snipName.text, _snipFolder.text, editId)) {
                                                            _snipSection._nameError =
                                                                "A snippet with this name already exists"
                                                                + (_snipFolder.text.trim() !== "" ? " in this folder." : ".")
                                                            return
                                                        }
                                                        if (_snipSection._editing)
                                                            SnippetManager.update(_snipSection._editing.id,
                                                                                  _snipName.text, _snipFolder.text,
                                                                                  _snipSql.text)
                                                        else
                                                            SnippetManager.save(_snipName.text, _snipFolder.text,
                                                                                _snipSql.text, "")
                                                        _snipSection._resetForm()
                                                    }
                                                }
                                            }
                                        }

                                        Component {
                                            id: _snipFolderHeader

                                            Item {
                                                id: _folderRoot
                                                property var row: ({ folder: "" })
                                                implicitHeight: 32

                                                Text {
                                                    anchors {
                                                        left: parent.left
                                                        bottom: parent.bottom; bottomMargin: 4
                                                    }
                                                    text:  _folderRoot.row.folder
                                                    color: Theme.textSecondary
                                                    font.family:      Theme.fontFamily
                                                    font.pixelSize:   Theme.textXs
                                                    font.weight:      Theme.weightSemibold
                                                    font.letterSpacing: 1.2
                                                }
                                            }
                                        }

                                        Component {
                                            id: _snipListRow

                                            ListRow {
                                                id: _snipRowRoot
                                                property var row: ({ snip: { id: -1, name: "", sql: "", connectionName: "" } })
                                                title: _snipRowRoot.row.snip.name
                                                subtitle: _snipRowRoot.row.snip.sql.replace(/\s+/g, " ").substring(0, 80)
                                                onClicked: _snipSection._openEdit(_snipRowRoot.row.snip)

                                                Badge {
                                                    visible:     _snipRowRoot.row.snip.connectionName !== ""
                                                    text:        _snipRowRoot.row.snip.connectionName
                                                    colorScheme: Badge.Color.Default
                                                    anchors.verticalCenter: parent.verticalCenter
                                                }
                                                Tooltip {
                                                    text: "Edit snippet"

                                                    Button {
                                                        iconOnly:  true
                                                        iconName:  Icons.pencilSimple
                                                        variant:   Button.Variant.Ghost
                                                        onClicked: _snipSection._openEdit(_snipRowRoot.row.snip)
                                                    }
                                                }
                                                Tooltip {
                                                    text: "Delete snippet"

                                                    Button {
                                                        iconOnly:  true
                                                        iconName:  Icons.trash
                                                        variant:   Button.Variant.Ghost
                                                        onClicked: {
                                                            _snipDeleteConfirm.snipId = _snipRowRoot.row.snip.id
                                                            _snipDeleteConfirm.dialogMessage =
                                                                "\"" + _snipRowRoot.row.snip.name + "\" will be permanently removed."
                                                            _snipDeleteConfirm.open()
                                                        }
                                                    }
                                                }
                                            }
                                        }

                                        Item { Layout.preferredHeight: 4 }
                                    }
                                }
                            }
                        }

                        Item { Layout.preferredHeight: 24 }
                    }
                }

                // ── Settings ─────────────────────────────────────────────────
                Item {
                    // Fixed search bar
                    Item {
                        id: _searchBar
                        anchors { top: parent.top; left: parent.left; right: parent.right }
                        height: _settingsSearch.implicitHeight + 24
                        z: 1

                        Rectangle {
                            anchors.fill: parent
                            color: Theme.panel
                            opacity: _settingsFlick.contentY > 0 ? 1 : 0
                            Behavior on opacity { NumberAnimation { duration: Theme.durationFast } }
                        }

                        SearchInput {
                            id: _settingsSearch
                            anchors {
                                left: parent.left;   leftMargin:  Math.max(24, (parent.width - root._contentMaxW) / 2 + 24)
                                right: parent.right; rightMargin: Math.max(24, (parent.width - root._contentMaxW) / 2 + 24)
                                verticalCenter: parent.verticalCenter
                            }
                            placeholder: "Search settings…"
                        }
                    }

                    ConfirmDialog {
                        id:            _deleteThemeDialog
                        dialogTitle:   "Delete theme?"
                        dialogMessage: "\"" + _themeSection._pendingDeleteName + "\" will be permanently removed."
                        confirmText:   "Delete"
                        isDestructive: true
                        z:             2
                        onConfirmed:   ThemeManager.removeTheme(_themeSection._pendingDeleteId)
                    }

                    Flickable {
                        id: _settingsFlick
                        anchors { top: _searchBar.bottom; left: parent.left; right: parent.right; bottom: parent.bottom }
                        contentHeight: _settings.implicitHeight
                        clip: true

                        ColumnLayout {
                            id: _settings
                            width: Math.min(parent.width, root._contentMaxW)
                            anchors.horizontalCenter: parent.horizontalCenter
                            spacing: 28

                            property string _q: _settingsSearch.text.toLowerCase().trim()

                            Item { Layout.preferredHeight: 4 }

                            ColumnLayout {
                                id: _secAppearance
                                Layout.fillWidth:    true
                                Layout.leftMargin:   24
                                Layout.rightMargin:  24
                                spacing: 14
                                visible: {
                                    const q = _settings._q
                                    return !q || ["appearance","dark","mode","light"].some(t => t.includes(q))
                                }

                                Text {
                                    text: "APPEARANCE"
                                    color: Theme.textDisabled
                                    font.family:      Theme.fontFamily
                                    font.pixelSize:   Theme.textXs
                                    font.weight:      Theme.weightSemibold
                                    font.letterSpacing: 1.5
                                }

                                Toggle {
                                    text: "Dark mode"
                                    checked: AppSettings.darkTheme
                                    onCheckedChanged: AppSettings.darkTheme = checked
                                }
                            }

                            Rectangle {
                                Layout.fillWidth: true; height: 1; color: Theme.border
                                visible: _secAppearance.visible && _secConnection.visible
                            }

                            ColumnLayout {
                                id: _secConnection
                                Layout.fillWidth:    true
                                Layout.leftMargin:   24
                                Layout.rightMargin:  24
                                spacing: 14
                                visible: {
                                    const q = _settings._q
                                    return !q || ["connection","close","leave","workspace","always","reconnect","drop","retry"].some(t => t.includes(q))
                                }

                                Text {
                                    text: "CONNECTION"
                                    color: Theme.textDisabled
                                    font.family:      Theme.fontFamily
                                    font.pixelSize:   Theme.textXs
                                    font.weight:      Theme.weightSemibold
                                    font.letterSpacing: 1.5
                                }

                                Toggle {
                                    text: "Always close connection when leaving a workspace"
                                    checked: AppSettings.autoCloseOnLeave
                                    onCheckedChanged: AppSettings.autoCloseOnLeave = checked
                                }

                                Toggle {
                                    text: "Auto-reconnect and retry query on connection drop"
                                    checked: AppSettings.autoReconnect
                                    onCheckedChanged: AppSettings.autoReconnect = checked
                                }
                            }

                            Rectangle {
                                Layout.fillWidth: true; height: 1; color: Theme.border
                                visible: _secConnection.visible && _secEditor.visible
                            }

                            ColumnLayout {
                                id: _secEditor
                                Layout.fillWidth:    true
                                Layout.leftMargin:   24
                                Layout.rightMargin:  24
                                spacing: 14
                                visible: {
                                    const q = _settings._q
                                    return !q || ["editor","font","size","font size","family","typeface","autocomplete","auto-complete","complete","limit","rows","result","highlight","current line","line height","spacing","compact","comfortable","tab","indent","spaces"].some(t => t.includes(q))
                                }

                                Text {
                                    text: "EDITOR"
                                    color: Theme.textDisabled
                                    font.family:      Theme.fontFamily
                                    font.pixelSize:   Theme.textXs
                                    font.weight:      Theme.weightSemibold
                                    font.letterSpacing: 1.5
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 8

                                    // ── Font family ───────────────────────────
                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 4

                                        Text {
                                            text: "Font"
                                            color: Theme.textSecondary
                                            font.family:    Theme.fontFamily
                                            font.pixelSize: Theme.textXs
                                        }

                                        QQC.ComboBox {
                                            id: _fontFamilyPicker
                                            Layout.fillWidth: true
                                            implicitHeight: 36
                                            model: Qt.fontFamilies()
                                            currentIndex: Math.max(0, Array.from(model).indexOf(AppSettings.fontFamily))
                                            onActivated: AppSettings.fontFamily = currentText

                                            contentItem: Text {
                                                leftPadding: Theme.sp3
                                                text:  _fontFamilyPicker.displayText
                                                color: Theme.textPrimary
                                                font { family: _fontFamilyPicker.displayText; pixelSize: Theme.textSm }
                                                verticalAlignment: Text.AlignVCenter
                                                elide: Text.ElideRight
                                            }

                                            background: Rectangle {
                                                color:  Theme.surface
                                                radius: Theme.radiusSm
                                                border.color: _fontFamilyPicker.popup.visible ? Theme.primary : Theme.border
                                                border.width: _fontFamilyPicker.popup.visible ? 2 : 1
                                                Behavior on border.color { ColorAnimation { duration: Theme.durationFast } }
                                            }

                                            delegate: QQC.ItemDelegate {
                                                id: delegateItem7
                                                required property string modelData
                                                required property int    index
                                                width: parent ? parent.width : 0
                                                implicitHeight: 30
                                                highlighted: _fontFamilyPicker.highlightedIndex === delegateItem7.index
                                                contentItem: Text {
                                                    leftPadding: Theme.sp3
                                                    text:  delegateItem7.modelData
                                                    color: delegateItem7.modelData === AppSettings.fontFamily ? Theme.primary : Theme.textPrimary
                                                    font { family: delegateItem7.modelData; pixelSize: Theme.textSm }
                                                    verticalAlignment: Text.AlignVCenter
                                                }
                                                background: Rectangle {
                                                    color: delegateItem7.highlighted
                                                           ? Qt.rgba(Qt.color(Theme.primary).r, Qt.color(Theme.primary).g, Qt.color(Theme.primary).b, 0.08)
                                                           : (delegateItem7.modelData === AppSettings.fontFamily ? Theme.panel : "transparent")
                                                }
                                            }

                                            popup: QQC.Popup {
                                                y: _fontFamilyPicker.height + 2
                                                width: _fontFamilyPicker.width
                                                height: Math.min(contentItem.implicitHeight, 260)
                                                padding: 1

                                                contentItem: QQC.ScrollView {
                                                    QQC.ScrollBar.horizontal.policy: QQC.ScrollBar.AlwaysOff
                                                    ListView {
                                                        implicitHeight: contentHeight
                                                        model:  _fontFamilyPicker.delegateModel
                                                        currentIndex: _fontFamilyPicker.highlightedIndex
                                                        clip: true
                                                    }
                                                }

                                                background: Rectangle {
                                                    color:  Theme.surface
                                                    radius: Theme.radiusSm
                                                    border.color: Theme.border
                                                    border.width: 1
                                                }
                                            }
                                        }
                                    }

                                    // ── Weight ────────────────────────────────
                                    ColumnLayout {
                                        spacing: 4

                                        Text {
                                            text: "Weight"
                                            color: Theme.textSecondary
                                            font.family:    Theme.fontFamily
                                            font.pixelSize: Theme.textXs
                                        }

                                        QQC.ComboBox {
                                            id: _fontWeightPicker
                                            implicitWidth:  120
                                            implicitHeight: 36
                                            model: [
                                                { label: "Thin",      value: Font.Thin      },
                                                { label: "Light",     value: Font.Light     },
                                                { label: "Regular",   value: Font.Normal    },
                                                { label: "Medium",    value: Font.Medium    },
                                                { label: "SemiBold",  value: Font.DemiBold  },
                                                { label: "Bold",      value: Font.Bold      },
                                                { label: "ExtraBold", value: Font.ExtraBold },
                                                { label: "Black",     value: Font.Black     }
                                            ]
                                            textRole: "label"
                                            currentIndex: {
                                                for (var i = 0; i < model.length; i++)
                                                    if (model[i].value === AppSettings.fontWeight) return i
                                                return 2
                                            }
                                            onActivated: AppSettings.fontWeight = model[currentIndex].value

                                            contentItem: Text {
                                                leftPadding: Theme.sp3
                                                text:  _fontWeightPicker.displayText
                                                color: Theme.textPrimary
                                                font { family: Theme.fontFamily; pixelSize: Theme.textSm; weight: AppSettings.fontWeight }
                                                verticalAlignment: Text.AlignVCenter
                                            }

                                            background: Rectangle {
                                                color:  Theme.surface
                                                radius: Theme.radiusSm
                                                border.color: _fontWeightPicker.popup.visible ? Theme.primary : Theme.border
                                                border.width: _fontWeightPicker.popup.visible ? 2 : 1
                                                Behavior on border.color { ColorAnimation { duration: Theme.durationFast } }
                                            }

                                            delegate: QQC.ItemDelegate {
                                                id: delegateItem8
                                                required property var modelData
                                                required property int index
                                                width: parent ? parent.width : 0
                                                implicitHeight: 30
                                                highlighted: _fontWeightPicker.highlightedIndex === delegateItem8.index
                                                contentItem: Text {
                                                    leftPadding: Theme.sp3
                                                    text:  delegateItem8.modelData.label
                                                    color: delegateItem8.modelData.value === AppSettings.fontWeight ? Theme.primary : Theme.textPrimary
                                                    font { family: Theme.fontFamily; pixelSize: Theme.textSm; weight: delegateItem8.modelData.value }
                                                    verticalAlignment: Text.AlignVCenter
                                                }
                                                background: Rectangle {
                                                    color: delegateItem8.highlighted
                                                           ? Qt.rgba(Qt.color(Theme.primary).r, Qt.color(Theme.primary).g, Qt.color(Theme.primary).b, 0.08)
                                                           : (delegateItem8.modelData.value === AppSettings.fontWeight ? Theme.panel : "transparent")
                                                }
                                            }

                                            popup: QQC.Popup {
                                                y: _fontWeightPicker.height + 2
                                                width: _fontWeightPicker.width
                                                height: Math.min(contentItem.implicitHeight, 260)
                                                padding: 1

                                                contentItem: QQC.ScrollView {
                                                    QQC.ScrollBar.horizontal.policy: QQC.ScrollBar.AlwaysOff
                                                    ListView {
                                                        implicitHeight: contentHeight
                                                        model:  _fontWeightPicker.delegateModel
                                                        currentIndex: _fontWeightPicker.highlightedIndex
                                                        clip: true
                                                    }
                                                }

                                                background: Rectangle {
                                                    color:  Theme.surface
                                                    radius: Theme.radiusSm
                                                    border.color: Theme.border
                                                    border.width: 1
                                                }
                                            }
                                        }
                                    }

                                    // ── Size ──────────────────────────────────
                                    ColumnLayout {
                                        spacing: 4

                                        Text {
                                            text: "Size"
                                            color: Theme.textSecondary
                                            font.family:    Theme.fontFamily
                                            font.pixelSize: Theme.textXs
                                        }

                                        NumberInput {
                                            value: AppSettings.fontSize
                                            min: 10; max: 24; step: 1
                                            onValueChanged: if (value !== AppSettings.fontSize) AppSettings.fontSize = value
                                        }
                                    }
                                }

                                Toggle {
                                    text: "Auto-complete table and column names in the query editor"
                                    checked: AppSettings.autoComplete
                                    onCheckedChanged: AppSettings.autoComplete = checked
                                }

                                Toggle {
                                    text: "Highlight current line in the query editor"
                                    checked: AppSettings.highlightCurrentLine
                                    onCheckedChanged: AppSettings.highlightCurrentLine = checked
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 8

                                    Text {
                                        text:  "Line height"
                                        color: Theme.textPrimary
                                        font { family: Theme.fontFamily; pixelSize: Theme.textSm }
                                    }

                                    Row {
                                        spacing: 6
                                        Repeater {
                                            model: [
                                                { label: "Compact",     value: 1.2 },
                                                { label: "Normal",      value: 1.0 },
                                                { label: "Comfortable", value: 1.5 },
                                            ]
                                            delegate: Button {
                                                id: delegateItem9
                                                required property var modelData
                                                text:    delegateItem9.modelData.label
                                                variant: Math.abs(AppSettings.lineHeight - delegateItem9.modelData.value) < 0.01
                                                         ? Button.Variant.Filled
                                                         : Button.Variant.Outlined
                                                onClicked: AppSettings.lineHeight = delegateItem9.modelData.value
                                            }
                                        }
                                    }
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 8

                                    Text {
                                        text:  "Tab size"
                                        color: Theme.textPrimary
                                        font { family: Theme.fontFamily; pixelSize: Theme.textSm }
                                    }

                                    Row {
                                        spacing: 6
                                        Repeater {
                                            model: [2, 4, 8]
                                            delegate: Button {
                                                id: delegateItem10
                                                required property int modelData
                                                text:    delegateItem10.modelData + " spaces"
                                                variant: AppSettings.tabSize === delegateItem10.modelData
                                                         ? Button.Variant.Filled
                                                         : Button.Variant.Outlined
                                                onClicked: AppSettings.tabSize = delegateItem10.modelData
                                            }
                                        }
                                    }
                                }

                                Toggle {
                                    text: "Insert spaces when pressing Tab (instead of a tab character)"
                                    checked: AppSettings.insertSpacesForTab
                                    onCheckedChanged: AppSettings.insertSpacesForTab = checked
                                }

                                NumberInput {
                                    label: "Default result limit (0 = no limit)"
                                    value: AppSettings.queryLimit
                                    min: 0; max: 100000; step: 100
                                    onValueChanged: if (value !== AppSettings.queryLimit) AppSettings.queryLimit = value
                                }
                            }

                            Rectangle {
                                Layout.fillWidth: true; height: 1; color: Theme.border
                                visible: _secEditor.visible && _secSchema.visible
                            }

                            ColumnLayout {
                                id: _secSchema
                                Layout.fillWidth:    true
                                Layout.leftMargin:   24
                                Layout.rightMargin:  24
                                spacing: 14
                                visible: {
                                    const q = _settings._q
                                    return !q || ["schema","tree","double-click","doubleclick","browse","quick","table","column"].some(t => t.includes(q))
                                }

                                Text {
                                    text: "SCHEMA BROWSER"
                                    color: Theme.textDisabled
                                    font.family:      Theme.fontFamily
                                    font.pixelSize:   Theme.textXs
                                    font.weight:      Theme.weightSemibold
                                    font.letterSpacing: 1.5
                                }

                                Toggle {
                                    text: "Insert table/column name on double-click in schema tree"
                                    checked: AppSettings.schemaInsertOnDoubleClick
                                    onCheckedChanged: AppSettings.schemaInsertOnDoubleClick = checked
                                }

                                Toggle {
                                    text: "Show quick-browse button on schema tree tables"
                                    checked: AppSettings.schemaQuickBrowse
                                    onCheckedChanged: AppSettings.schemaQuickBrowse = checked
                                }
                            }

                            Rectangle {
                                Layout.fillWidth: true; height: 1; color: Theme.border
                                visible: _secSchema.visible && _secHistory.visible
                            }

                            ColumnLayout {
                                id: _secHistory
                                Layout.fillWidth:    true
                                Layout.leftMargin:   24
                                Layout.rightMargin:  24
                                spacing: 14
                                visible: {
                                    const q = _settings._q
                                    return !q || ["history","limit","restore","cursor","caret","position"].some(t => t.includes(q))
                                }

                                Text {
                                    text: "HISTORY"
                                    color: Theme.textDisabled
                                    font.family:      Theme.fontFamily
                                    font.pixelSize:   Theme.textXs
                                    font.weight:      Theme.weightSemibold
                                    font.letterSpacing: 1.5
                                }

                                NumberInput {
                                    label: "History limit"
                                    value: AppSettings.historyLimit
                                    min: 10; max: 1000; step: 10
                                    onValueChanged: if (value !== AppSettings.historyLimit) AppSettings.historyLimit = value
                                }

                                Toggle {
                                    text: "Restore cursor position in editor tabs"
                                    checked: AppSettings.preserveCursorPosition
                                    onCheckedChanged: AppSettings.preserveCursorPosition = checked
                                }
                            }

                            Rectangle {
                                Layout.fillWidth: true; height: 1; color: Theme.border
                                visible: _secHistory.visible && _secSharing.visible
                            }

                            ColumnLayout {
                                id: _secSharing
                                Layout.fillWidth:    true
                                Layout.leftMargin:   24
                                Layout.rightMargin:  24
                                spacing: 14
                                visible: {
                                    const q = _settings._q
                                    return !q || ["share","live","sharing","warning","broadcast","https","tls","ssl","certificate","cert","download","csv","json","tsv","export"].some(t => t.includes(q))
                                }

                                Text {
                                    text: "SHARING"
                                    color: Theme.textDisabled
                                    font.family:      Theme.fontFamily
                                    font.pixelSize:   Theme.textXs
                                    font.weight:      Theme.weightSemibold
                                    font.letterSpacing: 1.5
                                }

                                Toggle {
                                    text: "Allow viewers to download results (CSV, JSON, TSV)"
                                    checked: AppSettings.liveShareAllowDownload
                                    onCheckedChanged: AppSettings.liveShareAllowDownload = checked
                                }

                                Toggle {
                                    text: "Show warning before starting Live Share"
                                    checked: AppSettings.liveShareWarnOnStart
                                    onCheckedChanged: AppSettings.liveShareWarnOnStart = checked
                                }

                                Toggle {
                                    text: "Show confirmation before stopping Live Share"
                                    checked: AppSettings.liveShareWarnOnStop
                                    onCheckedChanged: AppSettings.liveShareWarnOnStop = checked
                                }

                                Toggle {
                                    text: "Allow other devices on the network to connect (LAN)"
                                    checked: AppSettings.liveShareLanVisible
                                    onCheckedChanged: {
                                        AppSettings.liveShareLanVisible = checked
                                        // LAN exposure without TLS would send queries,
                                        // results, and the access token over the network
                                        // in the clear, so it is not permitted — enable
                                        // TLS alongside it.
                                        if (checked)
                                            AppSettings.liveShareUseTls = true
                                    }
                                }

                                Text {
                                    visible: AppSettings.liveShareLanVisible
                                    text: "TLS is required when sharing over the LAN and stays on while it is enabled."
                                    color: Theme.textDisabled
                                    wrapMode: Text.WordWrap
                                    Layout.fillWidth: true
                                    Layout.leftMargin: Theme.sp2
                                    font { family: Theme.fontFamily; pixelSize: Theme.textXs }
                                }

                                Toggle {
                                    id: _tlsToggle
                                    text: "Use HTTPS (TLS)"
                                    // Locked on while LAN sharing is enabled: plaintext
                                    // would expose everything on the wire.
                                    enabled: !AppSettings.liveShareLanVisible
                                    checked: AppSettings.liveShareUseTls || AppSettings.liveShareLanVisible
                                    onCheckedChanged: AppSettings.liveShareUseTls = checked
                                }

                                ColumnLayout {
                                    visible: _tlsToggle.checked
                                    Layout.fillWidth: true
                                    spacing: 10

                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: Theme.sp3

                                        Text {
                                            text:  "Certificate source"
                                            color: Theme.textSecondary
                                            font { family: Theme.fontFamily; pixelSize: Theme.textSm }
                                            Layout.preferredWidth: 140
                                        }

                                        ColumnLayout {
                                            spacing: 6

                                            RadioGroup {
                                                id: _certSourceGroup
                                                currentIndex: (AppSettings.liveShareCertPath !== "" && AppSettings.liveShareKeyPath !== "") ? 1 : 0
                                                model: [
                                                    { label: "Auto-generated (self-signed)" },
                                                    { label: "Custom certificate"           },
                                                ]
                                                onSelectionChanged: (i) => {
                                                    if (i === 0) {
                                                        AppSettings.liveShareCertPath = ""
                                                        AppSettings.liveShareKeyPath  = ""
                                                    }
                                                }
                                            }

                                            Text {
                                                visible: _certSourceGroup.currentIndex === 0
                                                text:    "⚠ Browsers will show a security warning. Open the URL, click Advanced → Proceed to trust the certificate once per device."
                                                color:   Theme.textDisabled
                                                font { family: Theme.fontFamily; pixelSize: Theme.textXs }
                                                wrapMode: Text.WordWrap
                                                Layout.fillWidth: true
                                            }
                                        }
                                    }

                                    ColumnLayout {
                                        visible: _certSourceGroup.currentIndex === 1
                                        Layout.fillWidth: true
                                        spacing: 8

                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: Theme.sp3

                                            Text {
                                                text:  "Certificate (.pem)"
                                                color: Theme.textSecondary
                                                font { family: Theme.fontFamily; pixelSize: Theme.textSm }
                                                Layout.preferredWidth: 140
                                            }

                                            FilePicker {
                                                Layout.fillWidth: true
                                                filePath:    AppSettings.liveShareCertPath
                                                placeholder: "No file selected"
                                                onBrowseClicked: _certDialog.open()
                                                onCleared:       AppSettings.liveShareCertPath = ""
                                            }

                                            FileDialog {
                                                id:          _certDialog
                                                title:       "Select certificate file"
                                                fileMode:    FileDialog.OpenFile
                                                nameFilters: ["PEM files (*.pem *.crt *.cer)", "All files (*)"]
                                                onAccepted:  AppSettings.liveShareCertPath = selectedFile.toString().replace("file://", "")
                                            }
                                        }

                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: Theme.sp3

                                            Text {
                                                text:  "Private key (.pem)"
                                                color: Theme.textSecondary
                                                font { family: Theme.fontFamily; pixelSize: Theme.textSm }
                                                Layout.preferredWidth: 140
                                            }

                                            FilePicker {
                                                Layout.fillWidth: true
                                                filePath:    AppSettings.liveShareKeyPath
                                                placeholder: "No file selected"
                                                onBrowseClicked: _keyDialog.open()
                                                onCleared:       AppSettings.liveShareKeyPath = ""
                                            }

                                            FileDialog {
                                                id:          _keyDialog
                                                title:       "Select private key file"
                                                fileMode:    FileDialog.OpenFile
                                                nameFilters: ["PEM files (*.pem *.key)", "All files (*)"]
                                                onAccepted:  AppSettings.liveShareKeyPath = selectedFile.toString().replace("file://", "")
                                            }
                                        }
                                    }
                                }
                            }

                            Rectangle {
                                Layout.fillWidth: true; height: 1; color: Theme.border
                                visible: _secSharing.visible && _secAi.visible
                            }

                            ColumnLayout {
                                id: _secAi
                                Layout.fillWidth:    true
                                Layout.leftMargin:   24
                                Layout.rightMargin:  24
                                spacing: 14
                                visible: {
                                    const q = _settings._q
                                    return !q || ["ai","llm","model","anthropic","openai","ollama","api key","key","generate","sql","assistant","provider"].some(t => t.includes(q))
                                }

                                Text {
                                    text: "AI ASSISTANT"
                                    color: Theme.textDisabled
                                    font.family:      Theme.fontFamily
                                    font.pixelSize:   Theme.textXs
                                    font.weight:      Theme.weightSemibold
                                    font.letterSpacing: 1.5
                                }

                                // Provider picker
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Theme.sp3

                                    Text {
                                        text:           "Provider"
                                        color:          Theme.textSecondary
                                        font.family:    Theme.fontFamily
                                        font.pixelSize: Theme.textSm
                                        Layout.preferredWidth: 100
                                    }

                                    RadioGroup {
                                        id:           _aiProviderGroup
                                        model:        ["Anthropic", "OpenAI", "Ollama"]
                                        horizontal:   true
                                        currentIndex: ["anthropic","openai","ollama"].indexOf(AppSettings.aiProvider.toLowerCase())
                                        onSelectionChanged: (i) => {
                                            AppSettings.aiProvider = ["anthropic","openai","ollama"][i]
                                        }
                                    }
                                }

                                // API Key
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Theme.sp3
                                    visible: AppSettings.aiProvider.toLowerCase() !== "ollama"

                                    Text {
                                        text:           "API Key"
                                        color:          Theme.textSecondary
                                        font.family:    Theme.fontFamily
                                        font.pixelSize: Theme.textSm
                                        Layout.preferredWidth: 100
                                    }

                                    PasswordInput {
                                        id:           _aiKeyInput
                                        Layout.fillWidth: true
                                        showStrength: false
                                        placeholder:  "sk-…"
                                    }

                                    Button {
                                        text:    "Save"
                                        size:    Button.Size.Sm
                                        enabled: _aiKeyInput.value.trim().length > 0
                                        onClicked: {
                                            AiClient.saveApiKey(_aiKeyInput.value.trim())
                                            _aiKeyInput.value = ""
                                            _toaster.show("API key saved to keychain.", Toaster.Type.Success)
                                        }
                                    }
                                }

                                // Model override
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Theme.sp3

                                    Text {
                                        text:           "Model"
                                        color:          Theme.textSecondary
                                        font.family:    Theme.fontFamily
                                        font.pixelSize: Theme.textSm
                                        Layout.preferredWidth: 100
                                    }

                                    Input {
                                        id: _aiModelInput
                                        Layout.fillWidth: true
                                        placeholderText: {
                                            const p = AppSettings.aiProvider.toLowerCase()
                                            if (p === "anthropic") return "claude-haiku-4-5-20251001 (default)"
                                            if (p === "openai")    return "gpt-4o-mini (default)"
                                            return "llama3.2 (default)"
                                        }
                                        Component.onCompleted: text = AppSettings.aiModel
                                        onEditingFinished: AppSettings.aiModel = text
                                    }
                                }

                                // Ollama URL
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Theme.sp3
                                    visible: AppSettings.aiProvider.toLowerCase() === "ollama"

                                    Text {
                                        text:           "Ollama URL"
                                        color:          Theme.textSecondary
                                        font.family:    Theme.fontFamily
                                        font.pixelSize: Theme.textSm
                                        Layout.preferredWidth: 100
                                    }

                                    Input {
                                        id: _aiOllamaUrlInput
                                        Layout.fillWidth: true
                                        placeholderText: "http://localhost:11434"
                                        Component.onCompleted: text = AppSettings.aiOllamaUrl
                                        onEditingFinished: AppSettings.aiOllamaUrl = text
                                    }
                                }
                            }

                            Rectangle {
                                Layout.fillWidth: true; height: 1; color: Theme.border
                                visible: _secAi.visible && _profilesSection.visible
                            }

                            ColumnLayout {
                                id: _profilesSection
                                Layout.fillWidth:    true
                                Layout.leftMargin:   24
                                Layout.rightMargin:  24
                                spacing: 14
                                visible: {
                                    const q = _settings._q
                                    return !q || ["profile","read-only","readonly","delete","drop","truncate","update","where","rule","confirm","safety","color"].some(t => t.includes(q))
                                }

                                property bool   _showForm:   false
                                property string _editingId:  ""
                                property string _newName:    ""
                                property string _newColor:   "#EF4444"
                                property bool   _newReadOnly:    false
                                property bool   _newConfDel:     true
                                property bool   _newConfDrop:    true
                                property bool   _newConfTrunc:   true
                                property bool   _newConfUpdNoWh: true

                                function _openEdit(p: var): void {
                                    _editingId       = p.id
                                    _newColor        = p.color        || "#EF4444"
                                    _newReadOnly     = p.readOnly     || false
                                    _newConfDel      = p.confirmDelete !== undefined ? p.confirmDelete : true
                                    _newConfDrop     = p.confirmDrop   !== undefined ? p.confirmDrop   : true
                                    _newConfTrunc    = p.confirmTruncate !== undefined ? p.confirmTruncate : true
                                    _newConfUpdNoWh  = p.confirmUpdateWithoutWhere !== undefined ? p.confirmUpdateWithoutWhere : true
                                    _profNameInput.text = p.name || ""
                                    _showForm = true
                                }

                                function _resetForm(): void {
                                    _profNameInput.clear()
                                    _editingId       = ""
                                    _newName         = ""
                                    _newColor        = "#EF4444"
                                    _newReadOnly     = false
                                    _newConfDel      = true
                                    _newConfDrop     = true
                                    _newConfTrunc    = true
                                    _newConfUpdNoWh  = true
                                    _showForm        = false
                                }

                                Text {
                                    text: "PROFILES"
                                    color: Theme.textDisabled
                                    font.family:      Theme.fontFamily
                                    font.pixelSize:   Theme.textXs
                                    font.weight:      Theme.weightSemibold
                                    font.letterSpacing: 1.5
                                }

                                Text {
                                    visible: ProfileManager.profiles.length === 0 && !_profilesSection._showForm
                                    text: "No profiles yet."
                                    color: Theme.textDisabled
                                    font.family:    Theme.fontFamily
                                    font.pixelSize: Theme.textSm
                                }

                                Repeater {
                                    model: ProfileManager.profiles
                                    delegate: RowLayout {
                                        id: delegateItem11
                                        required property var modelData
                                        Layout.fillWidth: true
                                        spacing: 10

                                        Rectangle {
                                            width: 10; height: 10; radius: 5
                                            color: delegateItem11.modelData.color || Theme.border
                                        }

                                        Text {
                                            text: delegateItem11.modelData.name
                                            color: Theme.textPrimary
                                            font.family:    Theme.fontFamily
                                            font.pixelSize: Theme.textSm
                                            Layout.fillWidth: true
                                        }

                                        Text {
                                            visible: delegateItem11.modelData.readOnly
                                            text: "read-only"
                                            color: Theme.error
                                            font.family:    Theme.fontFamily
                                            font.pixelSize: Theme.textXs
                                        }

                                        Tooltip {
                                            text: "Edit profile"

                                            Button {
                                                iconOnly: true
                                                iconName: Icons.pencilSimple
                                                variant: Button.Variant.Ghost
                                                onClicked: _profilesSection._openEdit(delegateItem11.modelData)
                                            }
                                        }

                                        Tooltip {
                                            text: "Delete profile"

                                            Button {
                                                iconOnly: true
                                                iconName: Icons.trash
                                                variant: Button.Variant.Ghost
                                                onClicked: {
                                                    _profileDeleteConfirm.profileId = delegateItem11.modelData.id
                                                    _profileDeleteConfirm.dialogMessage =
                                                        "\"" + delegateItem11.modelData.name + "\" will be permanently removed. " +
                                                        "Connections using it lose its safety rules."
                                                    _profileDeleteConfirm.open()
                                                }
                                            }
                                        }
                                    }
                                }

                                Button {
                                    visible: !_profilesSection._showForm
                                    text: "Add Profile"
                                    iconName: Icons.plus
                                    variant: Button.Variant.Outlined
                                    onClicked: _profilesSection._showForm = true
                                }

                                // ── New profile form ──────────────────────────
                                ColumnLayout {
                                    visible: _profilesSection._showForm
                                    Layout.fillWidth: true
                                    spacing: 12

                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 12

                                        Input {
                                            id: _profNameInput
                                            label: "Name"
                                            placeholderText: "Production"
                                            Layout.fillWidth: true
                                            onTextChanged: _profilesSection._newName = text
                                        }

                                        ColorPicker {
                                            label: "Color"
                                            color: _profilesSection._newColor
                                            Layout.preferredWidth: 180
                                            onColorPicked: (c) => _profilesSection._newColor = c.toString()
                                        }
                                    }

                                    Text {
                                        text: "Rules"
                                        color: Theme.textSecondary
                                        font.family:    Theme.fontFamily
                                        font.pixelSize: Theme.textSm
                                        font.weight:    Theme.weightSemibold
                                    }

                                    Toggle {
                                        text: "Read-only (block all write operations)"
                                        checked: _profilesSection._newReadOnly
                                        onCheckedChanged: _profilesSection._newReadOnly = checked
                                    }

                                    Toggle {
                                        text: "Confirm DELETE"
                                        checked: _profilesSection._newConfDel
                                        onCheckedChanged: _profilesSection._newConfDel = checked
                                    }

                                    Toggle {
                                        text: "Confirm DROP"
                                        checked: _profilesSection._newConfDrop
                                        onCheckedChanged: _profilesSection._newConfDrop = checked
                                    }

                                    Toggle {
                                        text: "Confirm TRUNCATE"
                                        checked: _profilesSection._newConfTrunc
                                        onCheckedChanged: _profilesSection._newConfTrunc = checked
                                    }

                                    Toggle {
                                        text: "Confirm UPDATE without WHERE"
                                        checked: _profilesSection._newConfUpdNoWh
                                        onCheckedChanged: _profilesSection._newConfUpdNoWh = checked
                                    }

                                    Divider {}

                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 8

                                        Item { Layout.fillWidth: true }

                                        Button {
                                            text: "Cancel"
                                            variant: Button.Variant.Ghost
                                            onClicked: _profilesSection._resetForm()
                                        }

                                        Button {
                                            text: _profilesSection._editingId !== "" ? "Update" : "Save"
                                            variant: Button.Variant.Filled
                                            enabled: _profilesSection._newName.trim() !== ""
                                            onClicked: {
                                                const data = {
                                                    name:                      _profilesSection._newName.trim(),
                                                    color:                     _profilesSection._newColor,
                                                    readOnly:                  _profilesSection._newReadOnly,
                                                    confirmDelete:             _profilesSection._newConfDel,
                                                    confirmDrop:               _profilesSection._newConfDrop,
                                                    confirmTruncate:           _profilesSection._newConfTrunc,
                                                    confirmUpdateWithoutWhere: _profilesSection._newConfUpdNoWh
                                                }
                                                if (_profilesSection._editingId !== "")
                                                    ProfileManager.updateProfile(_profilesSection._editingId, data)
                                                else
                                                    ProfileManager.addProfile(data)
                                                _profilesSection._resetForm()
                                            }
                                        }
                                    }
                                }
                            }

                            Rectangle {
                                Layout.fillWidth: true; height: 1; color: Theme.border
                                visible: _profilesSection.visible && _themeSection.visible
                            }

                            // ── THEMES section ────────────────────────────────
                            ColumnLayout {
                                id: _themeSection
                                Layout.fillWidth:    true
                                Layout.leftMargin:   24
                                Layout.rightMargin:  24
                                spacing: 14
                                visible: {
                                    const q = _settings._q
                                    return !q || ["theme","color","palette","dracula","solarized","womakerscode","import","export","custom","dark","light"].some(t => t.includes(q))
                                }

                                property bool   _showForm:          false
                                property string _editingId:         ""
                                property var    _editingTheme:      ({})
                                property string _exportingId:       ""
                                property string _pendingDeleteId:   ""
                                property string _pendingDeleteName: ""

                                function _openCreate(): void {
                                    _editingId    = ""
                                    _editingTheme = {}
                                    _showForm     = true
                                }

                                function _openEdit(t: var): void {
                                    _editingId    = t.id
                                    _editingTheme = t
                                    _showForm     = true
                                }

                                function _resetForm(): void {
                                    _showForm     = false
                                    _editingId    = ""
                                    _editingTheme = {}
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 4

                                    Text {
                                        text: "THEMES"
                                        color: Theme.textDisabled
                                        font.family:      Theme.fontFamily
                                        font.pixelSize:   Theme.textXs
                                        font.weight:      Theme.weightSemibold
                                        font.letterSpacing: 1.5
                                    }

                                    Item { Layout.fillWidth: true }

                                    Tooltip {
                                        text: "Import theme"
                                        visible: !_themeSection._showForm

                                        Button {
                                            iconOnly: true
                                            iconName: Icons.downloadSimple
                                            variant:  Button.Variant.Ghost
                                            onClicked: _importThemeDialog.open()
                                        }
                                    }
                                }

                                Alert {
                                    id: _themeAlert
                                    Layout.fillWidth: true
                                    visible: false
                                }

                                Repeater {
                                    model: ThemeManager.themes
                                    delegate: RowLayout {
                                        id: delegateItem12
                                        required property var modelData
                                        Layout.fillWidth: true
                                        spacing: 10

                                        Rectangle {
                                            width: 10; height: 10; radius: 5
                                            color: delegateItem12.modelData.primary || Theme.border
                                        }

                                        Text {
                                            text: delegateItem12.modelData.name
                                            color: Theme.textPrimary
                                            font.family:    Theme.fontFamily
                                            font.pixelSize: Theme.textSm
                                            Layout.fillWidth: true
                                        }

                                        Text {
                                            visible: delegateItem12.modelData.id === ThemeManager.activeThemeId
                                            text: "active"
                                            color: Theme.primary
                                            font.family:    Theme.fontFamily
                                            font.pixelSize: Theme.textXs
                                            font.weight:    Theme.weightSemibold
                                        }

                                        Tooltip {
                                            visible: delegateItem12.modelData.id !== ThemeManager.activeThemeId
                                            text: "Activate"

                                            Button {
                                                iconOnly: true
                                                iconName: Icons.checkCircle
                                                variant: Button.Variant.Ghost
                                                onClicked: ThemeManager.setActiveTheme(delegateItem12.modelData.id)
                                            }
                                        }

                                        Tooltip {
                                            text: "Export theme"

                                            Button {
                                                iconOnly: true
                                                iconName: Icons.uploadSimple
                                                variant: Button.Variant.Ghost
                                                onClicked: {
                                                    _themeSection._exportingId = delegateItem12.modelData.id
                                                    const slug = delegateItem12.modelData.name.toLowerCase()
                                                        .replace(/\s+/g, "-").replace(/[^a-z0-9-]/g, "")
                                                    _exportThemeDialog.selectedFile =
                                                        StandardPaths.writableLocation(StandardPaths.DocumentsLocation)
                                                        + "/" + (slug || "theme") + ".json"
                                                    _exportThemeDialog.open()
                                                }
                                            }
                                        }

                                        Tooltip {
                                            text: "Edit theme"
                                            visible: !delegateItem12.modelData.builtin

                                            Button {
                                                iconOnly: true
                                                iconName: Icons.pencilSimple
                                                variant: Button.Variant.Ghost
                                                onClicked: _themeSection._openEdit(delegateItem12.modelData)
                                            }
                                        }

                                        Tooltip {
                                            text: "Delete theme"
                                            visible: !delegateItem12.modelData.builtin

                                            Button {
                                                iconOnly: true
                                                iconName: Icons.trash
                                                variant: Button.Variant.Ghost
                                                onClicked: {
                                                    _themeSection._pendingDeleteId   = delegateItem12.modelData.id
                                                    _themeSection._pendingDeleteName = delegateItem12.modelData.name
                                                    _deleteThemeDialog.open()
                                                }
                                            }
                                        }
                                    }
                                }

                                Button {
                                    visible: !_themeSection._showForm
                                    text: "New Theme"
                                    iconName: Icons.plus
                                    variant: Button.Variant.Outlined
                                    onClicked: _themeSection._openCreate()
                                }

                                ThemeEditorForm {
                                    visible:      _themeSection._showForm
                                    Layout.fillWidth: true
                                    isEditing:    _themeSection._editingId !== ""
                                    initialTheme: _themeSection._editingTheme
                                    onSaved: (draft) => {
                                        if (_themeSection._editingId !== "")
                                            ThemeManager.updateTheme(_themeSection._editingId, draft)
                                        else
                                            ThemeManager.addTheme(draft)
                                        _themeSection._resetForm()
                                    }
                                    onCancelled: _themeSection._resetForm()
                                }
                            }

                            Item { Layout.preferredHeight: 16 }
                        }
                    }
                }

                // ── About ─────────────────────────────────────────────────────
                Flickable {
                    clip: true
                    contentHeight: _aboutCol.implicitHeight

                    ColumnLayout {
                        id: _aboutCol
                        width: Math.min(parent.width, root._contentMaxW)
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: 0

                        Item { Layout.preferredHeight: 40 }

                        // Logo + name row
                        RowLayout {
                            Layout.leftMargin: 36
                            spacing: 14

                            Image {
                                source: "qrc:/qt/qml/Qub/assets/cube.svg"
                                width:  48
                                height: 55
                                fillMode: Image.PreserveAspectFit
                            }

                            ColumnLayout {
                                spacing: 2

                                Text {
                                    text: "qub"
                                    color: Theme.textPrimary
                                    font.family:    Theme.fontFamily
                                    font.pixelSize: 42
                                    font.weight:    Theme.weightSemibold
                                    lineHeight:     0.9
                                }

                                Text {
                                    text: "v" + Qt.application.version
                                    color: Theme.textDisabled
                                    font.family:    Theme.fontFamily
                                    font.pixelSize: Theme.textSm
                                }

                            }
                        }

                        Item { Layout.preferredHeight: 28 }

                        Text {
                            text: "The SQL editor I built because I needed it. Shared because you might too."
                            color: Theme.textSecondary
                            font.family:    Theme.fontFamily
                            font.pixelSize: Theme.textBase
                            lineHeight:     1.4
                            wrapMode: Text.WordWrap
                            Layout.fillWidth:   true
                            Layout.leftMargin:  36
                            Layout.rightMargin: 36
                        }

                        Item { Layout.preferredHeight: 28 }

                        Rectangle {
                            Layout.fillWidth:   true
                            Layout.leftMargin:  36
                            Layout.rightMargin: 36
                            height: 1
                            color: Theme.border
                        }

                        Item { Layout.preferredHeight: 24 }

                        Text {
                            textFormat: Text.RichText
                            text: "There are great open-source SQL editors out there, but none of them ever really clicked for me. "
                                + "DataGrip was the one that gave me the feeling of productivity and control over my database workspace. "
                                + "But once my enterprise license got canceled, instead of picking a new one I decided to build myself "
                                + "an editor the way I always wanted it to be. So qub was built with an emphasis on SQL centricity, "
                                + "the basics done well, and a clean interface I enjoy looking at all day.<br/>"
                                + "After my first experience using qub as a user, I was amazed at the level of simplicity I had achieved in an SQL editor UI, so I decided to distribute it and open-source the project. "
                                + "I still intend to manage it as a personal project, bringing only the features I find useful, but feel free to open an issue to discuss anything you think could be an improvement."
                            onLinkActivated: (link) => Qt.openUrlExternally(link)
                            color: Theme.textSecondary
                            font.family:    Theme.fontFamily
                            font.pixelSize: Theme.textSm
                            lineHeight:     1.5
                            wrapMode: Text.WordWrap
                            Layout.fillWidth:   true
                            Layout.leftMargin:  36
                            Layout.rightMargin: 36

                            MouseArea {
                                anchors.fill:    parent
                                acceptedButtons: Qt.NoButton
                                cursorShape:     parent.hoveredLink !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor
                            }
                        }

                        Item { Layout.preferredHeight: 28 }

                        Rectangle {
                            Layout.fillWidth:   true
                            Layout.leftMargin:  36
                            Layout.rightMargin: 36
                            height: 1
                            color: Theme.border
                        }

                        Item { Layout.preferredHeight: 24 }

                        ColumnLayout {
                            Layout.leftMargin:  36
                            spacing: 10

                            RowLayout {
                                spacing: 8

                                Text {
                                    text: "Source"
                                    color: Theme.textDisabled
                                    font.family:    Theme.fontFamily
                                    font.pixelSize: Theme.textSm
                                    Layout.preferredWidth: 60
                                }

                                Text {
                                    text: "github.com/ajunior/qub"
                                    color: Theme.primary
                                    font.family:    Theme.fontFamily
                                    font.pixelSize: Theme.textSm
                                    MouseArea {
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: Qt.openUrlExternally("https://github.com/ajunior/qub")
                                    }
                                }
                            }

                            RowLayout {
                                spacing: 8

                                Text {
                                    text: "License"
                                    color: Theme.textDisabled
                                    font.family:    Theme.fontFamily
                                    font.pixelSize: Theme.textSm
                                    Layout.preferredWidth: 60
                                }

                                Text {
                                    text: "GNU General Public License v3.0"
                                    color: Theme.primary
                                    font.family:    Theme.fontFamily
                                    font.pixelSize: Theme.textSm
                                    MouseArea {
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: Qt.openUrlExternally("https://www.gnu.org/licenses/gpl-3.0.html")
                                    }
                                }
                            }

                            RowLayout {
                                spacing: 8

                                Text {
                                    text: "Author"
                                    color: Theme.textDisabled
                                    font.family:    Theme.fontFamily
                                    font.pixelSize: Theme.textSm
                                    Layout.preferredWidth: 60
                                }

                                Text {
                                    text: "Adjamilton Junior"
                                    color: Theme.textSecondary
                                    font.family:    Theme.fontFamily
                                    font.pixelSize: Theme.textSm
                                }
                            }

                            RowLayout {
                                spacing: 8

                                Text {
                                    text: "AI Usage"
                                    color: Theme.textDisabled
                                    font.family:    Theme.fontFamily
                                    font.pixelSize: Theme.textSm
                                    Layout.preferredWidth: 60
                                }

                                Text {
                                    text: "AI assistance was used to build this application, but all of its code is human-reviewed."
                                    color: Theme.textSecondary
                                    font.family:    Theme.fontFamily
                                    font.pixelSize: Theme.textSm
                                    wrapMode: Text.WordWrap
                                    Layout.fillWidth: true
                                }
                            }
                        }

                        Item { Layout.preferredHeight: 32 }

                        Rectangle {
                            Layout.fillWidth:   true
                            Layout.leftMargin:  36
                            Layout.rightMargin: 36
                            height: 1
                            color: Theme.border
                        }

                        Item { Layout.preferredHeight: 24 }

                        ColumnLayout {
                            Layout.leftMargin:  36
                            Layout.rightMargin: 36
                            spacing: 14

                            Text {
                                text: "I don't really drink coffee, but I'm willing to try it if you pay me one."
                                color: Theme.textSecondary
                                font.family:    Theme.fontFamily
                                font.pixelSize: Theme.textSm
                                font.italic:    true
                                wrapMode:       Text.WordWrap
                                Layout.fillWidth: true
                            }

                            Button {
                                text: "Buy me a coffee"
                                iconName: Icons.coffee
                                variant: Button.Variant.Outlined
                                onClicked: Qt.openUrlExternally("https://buymeacoffee.com/ajunior")
                            }
                        }

                        Item { Layout.preferredHeight: 40 }
                    }
                }
            }
        }

        // ── L-shaped divider (white region → grey content) ───────────────────
        Rectangle {
            x:      root._leftW
            y:      root._barH - 1
            width:  parent.width - root._leftW
            height: 1
            color:  Theme.border
        }
        Rectangle {
            x:      root._leftW
            y:      root._barH
            width:  1
            height: parent.height - root._barH
            color:  Theme.border
        }
    }

    FileDialog {
        id: _exportThemeDialog
        title: "Export Theme"
        fileMode: FileDialog.SaveFile
        defaultSuffix: "json"
        nameFilters: ["JSON files (*.json)", "All files (*)"]
        onAccepted: {
            const ok = ThemeManager.exportTheme(_themeSection._exportingId, selectedFile)
            _themeAlert.type    = ok ? Alert.Type.Success : Alert.Type.Error
            _themeAlert.message = ok ? "Theme exported successfully." : "Export failed. Could not write file."
            _themeAlert.visible = true
        }
    }

    FileDialog {
        id: _importThemeDialog
        title: "Import Theme"
        fileMode: FileDialog.OpenFile
        nameFilters: ["JSON files (*.json)", "All files (*)"]
        onAccepted: {
            const result = ThemeManager.importTheme(selectedFile)
            _themeAlert.type    = result.success ? Alert.Type.Success : Alert.Type.Error
            _themeAlert.message = result.message
            _themeAlert.visible = true
        }
    }

    FileDialog {
        id: _exportDialog
        title: "Export Connections"
        fileMode: FileDialog.SaveFile
        defaultSuffix: "json"
        selectedFile: StandardPaths.writableLocation(StandardPaths.DocumentsLocation) + "/qub-connections.json"
        nameFilters: ["JSON files (*.json)", "All files (*)"]
        onAccepted: {
            const ok = ConnectionManager.exportConnections(selectedFile)
            _ioAlert.type    = ok ? Alert.Type.Success : Alert.Type.Error
            _ioAlert.message = ok ? "Connections exported successfully." : "Export failed. Could not write file."
            _ioAlert.visible = true
        }
    }

    FileDialog {
        id: _importDialog
        title: "Import Connections"
        fileMode: FileDialog.OpenFile
        nameFilters: ["JSON files (*.json)", "All files (*)"]
        onAccepted: {
            const result = ConnectionManager.importConnections(selectedFile)
            _ioAlert.type    = result.success ? Alert.Type.Success : Alert.Type.Error
            _ioAlert.message = result.message
            _ioAlert.visible = true
        }
    }

    // Adds a CSV as a new table to an existing SQLite connection (creating a
    // fresh SQLite connection from a CSV lives in the New Connection form).
    FileDialog {
        id: _csvFileDialog
        property string targetConn: ""
        property string targetDb:   ""
        title: "Import CSV / TSV into " + targetConn
        fileMode: FileDialog.OpenFile
        nameFilters: ["Delimited text (*.csv *.tsv *.txt)", "All files (*)"]
        onAccepted: _csvImportDialog.openIntoExisting(targetConn, targetDb, selectedFile)
    }

    CsvImportDialog {
        id: _csvImportDialog
        anchors.fill: parent
        z: 150
        onTableAdded: (name, table) => {
            ConnectionManager.refreshSchema(name)
            _toaster.show("Added table \"" + table + "\" to \"" + name + "\".",
                          Toaster.Type.Success, 3000)
        }
    }

    FileDialog {
        id: _snipExportDialog
        title: "Export Snippets"
        fileMode: FileDialog.SaveFile
        defaultSuffix: "json"
        selectedFile: StandardPaths.writableLocation(StandardPaths.DocumentsLocation) + "/qub-snippets.json"
        nameFilters: ["JSON files (*.json)", "All files (*)"]
        onAccepted: {
            const ok = SnippetManager.exportSnippets(selectedFile)
            _snipAlert.type    = ok ? Alert.Type.Success : Alert.Type.Error
            _snipAlert.message = ok ? "Snippets exported successfully." : "Export failed. Could not write file."
            _snipAlert.visible = true
        }
    }

    FileDialog {
        id: _sshExportDialog
        title: "Export SSH Connections"
        fileMode: FileDialog.SaveFile
        defaultSuffix: "json"
        selectedFile: StandardPaths.writableLocation(StandardPaths.DocumentsLocation) + "/qub-ssh.json"
        nameFilters: ["JSON files (*.json)", "All files (*)"]
        onAccepted: {
            const ok = SshManager.exportConfigs(selectedFile)
            _sshAlert.type    = ok ? Alert.Type.Success : Alert.Type.Error
            _sshAlert.message = ok ? "SSH connections exported successfully." : "Export failed. Could not write file."
            _sshAlert.visible = true
        }
    }

    FileDialog {
        id: _sshImportDialog
        title: "Import SSH Connections"
        fileMode: FileDialog.OpenFile
        nameFilters: ["JSON files (*.json)", "All files (*)"]
        onAccepted: {
            const result = SshManager.importConfigs(selectedFile)
            _sshAlert.type    = result.success ? Alert.Type.Success : Alert.Type.Error
            _sshAlert.message = result.message
            _sshAlert.visible = true
        }
    }

    FileDialog {
        id: _snipImportDialog
        title: "Import Snippets"
        fileMode: FileDialog.OpenFile
        nameFilters: ["JSON files (*.json)", "All files (*)"]
        onAccepted: {
            const result = SnippetManager.importSnippets(selectedFile)
            _snipAlert.type    = result.success ? Alert.Type.Success : Alert.Type.Error
            _snipAlert.message = result.message
            _snipAlert.visible = true
        }
    }

    Connections {
        target: ConnectionManager

        // True once the pending Save & Connect has actually persisted —
        // distinguishes "saved but failed to open" from "not saved at all"
        // (e.g. duplicate name), which must stay in create mode.
        property bool _savedPending: false

        function onTestResult(success: bool, message: string): void {
            if (_connSection._showForm)
                _connForm.showTestResult(success, message)
        }

        // Fires when the connection is SAVED; the open attempt follows.
        // Plain Save returns to the list; Save & Connect keeps waiting.
        function onConnectionAdded(name: string): void {
            if (!_connSection._showForm || _connForm.isEditing) return
            if (_connForm.connecting && name === _connForm.pendingName)
                _savedPending = true
            else
                _connSection._resetForm()
        }

        // Save & Connect resolution: only enter the workspace once open.
        function onConnectionOpened(name: string): void {
            if (_connSection._showForm && _connForm.connecting
                    && name === _connForm.pendingName) {
                _savedPending = false
                _connSection._resetForm()
                root.connectionSelected(name)
            }
        }

        // Show driver / credential errors inline in the form. If the failed
        // connection was already saved, flip to edit mode so a retry updates
        // the record instead of duplicating it.
        function onConnectionError(name: string, message: string): void {
            if (!_connSection._showForm) return
            if (_connForm.connecting && name === _connForm.pendingName) {
                _connForm.connecting = false
                if (_savedPending) {
                    _savedPending = false
                    const conn = ConnectionManager.connections.find(c => c.name === name)
                    if (conn) _connForm.loadEdit(conn)
                }
            }
            _connForm.showError(message)
        }
    }

    Toaster { id: _toaster; anchors.fill: parent; z: 200 }

    WorkspaceFormDialog {
        id: _wsFormDialog
        anchors.fill: parent
        z: 150
    }

    ConfirmDialog {
        id:            _wsDeleteConfirm
        property int   wsId: -1
        dialogTitle:   "Delete workspace"
        confirmText:   "Delete"
        isDestructive: true
        onConfirmed:   WorkspaceManager.deleteWorkspace(wsId)
    }

    ConfirmDialog {
        id:              _connDeleteConfirm
        property string  connName: ""
        // Set from ConnectionManager.ownsDatabaseFile(): true when deleting also
        // destroys the imported SQLite file qub created for this connection.
        property bool    ownsFile: false
        dialogTitle:     "Delete connection?"
        dialogMessage:   ownsFile
            ? "\"" + connName + "\" was imported from a file. Deleting it permanently removes the "
              + "imported data — the SQLite database qub created for it — along with the stored "
              + "password. This can't be undone."
            : "\"" + connName + "\" and its stored password will be permanently removed. "
              + "Workspace tabs using it will stay but can no longer run."
        confirmText:     "Delete"
        isDestructive:   true
        onConfirmed:     ConnectionManager.removeConnection(connName)
    }

    ConfirmDialog {
        id:              _profileDeleteConfirm
        property string  profileId: ""
        dialogTitle:     "Delete profile?"
        confirmText:     "Delete"
        isDestructive:   true
        onConfirmed:     ProfileManager.removeProfile(profileId)
    }

    ConfirmDialog {
        id:            _snipDeleteConfirm
        property var   snipId: -1
        dialogTitle:   "Delete snippet?"
        confirmText:   "Delete"
        isDestructive: true
        onConfirmed:   SnippetManager.remove(snipId)
    }

    ConfirmDialog {
        id:            _deleteSshDialog
        dialogTitle:   "Delete SSH connection?"
        dialogMessage: "\"" + _sshSection._pendingDeleteName + "\" will be permanently removed."
        confirmText:   "Delete"
        isDestructive: true
        z:             100
        onConfirmed:   SshManager.removeConfig(_sshSection._pendingDeleteId)
    }

    FileDialog {
        id:          _sshKeyFileDlg
        title:       "Select private key file"
        nameFilters: ["All files (*)"]
        onAccepted:  _sKey.text = selectedFile.toString().replace("file://", "")
    }
}
