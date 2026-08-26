pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Mahina

// Thin popup wrapper around ConnectionForm, used when a new connection is
// requested from inside a workspace (the Home Data Sources page hosts the
// same form inline).
Popup {
    id: root

    function openNew(): void {
        _form.loadNew()
        open()
    }

    function showTestResult(ok: var, msg: var): void {
        _form.showTestResult(ok, msg)
    }

    anchors.centerIn: Overlay.overlay
    width: 640
    padding: 24
    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

    background: Rectangle {
        color: Theme.surface
        radius: Theme.radiusMd
        border.color: Theme.border
    }

    ConnectionForm {
        id: _form
        width: parent.width
        // In-workspace saves always adopt a tab, so the plain Save (without
        // connecting) variant doesn't apply here.
        allowSaveWithoutConnect: false
        onCancelled: root.close()
        onAdded:     root.close()
        onUpdated:   root.close()
    }
}
