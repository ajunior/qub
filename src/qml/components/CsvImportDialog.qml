pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Mahina
import Qub

// Preview + import of a CSV/TSV file as a queryable SQLite table. Opened with a
// file URL; it sniffs the delimiter, infers column types and shows a preview,
// then on confirm writes a standalone SQLite database and registers it as an
// ordinary QSQLITE connection — after which the data is queryable with plain SQL.
Dialog {
    id: root

    property url    _fileUrl
    property var    _preview:  null   // result of CsvImporter.preview()
    property bool   _hasHeader: true
    property string _error:     ""

    // "newSource"     → import creates a fresh SQLite connection.
    // "intoExisting"  → import adds a table to an existing SQLite connection.
    property string _mode:       "newSource"
    property string _targetConn: ""
    property string _targetDb:   ""

    // Emitted after a fresh connection is registered, with its name.
    signal imported(string connectionName)
    // Emitted after a table is added to an existing connection.
    signal tableAdded(string connectionName, string tableName)

    title:          _mode === "intoExisting" ? "Import CSV as table" : "Import CSV"
    subtitle:       _mode === "intoExisting"
                    ? (_fileName() + "  →  " + _targetConn)
                    : _fileName()
    preferredWidth: 640

    function openFile(fileUrl: var): void {
        root._mode      = "newSource"
        root._targetConn = ""
        root._targetDb   = ""
        _prepare(fileUrl)
    }

    // Import into an existing SQLite connection (dbPath is its file).
    function openIntoExisting(connName: var, dbPath: var, fileUrl: var): void {
        root._mode       = "intoExisting"
        root._targetConn = connName
        root._targetDb   = dbPath
        _prepare(fileUrl)
    }

    function _prepare(fileUrl: var): void {
        root._fileUrl   = fileUrl
        root._hasHeader = true
        root._error     = ""
        _reload()
        _nameInput.text = (root._preview && root._preview.success)
                          ? root._preview.table : "imported"
        open()   // Dialog.open()
        _nameInput.forceActiveFocus()
    }

    function _reload(): void {
        root._preview = CsvImporter.preview(root._fileUrl, root._hasHeader)
    }

    function _fileName(): var {
        const s = root._fileUrl.toString()
        const i = s.lastIndexOf("/")
        return i >= 0 ? s.substring(i + 1) : s
    }

    readonly property bool _ok: root._preview && root._preview.success === true
    readonly property var  _columns: _ok ? root._preview.columns : []
    readonly property var  _rows:    _ok ? root._preview.rows    : []

    function _delimLabel(): var {
        if (!_ok) return ""
        const d = root._preview.delimiter
        return d === "\t" ? "Tab" : d === "," ? "Comma"
             : d === ";"  ? "Semicolon" : d === "|" ? "Pipe" : d
    }

    function _doImport(): void {
        const name = _nameInput.text.trim()
        if (name === "") { root._error = "Give the table a name."; return }

        if (root._mode === "intoExisting") {
            const r = CsvImporter.importInto(root._targetDb, root._fileUrl, name,
                                             root._hasHeader,
                                             _ok ? root._preview.delimiter : "")
            if (!r.success) { root._error = r.error; return }
            root.tableAdded(root._targetConn, r.table)
            close()
            return
        }

        if (ConnectionManager.connections.some(c => c.name === name)) {
            root._error = "A connection named \"" + name + "\" already exists."
            return
        }
        const r = CsvImporter.import(root._fileUrl, name, root._hasHeader,
                                     _ok ? root._preview.delimiter : "")
        if (!r.success) { root._error = r.error; return }

        ConnectionManager.addConnection({
            name:     name,
            driver:   "QSQLITE",
            database: r.database
        })
        root.imported(name)
        close()
    }

    ColumnLayout {
        width: parent.width
        spacing: Theme.sp3

        // ── Parse error ────────────────────────────────────────────────────────
        Alert {
            Layout.fillWidth: true
            visible: !root._ok && root._preview !== null
            type:    Alert.Type.Error
            message: root._ok ? "" : (root._preview ? root._preview.error : "")
        }

        // ── Name + options ─────────────────────────────────────────────────────
        Input {
            id: _nameInput
            Layout.fillWidth: true
            label:           root._mode === "intoExisting"
                             ? "Table name" : "Table / connection name"
            placeholderText: "e.g. sales_2026"
            maximumLength:   60
            errorText:       root._error
            onTextEdited:    root._error = ""
            onAccepted:      root._doImport()
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.sp3
            visible: root._ok

            Checkbox {
                text:    "First row is header"
                checked: root._hasHeader
                onToggled: {
                    root._hasHeader = checked
                    root._reload()
                }
            }

            Item { Layout.fillWidth: true }

            Text {
                text:  "Delimiter"
                color: Theme.textDisabled
                font { family: Theme.fontFamily; pixelSize: Theme.textXs }
            }
            Badge {
                text:        root._delimLabel()
                colorScheme: Badge.Color.Default
            }
            Badge {
                text:        root._columns.length + (root._columns.length === 1 ? " column" : " columns")
                colorScheme: Badge.Color.Info
            }
        }

        // ── Preview grid ───────────────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 240
            visible: root._ok
            color:        Theme.surface
            radius:       Theme.radiusMd
            border.color: Theme.border
            border.width: 1
            clip: true

            ScrollArea {
                anchors.fill: parent
                horizontal: true

                Column {
                    spacing: 0

                    // Header row: column name + inferred type
                    Row {
                        spacing: 0
                        Repeater {
                            model: root._columns
                            delegate: Rectangle {
                                id: delegateItem
                                required property var modelData
                                width:  160
                                height: 44
                                color:  Theme.panel
                                Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.border }
                                Column {
                                    anchors { left: parent.left; verticalCenter: parent.verticalCenter; leftMargin: Theme.sp3 }
                                    spacing: 2
                                    Text {
                                        text: delegateItem.modelData.name
                                        color: Theme.textPrimary
                                        width: 148 - Theme.sp3
                                        elide: Text.ElideRight
                                        font { family: Theme.fontFamilyMono; pixelSize: Theme.textSm; weight: Theme.weightSemibold }
                                    }
                                    Text {
                                        text: delegateItem.modelData.type
                                        color: delegateItem.modelData.type === "TEXT" ? Theme.textDisabled : Theme.info
                                        font { family: Theme.fontFamilyMono; pixelSize: Theme.textXs }
                                    }
                                }
                            }
                        }
                    }

                    // Data rows
                    Repeater {
                        model: root._rows
                        delegate: Row {
                            id: _dataRow
                            required property var modelData
                            required property int index
                            spacing: 0
                            Repeater {
                                model: _dataRow.modelData
                                delegate: Rectangle {
                                    id: _cell
                                    required property var modelData
                                    width:  160
                                    height: 30
                                    color:  _dataRow.index % 2 === 0
                                            ? "transparent"
                                            : Qt.rgba(Theme.textPrimary.r, Theme.textPrimary.g, Theme.textPrimary.b, 0.03)
                                    Text {
                                        anchors { left: parent.left; verticalCenter: parent.verticalCenter
                                                  leftMargin: Theme.sp3; right: parent.right; rightMargin: Theme.sp2 }
                                        text:  _cell.modelData === "" ? "∅" : _cell.modelData
                                        color: _cell.modelData === "" ? Theme.textDisabled : Theme.textSecondary
                                        elide: Text.ElideRight
                                        font { family: Theme.fontFamilyMono; pixelSize: Theme.textXs }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        Text {
            Layout.fillWidth: true
            visible: root._ok
            text:  "Showing the first " + root._rows.length + " row" + (root._rows.length === 1 ? "" : "s")
                   + ". The full file is imported. "
                   + (root._mode === "intoExisting"
                      ? "The table is added to \"" + root._targetConn
                        + "\" so you can join it with the other tables there."
                      : "The table becomes a SQLite connection you can query with SQL.")
            color: Theme.textDisabled
            wrapMode: Text.WordWrap
            font { family: Theme.fontFamily; pixelSize: Theme.textXs }
        }
    }

    footer: RowLayout {
        spacing: Theme.sp2

        Button {
            text:    "Cancel"
            variant: Button.Variant.Ghost
            onClicked: root.close()
        }
        Button {
            text:    "Import"
            variant: Button.Variant.Filled
            enabled: root._ok && _nameInput.text.trim() !== ""
            onClicked: root._doImport()
        }
    }
}
