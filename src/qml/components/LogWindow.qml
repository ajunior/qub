pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Mahina

// Detached diagnostics window. Open with Ctrl+L from WorkspaceScreen.
// Two tabs: the activity log (LogView) and slow-query insights
// (SlowQueriesView). LogView is also usable standalone.
Window {
    id: root

    title: "Activity · qub"
    width: 900; height: 560
    minimumWidth: 640; minimumHeight: 380
    color: Theme.background
    flags: Qt.Window

    signal openSqlInEditor(string sql)

    property int _tab: 0

    ColumnLayout {
        anchors.fill: parent
        spacing:      0

        TabBar {
            Layout.fillWidth: true
            model:        ["Activity Log", "Slow Queries"]
            currentIndex: root._tab
            onTabClicked: (i) => root._tab = i
        }

        StackLayout {
            Layout.fillWidth:  true
            Layout.fillHeight: true
            currentIndex:      root._tab

            LogView {
                onOpenSqlInEditor: (sql) => root.openSqlInEditor(sql)
            }

            SlowQueriesView {
                onOpenSqlInEditor: (sql) => root.openSqlInEditor(sql)
            }
        }
    }
}
