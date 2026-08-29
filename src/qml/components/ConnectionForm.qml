pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import Mahina
import "../drivers.js" as Drivers
import Qub

// Shared connection form used by the Data Sources page (new/edit in place)
// and by ConnectionDialog (new connection from inside a workspace).
ColumnLayout {
    id: root

    property string editingName: ""
    readonly property bool isEditing: editingName !== ""

    // "Save & Connect" flow: connecting spins the button until the host
    // screen resolves it via connectionOpened / connectionError. pendingName
    // lets the host match those signals to this form's save.
    property bool   connecting:  false
    property string pendingName: ""

    // The plain "Save" button (save without connecting) — hidden inside the
    // workspace ConnectionDialog, where saving always adopts a tab anyway.
    property bool allowSaveWithoutConnect: true

    // Suppresses the driver-change port autofill while loadNew/loadEdit run.
    property bool _loading: false

    // A connection test is in flight. Driven by ConnectionManager, not by the
    // click, so it also covers the second attempt after a host-key prompt and
    // lowers itself on every path the test can end on.
    property bool _testing: false

    // Drivers the connection form offers. Only what Qt can actually load here:
    // a driver with no plugin behind it produces a connection that fails with
    // "driver could not be loaded" and nothing the user can do about it, and
    // Qt's official macOS and Windows binaries ship no MySQL plugin at all.
    //
    // _unusableDriver is the exception. Editing a connection saved with a
    // driver this build lacks — imported from another machine, most likely —
    // keeps that driver in the list so opening the form does not silently
    // rewrite it to whatever sorts first.
    property string _unusableDriver: ""
    readonly property var _driverLabels: {
        const avail = Drivers.availableLabels(ConnectionManager.availableDrivers)
        return (root._unusableDriver !== "" && avail.indexOf(root._unusableDriver) === -1)
            ? avail.concat([root._unusableDriver])
            : avail
    }

    // Docker discovery: whether the `docker` CLI is present (cached once, per
    // loadNew, rather than re-scanning PATH on every binding) and the last set
    // of discovered database containers offered in the picker menu.
    property bool _dockerAvailable: false
    property var  _dockerCandidates: []

    // SQLite source mode (new connections only): 0 = open existing file,
    // 1 = create new database, 2 = import a CSV/TSV as a queryable table.
    property int  _sqliteMode: 0
    property url  _csvUrl
    property var  _csvPreview: null   // CsvImporter.preview() result
    property bool _csvHeader:  true

    readonly property bool _isSqlite:  _driverDrop.currentValue === "SQLite"
    readonly property bool _isCsvMode: _isSqlite && !isEditing && _sqliteMode === 2
    readonly property bool _csvReady:  _csvPreview && _csvPreview.success === true

    function _csvFileName(): var {
        const s = _csvUrl.toString()
        const i = s.lastIndexOf("/")
        return i >= 0 ? s.substring(i + 1) : s
    }
    function _reloadCsv(): void {
        _csvPreview = _csvUrl.toString() !== ""
                      ? CsvImporter.preview(_csvUrl, _csvHeader) : null
    }
    function _csvDelimLabel(): var {
        if (!_csvReady) return ""
        const d = _csvPreview.delimiter
        return d === "\t" ? "Tab" : d === "," ? "Comma"
             : d === ";"  ? "Semicolon" : d === "|" ? "Pipe" : d
    }

    // Save (optionally connecting). CSV mode imports first, then registers the
    // resulting SQLite file as an ordinary QSQLITE connection.
    function _save(doConnect: var): void {
        let params
        if (_isCsvMode) {
            if (!_csvReady) { root.showError("Choose a CSV file to import."); return }
            // Validate the connection name *before* importing — the import writes
            // a file to disk, and addConnection rejects blank/duplicate names, so
            // checking here avoids orphaning that file.
            const nm = _nameInput.text.trim()
            if (nm === "") { root.showError("Give the connection a name."); return }
            if (ConnectionManager.connections.some(c => c.name === nm)) {
                root.showError("A connection named \"" + nm + "\" already exists.")
                return
            }
            const r = CsvImporter.import(_csvUrl, _csvTableInput.text.trim(),
                                         _csvHeader, _csvPreview.delimiter)
            if (!r.success) { root.showError(r.error); return }
            params          = root._buildParams()
            params.driver   = "QSQLITE"
            params.database = r.database
        } else {
            params = root._buildParams()
        }
        if (doConnect) {
            root.pendingName = params.name
            root.connecting  = true
            ConnectionManager.addConnection(params)
            root.added(params.name)
        } else {
            ConnectionManager.addConnection(params)
        }
    }

    signal cancelled()
    signal added(string name)
    signal updated(string name)

    spacing: 16

    function loadNew(): void {
        _loading = true
        // A test left running by the form we are replacing is not this form's,
        // so it must not arrive here already spinning. Its testPending(false)
        // still lands harmlessly.
        _testing = false
        editingName              = ""
        _unusableDriver          = ""
        _nameInput.text          = ""
        _driverDrop.currentIndex = 0
        _profileDrop.currentIndex = 0
        _sshDrop.currentIndex    = 0
        _urlCheck.checked        = false
        _sqliteMode              = 0
        _sqliteModeSeg.currentIndex = 0
        _csvUrl                  = ""
        _csvPreview              = null
        _csvHeader               = true
        _csvTableInput.text      = ""
        _urlInput.text           = ""
        _hostInput.text          = ""
        _portInput.text          = "5432"
        _dbInput.text            = ""
        _userInput.text          = ""
        _passInput.text          = ""
        _sslCheck.checked        = false
        _sslCaCertInput.text     = ""
        _sslClientCertInput.text = ""
        _sslClientKeyInput.text  = ""
        _timeoutInput.text       = "30"
        _schemaInput.text        = ""
        _alert.visible           = false
        connecting  = false
        pendingName = ""
        _dockerAvailable  = DockerDiscovery.available()
        _dockerCandidates = []
        _loading = false
    }

    // Prefill host/port/creds from a discovered Docker container. Wrapped in
    // _loading so setting the driver does not trip its port-autofill handler
    // and clobber the container's actual published port.
    function _prefillDocker(c: var): void {
        _loading = true
        _urlCheck.checked = false
        const di = _driverDrop.model.indexOf(Drivers.label(c.driver))
        if (di >= 0) _driverDrop.currentIndex = di
        _hostInput.text = c.host || "127.0.0.1"
        _portInput.text = c.port > 0 ? c.port.toString() : ""
        _dbInput.text   = c.database || ""
        _userInput.text = c.username || ""
        _passInput.text = c.password || ""
        if (!_nameInput.text.trim()) _nameInput.text = c.name || ""
        _loading = false

        _alert.type = Alert.Type.Success
        _alert.message = "Prefilled from container “" + (c.name || "") + "”."
            + (c.password ? "" : " No password found in the container’s env — enter it manually if the database requires one.")
        _alert.visible = true
    }

    function loadEdit(conn: var): void {
        loadNew()
        _loading = true
        editingName = conn.name
        _nameInput.text = conn.name

        // Set _unusableDriver before reading the model: _driverLabels appends it,
        // so the index below finds the saved driver rather than falling back to
        // the first entry and quietly changing what the connection is.
        const savedLabel = Drivers.label(conn.driver)
        if (root._driverLabels.indexOf(savedLabel) === -1)
            root._unusableDriver = savedLabel
        const di = _driverDrop.model.indexOf(savedLabel)
        _driverDrop.currentIndex = di >= 0 ? di : 0
        const pi = ProfileManager.profiles.findIndex(p => p.id === conn.profileId)
        _profileDrop.currentIndex = pi >= 0 ? pi + 1 : 0
        const si = SshManager.configs.findIndex(c => c.id === conn.sshConfigId)
        _sshDrop.currentIndex = si >= 0 ? si + 1 : 0

        // Connections saved in URL mode keep the URL in the database field.
        const isUrl = (conn.database || "").indexOf("://") !== -1 && !conn.host
        _urlCheck.checked = isUrl
        if (isUrl) {
            _urlInput.text = conn.database
        } else {
            _hostInput.text = conn.host || ""
            _portInput.text = conn.port > 0 ? conn.port.toString() : ""
            _dbInput.text   = conn.database || ""
            _userInput.text = conn.username || ""
        }

        _sslCheck.checked        = conn.ssl === true
        _sslCaCertInput.text     = conn.sslCaCert     || ""
        _sslClientCertInput.text = conn.sslClientCert || ""
        _sslClientKeyInput.text  = conn.sslClientKey  || ""
        _timeoutInput.text       = (conn.timeout || 30).toString()
        _schemaInput.text        = conn.schema || ""
        _loading = false
    }

    Connections {
        target: ConnectionManager
        function onTestPending(pending: bool): void { root._testing = pending }
    }

    function showTestResult(ok: var, msg: var): void {
        _alert.type    = ok ? Alert.Type.Success : Alert.Type.Error
        _alert.message = msg
        _alert.visible = true
    }

    function showError(msg: var): void {
        _alert.type    = Alert.Type.Error
        _alert.message = msg
        _alert.visible = true
    }

    function _buildParams(): var {
        const profs     = ProfileManager.profiles
        const profileId = _profileDrop.currentIndex > 0 ? profs[_profileDrop.currentIndex - 1].id : ""
        const sshCfgs   = SshManager.configs
        const sshConfigId = (_sshDrop.currentIndex > 0 && _sshDrop.currentIndex <= sshCfgs.length)
                            ? sshCfgs[_sshDrop.currentIndex - 1].id : ""
        return {
            name:        _nameInput.text,
            driver:      Drivers.qtKey(_driverDrop.currentValue ?? ""),
            host:        _urlCheck.checked ? "" : _hostInput.text,
            port:        _urlCheck.checked ? 0  : (parseInt(_portInput.text) || 0),
            database:    _urlCheck.checked ? _urlInput.text : _dbInput.text,
            username:    _urlCheck.checked ? "" : _userInput.text,
            password:    _urlCheck.checked ? "" : _passInput.text,
            profileId:   profileId,
            sshConfigId: sshConfigId,
            ssl:           _sslCheck.checked,
            sslCaCert:     _sslCaCertInput.text,
            sslClientCert: _sslClientCertInput.text,
            sslClientKey:  _sslClientKeyInput.text,
            timeout:       parseInt(_timeoutInput.text) || 30,
            schema:        _schemaInput.text
        }
    }

    Text {
        text: root.isEditing ? "EDIT CONNECTION" : "NEW CONNECTION"
        color: Theme.textDisabled
        font.family:      Theme.fontFamily
        font.pixelSize:   Theme.textXs
        font.weight:      Theme.weightSemibold
        font.letterSpacing: 1.5
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: 12
        z: _driverDrop._open || _profileDrop._open || _sshDrop._open ? 100 : 0

        Input {
            id: _nameInput
            label: "Name"
            placeholderText: "prod-postgres"
            Layout.fillWidth: true
        }

        Dropdown {
            id: _driverDrop
            label: "Driver"
            Layout.preferredWidth: 160
            model: root._driverLabels
            onCurrentIndexChanged: {
                if (root._loading) return
                _alert.visible = false
                const ports = { "PostgreSQL": "5432", "MySQL": "3306",
                                "MariaDB": "3306", "Oracle": "1521",
                                "Firebird": "3050", "SQLite": "", "ODBC": "" }
                _portInput.text = ports[model[currentIndex]] ?? ""
            }
        }

        Dropdown {
            id: _profileDrop
            label: "Profile"
            Layout.preferredWidth: 130
            model: {
                const names = ["(None)"]
                ProfileManager.profiles.forEach(p => names.push(p.name))
                return names
            }
        }

        Dropdown {
            id: _sshDrop
            label: "SSH Tunnel"
            Layout.preferredWidth: 140
            model: {
                const names = ["(None)"]
                SshManager.configs.forEach(c => names.push(c.name))
                return names
            }
        }
    }

    // Discover a running Docker database container and prefill from it. Shown
    // only for new server connections when the `docker` CLI is present; stays
    // invisible otherwise (qub never manages containers, only reads them).
    RowLayout {
        Layout.fillWidth: true
        spacing: 8
        visible: !root._isSqlite && !root.isEditing && root._dockerAvailable

        Button {
            id: _dockerBtn
            text: "Discover Docker container"
            iconName: Icons.shippingContainer
            variant: Button.Variant.Ghost
            onClicked: {
                const found = DockerDiscovery.discover()
                if (found.length === 0) {
                    root.showError("No running database containers with a published port were found.")
                    return
                }
                root._dockerCandidates = found
                _dockerMenu.open()
            }
        }
        Item { Layout.fillWidth: true }

        Menu {
            id: _dockerMenu
            anchor: _dockerBtn
            model: root._dockerCandidates.map(c => ({
                label: c.name + "  ·  " + c.image + "  :" + c.port,
                icon:  Icons.database
            }))
            onTriggered: (index, item) => root._prefillDocker(root._dockerCandidates[index])
        }
    }

    Checkbox {
        id: _urlCheck
        text: "Use database URL"
        visible: _driverDrop.currentValue !== "SQLite"
        onVisibleChanged: if (!visible) checked = false
    }

    // SQLite source: open an existing file, create a new one, or import a CSV.
    // Editing an existing connection always uses the plain file path.
    RowLayout {
        Layout.fillWidth: true
        spacing: 12
        visible: root._isSqlite && !root.isEditing

        Text {
            text:  "Source"
            color: Theme.textSecondary
            font { family: Theme.fontFamily; pixelSize: Theme.textSm; weight: Theme.weightMedium }
        }
        SegmentedControl {
            id: _sqliteModeSeg
            model: ["Open file", "New database", "Import CSV"]
            currentIndex: 0
            onSelectionChanged: (index) => {
                root._sqliteMode = index
                _alert.visible = false
            }
        }
    }

    Input {
        id: _urlInput
        label: "Database URL"
        placeholderText: "postgresql://user:pass@host:5432/db"
        Layout.fillWidth: true
        visible: _urlCheck.checked
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: 12
        visible: _driverDrop.currentValue !== "SQLite" && !_urlCheck.checked

        Input {
            id: _hostInput
            label: "Host"
            placeholderText: "localhost"
            Layout.fillWidth: true
        }

        Input {
            id: _portInput
            label: "Port"
            text: "5432"
            placeholderText: ({ "PostgreSQL": "5432", "MySQL": "3306",
                                "MariaDB": "3306", "Oracle": "1521",
                                "Firebird": "3050" })[_driverDrop.currentValue] ?? "Port"
            Layout.preferredWidth: 100
        }
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: 8
        visible: !_urlCheck.checked && !root._isCsvMode

        Input {
            id: _dbInput
            label: root._isSqlite
                   ? (root._sqliteMode === 1 ? "New file path" : "File path")
                   : "Database"
            placeholderText: root._isSqlite
                             ? (root._sqliteMode === 1
                                ? "/path/to/new.sqlite"
                                : "/path/to/db.sqlite")
                             : "mydb"
            Layout.fillWidth: true
        }

        Tooltip {
            text: "Browse for database file"
            visible: root._isSqlite
            Layout.alignment: Qt.AlignBottom

            Button {
                iconOnly: true
                iconName: Icons.folderOpen
                variant: Button.Variant.Outlined
                onClicked: _sqliteFileDlg.open()
            }
        }
    }

    // ── Import CSV (SQLite source = "Import CSV") ────────────────────────────
    RowLayout {
        Layout.fillWidth: true
        spacing: 8
        visible: root._isCsvMode

        Input {
            id: _csvPathInput
            label: "CSV / TSV file"
            placeholderText: "/path/to/data.csv"
            text: root._csvFileName()
            readOnly: true
            Layout.fillWidth: true
        }

        Tooltip {
            text: "Browse for CSV file"
            Layout.alignment: Qt.AlignBottom

            Button {
                iconOnly: true
                iconName: Icons.folderOpen
                variant: Button.Variant.Outlined
                onClicked: _csvFileDlg.open()
            }
        }
    }

    Input {
        id: _csvTableInput
        Layout.fillWidth: true
        visible: root._isCsvMode
        label: "Table name"
        placeholderText: "e.g. sales_2026"
        maximumLength: 60
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: 12
        visible: root._isCsvMode && root._csvReady

        Checkbox {
            text:    "First row is header"
            checked: root._csvHeader
            onToggled: {
                root._csvHeader = checked
                root._reloadCsv()
            }
        }

        Item { Layout.fillWidth: true }

        Badge {
            text:        root._csvDelimLabel()
            colorScheme: Badge.Color.Default
        }
        Badge {
            text: root._csvReady
                  ? root._csvPreview.columns.length
                    + (root._csvPreview.columns.length === 1 ? " column" : " columns")
                  : ""
            colorScheme: Badge.Color.Info
        }
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: 12
        visible: _driverDrop.currentValue !== "SQLite" && !_urlCheck.checked

        Input {
            id: _userInput
            label: "Username"
            placeholderText: "postgres"
            Layout.fillWidth: true
        }

        Input {
            id: _passInput
            label: "Password"
            placeholderText: root.isEditing ? "Leave blank to keep current" : "••••••••"
            echoMode: TextInput.Password
            Layout.fillWidth: true
        }
    }

    // Kept apart from _alert, which is cleared by half the handlers in this
    // file: this one states a fact about the build, not the result of an action.
    Alert {
        Layout.fillWidth: true
        type:    Alert.Type.Warning
        visible: root._unusableDriver !== ""
                 && _driverDrop.currentValue === root._unusableDriver
        message: "This build has no " + root._unusableDriver + " driver, so the "
               + "connection cannot be opened here. Saving keeps the driver as it is."
    }

    Alert {
        id: _alert
        Layout.fillWidth: true
        visible: false
    }

    Accordion {
        Layout.fillWidth: true
        title: "Advanced"
        style: Accordion.Style.Section

        Checkbox {
            id: _sslCheck
            text: "Require SSL"
            Layout.fillWidth: true
            visible: _driverDrop.currentValue !== "SQLite"
                     && _driverDrop.currentValue !== "ODBC"
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            visible: _sslCheck.checked
                     && _driverDrop.currentValue !== "SQLite"
                     && _driverDrop.currentValue !== "ODBC"

            Input {
                id: _sslCaCertInput
                label: "CA Certificate"
                placeholderText: "/path/to/ca.crt"
                Layout.fillWidth: true
            }
            Tooltip {
                text: "Browse for CA certificate"
                Layout.alignment: Qt.AlignBottom

                Button {
                    iconOnly: true
                    iconName: Icons.folderOpen
                    variant:  Button.Variant.Outlined
                    onClicked: _sslCaDlg.open()
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            visible: _sslCheck.checked
                     && _driverDrop.currentValue !== "SQLite"
                     && _driverDrop.currentValue !== "ODBC"

            Input {
                id: _sslClientCertInput
                label: "Client Certificate"
                placeholderText: "/path/to/client.crt"
                Layout.fillWidth: true
            }
            Tooltip {
                text: "Browse for client certificate"
                Layout.alignment: Qt.AlignBottom

                Button {
                    iconOnly: true
                    iconName: Icons.folderOpen
                    variant:  Button.Variant.Outlined
                    onClicked: _sslClientCertDlg.open()
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            visible: _sslCheck.checked
                     && _driverDrop.currentValue !== "SQLite"
                     && _driverDrop.currentValue !== "ODBC"

            Input {
                id: _sslClientKeyInput
                label: "Client Key"
                placeholderText: "/path/to/client.key"
                Layout.fillWidth: true
            }
            Tooltip {
                text: "Browse for client key"
                Layout.alignment: Qt.AlignBottom

                Button {
                    iconOnly: true
                    iconName: Icons.folderOpen
                    variant:  Button.Variant.Outlined
                    onClicked: _sslClientKeyDlg.open()
                }
            }
        }

        Input {
            id: _timeoutInput
            Layout.fillWidth: true
            label: "Connection timeout (s)"
            text: "30"
            placeholderText: "30"
            visible: _driverDrop.currentValue !== "SQLite"
        }

        Input {
            id: _schemaInput
            Layout.fillWidth: true
            label: "Default schema"
            placeholderText: "public"
            visible: ["PostgreSQL", "MySQL", "MariaDB"]
                     .indexOf(_driverDrop.currentValue) >= 0
        }
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: 8

        Button {
            // Importing a CSV has nothing to test until it's saved.
            visible: !root._isCsvMode
            // Opening a connection can take the whole connect timeout, and
            // until it answers there was nothing on screen to say the click
            // landed. loading spins an icon beside the label and disables the
            // button, so a second click cannot queue a second test.
            text:    root._testing ? "Testing…" : "Test"
            loading: root._testing
            variant: Button.Variant.Outlined
            onClicked: ConnectionManager.testConnection(root._buildParams())
        }

        Item { Layout.fillWidth: true }

        Button {
            text: "Cancel"
            variant: Button.Variant.Ghost
            onClicked: root.cancelled()
        }

        Button {
            visible: !root.isEditing && root.allowSaveWithoutConnect
            text: "Save"
            variant: Button.Variant.Outlined
            enabled: !root.connecting && (!root._isCsvMode || root._csvReady)
            onClicked: root._save(false)
        }

        Button {
            text: root.isEditing ? "Update"
                                 : (root._isCsvMode ? "Import & Connect" : "Save & Connect")
            variant: Button.Variant.Filled
            loading: !root.isEditing && root.connecting
            enabled: !root._isCsvMode || root._csvReady
            onClicked: {
                if (root.isEditing) {
                    const newName = _nameInput.text.trim()
                    if (newName === "") {
                        root.showError("Give the connection a name.")
                        return
                    }
                    if (newName !== root.editingName
                            && ConnectionManager.connections.some(c => c.name === newName)) {
                        root.showError("A connection named \"" + newName + "\" already exists.")
                        return
                    }
                    ConnectionManager.updateConnection(root.editingName, root._buildParams())
                    root.updated(newName)
                } else {
                    root._save(true)
                }
            }
        }
    }

    FileDialog {
        id:          _sqliteFileDlg
        title:       root._sqliteMode === 1 ? "Create new database" : "Open database"
        fileMode:    root._sqliteMode === 1 ? FileDialog.SaveFile : FileDialog.OpenFile
        nameFilters: ["SQLite databases (*.db *.sqlite *.sqlite3)", "All files (*)"]
        onAccepted:  _dbInput.text = selectedFile.toString().replace("file://", "")
    }

    FileDialog {
        id:          _csvFileDlg
        title:       "Choose CSV file"
        fileMode:    FileDialog.OpenFile
        nameFilters: ["Delimited text (*.csv *.tsv *.txt)", "All files (*)"]
        onAccepted:  {
            root._csvUrl = selectedFile
            root._reloadCsv()
            if (root._csvReady) {
                _alert.visible = false
                if (_csvTableInput.text.trim() === "")
                    _csvTableInput.text = root._csvPreview.table
                if (_nameInput.text.trim() === "")
                    _nameInput.text = root._csvPreview.table
            } else {
                root.showError(root._csvPreview ? root._csvPreview.error
                                                : "Could not read that file.")
            }
        }
    }

    FileDialog {
        id:          _sslCaDlg
        title:       "Select CA Certificate"
        fileMode:    FileDialog.OpenFile
        nameFilters: ["Certificate files (*.crt *.pem *.cer)", "All files (*)"]
        onAccepted:  _sslCaCertInput.text = selectedFile.toString().replace("file://", "")
    }

    FileDialog {
        id:          _sslClientCertDlg
        title:       "Select Client Certificate"
        fileMode:    FileDialog.OpenFile
        nameFilters: ["Certificate files (*.crt *.pem *.cer)", "All files (*)"]
        onAccepted:  _sslClientCertInput.text = selectedFile.toString().replace("file://", "")
    }

    FileDialog {
        id:          _sslClientKeyDlg
        title:       "Select Client Key"
        fileMode:    FileDialog.OpenFile
        nameFilters: ["Key files (*.key *.pem)", "All files (*)"]
        onAccepted:  _sslClientKeyInput.text = selectedFile.toString().replace("file://", "")
    }
}
