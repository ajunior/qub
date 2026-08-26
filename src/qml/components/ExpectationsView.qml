pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Mahina

// Data-quality checks pane. Author per-column expectations (not-null, unique,
// range, regex, …) and see them evaluated live against the current result set
// via ResultModel.checkExpectations(). Rules persist per query tab (owned by
// WorkspaceScreen); this view is stateless beyond what it emits.
Item {
    id: root

    property var  model:  null    // ResultModel for the active tab
    property bool hasRun: false
    property var  rules:  []       // [{ column, check, arg }]
    signal rulesEdited(var newRules)

    readonly property var _checkOptions: [
        { label: "Not null",          value: "not_null" },
        { label: "Unique",            value: "unique" },
        { label: "Not empty",         value: "not_empty" },
        { label: "Positive (> 0)",    value: "positive" },
        { label: "Non-negative (≥ 0)", value: "non_negative" },
        { label: "In range",          value: "range" },
        { label: "Max length",        value: "max_length" },
        { label: "Matches regex",     value: "matches" },
    ]
    function _checkLabel(v: var): var {
        for (var i = 0; i < _checkOptions.length; i++)
            if (_checkOptions[i].value === v) return _checkOptions[i].label
        return v
    }
    function _checkIndex(v: var): var {
        for (var i = 0; i < _checkOptions.length; i++)
            if (_checkOptions[i].value === v) return i
        return 0
    }
    function _argNeeded(check: var): var {
        return check === "range" || check === "max_length" || check === "matches"
    }
    function _argPlaceholder(check: var): var {
        if (check === "range")      return "min, max"
        if (check === "max_length") return "e.g. 255"
        if (check === "matches")    return "pattern"
        return ""
    }

    readonly property var _cols: root.model ? root.model.columnNames : []

    // Live evaluation — recomputes when the data (model.count) or rules change.
    readonly property var _results: {
        if (!root.model || !root.hasRun || root.rules.length === 0) return []
        root.model.count // dependency: re-evaluate when the result set changes
        return root.model.checkExpectations(root.rules)
    }
    readonly property int _passCount: {
        var c = 0
        for (var i = 0; i < _results.length; i++) if (_results[i].passed) c++
        return c
    }
    readonly property int _failCount: _results.length - _passCount

    // ── Rule mutation (emit a fresh array; WorkspaceScreen persists it) ───────
    function _clone(): var { return JSON.parse(JSON.stringify(root.rules)) }
    function _addRule(): void {
        var r = _clone()
        r.push({ column: (root._cols[0] ?? ""), check: "not_null", arg: "" })
        root.rulesEdited(r)
    }
    function _removeRule(i: var): void { var r = _clone(); r.splice(i, 1); root.rulesEdited(r) }
    function _setField(i: var, field: var, val: var): void {
        var r = _clone()
        if (r[i][field] === val) return
        r[i][field] = val
        root.rulesEdited(r)
    }

    ColumnLayout {
        anchors.fill: parent
        spacing:      0
        visible:      root.hasRun

        // ── Toolbar ───────────────────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            height:           48
            color:            Theme.panel
            border.color:     Theme.border
            border.width:     1

            RowLayout {
                anchors { fill: parent; leftMargin: Theme.sp3; rightMargin: Theme.sp3 }
                spacing: Theme.sp2

                Button {
                    text:     "Add check"
                    iconName: Icons.plus
                    size:     Button.Size.Sm
                    variant:  Button.Variant.Outlined
                    enabled:  root._cols.length > 0
                    onClicked: root._addRule()
                    Layout.alignment: Qt.AlignVCenter
                }

                Item { Layout.fillWidth: true }

                Badge {
                    visible:     root._results.length > 0 && root._passCount > 0
                    text:        root._passCount + " passed"
                    colorScheme: Badge.Color.Success
                }
                Badge {
                    visible:     root._failCount > 0
                    text:        root._failCount + " failed"
                    colorScheme: Badge.Color.Error
                }
            }
        }

        // ── Rule rows ───────────────────────────────────────────────────────
        ListView {
            id: _rules
            Layout.fillWidth:  true
            Layout.fillHeight: true
            clip:              true
            model:             root.rules
            visible:           root.rules.length > 0
            boundsBehavior:    Flickable.StopAtBounds
            spacing:           0
            ScrollBar.vertical: ScrollBar {}

            delegate: Rectangle {
                id: delegateItem
                required property var modelData
                required property int index

                readonly property var result: root._results[index] ?? null

                width:  _rules.width
                height: 52
                color:  index % 2 === 0 ? Theme.surface : Theme.panel

                RowLayout {
                    anchors { fill: parent; leftMargin: Theme.sp3; rightMargin: Theme.sp3 }
                    spacing: Theme.sp2

                    // Column picker
                    Dropdown {
                        implicitWidth: 150
                        model:         root._cols
                        currentIndex:  root._cols.indexOf(delegateItem.modelData.column)
                        Layout.alignment: Qt.AlignVCenter
                        onCurrentIndexChanged:
                            root._setField(delegateItem.index, "column", root._cols[currentIndex] ?? "")
                    }

                    // Check picker
                    Dropdown {
                        implicitWidth: 160
                        model:         root._checkOptions
                        currentIndex:  root._checkIndex(delegateItem.modelData.check)
                        Layout.alignment: Qt.AlignVCenter
                        onCurrentIndexChanged:
                            root._setField(delegateItem.index, "check",
                                           root._checkOptions[currentIndex].value)
                    }

                    // Argument (only for checks that take one)
                    Input {
                        implicitWidth: 130
                        visible:       root._argNeeded(delegateItem.modelData.check)
                        text:          delegateItem.modelData.arg
                        placeholderText: root._argPlaceholder(delegateItem.modelData.check)
                        Layout.alignment: Qt.AlignVCenter
                        onEditingFinished: root._setField(delegateItem.index, "arg", text)
                    }

                    Item { Layout.fillWidth: true }

                    // Verdict
                    RowLayout {
                        spacing: Theme.sp2
                        visible: parent && delegateItem.result !== null
                        Layout.alignment: Qt.AlignVCenter

                        Icon {
                            name:  delegateItem.result && delegateItem.result.error ? Icons.warning
                                 : (delegateItem.result && delegateItem.result.passed ? Icons.checkCircle : Icons.xCircle)
                            size:  15
                            color: delegateItem.result && delegateItem.result.error ? Theme.warning
                                 : (delegateItem.result && delegateItem.result.passed ? Theme.success : Theme.error)
                        }
                        Text {
                            text: {
                                if (!delegateItem.result) return ""
                                if (delegateItem.result.error) return delegateItem.result.error
                                if (delegateItem.result.passed) return "Pass · " + delegateItem.result.checked + " rows"
                                return delegateItem.result.violations + " / " + delegateItem.result.checked + " failed"
                                     + (delegateItem.result.sample !== undefined ? "  (e.g. " + delegateItem.result.sample + ")" : "")
                            }
                            color: delegateItem.result && delegateItem.result.error ? Theme.warning
                                 : (delegateItem.result && delegateItem.result.passed ? Theme.success : Theme.error)
                            font { family: Theme.fontFamily; pixelSize: Theme.textSm }
                            elide: Text.ElideRight
                            Layout.maximumWidth: 260
                        }
                    }

                    Button {
                        iconOnly: true
                        iconName: Icons.trash
                        size:     Button.Size.Sm
                        variant:  Button.Variant.Ghost
                        Layout.alignment: Qt.AlignVCenter
                        onClicked: root._removeRule(delegateItem.index)
                    }
                }

                Rectangle { anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                            height: 1; color: Theme.border; opacity: 0.4 }
            }
        }

        // Empty (has run, but no rules yet)
        EmptyState {
            Layout.fillWidth:  true
            Layout.fillHeight: true
            visible:  root.rules.length === 0
            icon:     Icons.checkCircle
            iconSize: 40
            title:    "No data-quality checks yet"
            description: "Add a check to assert things about the result — e.g. a column has no nulls, values are unique, or numbers fall in a range."
        }
    }

    // Empty (nothing run in this tab)
    EmptyState {
        anchors.fill: parent
        visible:  !root.hasRun
        icon:     Icons.checkCircle
        iconSize: 40
        title:    "Run a query to add checks"
        description: "Data-quality checks evaluate against the current result set."
    }
}
