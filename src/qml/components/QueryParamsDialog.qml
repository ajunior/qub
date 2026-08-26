pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Mahina
import Qub

// Shows one Input per detected query parameter.
// Usage:
//   QueryParamsDialog {
//       id: _paramsDialog
//       onAccepted: (filledSql) => QueryExecutor.execute(conn, filledSql)
//   }
//   _paramsDialog.openWith(params, rawSql, prevValues, "run")
//
// params: [{name, positional}]  — positional=true means $1-style
// prevValues: { name: lastValue } to prefill (persisted by the caller per tab)
// purpose: "run" | "explain" — only changes the confirm button's label/icon;
//          the caller inspects it in onAccepted to decide what to do.
Dialog {
    id: root

    signal accepted(string filledSql)

    // ── API ──────────────────────────────────────────────────────────────────
    property var    _params:  []   // [{name, positional}]
    property string _rawSql:  ""
    property string purpose:  "run"

    function openWith(params: var, rawSql: var, prevValues: var, mode: var): void {
        _params        = params
        _rawSql        = rawSql
        purpose        = mode || "run"
        _initialValues = prevValues || {}
        // Seed working values from the prefill so untouched fields still submit.
        _values        = Object.assign({}, _initialValues)
        open()
    }

    property var _values:        ({})
    property var _initialValues: ({})   // prefill; only reassigned on openWith

    // ── Dialog chrome ─────────────────────────────────────────────────────────
    title:          purpose === "explain" ? "Explain Parameters" : "Query Parameters"
    subtitle:       _params.length + " parameter" + (_params.length !== 1 ? "s" : "") + " detected"
    preferredWidth: 420

    // ── Content ───────────────────────────────────────────────────────────────
    ColumnLayout {
        width:   parent.width
        spacing: 12

        Repeater {
            model: root._params
            delegate: Input {
                id: delegateItem
                required property var   modelData
                required property int   index
                Layout.fillWidth: true
                label:       modelData.positional ? ("$" + modelData.name) : (":" + modelData.name)
                // Delegates are recreated on every openWith (model is reassigned),
                // so this evaluates fresh against the latest prefill.
                text:        root._initialValues[modelData.name] ?? ""
                placeholderText: "Value for " + label
                onTextChanged: {
                    const v = Object.assign({}, root._values)
                    v[delegateItem.modelData.name] = text
                    root._values = v
                }
                Keys.onReturnPressed: if (index === root._params.length - 1) root._submit()
            }
        }
    }

    // ── Footer ────────────────────────────────────────────────────────────────
    footer: RowLayout {
        Button {
            text:    "Cancel"
            size:    Button.Size.Sm
            variant: Button.Variant.Ghost
            onClicked: root.close ? root.close() : root.visible = false
        }
        Item { Layout.fillWidth: true }
        Button {
            text:     root.purpose === "explain" ? "Explain" : "Run"
            iconName: root.purpose === "explain" ? Icons.lightning : Icons.play
            size:     Button.Size.Sm
            variant:  Button.Variant.Filled
            onClicked: root._submit()
        }
    }

    // Turn a raw field value into a SQL literal. Numbers, booleans and an
    // explicit `null` go in unquoted (so `LIMIT :n` and numeric comparisons
    // work); everything else is a quoted, escaped string. A blank field is an
    // empty string ''. Trade-off: a value like "0123" or the word "true" is
    // coerced — wrap it in quotes in the field to force a string.
    function _coerce(raw: var): var {
        const t = (raw ?? "").trim()
        if (t === "")                     return "''"
        if (/^-?\d+(\.\d+)?$/.test(t))    return t
        if (/^(true|false)$/i.test(t))    return t.toUpperCase()
        if (/^null$/i.test(t))            return "NULL"
        return "'" + (raw ?? "").replace(/'/g, "''") + "'"
    }

    function _submit(): void {
        let sql = root._rawSql
        for (const p of root._params) {
            const lit = root._coerce(root._values[p.name] ?? "")
            if (p.positional) {
                // Replace $1, $2 … with the coerced literal
                sql = sql.replace(new RegExp("\\$" + p.name + "(?!\\d)", "g"), lit)
            } else {
                sql = sql.replace(new RegExp(":" + p.name + "\\b", "g"), lit)
            }
        }
        if (root.close) root.close(); else root.visible = false
        root.accepted(sql)
    }
}
