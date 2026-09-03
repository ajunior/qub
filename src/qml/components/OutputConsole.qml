pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic as QQC
import Mahina
import Qub

// DataGrip-style session console: the chronological stream of everything the
// given connection did — executed statements with their outcome, connection
// and tunnel events, errors inline. Sits as the "Output" tab next to Results.
//
// It is one selectable text buffer rather than a list of rows, which is the
// whole point: a console you can drag a cursor through copies the three lines
// you want as readily as the whole session, and a list of delegates can only
// ever hand you a row at a time.
Rectangle {
    id: root

    property string connectionName: ""

    color: Theme.surface

    readonly property var _entries: {
        const name = root.connectionName
        if (name === "") return []
        return LogManager.entries.filter(e => e.connection === name)
    }

    function _levelColor(level: string): color {
        if (level === "error") return Theme.error
        if (level === "warn")  return Theme.warning
        return Theme.textPrimary
    }

    // Rich text wants six hex digits; a Theme token stringifies to eight when
    // it carries an alpha channel, which Qt's CSS subset then ignores along
    // with the colour it was attached to.
    function _hex(c: color): string {
        const col = Qt.color(c)
        return Qt.rgba(col.r, col.g, col.b, 1).toString()
    }

    function _esc(s: string): string {
        return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    }

    // "2026-09-03 14:02:31.204" → ["2026-09-03", "14:02:31.204"]. The date is
    // worth one line when it changes and worth nothing on every line after.
    function _splitStamp(stamp: string): var {
        const at = String(stamp).indexOf(" ")
        return at < 0 ? ["", String(stamp)]
                      : [String(stamp).substring(0, at), String(stamp).substring(at + 1)]
    }

    // The console as a list of { text, color, dim } lines — built once and used
    // twice, since the coloured markup on screen and the plain text that goes
    // to the clipboard have to be the same lines in the same order.
    readonly property var _lines: {
        const out  = []
        const ents = root._entries
        let lastDate = ""

        for (let i = 0; i < ents.length; i++) {
            const e      = ents[i]
            const detail = e.detail ?? ({})
            const level  = e.level ?? "info"
            const parts  = root._splitStamp(e.timestamp ?? "")
            const date   = parts[0]
            const done   = parts[1]

            if (date !== "" && date !== lastDate) {
                out.push({ text: date, color: Theme.textDisabled, dim: true })
                lastDate = date
            }

            // A statement gets two lines with two stamps: it was sent at one
            // moment and answered at another, and the gap between them is
            // often the only thing on screen worth reading.
            const sql = (detail.sql ?? "").replace(/\s+/g, " ").trim()
            if (sql !== "") {
                const started = root._splitStamp(detail.startedAt ?? e.timestamp ?? "")[1]
                out.push({ text: "[" + started + "] " + sql,
                           color: Theme.textSecondary, dim: false })
            }

            out.push({ text: "[" + done + "] " + (e.message ?? ""),
                       color: root._levelColor(level), dim: false })

            const err = detail.error ?? ""
            if (level === "error" && err !== "")
                out.push({ text: String(err), color: Theme.error, dim: false })
        }
        return out
    }

    readonly property string _plainText: {
        const ls = root._lines
        let out = ""
        for (let i = 0; i < ls.length; i++) out += ls[i].text + "\n"
        return out
    }

    readonly property string _richText: {
        const ls = root._lines
        let out = ""
        for (let i = 0; i < ls.length; i++) {
            const l = ls[i]
            out += '<span style="color:' + root._hex(l.color) + '">'
                 + root._esc(l.text) + '</span><br/>'
        }
        return out
    }

    function _copy(text: string): void {
        _clip.text = text
        _clip.selectAll()
        _clip.copy()
        _clip.text = ""
    }

    Flickable {
        id: _flick
        anchors { fill: parent; margins: Theme.sp2 }
        contentWidth:   width
        contentHeight:  _out.contentHeight
        clip:           true
        boundsBehavior: Flickable.StopAtBounds
        QQC.ScrollBar.vertical: QQC.ScrollBar {
            policy: QQC.ScrollBar.AsNeeded
            contentItem: Rectangle { radius: 3; color: Theme.textDisabled; opacity: 0.6 }
            background:  Rectangle { color: "transparent" }
        }

        // Stick to the bottom like a terminal, but stop following when the
        // user scrolls up to read; resume when they return to the end.
        property bool _stick: true
        function _toEnd(): void { contentY = Math.max(0, contentHeight - height) }
        onMovementEnded:    _stick = atYEnd
        onContentHeightChanged: if (_stick) Qt.callLater(_flick._toEnd)

        TextEdit {
            id: _out
            width:         _flick.width
            readOnly:      true
            selectByMouse: true
            textFormat:    TextEdit.RichText
            text:          root._richText
            wrapMode:      TextEdit.Wrap
            color:         Theme.textPrimary
            font { family: Theme.fontFamilyMono; pixelSize: Theme.textXs }

            ContextMenu {
                anchor: _out
                menuWidth: 190
                model: [
                    { label: "Copy",       act: "copy",   icon: Icons.copy,
                      disabled: _out.selectedText === "" },
                    { label: "Select all", act: "all",    icon: Icons.selectionAll,
                      disabled: root._lines.length === 0 },
                    null,
                    { label: "Copy console", act: "whole", icon: Icons.clipboardText,
                      disabled: root._lines.length === 0 },
                ]
                onTriggered: (index, item) => {
                    // "Copy" hands over the selection as the user sees it;
                    // "Copy console" goes through the plain lines instead, so a
                    // whole session pasted into a chat window arrives as text
                    // and not as a page of coloured markup.
                    if (item.act === "copy")  _out.copy()
                    if (item.act === "all")   _out.selectAll()
                    if (item.act === "whole") root._copy(root._plainText)
                }
            }
        }
    }

    // Jump back to the live tail after scrolling up
    Button {
        anchors { right: parent.right; bottom: parent.bottom; margins: Theme.sp3 }
        visible:  !_flick._stick && root._lines.length > 0
        text:     "Latest"
        iconName: Icons.arrowDown
        size:     Button.Size.Sm
        onClicked: { _flick._stick = true; _flick._toEnd() }
    }

    // Empty state
    Text {
        anchors.centerIn: parent
        visible: root._entries.length === 0
        width:   Math.min(parent.width - Theme.sp6 * 2, 340)
        text: root.connectionName === ""
              ? "No active connection."
              : "Statements you run on \"" + root.connectionName + "\" will appear here."
        color:          Theme.textDisabled
        font { family: Theme.fontFamily; pixelSize: Theme.textSm }
        wrapMode:       Text.Wrap
        horizontalAlignment: Text.AlignHCenter
    }

    TextEdit { id: _clip; visible: false }
}
