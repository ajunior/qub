pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Dialogs
import QtCore
import Mahina
import Qub

// Reusable activity-log view: category/connection filters, the expandable
// entry list, and a status bar. Embedded both in the detached LogWindow
// (Ctrl+L in the workspace) and in the Home screen's Logs tab. Sizes to its
// parent — give it an explicit height when placed in a content-sized panel.
Item {
    id: root

    signal openSqlInEditor(string sql)

    Toaster { id: _toast }

    // ── Filtering state ───────────────────────────────────────────────────────
    property var    _enabledCats: ["SSH", "CONN", "QUERY", "AI", "SYSTEM"]
    property string _connFilter:  ""
    property bool   _autoScroll:  true

    readonly property var _allConns: {
        var names = [], seen = {}
        for (var i = 0; i < LogManager.entries.length; i++) {
            var n = LogManager.entries[i].connection ?? ""
            if (n !== "" && !seen[n]) { seen[n] = true; names.push(n) }
        }
        return names
    }

    readonly property var _catFilterItems: [
        { key: "SSH",   label: "SSH",   active: root._enabledCats.indexOf("SSH")   !== -1 },
        { key: "CONN",  label: "CONN",  active: root._enabledCats.indexOf("CONN")  !== -1 },
        { key: "QUERY", label: "QUERY", active: root._enabledCats.indexOf("QUERY") !== -1 },
        { key: "AI",    label: "AI",    active: root._enabledCats.indexOf("AI")    !== -1 },
    ]

    readonly property var _filtered: {
        var cats = root._enabledCats
        var conn = root._connFilter
        return LogManager.entries.filter(function(e) {
            if (cats.indexOf(e.category ?? "") === -1) return false
            if (conn !== "" && e.connection !== conn) return false
            return true
        })
    }

    // ── Root layout ───────────────────────────────────────────────────────────
    ColumnLayout {
        anchors.fill: parent
        spacing:      0

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

                // Category filter chips
                FilterBar {
                    filterItems:  root._catFilterItems
                    showClearAll: false
                    multiSelect:  true
                    Layout.alignment: Qt.AlignVCenter
                    onFilterToggled: (f, active) => {
                        var cats = root._enabledCats.slice()
                        var idx  = cats.indexOf(f.key)
                        if (active  && idx === -1) cats.push(f.key)
                        if (!active && idx !== -1) cats.splice(idx, 1)
                        root._enabledCats = cats
                    }
                }

                Rectangle { width: 1; height: 20; color: Theme.border; Layout.alignment: Qt.AlignVCenter }

                // Connection filter dropdown
                Dropdown {
                    implicitWidth: 150
                    label:         ""
                    placeholder:   "All connections"
                    model:          ["All connections"].concat(root._allConns)
                    currentIndex: {
                        if (root._connFilter === "") return 0
                        var idx = root._allConns.indexOf(root._connFilter)
                        return idx === -1 ? 0 : idx + 1
                    }
                    Layout.alignment: Qt.AlignVCenter
                    onCurrentIndexChanged: {
                        root._connFilter = currentIndex === 0 ? "" : (root._allConns[currentIndex - 1] ?? "")
                    }
                }

                Item { Layout.fillWidth: true }

                Tooltip {
                    text: "Export log"
                    Layout.alignment: Qt.AlignVCenter

                    Button {
                        id:       _exportBtn
                        iconOnly: true
                        iconName: Icons.downloadSimple
                        size:     Button.Size.Sm
                        variant:  Button.Variant.Ghost
                        onClicked: _exportMenu.open()
                    }
                }

                Menu {
                    id:     _exportMenu
                    anchor: _exportBtn
                    model: [
                        { label: "Export JSON…", icon: Icons.brackets },
                        { label: "Export CSV…",  icon: Icons.table    },
                        null,
                        { label: "Copy as JSON", icon: Icons.copy },
                        { label: "Copy as CSV",  icon: Icons.copy },
                    ]
                    onTriggered: (index, item) => {
                        if (index === 0 || index === 1) {
                            _logExportDialog.asJson = (index === 0)
                            _logExportDialog.openSuggested()
                            return
                        }
                        const text = index === 3 ? LogManager.exportJson() : LogManager.exportCsv()
                        _clip.text = text
                        _clip.selectAll()
                        _clip.copy()
                        _clip.text = ""
                    }
                }

                FileDialog {
                    id:          _logExportDialog
                    property bool asJson: true
                    title:       "Export log"
                    fileMode:    FileDialog.SaveFile
                    defaultSuffix: asJson ? "json" : "csv"
                    nameFilters: asJson ? ["JSON files (*.json)", "All files (*)"]
                                        : ["CSV files (*.csv)",  "All files (*)"]
                    function openSuggested(): void {
                        const day = new Date().toISOString().slice(0, 10)
                        selectedFile = StandardPaths.writableLocation(StandardPaths.DocumentsLocation)
                                       + "/qub-log-" + day + (asJson ? ".json" : ".csv")
                        open()
                    }
                    onAccepted: {
                        const ok = AppSettings.writeFile(selectedFile,
                                       asJson ? LogManager.exportJson() : LogManager.exportCsv())
                        _toast.show(ok ? "Log exported." : "Export failed. Could not write file.",
                                    ok ? Toaster.Type.Success : Toaster.Type.Error)
                    }
                }

                Tooltip {
                    text: "Clear log"
                    Layout.alignment: Qt.AlignVCenter

                    Button {
                        iconOnly: true
                        iconName: Icons.trash
                        size:     Button.Size.Sm
                        variant:  Button.Variant.Ghost
                        onClicked: LogManager.clear()
                    }
                }

                // Hidden TextEdit for clipboard copy
                TextEdit { id: _clip; visible: false }
            }
        }

        // ── Log ───────────────────────────────────────────────────────────────
        ExpandableLog {
            Layout.fillWidth:  true
            Layout.fillHeight: true
            log:              root._filtered
            autoScroll:       root._autoScroll
            showFilter:       true
            detailComponent:  _entryDetail
        }

        // ── Status bar ────────────────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            height:           32
            color:            Theme.panel
            border.color:     Theme.border
            border.width:     1

            RowLayout {
                anchors { fill: parent; leftMargin: Theme.sp3; rightMargin: Theme.sp3 }
                spacing: Theme.sp3

                Text {
                    text:  LogManager.entries.length + " entries"
                    color: Theme.textSecondary
                    font { family: Theme.fontFamily; pixelSize: Theme.textXs }
                }

                Rectangle { width: 1; height: 14; color: Theme.border }

                Text {
                    visible: LogManager.errorCount > 0
                    text:    LogManager.errorCount + " error" + (LogManager.errorCount !== 1 ? "s" : "")
                    color:   Theme.error
                    font { family: Theme.fontFamily; pixelSize: Theme.textXs }
                }

                Text {
                    visible: LogManager.warnCount > 0
                    text:    LogManager.warnCount + " warning" + (LogManager.warnCount !== 1 ? "s" : "")
                    color:   Theme.warning
                    font { family: Theme.fontFamily; pixelSize: Theme.textXs }
                }

                Item { Layout.fillWidth: true }

                Toggle {
                    checked:   root._autoScroll
                    onToggled: root._autoScroll = checked
                    text:      "Auto-scroll"
                }
            }
        }
    }

    // ── Detail component (per-category) ───────────────────────────────────────
    Component {
        id: _entryDetail

        Item {
            id:     _det
            property var entry:  null
            property var detail: entry ? (entry.detail ?? {}) : {}

            implicitHeight: _body.implicitHeight + 20

            ColumnLayout {
                id:      _body
                anchors { left: parent.left; right: parent.right; top: parent.top; topMargin: 10 }
                spacing: 8

                // ── Full message ──────────────────────────────────────────────
                // The summary row shows only the first line, so a multi-line
                // driver error (libpq writes three) is readable only here.
                Rectangle {
                    Layout.fillWidth: true
                    visible: _det.entry !== null && String(_det.entry.message ?? "").indexOf("\n") !== -1
                    Layout.preferredHeight: _msgTxt.implicitHeight + 16
                    color:   Theme.surfaceVariant
                    radius:  Theme.radiusSm
                    Text {
                        id:      _msgTxt
                        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 8 }
                        text:    _det.entry ? (_det.entry.message ?? "") : ""
                        color:   Theme.textSecondary
                        font { family: Theme.fontFamilyMono; pixelSize: Theme.textXs }
                        wrapMode: Text.WordWrap
                    }
                }

                // ── SSH ───────────────────────────────────────────────────────
                PropertyGrid {
                    Layout.fillWidth: true
                    visible:  _det.entry !== null && _det.entry.category === "SSH"
                    keyWidth: 110
                    model: _det.entry && _det.entry.category === "SSH" ? [
                        { key: "Remote",     value: (_det.detail.remoteHost ?? "") + ":" + (_det.detail.remotePort ?? "") },
                        { key: "Local port", value: _det.detail.localPort !== undefined ? ":" + _det.detail.localPort : "—" },
                        { key: "SSH config", value: _det.detail.sshConfigId ?? "—" },
                        { key: "Error",      value: _det.detail.error ?? "" },
                    ].filter(function(r) { return r.value !== "" && r.value !== "—" || r.key === "Remote" }) : []
                }

                // ── CONN ──────────────────────────────────────────────────────
                PropertyGrid {
                    Layout.fillWidth: true
                    visible:  _det.entry !== null && _det.entry.category === "CONN"
                    keyWidth: 110
                    model: _det.entry && _det.entry.category === "CONN" ? [
                        { key: "Driver",   value: _det.detail.driver   ?? "—" },
                        { key: "Host",     value: (_det.detail.host ?? "") + ":" + (_det.detail.port ?? "") },
                        { key: "Database", value: _det.detail.database ?? "—" },
                        { key: "User",     value: _det.detail.user     ?? "—" },
                        { key: "SSL",      value: _det.detail.ssl ? "Yes" : "No", type: "badge",
                          badgeColor: _det.detail.ssl ? Theme.success : Theme.textDisabled },
                    ] : []
                }

                // ── QUERY — SQL block ─────────────────────────────────────────
                CodeBlock {
                    Layout.fillWidth: true
                    visible:   _det.entry !== null && _det.entry.category === "QUERY" && (_det.detail.sql ?? "") !== ""
                    language:  "sql"
                    code:      _det.detail.sql ?? ""
                    maxHeight: 200
                }

                // QUERY — timing + row count
                RowLayout {
                    Layout.fillWidth: true
                    visible: _det.entry !== null && _det.entry.category === "QUERY"
                    spacing: Theme.sp3

                    Icon { name: Icons.timer; size: 13; color: Theme.textSecondary }
                    Text {
                        text:  (_det.detail.elapsedMs ?? 0) + "ms"
                        color: Theme.textSecondary
                        font { family: Theme.fontFamilyMono; pixelSize: Theme.textSm }
                    }
                    Text {
                        visible: (_det.detail.rowCount ?? 0) > 0
                        text:    (_det.detail.rowCount ?? 0) + " rows returned"
                        color:   Theme.textSecondary
                        font { family: Theme.fontFamilyMono; pixelSize: Theme.textSm }
                    }
                    Text {
                        visible: (_det.detail.rowsAffected ?? 0) > 0
                        text:    (_det.detail.rowsAffected ?? 0) + " rows affected"
                        color:   Theme.textSecondary
                        font { family: Theme.fontFamilyMono; pixelSize: Theme.textSm }
                    }
                    Item { Layout.fillWidth: true }
                    Button {
                        text:     "Open in editor"
                        iconName: Icons.arrowSquareIn
                        size:     Button.Size.Sm
                        variant:  Button.Variant.Ghost
                        visible:  (_det.detail.sql ?? "") !== ""
                        onClicked: root.openSqlInEditor(_det.detail.sql ?? "")
                    }
                }

                // QUERY — error block
                Rectangle {
                    Layout.fillWidth: true
                    visible: _det.entry !== null && _det.entry.level === "error" &&
                             _det.entry.category === "QUERY" && (_det.detail.error ?? "") !== ""
                    height:  _errTxt.implicitHeight + 16
                    color:   Qt.rgba(0.95, 0.24, 0.35, 0.08)
                    radius:  Theme.radiusSm
                    border.color: Qt.rgba(0.95, 0.24, 0.35, 0.3); border.width: 1
                    Text {
                        id:      _errTxt
                        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 8 }
                        text:    _det.detail.error ?? ""
                        color:   "#f38ba8"
                        font { family: Theme.fontFamilyMono; pixelSize: Theme.textXs }
                        wrapMode: Text.WrapAnywhere
                    }
                }

                // ── AI — prompt ───────────────────────────────────────────────
                RowLayout {
                    Layout.fillWidth: true
                    visible: _det.entry !== null && _det.entry.category === "AI" && (_det.detail.prompt ?? "") !== ""
                    spacing: Theme.sp2
                    Text {
                        text: "Prompt"
                        color: Theme.textDisabled
                        font { family: Theme.fontFamilyMono; pixelSize: Theme.textXs }
                        Layout.alignment: Qt.AlignTop
                        topPadding: 1
                    }
                    Text {
                        text:             _det.detail.prompt ?? ""
                        color:            Theme.textSecondary
                        font { family: Theme.fontFamilyMono; pixelSize: Theme.textSm }
                        wrapMode:         Text.WordWrap
                        Layout.fillWidth: true
                    }
                }

                // AI — provider + model badges
                RowLayout {
                    Layout.fillWidth: true
                    visible: _det.entry !== null && _det.entry.category === "AI"
                    spacing: Theme.sp2

                    Badge {
                        text:        _det.detail.provider ?? ""
                        colorScheme: Badge.Color.Primary
                    }
                    Badge {
                        text:        _det.detail.model ?? ""
                        colorScheme: Badge.Color.Default
                    }
                    Item { Layout.fillWidth: true }
                }

                // AI — generated SQL
                CodeBlock {
                    Layout.fillWidth: true
                    visible:   _det.entry !== null && _det.entry.category === "AI" && (_det.detail.sql ?? "") !== ""
                    language:  "sql"
                    code:      _det.detail.sql ?? ""
                    maxHeight: 200
                }

                // AI — error block
                Rectangle {
                    Layout.fillWidth: true
                    visible: _det.entry !== null && _det.entry.level === "error" &&
                             _det.entry.category === "AI" && (_det.detail.message ?? "") !== ""
                    height:  _aiErrTxt.implicitHeight + 16
                    color:   Qt.rgba(0.95, 0.24, 0.35, 0.08)
                    radius:  Theme.radiusSm
                    border.color: Qt.rgba(0.95, 0.24, 0.35, 0.3); border.width: 1
                    Text {
                        id:      _aiErrTxt
                        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 8 }
                        text:    _det.detail.message ?? ""
                        color:   "#f38ba8"
                        font { family: Theme.fontFamilyMono; pixelSize: Theme.textXs }
                        wrapMode: Text.WrapAnywhere
                    }
                }
            }
        }
    }
}
