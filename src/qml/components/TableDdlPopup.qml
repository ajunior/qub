pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import Mahina
import Qub

Dialog {
    id: root

    // ── API ──────────────────────────────────────────────────────────────────
    property string connectionName: ""
    property string tableName:      ""
    property string schemaName:     ""

    // See TableStatsPopup: the title names the table the DDL is actually for.
    property string tableLabel: ""

    function openFor(conn: var, schema: var, table: var, label: var): void {
        connectionName = conn
        schemaName     = schema ?? ""
        tableName      = table
        tableLabel     = label || table
        _ddl           = ""
        _ddl           = DatabaseInspector.tableDdl(conn, schemaName, table)
        open()
    }

    // ── State ─────────────────────────────────────────────────────────────────
    property string _ddl: ""

    // ── Dialog chrome ─────────────────────────────────────────────────────────
    title:          root.tableLabel
    subtitle:       "DDL · " + root.connectionName
    preferredWidth: 600

    // ── Content ───────────────────────────────────────────────────────────────
    ScrollView {
        width:              parent.width
        height:             Math.min(_ddlText.implicitHeight + 24, 420)
        clip:               true
        ScrollBar.vertical.policy: ScrollBar.AsNeeded

        Rectangle {
            width:  parent.width
            height: Math.max(_ddlText.implicitHeight + 24, parent.height)
            color:  Theme.panel
            radius: Theme.radiusSm

            TextEdit {
                id:          _ddlText
                anchors {
                    fill: parent
                    margins: 12
                }
                text:        root._ddl
                readOnly:    true
                selectByMouse: true
                wrapMode:    TextEdit.NoWrap
                color:       Theme.textPrimary
                font {
                    family:    Theme.fontFamilyMono
                    pixelSize: Theme.textSm
                }

                EmptyState {
                    anchors.centerIn: parent
                    visible:     root._ddl === ""
                    icon:        Icons.code
                    title:       "DDL not available"
                    description: "Could not retrieve the DDL for this table."
                }
            }
        }
    }

    // ── Footer ────────────────────────────────────────────────────────────────
    footer: RowLayout {
        Button {
            text:     "Copy"
            iconName: Icons.copy
            size:     Button.Size.Sm
            variant:  Button.Variant.Ghost
            enabled:  root._ddl !== ""
            onClicked: {
                _ddlText.selectAll()
                _ddlText.copy()
                _ddlText.deselect()
            }
        }
        Item { Layout.fillWidth: true }
        Button {
            text:    "Close"
            size:    Button.Size.Sm
            variant: Button.Variant.Ghost
            onClicked: root.close ? root.close() : root.visible = false
        }
    }
}
