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
//
// It rides on the section's title row rather than taking a band of its own.
// Nine saved connections do not need a search field the width of the window,
// and a full-width one reads as a mode the list is in instead of a control
// sitting beside it.
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

    // Sized once rather than to the space available: it is a control on a
    // toolbar, and the list it filters is short. The placeholder can stay at
    // "Search…" for the same reason the toolbar fits here at all — the section
    // title is on this row, three inches to the left, saying what is searched.
    SearchInput {
        id: _search
        placeholder: root.placeholder
        Layout.preferredWidth: 220
    }

    // Separates the list's controls from the section's actions — new, import,
    // export — which share the title row and are a different kind of thing. It
    // lives here so that it disappears together with the toolbar, which hides
    // itself when there is nothing worth sorting.
    Divider { vertical: true; Layout.preferredHeight: 20 }

    // Left-aligned under the button, which is safe at any window width: the
    // controls that follow the key button on this row — direction, search,
    // divider, the section's own actions — are wider than the menu, so there is
    // always room to its right.
    Menu {
        id:       _keyMenu
        anchor:   _keyBtn
        position: Menu.Position.Bottom
        model:  root.sortKeys.map(k => ({
                    label: k.label,
                    icon:  k.key === root.sortKey ? Icons.check : ""
                }))
        onTriggered: (index, item) => root.sortKeyPicked(root.sortKeys[index].key)
    }
}
