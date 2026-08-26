pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Mahina
import Qub

// Floating AI command palette — open with Ctrl+K, dismiss with Escape.
// Emits promptSubmitted(prompt, schema); caller is responsible for calling
// AiClient.generate() and wiring the result back.
Item {
    id: root

    // ── API ──────────────────────────────────────────────────────────────────
    property string schema:  ""
    property string dialect: ""   // e.g. "PostgreSQL"; empty = unknown

    signal promptSubmitted(string prompt)

    function open(): void {
        visible = true
        _input.forceActiveFocus()
        _input.selectAll()
    }

    function close(): void {
        visible = false
        _input.text = ""
        _resultText = ""
    }

    // ── State ─────────────────────────────────────────────────────────────────
    property string _resultText: ""

    visible: false

    // Backdrop — clicking outside closes the palette
    MouseArea {
        anchors.fill: parent
        onClicked: root.close()
    }

    // Palette box — centered horizontally, near the top
    Rectangle {
        id:           _box
        anchors {
            top:              parent.top
            topMargin:        56
            horizontalCenter: parent.horizontalCenter
        }
        width:   Math.min(parent.width - 48, 520)
        height:  _col.implicitHeight + 24
        color:   Theme.surface
        radius:  Theme.radiusMd
        border.color: Theme.border
        border.width: 1

        layer.enabled: true
        layer.effect: null  // shadow handled via border

        // Eat clicks so backdrop MouseArea doesn't fire
        MouseArea { anchors.fill: parent; onClicked: {} }

        ColumnLayout {
            id:      _col
            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 12 }
            spacing: 10

            // ── Input row ─────────────────────────────────────────────────────
            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Icon {
                    name:  AiClient.loading ? Icons.spinner : Icons.sparkle
                    size:  16
                    color: Theme.primary
                    Layout.alignment: Qt.AlignVCenter

                    RotationAnimation on rotation {
                        running:  AiClient.loading
                        from: 0; to: 360
                        duration: 900
                        loops: Animation.Infinite
                    }
                }

                Input {
                    id:              _input
                    Layout.fillWidth: true
                    placeholderText: "Ask AI to write SQL…"
                    enabled:         !AiClient.loading

                    Keys.onReturnPressed: root._submit()
                    Keys.onEscapePressed: root.close()
                }

                Button {
                    text:     AiClient.loading ? "…" : "Ask"
                    size:     Button.Size.Sm
                    variant:  Button.Variant.Filled
                    enabled:  !AiClient.loading && _input.text.trim().length > 0
                    onClicked: root._submit()
                }
            }

            // ── Result area ───────────────────────────────────────────────────
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 8
                visible: root._resultText !== ""

                Divider { Layout.fillWidth: true }

                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight:  _resEdit.implicitHeight + 16
                    color:           Theme.panel
                    radius:          Theme.radiusSm

                    TextEdit {
                        id:        _resEdit
                        anchors {
                            left: parent.left; right: parent.right
                            top: parent.top; margins: 8
                        }
                        text:             root._resultText
                        readOnly:         true
                        selectByMouse:    true
                        wrapMode:         TextEdit.WrapAnywhere
                        color:            Theme.textPrimary
                        selectionColor:   Theme.primarySubtle
                        selectedTextColor: Theme.primary
                        font { family: Theme.fontFamilyMono; pixelSize: Theme.textSm }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true

                    Button {
                        text:     "Insert at cursor"
                        iconName: Icons.arrowSquareIn
                        size:     Button.Size.Sm
                        variant:  Button.Variant.Filled
                        onClicked: {
                            root.promptSubmitted("__insert__:" + root._resultText)
                            root.close()
                        }
                    }

                    Button {
                        text:     "Replace editor"
                        iconName: Icons.pencilSimple
                        size:     Button.Size.Sm
                        variant:  Button.Variant.Ghost
                        onClicked: {
                            root.promptSubmitted("__replace__:" + root._resultText)
                            root.close()
                        }
                    }

                    Item { Layout.fillWidth: true }

                    Button {
                        text:    "Dismiss"
                        size:    Button.Size.Sm
                        variant: Button.Variant.Ghost
                        onClicked: root.close()
                    }
                }
            }
        }
    }

    // ── AI wiring ─────────────────────────────────────────────────────────────
    Connections {
        target: AiClient
        function onResultReady(sql: string): void {
            if (!root.visible) return
            root._resultText = sql
        }
    }

    function _submit(): void {
        const p = _input.text.trim()
        if (!p || AiClient.loading) return
        _resultText = ""
        AiClient.generate(p, root.schema, root.dialect)
    }
}
