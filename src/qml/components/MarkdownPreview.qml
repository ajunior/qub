pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Mahina
import Qub

// Rendered, read-only view of the editor buffer: /* @md … */ blocks are shown
// as formatted Markdown, everything between them as SQL code blocks. Follows
// the `sql` property live (debounced so typing stays cheap).
Rectangle {
    id: root

    property string sql: ""

    color: Theme.background

    property var _segments: []

    // Re-parse shortly after the last keystroke instead of on every one.
    Timer {
        id:       _reparse
        interval: 250
        onTriggered: root._segments = MarkdownDoc.segments(root.sql)
    }
    onSqlChanged: _reparse.restart()
    Component.onCompleted: _segments = MarkdownDoc.segments(sql)

    Flickable {
        id:             _flick
        anchors.fill:   parent
        contentHeight:  _content.implicitHeight + Theme.sp6 * 2
        clip:           true
        boundsBehavior: Flickable.StopAtBounds

        ColumnLayout {
            id: _content
            // Explicit width, not anchors: inside a Flickable, anchoring to
            // the parent (= contentItem, sized from its children) is circular
            // and lets long unwrapped text push the width out instead of wrapping.
            x:       Theme.sp6
            y:       Theme.sp6
            width:   _flick.width - Theme.sp6 * 2
            spacing: Theme.sp4

            Repeater {
                model: root._segments

                delegate: Loader {
                    id: delegateItem
                    required property var modelData
                    Layout.fillWidth: true
                    sourceComponent: modelData.type === "md" ? _mdBlock : _sqlBlock

                    property string blockText: modelData.text

                    Component {
                        id: _mdBlock
                        MarkdownView {
                            text: delegateItem.blockText
                        }
                    }

                    Component {
                        id: _sqlBlock
                        CodeBlock {
                            code:        delegateItem.blockText
                            language:    "sql"
                            followTheme: true
                            wrapText:    true
                        }
                    }
                }
            }
        }
    }

    // Empty state: nothing in the buffer yet.
    Text {
        anchors.centerIn: parent
        visible: root._segments.length === 0
        width:   Math.min(parent.width - Theme.sp6 * 2, 320)
        text:    "Write SQL with /* @md … */ comment blocks to build a " +
                 "literate document. Markdown renders here; export it from " +
                 "the editor's ··· menu."
        color:          Theme.textDisabled
        font.family:    Theme.fontFamily
        font.pixelSize: Theme.textSm
        wrapMode:       Text.Wrap
        horizontalAlignment: Text.AlignHCenter
    }
}
