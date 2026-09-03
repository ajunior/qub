pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Mahina
import Qub
import "../fk.js" as Fk
import "../cellview.js" as CellView

Rectangle {
    id: root

    property var    model:        null
    onModelChanged: { _filterInput.text = ""; root._selRow = -1; root._selCol = -1; root._selColName = "" }
    property string errorMessage: ""
    property bool   editable:     false
    property string tableName:    ""
    property var    pkColumns:    []
    // Foreign keys for the active connection ({fromTable,fromColumn,toTable,toColumn})
    // and the Qt driver, used to offer FK navigation on the selected cell.
    property var    foreignKeys:  []
    property string driver:       ""
    // Whether a query has actually been run for this tab. Distinguishes the
    // blank-slate ("run a query") state from a query that returned no rows.
    property bool   hasRun:       false

    signal cellCopied(string value)
    signal exportRequested()
    signal editCommitted(int row, int col, string colName, string newValue, string oldValue)
    // Emitted when the user follows a foreign key; carries the SELECT to open.
    signal navigateRequested(string sql, string title)

    color: Theme.surface
    // No frame: this fills a pane whose seams are already drawn — the
    // SplitPane divider on three sides, the results header's rule on top.
    // Rectangle's border.width defaults to 1, so it has to be said.
    border.width: 0

    // Hidden clipboard helper
    TextEdit { id: _clip; visible: false; text: "" }

    function _copyText(txt: var): void {
        _clip.text = txt
        _clip.selectAll()
        _clip.copy()
    }

    // ── Per-cell click tracking ───────────────────────────────────────────────
    property int    _selRow: -1
    property int    _selCol: -1
    property string _selVal: ""
    property string _selColName: ""

    // ── Foreign-key navigation for the selected cell ──────────────────────────
    // Outgoing: the selected column is an FK → { toTable, toColumn } (or null).
    // Incoming: tables referencing the selected column → [{ fromTable, fromColumn }].
    readonly property var _fkOut:
        (root.model && root._selCol >= 0 && root._selColName !== "")
            ? Fk.outgoing(root.foreignKeys, root.tableName, root._selColName) : null
    readonly property var _fkIn:
        (root.model && root._selCol >= 0 && root._selColName !== "")
            ? Fk.incoming(root.foreignKeys, root.tableName, root._selColName) : []

    // Aggregates for the selected cell's column (over the visible/filtered rows).
    // null when nothing is selected. Re-evaluates when the filtered row count
    // changes (model.count) so it tracks the current filter.
    readonly property var columnStats:
        (root.model && root._selCol >= 0 && root.model.count >= 0)
            ? root.model.columnStats(root._selCol)
            : null

    // ── Inline edit state ─────────────────────────────────────────────────────
    property int    _editRow:     -1
    property int    _editCol:     -1
    property string _editColName: ""
    property string _editOldVal:  ""

    function _openEdit(row: var, col: var, value: var): var {
        const colName = root.model.headerData(col, Qt.Horizontal, Qt.DisplayRole)
        if ((root.pkColumns ?? []).indexOf(colName) >= 0) return  // PK — read-only
        root._editRow     = row
        root._editCol     = col
        root._editColName = colName
        root._editOldVal  = value
        _editInput.text   = value
        _editInput.forceActiveFocus()
        _editInput.selectAll()
    }

    function _commitEdit(): void {
        const newVal = _editInput.text
        if (newVal !== root._editOldVal)
            root.editCommitted(root._editRow, root._editCol, root._editColName, newVal, root._editOldVal)
        root._editRow = -1
    }

    function _cancelEdit(): void {
        root._editRow = -1
    }

    // ── Value inspector ───────────────────────────────────────────────────────
    property string _viewColName: ""
    property string _viewText:    ""
    property string _viewKind:    "text"   // "text" | "json"

    function _openValue(colName: var, value: var): void {
        const r = CellView.inspect(value)
        root._viewColName = colName
        root._viewKind    = r.kind
        root._viewText    = r.text
        _valueDialog.open()
    }

    // ── Row viewer (record form) ──────────────────────────────────────────────
    property int _rowViewIdx: -1

    // The current row as [{ name, value, fkSql, fkLabel }] — FK fields carry the
    // navigation query (reuses fk.js), values are drilled into via the inspector.
    readonly property var _rowFields: {
        if (!root.model || root._rowViewIdx < 0 || root._rowViewIdx >= root.model.count)
            return []
        const cols = root.model.columnNames ?? []
        const out  = []
        for (let c = 0; c < cols.length; c++) {
            const val = root.model.cellValue(root._rowViewIdx, c)
            const fk  = Fk.outgoing(root.foreignKeys, root.tableName, cols[c])
            out.push({
                name:    cols[c],
                value:   val,
                fkSql:   fk ? Fk.selectBy(fk.toTable, fk.toColumn, val, root.driver,
                                          AppSettings.sqlKeywordCase) : "",
                fkLabel: fk ? ("Go to " + fk.toTable + " row") : ""
            })
        }
        return out
    }

    function _openRow(rowIdx: var): void {
        if (!root.model || rowIdx < 0) return
        root._rowViewIdx = rowIdx
        _rowDialog.open()
    }

    // Open the row viewer for the currently selected row (used by the shortcut).
    // Returns false when there's no selection so the caller can hint the user.
    function openSelectedRow(): var {
        if (!root.model || root._selRow < 0) return false
        root._openRow(root._selRow)
        return true
    }

    function _stepRow(delta: var): void {
        if (!root.model) return
        const n = root.model.count
        if (n <= 0) return
        root._rowViewIdx = Math.max(0, Math.min(root._rowViewIdx + delta, n - 1))
    }

    // ── Edit bar ──────────────────────────────────────────────────────────────
    Rectangle {
        id: _editBar
        visible: root._editRow >= 0 && root.editable
        anchors { top: parent.top; left: parent.left; right: parent.right }
        height: 42
        color: Theme.panel
        z: 2

        Rectangle {
            anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
            height: 1; color: Theme.primary
        }

        RowLayout {
            anchors { fill: parent; leftMargin: Theme.sp3; rightMargin: Theme.sp2 }
            spacing: Theme.sp2

            Icon { name: Icons.pencilSimple; size: 14; color: Theme.primary }

            Text {
                text: root._editColName
                color: Theme.primary
                font { family: Theme.fontFamilyMono; pixelSize: Theme.textSm; weight: Theme.weightSemibold }
            }

            Text { text: "="; color: Theme.textDisabled; font { family: Theme.fontFamily; pixelSize: Theme.textSm } }

            // Text input
            Rectangle {
                Layout.fillWidth: true
                height: 28
                color: Theme.surface
                radius: Theme.radiusSm
                border.color: _editInput.activeFocus ? Theme.primary : Theme.border

                Behavior on border.color { ColorAnimation { duration: 80 } }

                TextInput {
                    id: _editInput
                    anchors {
                        left: parent.left; right: parent.right
                        verticalCenter: parent.verticalCenter
                        leftMargin: Theme.sp2; rightMargin: Theme.sp2
                    }
                    color: Theme.textPrimary
                    font { family: Theme.fontFamilyMono; pixelSize: Theme.textSm }
                    selectByMouse: true
                    selectionColor: Qt.rgba(Qt.color(Theme.primary).r,
                                           Qt.color(Theme.primary).g,
                                           Qt.color(Theme.primary).b, 0.25)
                    selectedTextColor: Theme.textPrimary
                    Keys.onReturnPressed: root._commitEdit()
                    Keys.onEscapePressed: root._cancelEdit()
                }
            }

            Button {
                text:    "Apply"
                variant: Button.Variant.Filled
                onClicked: root._commitEdit()
            }

            Button {
                text:    "Cancel"
                variant: Button.Variant.Ghost
                onClicked: root._cancelEdit()
            }
        }
    }

    // The result set has rows, but the active filter hides every one of them —
    // a distinct kind of empty from "the query returned nothing".
    readonly property bool _filteredToNothing: root.model
                                            && root.model.count === 0
                                            && root.model.totalRowCount > 0

    // Which bar sits at the top (drives ModelTable's top anchor)
    readonly property Item _topBar: _filterBar.visible ? _filterBar
                                  : _editBar.visible   ? _editBar
                                  : null

    // ── Filter bar ────────────────────────────────────────────────────────────
    Rectangle {
        id: _filterBar
        // Keyed to the *unfiltered* row count, not the visible one: a filter that
        // matches nothing empties the table, and hiding the bar with it would
        // strand the user with no way to clear what they just typed.
        visible: root.errorMessage === "" && root.model && root.model.totalRowCount > 0
        anchors {
            top:   _editBar.visible ? _editBar.bottom : parent.top
            left:  parent.left
            right: parent.right
        }
        height: 36
        color:  Theme.panel
        z: 2

        Rectangle {
            anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
            height: 1; color: Theme.border
        }

        Row {
            anchors { left: parent.left; right: _filterCount.left; top: parent.top; bottom: parent.bottom
                      leftMargin: Theme.sp2; rightMargin: Theme.sp1 }
            spacing: Theme.sp1

            Icon {
                anchors.verticalCenter: parent.verticalCenter
                name: Icons.magnifyingGlass; size: 14
                color: _filterInput.activeFocus ? Theme.primary : Theme.textDisabled
            }

            TextInput {
                id: _filterInput
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - parent.spacing - 14
                color: Theme.textPrimary
                font { family: Theme.fontFamily; pixelSize: Theme.textSm }
                selectByMouse: true
                selectionColor: Qt.rgba(Qt.color(Theme.primary).r,
                                        Qt.color(Theme.primary).g,
                                        Qt.color(Theme.primary).b, 0.25)
                selectedTextColor: Theme.textPrimary

                Text {
                    anchors.fill: parent
                    visible: !_filterInput.activeFocus && _filterInput.text === ""
                    text:  "Filter rows…"
                    color: Theme.textDisabled
                    font:  _filterInput.font
                    verticalAlignment: Text.AlignVCenter
                }

                onTextChanged: {
                    if (root.model && root.model.setFilterText)
                        root.model.setFilterText(text)
                }
                Keys.onEscapePressed: { text = ""; focus = false }
            }
        }

        // Row count badge — shown when filter is active
        Row {
            id: _filterCount
            anchors { right: parent.right; verticalCenter: parent.verticalCenter; rightMargin: Theme.sp2 }
            spacing: Theme.sp1
            visible: _filterInput.text !== ""

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.model ? (root.model.count + " / " + root.model.totalRowCount) : ""
                color: Theme.textDisabled
                font { family: Theme.fontFamily; pixelSize: Theme.textXs }
            }

            // Clear button
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 16; height: 16; radius: 8
                color: _clearHov.hovered ? Theme.border : "transparent"
                Behavior on color { ColorAnimation { duration: 60 } }
                HoverHandler { id: _clearHov }
                Text {
                    anchors.centerIn: parent
                    text: "×"; color: Theme.textDisabled
                    font { family: Theme.fontFamily; pixelSize: 12 }
                }
                MouseArea {
                    anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                    onClicked: _filterInput.text = ""
                }
            }
        }
    }

    // ── Error state ───────────────────────────────────────────────────────────
    ColumnLayout {
        anchors.centerIn: parent
        spacing: 10
        width: Math.min(parent.width - 48, 480)
        visible: root.errorMessage !== ""

        Icon { name: Icons.warningCircle; size: 36; color: Theme.error; Layout.alignment: Qt.AlignHCenter }

        Text {
            text: "Query error"
            color: Theme.error
            font { family: Theme.fontFamily; pixelSize: Theme.textSm; weight: Theme.weightSemibold }
            Layout.alignment: Qt.AlignHCenter
        }

        Text {
            text:             root.errorMessage
            color:            Theme.textSecondary
            font { family: Theme.fontFamilyMono; pixelSize: Theme.textXs }
            wrapMode:         Text.WordWrap
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignHCenter
        }
    }

    // ── Empty / DML state ─────────────────────────────────────────────────────
    ColumnLayout {
        anchors.centerIn: parent
        width:   Math.min(parent.width - Theme.sp6, 320)
        spacing: 10
        visible: root.errorMessage === "" && (!root.model || root.model.count === 0)

        Icon {
            name:  root.hasRun ? Icons.table : Icons.play
            size:  36
            color: Theme.textDisabled
            Layout.alignment: Qt.AlignHCenter
        }

        Text {
            text: root._filteredToNothing ? "No rows match the filter"
                                          : (root.hasRun ? "No rows returned"
                                                         : "Run a query to see results")
            color:          Theme.textPrimary
            font { family: Theme.fontFamily; pixelSize: Theme.textSm; weight: Theme.weightMedium }
            horizontalAlignment: Text.AlignHCenter
            Layout.fillWidth:    true
        }

        Text {
            visible:        !root.hasRun || root._filteredToNothing
            text: root._filteredToNothing
                ? "Clear the filter above (or press Esc in it) to see all "
                  + root.model.totalRowCount + " rows."
                : "Write SQL in the editor above and press "
                  + KeyLabels.sequence("Ctrl+Enter") + "."
            color:          Theme.textSecondary
            font { family: Theme.fontFamily; pixelSize: Theme.textXs }
            wrapMode:       Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
            Layout.fillWidth:    true
        }
    }

    // ── Results table ─────────────────────────────────────────────────────────
    ModelTable {
        id: _table
        anchors {
            top:    root._topBar ? root._topBar.bottom : parent.top
            left:   parent.left
            right:  parent.right
            bottom: _limitBanner.visible ? _limitBanner.top : parent.bottom
            margins: 1
        }
        visible: root.errorMessage === "" && root.model && root.model.count > 0
        model:   root.model
        striped: true

        onCellClicked: (row, col, value) => {
            root._selRow = row
            root._selCol = col
            root._selVal = value
            root._selColName = root.model
                ? root.model.headerData(col, Qt.Horizontal, Qt.DisplayRole) : ""
            root._copyText(value)
            root.cellCopied(value)
        }

        onCellDoubleClicked: (row, col, value) => {
            if (root.editable) {
                root._openEdit(row, col, value)
            } else {
                const colName = root.model
                    ? root.model.headerData(col, Qt.Horizontal, Qt.DisplayRole) : ""
                root._selColName = colName
                root._openValue(colName, value)
            }
        }

        ContextMenu {
            anchor: _table
            model: {
                const items = [
                    { label: "View value…",     icon: Icons.arrowsOut,  act: "view",
                      disabled: root._selCol < 0 },
                    { label: "View row…",       icon: Icons.rows,       act: "viewrow",
                      shortcut: "Ctrl+Shift+R", disabled: root._selRow < 0 },
                    { label: "Copy cell value", icon: Icons.copy,       act: "copy" },
                    { label: "Copy row as TSV", icon: Icons.copySimple, act: "copyrow" },
                ]
                // Foreign-key navigation for the last-clicked cell.
                const fk = []
                if (root._fkOut)
                    fk.push({ label: "Go to " + root._fkOut.toTable + " row",
                              icon: Icons.arrowSquareOut, act: "nav",
                              disabled: root._selVal === "",
                              sql: Fk.selectBy(root._fkOut.toTable, root._fkOut.toColumn,
                                               root._selVal, root.driver,
                                               AppSettings.sqlKeywordCase) })
                for (let i = 0; i < root._fkIn.length; i++) {
                    const inc = root._fkIn[i]
                    fk.push({ label: "Rows in " + inc.fromTable + " (" + inc.fromColumn + ")",
                              icon: Icons.arrowBendUpLeft, act: "nav",
                              disabled: root._selVal === "",
                              sql: Fk.selectBy(inc.fromTable, inc.fromColumn,
                                               root._selVal, root.driver,
                                               AppSettings.sqlKeywordCase) })
                }
                const tail = [ null,
                    { label: "Export CSV…", icon: Icons.downloadSimple, act: "export",
                      disabled: !root.model || root.model.count === 0 } ]
                return items.concat(fk.length ? [null].concat(fk) : []).concat(tail)
            }
            onTriggered: (index, item) => {
                if (!item) return
                if (item.act === "view") {
                    root._openValue(root._selColName, root._selVal)
                } else if (item.act === "viewrow") {
                    root._openRow(root._selRow)
                } else if (item.act === "copy") {
                    root._copyText(root._selVal)
                    root.cellCopied(root._selVal)
                } else if (item.act === "copyrow") {
                    if (root._selRow >= 0 && root.model) {
                        const tsv = root.model.rowAsTsv(root._selRow)
                        root._copyText(tsv)
                        root.cellCopied(tsv)
                    }
                } else if (item.act === "nav") {
                    root.navigateRequested(item.sql, item.label)
                } else if (item.act === "export") {
                    root.exportRequested()
                }
            }
        }
    }

    // ── Row-limit banner ──────────────────────────────────────────────────────
    Rectangle {
        id:      _limitBanner
        visible: root.model && root.model.truncated
        anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
        height: 28
        color:  Theme.panel
        border.color: Theme.border

        Rectangle {
            anchors { top: parent.top; left: parent.left; right: parent.right }
            height: 1; color: Theme.border
        }

        Text {
            anchors { left: parent.left; verticalCenter: parent.verticalCenter; leftMargin: 12 }
            text:           "Showing first 1 000 rows — add a LIMIT clause to narrow results"
            color:          Theme.textDisabled
            font { family: Theme.fontFamily; pixelSize: Theme.textXs }
        }
    }

    // ── Value inspector dialog ────────────────────────────────────────────────
    // Expands a single cell so long text and JSON columns are readable.
    Dialog {
        id:             _valueDialog
        title:          root._viewColName !== "" ? root._viewColName : "Value"
        subtitle:       (root._viewKind === "json" ? "JSON · " : "")
                        + root._viewText.length + " characters"
        preferredWidth: 620

        ColumnLayout {
            width:   parent.width
            spacing: Theme.sp2

            Rectangle {
                Layout.fillWidth:      true
                Layout.preferredHeight: Math.min(Math.max(_valText.implicitHeight + 16, 80), 460)
                color:        Theme.surface
                border.color: Theme.border
                radius:       Theme.radiusSm

                ScrollArea {
                    id:            _valScroll
                    anchors.fill:  parent
                    anchors.margins: 8

                    TextEdit {
                        id:            _valText
                        width:         _valScroll.width
                        readOnly:      true
                        selectByMouse: true
                        wrapMode:      TextEdit.Wrap
                        text:          root._viewText
                        color:         Theme.textPrimary
                        font { family: Theme.fontFamilyMono; pixelSize: Theme.textSm }
                        selectionColor: Qt.rgba(Qt.color(Theme.primary).r,
                                                Qt.color(Theme.primary).g,
                                                Qt.color(Theme.primary).b, 0.25)
                        selectedTextColor: Theme.textPrimary
                    }
                }
            }
        }

        footer: RowLayout {
            width: parent.width
            spacing: Theme.sp2

            Item { Layout.fillWidth: true }

            Button {
                text:    "Copy"
                variant: Button.Variant.Ghost
                onClicked: {
                    root._copyText(root._viewText)
                    root.cellCopied(root._viewText)
                }
            }

            Button {
                text:    "Close"
                variant: Button.Variant.Filled
                onClicked: _valueDialog.close()
            }
        }
    }

    // ── Row viewer dialog (record form) ───────────────────────────────────────
    // One row as a vertical field list — readable for wide tables. Each value
    // drills into the cell inspector; FK fields jump to the referenced row.
    Dialog {
        id:             _rowDialog
        title:          root.tableName !== "" ? root.tableName : "Row"
        subtitle:       root.model && root._rowViewIdx >= 0
                        ? "Row " + (root._rowViewIdx + 1) + " of " + root.model.count
                        : ""
        preferredWidth: 640

        Rectangle {
            width:  parent.width
            height: Math.min(Math.max(_rowCol.implicitHeight + 16, 80), 480)
            color:        Theme.surface
            border.color: Theme.border
            radius:       Theme.radiusSm

            ScrollArea {
                id:              _rowScroll
                anchors.fill:    parent
                anchors.margins: 8

                Column {
                    id:      _rowCol
                    width:   _rowScroll.width
                    spacing: 0

                    Repeater {
                        model: root._rowFields
                        delegate: Rectangle {
                            id: delegateItem
                            required property var modelData
                            required property int index
                            width:  _rowCol.width
                            height: Math.max(_fieldRow.implicitHeight + 12, 34)
                            color:  index % 2 === 0 ? "transparent" : Theme.panel

                            RowLayout {
                                id: _fieldRow
                                anchors {
                                    left: parent.left; right: parent.right
                                    verticalCenter: parent.verticalCenter
                                    leftMargin: 8; rightMargin: 8
                                }
                                spacing: Theme.sp2

                                // Column name
                                Text {
                                    Layout.preferredWidth: 170
                                    Layout.alignment:      Qt.AlignTop
                                    topPadding:            2
                                    text:                  delegateItem.modelData.name
                                    color:                 Theme.textSecondary
                                    elide:                 Text.ElideRight
                                    font { family: Theme.fontFamilyMono; pixelSize: Theme.textSm;
                                           weight: Theme.weightMedium }
                                }

                                // Value — click to inspect (full text / pretty JSON)
                                Text {
                                    Layout.fillWidth:  true
                                    text:              delegateItem.modelData.value === "" ? "∅" : delegateItem.modelData.value
                                    color:             delegateItem.modelData.value === "" ? Theme.textDisabled
                                                                              : Theme.textPrimary
                                    wrapMode:          Text.Wrap
                                    maximumLineCount:  4
                                    elide:             Text.ElideRight
                                    font { family: Theme.fontFamilyMono; pixelSize: Theme.textSm }

                                    MouseArea {
                                        anchors.fill: parent
                                        enabled:      delegateItem.modelData.value !== ""
                                        cursorShape:  Qt.PointingHandCursor
                                        onClicked:    root._openValue(delegateItem.modelData.name, delegateItem.modelData.value)
                                    }
                                }

                                // FK jump
                                Icon {
                                    visible: delegateItem.modelData.fkSql !== "" && delegateItem.modelData.value !== ""
                                    name:    Icons.arrowSquareOut
                                    size:    15
                                    color:   _fkHov.hovered ? Theme.primary : Theme.textDisabled
                                    Layout.alignment: Qt.AlignTop
                                    HoverHandler { id: _fkHov }
                                    MouseArea {
                                        anchors.fill: parent
                                        cursorShape:  Qt.PointingHandCursor
                                        onClicked: {
                                            _rowDialog.close()
                                            root.navigateRequested(delegateItem.modelData.fkSql, delegateItem.modelData.fkLabel)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        footer: RowLayout {
            width: parent.width
            spacing: Theme.sp2

            Button {
                text:     "‹ Prev"
                variant:  Button.Variant.Ghost
                enabled:  root._rowViewIdx > 0
                onClicked: root._stepRow(-1)
            }
            Button {
                text:     "Next ›"
                variant:  Button.Variant.Ghost
                enabled:  root.model && root._rowViewIdx < root.model.count - 1
                onClicked: root._stepRow(1)
            }

            Item { Layout.fillWidth: true }

            Button {
                text:    "Copy row"
                variant: Button.Variant.Ghost
                onClicked: {
                    if (root._rowViewIdx >= 0 && root.model) {
                        const tsv = root.model.rowAsTsv(root._rowViewIdx)
                        root._copyText(tsv)
                        root.cellCopied(tsv)
                    }
                }
            }
            Button {
                text:    "Close"
                variant: Button.Variant.Filled
                onClicked: _rowDialog.close()
            }
        }
    }
}
