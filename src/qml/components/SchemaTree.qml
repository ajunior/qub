pragma ComponentBehavior: Bound

import QtQuick
import Mahina
import Qub

// Thin wrapper: loads schema data and feeds it into Mahina's SchemaBrowser.
Item {
    id: root

    property string connectionName: ""
    property var    _schemas:       []

    // How many schemas this connection exposes. One means every table name in
    // the tree is already unambiguous; more than one means none of them are.
    readonly property int schemaCount: root._schemas.length

    signal schemaDoubleClicked(string schema)
    signal tableSelected(string schema, string name)
    signal columnClicked(string schema, string table, string column)
    signal tableDoubleClicked(string schema, string name)
    signal columnDoubleClicked(string schema, string table, string column)
    signal tableQuickBrowseRequested(string schema, string name)
    signal tableStatsRequested(string schema, string name)
    signal tableDdlRequested(string schema, string name)
    signal tableCopyNameRequested(string schema, string name)
    signal schemaCopyNameRequested(string schema)
    signal schemaGraphRequested(string schema)

    onConnectionNameChanged: _reload()

    Connections {
        target: ConnectionManager
        function onConnectionsChanged() { Qt.callLater(root._reload) }
    }

    // Only when the database's structure may have moved. Re-reading it after
    // every finished SELECT meant a full schema walk on the GUI thread for a
    // query that could not have changed anything.
    Connections {
        target: QueryExecutor
        function onSchemaMayHaveChanged(connectionName: string): void {
            if (connectionName === root.connectionName) Qt.callLater(root._reload)
        }
    }

    function _reload(): void {
        root._schemas = root.connectionName
                        ? ConnectionManager.schemas(root.connectionName)
                        : []
    }

    SchemaBrowser {
        anchors.fill: parent
        // Same as the editor: inside a SplitPane the divider is the seam.
        framed:       false
        schemas:          root._schemas
        showBrowseAction: AppSettings.schemaQuickBrowse
        onSchemaDoubleClicked:       (schema)                => root.schemaDoubleClicked(schema)
        onTableSelected:             (schema, name)          => root.tableSelected(schema, name)
        onColumnClicked:             (schema, table, column) => root.columnClicked(schema, table, column)
        onTableDoubleClicked:        (schema, name)          => root.tableDoubleClicked(schema, name)
        onColumnDoubleClicked:       (schema, table, column) => root.columnDoubleClicked(schema, table, column)
        onTableQuickBrowseRequested: (schema, name)          => root.tableQuickBrowseRequested(schema, name)
        onTableStatsRequested:       (schema, name)          => root.tableStatsRequested(schema, name)
        onTableDdlRequested:         (schema, name)          => root.tableDdlRequested(schema, name)
        onTableCopyNameRequested:    (schema, name)          => root.tableCopyNameRequested(schema, name)
        onSchemaCopyNameRequested:   (schema)                => root.schemaCopyNameRequested(schema)
        onSchemaGraphRequested:      (schema)                => root.schemaGraphRequested(schema)
    }
}
