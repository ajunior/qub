pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Mahina
import Qub

// Single per-connection "Database" window: Overview (static identity — version,
// size, encoding, object counts) and Health (live sparkline metrics polled
// every 3s while the window is open) as tabs. Replaces the old separate
// DatabaseInfoPopup dialog and DbHealthWindow.
Window {
    id: root

    // ── API ──────────────────────────────────────────────────────────────────
    property string connectionName: ""

    function openFor(name: var): void {
        connectionName = name
        _info        = ({})
        _error       = ""
        _samples     = []
        _lastMap     = ({})
        _unavailable = false
        DatabaseInspector.inspect(name)
        _poll()
        show(); raise(); requestActivate()
    }

    title: "Database · " + (connectionName || "")
    width: 780; height: 560
    minimumWidth: 520; minimumHeight: 360
    color: Theme.background
    flags: Qt.Window

    // 0 = Overview, 1 = Health. Kept across opens: health watchers get their
    // tab back when they reopen.
    property int _tab: 0

    // ── Overview state ────────────────────────────────────────────────────────
    property var    _info:  ({})
    property string _error: ""

    Connections {
        target: DatabaseInspector
        function onResultReady(info: var): void  { if (root.visible) root._info = info }
        function onErrorOccurred(msg: string): void { if (root.visible) root._error = msg }
    }

    // ── Health state (rolling sample history) ────────────────────────────────
    property var _samples: []                    // [{ t: ms, m: metricsMap }]
    readonly property int _maxSamples: 40        // ~2 min at 3s cadence
    property var _lastMap: ({})
    property bool _unavailable: false

    readonly property bool   _serverMetrics: _lastMap.serverMetrics === true
    readonly property string _driver:        _lastMap.driver ?? ""

    // ── Threshold alerting ────────────────────────────────────────────────────
    property var _alerts: []                      // HealthAlertManager.evaluate() result
    property int _rulesRev: 0                      // bumped to re-read rulesFor() bindings
    // New-rule form state
    property string _newMetric:    ""
    property string _newCmp:       "gt"
    property string _newThreshold: ""
    // Metrics that can carry a threshold (everything except raw byte sizes).
    readonly property var _alertableDefs: root._defs.filter(d => d.kind !== "bytes")
    readonly property var _activeAlerts:  root._alerts.filter(a => a.breached)

    // Current value of every alertable metric, keyed by its label (the rule's
    // metric identity). Skips metrics with no sample yet.
    function _alertValues(): var {
        const out = {}
        const defs = root._alertableDefs
        for (let i = 0; i < defs.length; i++) {
            const s = root._series(defs[i])
            if (s.length === 0) continue
            out[defs[i].label] = s[s.length - 1]
        }
        return out
    }
    function _refreshAlerts(): void {
        if (connectionName === "") { root._alerts = []; return }
        root._alerts = HealthAlertManager.evaluate(connectionName, root._alertValues())
    }

    function _poll(): void {
        if (connectionName === "") return
        const m = DatabaseInspector.metrics(connectionName)
        if (!m || Object.keys(m).length === 0) { _unavailable = true; return }
        _unavailable = false
        _lastMap = m
        const s = _samples.slice()
        s.push({ t: Date.now(), m: m })
        while (s.length > _maxSamples) s.shift()
        _samples = s
        // Edge-triggered check (logs + toasts on transition) each poll.
        root._alerts = HealthAlertManager.checkAndNotify(connectionName, root._alertValues())
    }

    // Re-evaluate status immediately when rules are added/removed/toggled.
    Connections {
        target: HealthAlertManager
        function onChanged() { root._rulesRev++; root._refreshAlerts() }
    }

    Timer {
        interval: 3000; repeat: true
        running:  root.visible && root.connectionName !== ""
        onTriggered: root._poll()
    }

    // ── Metric definitions (per driver) ───────────────────────────────────────
    readonly property var _defs: {
        if (_driver === "postgres") return [
            { key: "connections", label: "Active connections", kind: "gauge", color: Theme.primary },
            { key: "tuples",      label: "Rows read / sec",     kind: "rate", unit: "/s", color: Theme.info },
            { key: "commits",     label: "Commits / sec",       kind: "rate", unit: "/s", color: Theme.success },
            { label: "Cache hit ratio", kind: "ratio", totalKeys: ["blksHit", "blksRead"], subKeys: ["blksRead"], color: Theme.warning },
            { key: "blocked",     label: "Lock waits",          kind: "gauge", color: Theme.error },
            { key: "dbSize",      label: "Database size",       kind: "bytes", color: Theme.textSecondary },
        ]
        if (_driver === "mysql") return [
            { key: "connections", label: "Threads connected",   kind: "gauge", color: Theme.primary },
            { key: "queries",     label: "Queries / sec",       kind: "rate", unit: "/s", color: Theme.info },
            { key: "rowsRead",    label: "Rows read / sec",     kind: "rate", unit: "/s", color: Theme.success },
            { label: "Buffer pool hit", kind: "ratio", totalKeys: ["bpReadReq"], subKeys: ["bpReads"], color: Theme.warning },
            { key: "commits",     label: "Commits / sec",       kind: "rate", unit: "/s", color: Theme.textSecondary },
            { key: "dbSize",      label: "Database size",       kind: "bytes", color: Theme.textSecondary },
        ]
        // sqlite / unknown — no server counters, just the file size
        return [ { key: "dbSize", label: "Database size", kind: "bytes", color: Theme.primary } ]
    }

    // ── Series / value derivation ─────────────────────────────────────────────
    function _num(v: var): var { return (v === undefined || v === null) ? 0 : Number(v) }

    function _series(def: var): var {
        const s = root._samples
        if (s.length === 0) return []
        if (def.kind === "gauge" || def.kind === "bytes")
            return s.map(x => root._num(x.m[def.key]))
        if (def.kind === "rate") {
            const out = []
            for (let i = 1; i < s.length; i++) {
                const dt = (s[i].t - s[i - 1].t) / 1000
                const dv = root._num(s[i].m[def.key]) - root._num(s[i - 1].m[def.key])
                out.push(dt > 0 ? Math.max(0, dv / dt) : 0)   // clamp counter resets
            }
            return out
        }
        if (def.kind === "ratio") {
            const out = []
            for (let i = 1; i < s.length; i++) {
                let dTot = 0, dSub = 0
                def.totalKeys.forEach(k => dTot += root._num(s[i].m[k]) - root._num(s[i - 1].m[k]))
                def.subKeys.forEach(k => dSub += root._num(s[i].m[k]) - root._num(s[i - 1].m[k]))
                const hit = dTot > 0 ? ((dTot - dSub) / dTot) * 100
                                     : (out.length ? out[out.length - 1] : 100)
                out.push(Math.max(0, Math.min(100, hit)))
            }
            return out
        }
        return []
    }

    function _fmtBytes(b: var): var {
        b = Number(b)
        if (isNaN(b) || b < 0)   return "—"
        if (b < 1024)            return b + " B"
        if (b < 1048576)         return (b / 1024).toFixed(1) + " KB"
        if (b < 1073741824)      return (b / 1048576).toFixed(1) + " MB"
        return (b / 1073741824).toFixed(2) + " GB"
    }

    function _fmtValue(def: var, series: var): var {
        if (series.length === 0) return "—"
        const v = series[series.length - 1]
        if (def.kind === "bytes") return root._fmtBytes(v)
        if (def.kind === "ratio") return v.toFixed(1) + "%"
        if (def.kind === "rate")  return (v >= 100 ? Math.round(v).toString() : v.toFixed(1)) + (def.unit || "")
        return Math.round(v).toString()   // gauge
    }

    function _delta(series: var): var {
        if (series.length < 2) return 0
        const prev = series[series.length - 2]
        const last = series[series.length - 1]
        if (prev === 0) return 0
        return ((last - prev) / Math.abs(prev)) * 100
    }

    // ── Layout ────────────────────────────────────────────────────────────────
    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // Header: identity + tabs
        Rectangle {
            Layout.fillWidth: true
            height: 48
            color:  Theme.panel
            border.color: Theme.border; border.width: 1

            RowLayout {
                anchors { fill: parent; leftMargin: Theme.sp3; rightMargin: Theme.sp3 }
                spacing: Theme.sp2

                Icon { name: Icons.database; size: 16; color: Theme.primary }

                Text {
                    text:  root.connectionName || "No connection"
                    color: Theme.textPrimary
                    font { family: Theme.fontFamily; pixelSize: Theme.textBase; weight: Theme.weightSemibold }
                }

                Badge {
                    visible:     root._driver !== ""
                    text:        root._driver
                    colorScheme: Badge.Color.Default
                }

                Item { Layout.fillWidth: true }

                Rectangle {
                    width: 7; height: 7; radius: 3.5
                    color: Theme.success
                    visible: root._tab === 1 && root._serverMetrics
                    Layout.alignment: Qt.AlignVCenter
                }
                Text {
                    visible: root._tab === 1 && root._serverMetrics
                    text:    "Live · every 3s"
                    color:   Theme.textDisabled
                    font { family: Theme.fontFamily; pixelSize: Theme.textXs }
                }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            height: 36
            color:  Theme.surface

            Rectangle {
                anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
                height: 1; color: Theme.border
            }

            TabBar {
                anchors { left: parent.left; leftMargin: Theme.sp3; top: parent.top; bottom: parent.bottom }
                tabHeight:   36
                tabMinWidth: 90
                model:       ["Overview", "Health"]
                currentIndex: root._tab
                onTabClicked: (i) => root._tab = i
            }
        }

        // Body
        StackLayout {
            Layout.fillWidth:  true
            Layout.fillHeight: true
            currentIndex: root._tab

            // ── Overview ──────────────────────────────────────────────────────
            Flickable {
                id: _ovFlick
                contentHeight: _ovBody.implicitHeight + Theme.sp4 * 2
                clip: true

                ColumnLayout {
                    id: _ovBody
                    x: Theme.sp4; y: Theme.sp4
                    width: _ovFlick.width - Theme.sp4 * 2
                    spacing: Theme.sp3

                    Text {
                        visible: root._error !== "" || DatabaseInspector.loading
                        text:    root._error !== "" ? root._error : "Loading…"
                        color:   root._error !== "" ? Theme.error : Theme.textDisabled
                        font { family: Theme.fontFamily; pixelSize: Theme.textSm }
                    }

                    GridLayout {
                        Layout.fillWidth: true
                        columns:       3
                        columnSpacing: Theme.sp2
                        rowSpacing:    Theme.sp2
                        visible: !DatabaseInspector.loading && root._error === "" && root._info.tableCount !== undefined

                        Repeater {
                            model: {
                                const i = root._info
                                return [
                                    { label: "Tables",      value: i.tableCount,        icon: Icons.table          },
                                    { label: "Views",       value: i.viewCount,         icon: Icons.eyeSlash       },
                                    { label: "Indexes",     value: i.indexCount,        icon: Icons.arrowsDownUp   },
                                    { label: "Triggers",    value: i.triggerCount,      icon: Icons.lightning      },
                                    { label: "Functions",   value: i.functionCount,     icon: Icons.function_      },
                                    { label: "Connections", value: i.activeConnections, icon: Icons.plugsConnected },
                                ].filter(c => c.value !== undefined && c.value !== null)
                            }

                            delegate: Stat {
                                id: delegateItem
                                required property var modelData
                                Layout.fillWidth: true
                                label: modelData.label
                                value: modelData.value?.toString() ?? "—"
                                icon:  modelData.icon
                            }
                        }
                    }

                    PropertyGrid {
                        Layout.fillWidth: true
                        visible:  !DatabaseInspector.loading && root._error === "" && root._info.size !== undefined
                        keyWidth: 90
                        model: {
                            const i = root._info
                            return [
                                { key: "Size",      value: i.size      },
                                { key: "Encoding",  value: i.encoding  },
                                { key: "Collation", value: i.collation },
                                { key: "Version",   value: i.version   },
                                { key: "File",      value: i.filePath  },
                            ].filter(r => r.value !== undefined && r.value !== null && r.value !== "")
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        Button {
                            text:     "Refresh"
                            iconName: Icons.arrowClockwise
                            size:     Button.Size.Sm
                            variant:  Button.Variant.Ghost
                            visible:  !DatabaseInspector.loading
                            onClicked: DatabaseInspector.inspect(root.connectionName)
                        }
                        Item { Layout.fillWidth: true }
                    }
                }
            }

            // ── Health ────────────────────────────────────────────────────────
            Item {
                EmptyState {
                    anchors.centerIn: parent
                    width:       parent.width - Theme.sp6 * 2
                    visible:     root._unavailable
                    icon:        Icons.warningCircle
                    title:       "Metrics unavailable"
                    description: "Couldn't read metrics — the connection may be down."
                }

                Flickable {
                    id:            _hFlick
                    anchors.fill:  parent
                    visible:       !root._unavailable
                    contentHeight: _healthBody.implicitHeight
                    clip:          true

                    ColumnLayout {
                        id:      _healthBody
                        width:   _hFlick.width
                        spacing: Theme.sp3

                        // Embedded-DB note (SQLite / unknown drivers)
                        Rectangle {
                            Layout.fillWidth:   true
                            Layout.leftMargin:  Theme.sp4
                            Layout.rightMargin: Theme.sp4
                            Layout.topMargin:   Theme.sp4
                            visible: root._driver !== "" && !root._serverMetrics
                            height:  _noteRow.implicitHeight + Theme.sp3 * 2
                            radius:  Theme.radiusSm
                            color:   Theme.panel
                            border.color: Theme.border; border.width: 1

                            RowLayout {
                                id: _noteRow
                                anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter
                                          leftMargin: Theme.sp3; rightMargin: Theme.sp3 }
                                spacing: Theme.sp2
                                Icon { name: Icons.info; size: 15; color: Theme.textSecondary }
                                Text {
                                    Layout.fillWidth: true
                                    text:  "This is an embedded database with no server-side counters. Only the file size is tracked."
                                    color: Theme.textSecondary
                                    wrapMode: Text.WordWrap
                                    font { family: Theme.fontFamily; pixelSize: Theme.textSm }
                                }
                            }
                        }

                        // Active-alert banner
                        Rectangle {
                            Layout.fillWidth:   true
                            Layout.leftMargin:  Theme.sp4
                            Layout.rightMargin: Theme.sp4
                            Layout.topMargin:   Theme.sp4
                            visible: root._activeAlerts.length > 0
                            height:  _alertCol.implicitHeight + Theme.sp3 * 2
                            radius:  Theme.radiusSm
                            color:   Qt.rgba(Theme.error.r, Theme.error.g, Theme.error.b, 0.10)
                            border.color: Theme.error; border.width: 1

                            ColumnLayout {
                                id: _alertCol
                                anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter
                                          leftMargin: Theme.sp3; rightMargin: Theme.sp3 }
                                spacing: Theme.sp1

                                RowLayout {
                                    spacing: Theme.sp2
                                    Icon { name: Icons.warningCircle; size: 15; color: Theme.error }
                                    Text {
                                        text:  root._activeAlerts.length + " alert" +
                                               (root._activeAlerts.length === 1 ? "" : "s") + " active"
                                        color: Theme.error
                                        font { family: Theme.fontFamily; pixelSize: Theme.textSm;
                                               weight: Theme.weightSemibold }
                                    }
                                }
                                Repeater {
                                    model: root._activeAlerts
                                    delegate: Text {
                                        id: delegateItem2
                                        required property var modelData
                                        Layout.fillWidth: true
                                        text:  modelData.metric + " " +
                                               (modelData.comparator === "lt" ? "<" : ">") + " " +
                                               modelData.threshold + "  ·  now " +
                                               (Math.round(modelData.value * 10) / 10)
                                        color: Theme.textPrimary
                                        elide: Text.ElideRight
                                        font { family: Theme.fontFamilyMono; pixelSize: Theme.textXs }
                                    }
                                }
                            }
                        }

                        // Metric cards
                        GridLayout {
                            Layout.fillWidth:   true
                            Layout.leftMargin:  Theme.sp4
                            Layout.rightMargin: Theme.sp4
                            Layout.topMargin:   Theme.sp4
                            Layout.bottomMargin: Theme.sp4
                            columnSpacing: Theme.sp3
                            rowSpacing:    Theme.sp3
                            columns: Math.max(1, Math.floor(_healthBody.width / 250))

                            Repeater {
                                model: root._defs
                                delegate: MetricCard {
                                    id: delegateItem3
                                    required property var modelData
                                    // Re-evaluates whenever _samples changes.
                                    readonly property var _s: root._series(modelData)
                                    Layout.fillWidth:       true
                                    Layout.preferredHeight: 132
                                    cardLabel:   modelData.label
                                    metricValue: root._fmtValue(modelData, _s)
                                    delta:       root._delta(_s)
                                    deltaLabel:  root._delta(_s) !== 0 ? "vs prev" : ""
                                    sparkData:   _s
                                    accentColor: modelData.color
                                }
                            }
                        }

                        // ── Alerts configuration ────────────────────────────
                        Rectangle {
                            Layout.fillWidth:    true
                            Layout.leftMargin:   Theme.sp4
                            Layout.rightMargin:  Theme.sp4
                            Layout.bottomMargin: Theme.sp4
                            visible: root._alertableDefs.length > 0
                            height:  _alertsCfg.implicitHeight + Theme.sp3 * 2
                            radius:  Theme.radiusSm
                            color:   Theme.panel
                            border.color: Theme.border; border.width: 1

                            ColumnLayout {
                                id: _alertsCfg
                                anchors { left: parent.left; right: parent.right; top: parent.top
                                          leftMargin: Theme.sp3; rightMargin: Theme.sp3; topMargin: Theme.sp3 }
                                spacing: Theme.sp2

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Theme.sp2
                                    Icon { name: Icons.bell; size: 15; color: Theme.textSecondary }
                                    Text {
                                        text:  "Alerts"
                                        color: Theme.textPrimary
                                        font { family: Theme.fontFamily; pixelSize: Theme.textSm;
                                               weight: Theme.weightSemibold }
                                    }
                                    Text {
                                        text:  "notify when a metric crosses a threshold"
                                        color: Theme.textDisabled
                                        font { family: Theme.fontFamily; pixelSize: Theme.textXs }
                                    }
                                    Item { Layout.fillWidth: true }
                                }

                                // Existing rules
                                Repeater {
                                    model: (root._rulesRev, HealthAlertManager.rulesFor(root.connectionName))
                                    delegate: RowLayout {
                                        id: delegateItem4
                                        required property var modelData
                                        Layout.fillWidth: true
                                        spacing: Theme.sp2

                                        readonly property var _st: {
                                            var a = root._alerts
                                            for (var i = 0; i < a.length; i++)
                                                if (a[i].id === delegateItem4.modelData.id) return a[i]
                                            return null
                                        }

                                        Toggle {
                                            checked:   delegateItem4.modelData.enabled
                                            onToggled: HealthAlertManager.setEnabled(delegateItem4.modelData.id, checked)
                                        }
                                        Text {
                                            text:  delegateItem4.modelData.metric + "  " +
                                                   (delegateItem4.modelData.comparator === "lt" ? "<" : ">") + "  " +
                                                   delegateItem4.modelData.threshold
                                            color: delegateItem4.modelData.enabled ? Theme.textPrimary : Theme.textDisabled
                                            font { family: Theme.fontFamilyMono; pixelSize: Theme.textXs }
                                            Layout.fillWidth: true
                                            elide: Text.ElideRight
                                        }
                                        Badge {
                                            visible:     delegateItem4._st !== null && delegateItem4._st.value !== null && delegateItem4.modelData.enabled
                                            text:        delegateItem4._st ? ("now " + (Math.round(delegateItem4._st.value * 10) / 10)) : ""
                                            colorScheme: (delegateItem4._st && delegateItem4._st.breached) ? Badge.Color.Error : Badge.Color.Success
                                        }
                                        Button {
                                            iconOnly: true
                                            iconName: Icons.trash
                                            size:     Button.Size.Sm
                                            variant:  Button.Variant.Ghost
                                            onClicked: HealthAlertManager.removeRule(delegateItem4.modelData.id)
                                        }
                                    }
                                }

                                Rectangle { Layout.fillWidth: true; height: 1; color: Theme.border; opacity: 0.5 }

                                // New-rule form
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Theme.sp2

                                    Dropdown {
                                        Layout.fillWidth: true
                                        placeholder:  "Metric"
                                        model:        root._alertableDefs.map(d => d.label)
                                        currentIndex: root._alertableDefs.map(d => d.label).indexOf(root._newMetric)
                                        onCurrentIndexChanged:
                                            root._newMetric = root._alertableDefs.map(d => d.label)[currentIndex] ?? ""
                                    }
                                    Dropdown {
                                        implicitWidth: 90
                                        model:        [{ label: "＞ above", value: "gt" },
                                                       { label: "＜ below", value: "lt" }]
                                        currentIndex: root._newCmp === "lt" ? 1 : 0
                                        onCurrentIndexChanged: root._newCmp = (currentIndex === 1 ? "lt" : "gt")
                                    }
                                    Input {
                                        implicitWidth:   110
                                        text:            root._newThreshold
                                        placeholderText: "Threshold"
                                        onTextChanged:   root._newThreshold = text
                                    }
                                    Button {
                                        text:     "Add"
                                        iconName: Icons.plus
                                        size:     Button.Size.Sm
                                        enabled:  root._newMetric !== "" && root._newThreshold.trim() !== "" &&
                                                  !isNaN(parseFloat(root._newThreshold))
                                        onClicked: {
                                            HealthAlertManager.addRule(root.connectionName, root._newMetric,
                                                                       root._newCmp, parseFloat(root._newThreshold))
                                            root._newThreshold = ""
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
