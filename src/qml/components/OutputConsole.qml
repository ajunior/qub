pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Mahina
import Qub

// DataGrip-style session console: the chronological stream of everything the
// given connection did — executed statements with their outcome, connection
// and tunnel events, errors inline. Dense, read-only, console-like. Sits as
// the "Output" tab next to Results in the workspace.
Rectangle {
    id: root

    property string connectionName: ""

    color: Theme.surface

    readonly property var _entries: {
        const name = root.connectionName
        if (name === "") return []
        return LogManager.entries.filter(e => e.connection === name)
    }

    function _levelColor(level: var): var {
        if (level === "error") return Theme.error
        if (level === "warn")  return Theme.warning
        return Theme.textPrimary
    }

    ListView {
        id: _lv
        anchors { fill: parent; margins: Theme.sp2 }
        model:          root._entries
        clip:           true
        spacing:        2
        boundsBehavior: Flickable.StopAtBounds

        // Stick to the bottom like a terminal, but stop following when the
        // user scrolls up to read; resume when they return to the end.
        property bool _stick: true
        onMovementEnded: _stick = atYEnd
        onCountChanged:  Qt.callLater(() => { if (_stick) positionViewAtEnd() })

        delegate: Item {
            id: _row
            required property var modelData

            readonly property string _sqlOneLine:
                (modelData.detail?.sql ?? "").replace(/\s+/g, " ").trim()

            // What lands on the clipboard: the statement as written, then the
            // stamped outcome, then the error if there was one. That is the
            // block you paste back to whoever asked you to run the query, so
            // it carries the full date rather than the row's clock time.
            function copyBlock(): string {
                const sql   = _row.modelData.detail?.sql   ?? ""
                const err   = _row.modelData.detail?.error ?? ""
                const stamp = _row.modelData.datetime ?? _row.modelData.timestamp ?? ""
                let out = ""
                if (sql.trim() !== "") out += sql.trim() + "\n"
                out += "[" + stamp + "] " + (_row.modelData.message ?? "")
                if (err !== "") out += "\n" + err
                return out
            }

            width:  _lv.width
            height: _lines.implicitHeight + 6

            Rectangle {
                anchors.fill: parent
                radius:  Theme.radiusSm
                color:   Theme.surfaceVariant
                visible: _rowH.hovered
            }
            HoverHandler { id: _rowH }

            ColumnLayout {
                id: _lines
                anchors {
                    left: parent.left; right: parent.right
                    verticalCenter: parent.verticalCenter
                    leftMargin: Theme.sp2; rightMargin: Theme.sp2
                }
                spacing: 1

                // Echo of the executed statement, collapsed to one line. It
                // comes first because the outcome below is a sentence *about*
                // it — the same order DataGrip's console uses.
                Text {
                    Layout.fillWidth: true
                    visible: _row._sqlOneLine !== ""
                    text:    _row._sqlOneLine
                    color:   Theme.textSecondary
                    font { family: Theme.fontFamilyMono; pixelSize: Theme.textXs }
                    elide:   Text.ElideRight
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.sp2

                    Text {
                        Layout.alignment: Qt.AlignTop
                        text:  _row.modelData.timestamp ?? ""
                        color: Theme.textDisabled
                        font { family: Theme.fontFamilyMono; pixelSize: Theme.textXs }
                    }
                    Text {
                        Layout.fillWidth: true
                        // Wraps rather than elides: the timing breakdown is the
                        // point of the line, and it sits at the end of it.
                        text:     _row.modelData.message ?? ""
                        color:    root._levelColor(_row.modelData.level ?? "info")
                        font { family: Theme.fontFamilyMono; pixelSize: Theme.textSm }
                        wrapMode: Text.Wrap
                    }

                    Tooltip {
                        text: _row._sqlOneLine !== "" ? "Copy statement and result"
                                                      : "Copy message"
                        visible: _rowH.hovered
                        Button {
                            iconOnly: true
                            iconName: Icons.copy
                            size:     Button.Size.Sm
                            variant:  Button.Variant.Ghost
                            onClicked: {
                                _clip.text = _row.copyBlock()
                                _clip.selectAll()
                                _clip.copy()
                                _clip.text = ""
                            }
                        }
                    }
                }

                // Full error text, wrapped — errors deserve the space
                Text {
                    Layout.fillWidth: true
                    visible:  (_row.modelData.level ?? "") === "error"
                              && (_row.modelData.detail?.error ?? "") !== ""
                    text:     _row.modelData.detail?.error ?? ""
                    color:    Theme.error
                    font { family: Theme.fontFamilyMono; pixelSize: Theme.textXs }
                    wrapMode: Text.WrapAnywhere
                }
            }
        }
    }

    // Jump back to the live tail after scrolling up
    Button {
        anchors { right: parent.right; bottom: parent.bottom; margins: Theme.sp3 }
        visible:  !_lv._stick && _lv.count > 0
        text:     "Latest"
        iconName: Icons.arrowDown
        size:     Button.Size.Sm
        onClicked: { _lv._stick = true; _lv.positionViewAtEnd() }
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
