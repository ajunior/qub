pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Mahina
import Qub

ApplicationWindow {
    id: root
    width: 1280
    height: 800
    minimumWidth: 960
    minimumHeight: 600
    visible: true
    title: _page === 1
           ? "qub · " + _workspace.workspaceName
             + (_workspace.activeConnection !== "" ? " — " + _workspace.activeConnection : "")
           : "qub"

    color: Theme.background
    font.family: Theme.fontFamily

    Binding { target: Theme; property: "dark"; value: AppSettings.darkTheme }
    Binding { target: HistoryManager; property: "limit"; value: AppSettings.historyLimit }

    function applyTheme(colors: var): void {
        Theme.reset()
        Theme.load(colors)
    }

    Component.onCompleted: applyTheme(ThemeManager.activeThemeColors())

    Connections {
        target: ThemeManager
        function onActiveThemeChanged() { root.applyTheme(ThemeManager.activeThemeColors()) }
    }

    onClosing: (close) => {
        _workspace.flushWorkspace()
        close.accepted = true
    }

    property int _page: 0   // 0 = home, 1 = workspace

    HomeScreen {
        anchors.fill: parent
        visible: root._page === 0
        onConnectionSelected:     (name) => { _workspace.openConnection(name); root._page = 1 }
        onWorkspaceSelected:      (id)   => { _workspace.loadWorkspace(id); root._page = 1 }
        onGoToWorkspace:          root._page = 1
        onLogsRequested:          _workspace.toggleLogs()
    }

    WorkspaceScreen {
        id:                _workspace
        anchors.fill:      parent
        visible:           root._page === 1
        initialSql:        Startup.sql
        onGoToHome:        root._page = 0
        onNewConnectionRequested: connectionDialog.openNew()
    }

    ConnectionDialog {
        id: connectionDialog
    }

    // ── SSH host key confirmation ─────────────────────────────────────────────
    // Shown the first time a tunnel targets a host that is not in known_hosts.
    ConfirmDialog {
        id: hostKeyDialog
        property string connName: ""
        dialogTitle: "Verify SSH host key"
        confirmText: "Trust & Connect"
        cancelText:  "Cancel"
        onConfirmed: ConnectionManager.acceptHostKey(connName)
        onCancelled: ConnectionManager.rejectHostKey(connName)
    }

    // App-wide health-alert toasts (fired on entering a threshold breach). The
    // breach is also logged to the Activity Log via LogManager.
    Toaster { id: _healthToaster }
    Connections {
        target: HealthAlertManager
        function onAlertRaised(connectionName: string, message: string): void {
            _healthToaster.show(message, Toaster.Type.Warning, 6000)
        }
    }

    Connections {
        target: ConnectionManager
        function onTestResult(success: bool, message: string): void {
            if (connectionDialog.opened)
                connectionDialog.showTestResult(success, message)
        }
        function onHostKeyConfirmationRequired(name: string, host: string, fingerprints: string): void {
            hostKeyDialog.connName = name
            hostKeyDialog.dialogMessage =
                "This is the first connection to " + host + ".\n" +
                "Compare the fingerprint below with one obtained from the " +
                "server administrator before trusting it:\n\n" + fingerprints
            hostKeyDialog.open()
        }
    }
}
