pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Mahina
import Qub
import "../complete.js" as Complete

Item {
    id: root

    property string connectionName: ""

    readonly property string sql:          _editor.code
    readonly property string selectedText: _editor.selectedText
    readonly property int    cursorPosition: _editor.cursorPosition

    property var lineDecorations: []

    // 1-based line where the current selection (or cursor) starts
    readonly property int selectionStartLine: {
        const pos = _editor.selectedText !== "" ? _editor.selectionStart : 0
        return _editor.code.substring(0, pos).split('\n').length
    }

    function setSql(value: var): void { _editor.code = value }
    function insertAtCursor(text: var): void { _editor.insertAtCursor(text) }

    // CodeEditor exposes cursorPosition as a read-only alias, so we move the
    // caret by replacing an empty range at the target offset. Clamped to the
    // current text length (a restored position may exceed a shortened buffer).
    function setCursorPosition(pos: var): void {
        const clamped = Math.max(0, Math.min(pos, _editor.code.length))
        _editor.replaceRange(clamped, clamped, "")
    }

    function setDecorations(decs: var): void { lineDecorations = decs }
    function clearDecorations(): void { lineDecorations = [] }

    // ── Completion state ──────────────────────────────────────────────────────
    property var  _items:    []
    property int  _selIdx:   0
    property bool _dotMode:  false   // true = completing columns after "table."

    readonly property bool _popupOpen: _items.length > 0

    function _prefix(): var {
        const text = _editor.code
        const cur  = _editor.cursorPosition
        let i = cur - 1
        while (i >= 0 && /[a-zA-Z0-9_.]/.test(text[i])) i--
        return text.substring(i + 1, cur)
    }

    // Columns of a table, tolerating a schema-qualified name.
    function _columnsOf(table: var): var {
        let cols = ConnectionManager.columns(root.connectionName, table)
        if ((!cols || cols.length === 0) && table.indexOf('.') >= 0)
            cols = ConnectionManager.columns(root.connectionName, table.split('.').pop())
        return cols || []
    }

    function _refresh(): void {
        if (!AppSettings.autoComplete || !root.connectionName) { _items = []; return }
        const p = _prefix()
        if (p.length < 2) { _items = []; _selIdx = 0; return }

        const scope = Complete.tablesInScope(_editor.code, _editor.cursorPosition)
        const dot   = p.lastIndexOf('.')

        if (dot >= 0) {
            // Column completion: resolve "alias." / "table." against scope.
            const stub = p.substring(dot + 1).toLowerCase()
            const tbl  = Complete.dottedTable(p, scope)
            _items = root._columnsOf(tbl)
                .filter(c => c.name.toLowerCase().startsWith(stub))
                .map(c => ({ label: c.name, suffix: c.name, detail: c.type ?? "column" }))
                .slice(0, 12)
            _dotMode = true
        } else {
            // Bare word → columns of in-scope tables, then matching tables,
            // then SQL keywords. Deduped by label.
            const lp   = p.toLowerCase()
            const seen = {}
            const out  = []
            const add  = (it) => {
                const key = it.label.toLowerCase()
                if (!seen[key]) { seen[key] = true; out.push(it) }
            }

            for (let s = 0; s < scope.length; s++) {
                const src = scope[s].alias || scope[s].name
                const cols = root._columnsOf(scope[s].name)
                for (let c = 0; c < cols.length; c++)
                    if (cols[c].name.toLowerCase().startsWith(lp))
                        add({ label: cols[c].name, suffix: cols[c].name,
                              detail: (cols[c].type ?? "column") + " · " + src })
            }

            const tbls = ConnectionManager.tables(root.connectionName)
            for (let t = 0; t < tbls.length; t++)
                if (tbls[t].toLowerCase().startsWith(lp))
                    add({ label: tbls[t], suffix: tbls[t], detail: "table" })

            const kws = Complete.keywordItems(p)
            for (let k = 0; k < kws.length; k++) add(kws[k])

            _items   = out.slice(0, 12)
            _dotMode = false
        }
        _selIdx = 0
    }

    function _apply(item: var): void {
        const text = _editor.code
        const cur  = _editor.cursorPosition

        // Walk back to find where the prefix starts
        let start = cur - 1
        while (start >= 0 && /[a-zA-Z0-9_.]/.test(text[start])) start--
        start++

        // In dot mode replace only the stub after the last dot
        let insertFrom = start
        if (_dotMode) {
            for (let k = start; k < cur; k++)
                if (text[k] === '.') insertFrom = k + 1
        }

        _editor.replaceRange(insertFrom, cur, item.suffix)
        _items = []
    }

    // ── Reactions ─────────────────────────────────────────────────────────────
    Connections {
        target: _editor
        // Text/cursor changes → refresh suggestions
        function onCodeChanged()           { root._refresh() }
        function onCursorPositionChanged() { root._refresh() }
        // Focus lost → dismiss
        function onActiveFocusChanged()    { if (!_editor.activeFocus) root._items = [] }
        // Key routing from CodeEditor when completionActive
        function onCompletionMoveDown()    { root._selIdx = Math.min(root._selIdx + 1, root._items.length - 1) }
        function onCompletionMoveUp()      { root._selIdx = Math.max(root._selIdx - 1, 0) }
        function onCompletionAccept()      { if (root._popupOpen) root._apply(root._items[root._selIdx]) }
        function onCompletionDismiss()     { root._items = [] }
    }

    // Keep CodeEditor's key-routing flag in sync with popup visibility
    Binding { target: _editor; property: "completionActive"; value: root._popupOpen }

    // ── Editor ────────────────────────────────────────────────────────────────
    CodeEditor {
        id: _editor
        anchors.fill:         parent
        lineNumbers:          true
        // No language badge: this editor only ever holds SQL, and the badge
        // floats over the first line at the top right. The connection's
        // dialect is in the status bar, where it does not sit on the text.
        fontFamily:           AppSettings.fontFamily
        fontSize:             AppSettings.fontSize
        fontWeight:           AppSettings.fontWeight
        backgroundColor:      Theme.surface
        lineDecorations:      root.lineDecorations
        highlightCurrentLine: AppSettings.highlightCurrentLine
        lineHeight:           AppSettings.lineHeight
        tabWidth:             AppSettings.tabSize
        insertSpacesForTab:   AppSettings.insertSpacesForTab
    }

    // The five semantic colours are tuned to carry a button fill or an accent on
    // chrome, where they sit against a surface rather than a page, and on a light
    // theme that leaves every one of them between 2.4:1 and 3.2:1 against the
    // editor background — below the 4.5:1 that body text needs, and a fifth of
    // the contrast the surrounding identifiers have. Keywords used to be bold,
    // which hid it for that one token and for no other. Darkening them on light
    // themes lifts the set to roughly 4:1–5:1; on a dark theme they already clear
    // it, so they are passed through untouched. Derived rather than hard-coded so
    // an imported theme gets the same treatment.
    SqlHighlighter {
        document:      _editor.textDocument
        keywordColor:  root._ink(Theme.primary)
        functionColor: root._ink(Theme.info)
        stringColor:   root._ink(Theme.success)
        commentColor:  root._ink(Theme.textDisabled)
        numberColor:   root._ink(Theme.warning)
    }

    function _ink(c: color): color { return Theme.dark ? c : Qt.darker(c, 1.3) }

    // ── Completion popup ──────────────────────────────────────────────────────
    Rectangle {
        visible:       root._popupOpen
        width:         260
        height:        Math.min(root._items.length, 10) * 28 + 2
        z:             200
        color:         Theme.surface
        border.color:  Theme.border
        border.width:  1
        radius:        Theme.radiusSm

        // Horizontal: clamp so popup never overflows the editor width
        x: Math.max(0, Math.min(_editor.cursorEditorPos.x, parent.width - width - 4))

        // Vertical: below cursor by default; flip above if it overflows bottom
        y: {
            const below = _editor.cursorEditorPos.y + 2
            const above = _editor.cursorEditorPos.y - _editor.cursorRectangle.height - height - 2
            return (below + height > parent.height && above >= 0) ? above : below
        }

        ListView {
            anchors { fill: parent; margins: 1 }
            model:        root._items
            currentIndex: root._selIdx
            clip:         true

            delegate: Rectangle {
                id: delegateItem
                required property var modelData
                required property int index
                width:  parent ? parent.width : 260
                height: 28
                color:  index === root._selIdx
                    ? Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.12)
                    : (_rowHov.hovered ? Theme.surfaceVariant : "transparent")

                RowLayout {
                    anchors { fill: parent; leftMargin: 10; rightMargin: 8 }
                    spacing: 8

                    Text {
                        text:             delegateItem.modelData.label
                        color:            Theme.textPrimary
                        font.family:      Theme.fontFamilyMono
                        font.pixelSize:   Theme.textSm
                        elide:            Text.ElideRight
                        Layout.fillWidth: true
                    }

                    Text {
                        visible:        delegateItem.modelData.detail !== ""
                        text:           delegateItem.modelData.detail
                        color:          Theme.textDisabled
                        font.family:    Theme.fontFamily
                        font.pixelSize: 10
                    }
                }

                HoverHandler { id: _rowHov }
                MouseArea {
                    anchors.fill: parent
                    cursorShape:  Qt.PointingHandCursor
                    onClicked:    root._apply(delegateItem.modelData)
                }
            }
        }
    }
}
