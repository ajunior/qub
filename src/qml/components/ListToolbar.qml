pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Mahina

// Search box and sort control for one of the Home screen's saved-item lists.
//
// The four lists — data sources, SSH connections, workspaces, snippets — are
// read the same way and so are given the same handle, rather than each growing
// its own arrangement of controls. The key lives behind a menu and the
// direction does not: the key is chosen once and then left alone, while the
// direction gets flipped back and forth, and both controls state where the list
// currently stands without having to be opened.
RowLayout {
    id: root

    // ── API ──────────────────────────────────────────────────────────────────
    property alias  query:       _search.text
    property string placeholder: "Search…"

    // [{ key: "name", label: "Name" }, …] — first entry is the fallback label.
    property var    sortKeys:    []
    property string sortKey:     ""
    property bool   ascending:   true

    signal sortKeyPicked(string key)
    signal directionToggled()

    spacing: Theme.sp2

    readonly property string _activeLabel: {
        for (let i = 0; i < root.sortKeys.length; ++i)
            if (root.sortKeys[i].key === root.sortKey) return root.sortKeys[i].label
        return root.sortKeys.length > 0 ? root.sortKeys[0].label : ""
    }

    SearchInput {
        id: _search
        placeholder: root.placeholder
        Layout.fillWidth: true
    }

    // Sort key. Labelled rather than icon-only: which column the list is
    // ordered by is the thing you cannot infer by looking at four names, and a
    // button that already says "Name" answers it without being opened.
    Button {
        id:        _keyBtn
        text:      root._activeLabel
        iconName:  Icons.arrowsDownUp
        size:      Button.Size.Sm
        variant:   Button.Variant.Ghost
        visible:   root.sortKeys.length > 1
        onClicked: _keyMenu.open()
    }

    // Direction. Flipping it is the frequent gesture, so it is one click and
    // never behind a menu; the icon carries the current state.
    Tooltip {
        text: root.ascending ? "Ascending" : "Descending"

        Button {
            iconOnly:  true
            size:      Button.Size.Sm
            iconName:  root.ascending ? Icons.sortAscending : Icons.sortDescending
            variant:   Button.Variant.Ghost
            onClicked: root.directionToggled()
        }
    }

    // Right-aligned: the toolbar sits at the right edge of the card, and a
    // left-aligned popup runs off the window.
    Menu {
        id:       _keyMenu
        anchor:   _keyBtn
        position: Menu.Position.BottomRight
        model:  root.sortKeys.map(k => ({
                    label: k.label,
                    icon:  k.key === root.sortKey ? Icons.check : ""
                }))
        onTriggered: (index, item) => root.sortKeyPicked(root.sortKeys[index].key)
    }
}
