pragma ComponentBehavior: Bound

import QtQuick
import Mahina
import Qub

// Thin wrapper: loads schema data and feeds it into Mahina's SchemaBrowser.
Item {
    id: root

    property string connectionName: ""
    property var    _schemas:       []

    signal tableSelected(string name)
    signal columnClicked(string table, string column)
    signal tableDoubleClicked(string name)
    signal columnDoubleClicked(string table, string column)
    signal tableQuickBrowseRequested(string name)
    signal tableStatsRequested(string name)
    signal tableDdlRequested(string name)

    onConnectionNameChanged: _reload()

    Connections {
        target: ConnectionManager
        function onConnectionsChanged() { Qt.callLater(root._reload) }
    }

    Connections {
        target: QueryExecutor
        function onExecutionFinished(success: bool): void {
            if (success) Qt.callLater(root._reload)
        }
    }

    function _reload(): void {
        root._schemas = root.connectionName
                        ? ConnectionManager.schemas(root.connectionName)
                        : []
    }

    SchemaBrowser {
        anchors.fill: parent
        schemas:          root._schemas
        showBrowseAction: AppSettings.schemaQuickBrowse
        onTableSelected:             (name)          => root.tableSelected(name)
        onColumnClicked:             (table, column) => root.columnClicked(table, column)
        onTableDoubleClicked:        (name)          => root.tableDoubleClicked(name)
        onColumnDoubleClicked:       (table, column) => root.columnDoubleClicked(table, column)
        onTableQuickBrowseRequested: (name)          => root.tableQuickBrowseRequested(name)
        onTableStatsRequested:       (name)          => root.tableStatsRequested(name)
        onTableDdlRequested:         (name)          => root.tableDdlRequested(name)
    }
}
