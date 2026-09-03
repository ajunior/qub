pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Dialogs
import QtCore
import QtQuick.Controls.Basic as QQC
import Mahina
import "../guard.js"   as Guard
import "../drivers.js" as Drivers
import "../format.js"  as Fmt
import "../params.js"  as Params
import Qub

Item {
    id: root

    // ── API ──────────────────────────────────────────────────────────────────
    property string initialSql:        ""

    // ── Workspace ─────────────────────────────────────────────────────────────
    // The screen always renders exactly one workspace: a named container of
    // query tabs plus an explicit subset of the global connections.
    // Switching workspaces flushes the outgoing tabs and rebuilds in place.
    property int    workspaceId:       -1
    property string workspaceName:     ""
    property var    workspaceConnections: []

    // Connections that are both in this workspace and still exist in
    // the global pool — the only valid targets for tabs and queries.
    readonly property var _usableConnections:
        ConnectionManager.connections.filter(c => workspaceConnections.indexOf(c.name) !== -1)
    // The active tab points at a connection this workspace may actually use.
    // A tab whose connection was deleted or dropped from the workspace is never
    // retargeted: it keeps its SQL and its target name and renders disabled
    // until a same-named connection exists again. (Silently moving a query from
    // staging to prod is exactly the wrong favour to do someone.)
    readonly property bool _activeTabUsable:
        activeConnection !== "" && _usableConnections.some(c => c.name === activeConnection)

    function _inWorkspace(name: string): bool { return workspaceConnections.indexOf(name) !== -1 }
    function _connExists(name: string): bool { return ConnectionManager.connections.some(c => c.name === name) }
    function _firstUsableConnection(): string {
        return _usableConnections.length > 0 ? _usableConnections[0].name : ""
    }
    // The active connection is derived from the active tab — each tab targets
    // its own connection (flat tab model). Changing a tab's connection or
    // switching tabs updates this automatically.
    readonly property string activeConnection: {
        const t = _queryTabs[_activeQueryTabIdx]
        return t && t.connectionName ? t.connectionName : ""
    }
    readonly property string currentSql: queryEditor.sql
    onCurrentSqlChanged: _sessionDirty = true

    signal goToHome()
    signal newConnectionRequested()

    // Crash-safety: periodically checkpoint the workspace so an unclean exit
    // (crash, kill, power loss) doesn't lose open tabs.
    Timer {
        interval: 15000
        running:  true
        repeat:   true
        onTriggered: if (root._sessionDirty) root.flushWorkspace()
    }

    // Compact relative time for history entries ("just now", "5m", "3h", "2d").
    function _relativeTime(iso: string): string {
        if (!iso) return ""
        const then = new Date(iso).getTime()
        if (isNaN(then)) return ""
        const secs = Math.max(0, Math.floor((Date.now() - then) / 1000))
        if (secs < 45)    return "just now"
        if (secs < 3600)  return Math.round(secs / 60) + "m ago"
        if (secs < 86400) return Math.round(secs / 3600) + "h ago"
        if (secs < 604800) return Math.round(secs / 86400) + "d ago"
        return new Date(iso).toLocaleDateString(Qt.locale(), Locale.ShortFormat)
    }

    // First non-empty line of a SQL string, collapsed and trimmed.
    function _firstLine(sql: string): string {
        const lines = (sql || "").split("\n")
        for (let i = 0; i < lines.length; ++i) {
            const t = lines[i].replace(/\s+/g, " ").trim()
            if (t.length > 0) return t
        }
        return ""
    }

    // ── History entries (reactive) ────────────────────────────────────────────
    property var _historyEntries: []
    Component.onCompleted: {
        _historyEntries = HistoryManager.entries(50)

        loadWorkspace(WorkspaceManager.activeWorkspaceId)

        if (root.initialSql !== "")
            Qt.callLater(() => {
                const sql = root.initialSql.length > 600
                          ? root.initialSql.slice(0, 600) + "\n…"
                          : root.initialSql
                _externalSqlDialog.dialogMessage =
                    "qub was opened through a qub:// link that wants to place this " +
                    "SQL in the editor. It will not run automatically — review it " +
                    "before executing:\n\n" + sql
                _externalSqlDialog.open()
            })
    }

    // ── Panel visibility ──────────────────────────────────────────────────────
    property bool   _showSchema:  true
    property bool   _showQuery:   true
    property bool   _showResults: true
    property bool   _showSidebar: true
    property bool   _showPreview: false  // rendered /* @md */ markdown preview

    // ── Panel focus (solo) mode ───────────────────────────────────────────────
    // Ctrl+Shift+N gives panel N the window to itself; the same key puts the
    // layout back. That is why entering solo takes a snapshot: un-hiding the
    // panels afterwards would land on the defaults, not on the arrangement the
    // person had actually chosen before they zoomed in.
    property string _soloed:  ""     // "" while the layout is the person's own
    property var    _preSolo: null

    readonly property var _panelNames: ({
        schema:  "Schema",
        query:   "Query editor",
        results: "Results",
        sidebar: "Sidebar",
        preview: "Editor and preview"
    })
    readonly property var _panelKeys: ({
        schema: "1", query: "2", results: "3", sidebar: "4", preview: "5"
    })

    // Both Ctrl+Shift+N and Ctrl+Alt+N focus a panel, but only one of them is
    // worth telling a person about. On macOS the system takes Cmd+Shift+3 and
    // Cmd+Shift+4 for its screenshots before the application is ever asked, so
    // there the alias is the shortcut — printing Shift would name a key
    // combination that cannot reach qub. Mahina prints Ctrl as ⌘ and Alt as ⌥
    // from here, so what the panel shows is ⌘⌥3.
    readonly property string _focusMod: Qt.platform.os === "osx" ? "Alt" : "Shift"

    function _setPanels(schema: bool, query: bool, results: bool,
                        sidebar: bool, preview: bool): void {
        root._showSchema  = schema
        root._showQuery   = query
        root._showResults = results
        root._showSidebar = sidebar
        root._showPreview = preview
    }

    function _soloPanel(name: string): void {
        if (root._soloed === name) { root._restoreLayout(); return }

        if (root._soloed === "")
            root._preSolo = { schema:  root._showSchema,  query:   root._showQuery,
                              results: root._showResults, sidebar: root._showSidebar,
                              preview: root._showPreview }
        root._soloed = name

        // The markdown preview is not a panel in its own right — it shares the
        // editor's split — so focusing it means editor and preview, nothing else.
        root._setPanels(name === "schema",
                        name === "query" || name === "preview",
                        name === "results",
                        name === "sidebar",
                        name === "preview")

        // The window has just emptied out. Say which key fills it again, so
        // nobody has to guess what they pressed.
        _toaster.show(root._panelNames[name] + " only — "
                      + KeyLabels.sequence("Ctrl+" + root._focusMod + "+"
                                           + root._panelKeys[name])
                      + " brings the rest back",
                      Toaster.Type.Info, 2600)
    }

    function _restoreLayout(): void {
        if (root._preSolo !== null)
            root._setPanels(root._preSolo.schema,  root._preSolo.query,
                            root._preSolo.results, root._preSolo.sidebar,
                            root._preSolo.preview)
        root._soloed  = ""
        root._preSolo = null
    }

    // Every by-hand toggle — key, menu or palette — ends solo mode. The
    // snapshot describes a layout the person has since moved on from, and
    // restoring it later would undo the change they just made on purpose.
    function _togglePanel(name: string): void {
        root._soloed  = ""
        root._preSolo = null
        switch (name) {
        case "schema":  root._showSchema  = !root._showSchema;  break
        case "query":   root._showQuery   = !root._showQuery;   break
        case "results": root._showResults = !root._showResults; break
        case "sidebar": root._showSidebar = !root._showSidebar; break
        case "preview": root._showPreview = !root._showPreview; break
        }
    }
    property int    _resultsPane: 0      // bottom pane: 0 = Results, 1 = Output console

    // Errors on the active connection that arrived while Output wasn't showing —
    // surfaced as a count on the Output tab label, cleared on viewing it.
    property int _outputUnseenErrors: 0
    on_ResultsPaneChanged: if (_resultsPane === 1) _outputUnseenErrors = 0
    Connections {
        target: LogManager
        function onEntryAdded(entry: var): void {
            if (entry.level === "error"
                    && entry.connection === root.activeConnection
                    && root._resultsPane !== 1)
                root._outputUnseenErrors++
        }
    }
    property string _sidebarTab:  "history"  // "history" | "snippets"

    // ── Live Share URL selection ──────────────────────────────────────────────
    property string _liveShareSelectedUrl: ""
    Connections {
        target: LiveShareServer
        function onActiveChanged() {
            root._liveShareSelectedUrl = LiveShareServer.active ? LiveShareServer.url : ""
        }
        function onStartFailed(message: string): void {
            _toaster.show("Live Share failed to start: " + message, Toaster.Type.Error, 8000)
        }
    }

    readonly property bool _anyPanelVisible: _showSchema || _showQuery || _showResults || _showSidebar

    // ── AI Client sync ────────────────────────────────────────────────────────
    Binding { target: AiClient; property: "provider";  value: AppSettings.aiProvider  }
    Binding { target: AiClient; property: "model";     value: AppSettings.aiModel     }
    Binding { target: AiClient; property: "ollamaUrl"; value: AppSettings.aiOllamaUrl }

    // ── Live Share sync ───────────────────────────────────────────────────────
    Binding { target: LiveShareServer; property: "allowDownload"; value: AppSettings.liveShareAllowDownload }

    // Keep the executor's fetch cap in sync with the toolbar limit picker so
    // the rows fetched match the LIMIT appended to the SQL.
    Binding { target: QueryExecutor; property: "rowLimit"; value: root._limit }

    property string _aiMode: ""  // "inline" | "palette" | ""

    // Friendly dialect name ("PostgreSQL", …) of the active connection, so the
    // AI generates SQL in the right dialect. Empty when no usable connection.
    readonly property string _aiDialect:
        root._activeTabUsable ? Drivers.label(root._activeConn?.driver ?? "") : ""

    // A function, not a binding: the sweep behind it costs two round-trips per
    // table and runs on the GUI thread, so it happens when the AI is actually
    // asked to generate — not every time the active tab changes.
    function _openAiPalette(): void {
        root._aiMode      = "palette"
        _aiPalette.schema = root._aiSchema()
        _aiPalette.open()
    }

    function _aiSchema(): string {
        // Never leak an out-of-workspace connection's schema into AI prompts.
        if (!root._activeTabUsable) return ""
        const tables = ConnectionManager.schema(root.activeConnection)
        if (!tables || tables.length === 0) return ""
        return tables.map(t => {
            const cols = t.columns.map(c => {
                let s = c.name + " " + c.type
                if (c.pk) s += " PRIMARY KEY"
                return s
            }).join(", ")
            return t.name + "(" + cols + ")"
        }).join("\n")
    }

    // Exact "/* @ai … */" block text to replace with the generated SQL. Re-found
    // by content at result time so edits made while generating can't misplace it.
    property string _aiBlockText: ""

    function _runAiBlock(): void {
        const text = queryEditor.sql
        const pos  = queryEditor.cursorPosition
        const re   = /\/\*\s*@ai\b([\s\S]*?)\*\//g

        // The block under the cursor wins; a lone block anywhere also works.
        let m, hit = null, first = null, count = 0
        while ((m = re.exec(text)) !== null) {
            count++
            if (first === null) first = m
            if (pos >= m.index && pos <= m.index + m[0].length) { hit = m; break }
        }
        if (hit === null && count === 1) hit = first

        if (hit === null) {
            _toaster.show(count === 0
                ? "No @ai block found. Write: /* @ai <your prompt> */"
                : "Multiple @ai blocks — place the cursor inside the one to run.",
                Toaster.Type.Warning, 4000)
            return
        }
        const prompt = hit[1].trim()
        if (prompt === "") {
            _toaster.show("Empty @ai prompt. Write: /* @ai <your prompt> */", Toaster.Type.Warning, 4000)
            return
        }
        root._aiBlockText = hit[0]
        root._aiMode = "inline"
        AiClient.generate(prompt, root._aiSchema(), root._aiDialect)
    }

    Connections {
        target: AiClient
        function onResultReady(sql: string): void {
            if (root._aiMode === "inline") {
                const cur = queryEditor.sql
                const idx = cur.indexOf(root._aiBlockText)
                if (root._aiBlockText !== "" && idx >= 0) {
                    queryEditor.setSql(cur.substring(0, idx) + sql
                                       + cur.substring(idx + root._aiBlockText.length))
                    queryEditor.setCursorPosition(idx + sql.length)
                } else {
                    queryEditor.insertAtCursor(sql)   // block edited away meanwhile
                }
                root._aiBlockText = ""
                root._aiMode = ""
            }
        }
        function onErrorOccurred(message: string): void {
            root._aiMode = ""
            root._aiBlockText = ""
            _toaster.show(message, Toaster.Type.Error)
        }
    }

    // ── Query tabs ────────────────────────────────────────────────────────────
    // Flat tab strip — every tab carries its own connection, shown color-coded.
    // Populated by loadWorkspace() in Component.onCompleted.
    property var  _queryTabs:         []
    property int  _activeQueryTabIdx: 0
    property int  _nextTabId:         1

    property var  _tabSqlMap:         ({})   // { tabId: sqlString } — only written on tab switch
    property var  _tabCursorMap:      ({})   // { tabId: cursorPosition }

    // The .sql file a tab was opened from or last saved to, and the text as it
    // went to disk. Both halves are needed: the path is what Ctrl+S overwrites
    // without asking, and the text is the only thing that makes the divergence
    // marker beside the tab label checkable rather than decorative.
    // { tabId: { path: fileUrlString, savedSql: string } }
    property var  _tabFileMap:        ({})
    property bool _tabSwitching:      false

    // Set whenever editor content / tabs change; drives the crash-safety autosave.
    property bool _sessionDirty:      false

    // ── Query result state (per-tab) ─────────────────────────────────────────
    // Each tab stores { success, rowCount, rowsAffected, elapsedMs, error }
    readonly property int    _currentTabId:  _queryTabs[_activeQueryTabIdx]?.id ?? -1
    readonly property bool   _running:       QueryExecutor.running

    property var    _tabStateMap:   ({})   // { [tabId]: { success, rowCount, rowsAffected, elapsedMs, error, truncated } }

    // Computed from active tab — re-evaluates when _tabStateMap or _currentTabId changes
    readonly property bool   _success:      _tabStateMap[_currentTabId]?.success      ?? true
    readonly property int    _rowCount:     _tabStateMap[_currentTabId]?.rowCount     ?? 0
    readonly property int    _rowsAffected: _tabStateMap[_currentTabId]?.rowsAffected ?? 0
    readonly property int    _elapsedMs:    _tabStateMap[_currentTabId]?.elapsedMs    ?? 0
    readonly property string _lastError:    _tabStateMap[_currentTabId]?.error        ?? ""
    // The result came back cut: the limit is hiding rows the query would return.
    readonly property bool   _truncated:    _tabStateMap[_currentTabId]?.truncated    ?? false

    property string _executingSql:          ""    // SQL that was actually sent (may be a selection)
    property bool   _reconnectRetryPending: false // auto-reconnect in flight

    // ── EXPLAIN (query plan) state ─────────────────────────────────────────────
    property var  _tabExplainMap:    ({})   // { [tabId]: plan map from DatabaseInspector.explain() }
    property var  _explainSqlMap:    ({})   // { [tabId]: raw SQL the plan is for }
    property bool _explaining:       false  // an explain() call is in flight
    property bool _pendingExplainAnalyze: false // analyze flag while the params dialog is open

    // Last-entered parameter values per tab, so the params dialog prefills.
    property var  _tabParamValuesMap: ({})  // { [tabId]: { paramName: value } }

    // Data-quality check rules per tab. { [tabId]: [{ column, check, arg }] }
    property var  _tabExpectationsMap: ({})
    property var  _tabBaselineMap: ({})     // { [tabId]: snapshot map } for result diffing

    // ── Inline edit support ───────────────────────────────────────────────────
    property var _tabTableMap:       ({})   // { [tabId]: tableName } — extracted from each SELECT
    property var _tabDecorationMap:  ({})   // { [tabId]: [{line, icon, color}] }
    property int _execStartLine:     1      // gutter line for the currently-running SQL

    // PK column names for the active tab's table. This re-evaluates every time
    // a query runs (_runQuery rewrites _tabTableMap) and on every tab switch,
    // so it has to be cheap: one primary-index lookup for the one table. It
    // used to dump the whole database's schema, which costs two round-trips
    // per table and view and blocked the GUI thread for the whole sweep.
    readonly property var _currentPkCols: {
        const tbl = _tabTableMap[_currentTabId] ?? ""
        if (!tbl || !root.activeConnection) return []
        return ConnectionManager.primaryKeys(root.activeConnection, tbl)
    }

    // True when results are from a single-table SELECT and PKs are known
    readonly property bool _resultEditable: {
        const tbl = _tabTableMap[_currentTabId] ?? ""
        return tbl !== "" && _currentPkCols.length > 0
    }

    // ── Foreign keys (for FK navigation) ──────────────────────────────────────
    // Cached per connection — the schema-level FK list rarely changes, so we
    // fetch it once per connection (refreshed lazily when the connection changes).
    property string _fkConn: ""
    property var    _fkList: []
    function _ensureFks(): void {
        const c = root._activeTabUsable ? root.activeConnection : ""
        if (c === root._fkConn) return
        root._fkConn = c
        root._fkList = c ? DatabaseInspector.foreignKeys(c) : []
    }

    // Open the referenced/​referencing rows from an FK menu in a fresh tab.
    function _openFkTab(sql: string, title: string): void {
        root._newQueryTab(root.activeConnection)
        queryEditor.setSql(sql)
        root._runQuery()
    }

    // Set while an inline-edit UPDATE is in flight: { tabId, row, col, value }
    property var _pendingCellEdit: null

    function _applyInlineEdit(row: int, col: int, colName: string, newValue: var): void {
        const tabId = root._currentTabId
        const tbl   = root._tabTableMap[tabId] ?? ""
        const pks   = root._currentPkCols
        if (!tbl || pks.length === 0) return

        const model  = QueryExecutor.tabResultModel(tabId)
        const cols   = model.columnNames ?? []

        const pkVals = pks.map(pk => {
            const i = cols.indexOf(pk)
            return i >= 0 ? model.cellValue(row, i) : null
        })

        if (pkVals.some(v => v === null)) {
            _toaster.show("Cannot update: primary key column not in result set.", Toaster.Type.Error)
            return
        }

        const q = v => {
            if (v === null || v === undefined) return "NULL"
            const s = String(v)
            if (s === "") return "''"
            if (/^-?\d+(\.\d+)?([eE][+-]?\d+)?$/.test(s)) return s
            return "'" + s.replace(/'/g, "''") + "'"
        }

        const setClause   = `"${colName}" = ${q(newValue)}`
        const whereClause = pks.map((c, i) => `"${c}" = ${q(pkVals[i])}`).join(" AND ")
        const sql = `UPDATE "${tbl}" SET ${setClause} WHERE ${whereClause}`

        root._pendingCellEdit = { tabId, row, col, value: newValue }
        QueryExecutor.activeTabId = tabId
        QueryExecutor.execute(root.activeConnection, sql)
    }

    // Export the active tab's result in `format` ∈ {csv,tsv,json,xlsx,sql}.
    // When the displayed result is row-limited, re-run the query unlimited and
    // stream the full set to disk (async → onExportFinished); otherwise export
    // the in-memory rows directly.
    function _exportResults(format: string, fileUrl: url, tableName: string): void {
        const model  = QueryExecutor.tabResultModel(root._currentTabId)
        const driver = root._activeConn?.driver ?? ""

        if (model.truncated) {
            const started = QueryExecutor.exportFull(
                root._currentTabId, format, fileUrl, tableName || "", driver)
            _toaster.show(started
                ? "Result is limited — exporting the full set…"
                : "Couldn't export the full result set (re-run the query first).",
                started ? Toaster.Type.Info : Toaster.Type.Error, 3000)
            return
        }

        let ok = false
        if      (format === "csv")  ok = model.exportCsv(fileUrl)
        else if (format === "tsv")  ok = model.exportTsv(fileUrl)
        else if (format === "json") ok = model.exportJson(fileUrl)
        else if (format === "xlsx") ok = model.exportXlsx(fileUrl)
        else if (format === "sql")  ok = model.exportSql(fileUrl, tableName, driver)
        _toaster.show(ok ? "Export complete." : "Export failed. Could not write file.",
                      ok ? Toaster.Type.Success : Toaster.Type.Error)
    }

    Connections {
        target: QueryExecutor
        function onExportFinished(success: bool, path: string, rowCount: int, truncated: bool): void {
            if (!success) {
                _toaster.show("Export failed. Could not write file.", Toaster.Type.Error)
                return
            }
            _toaster.show(truncated
                ? "Exported " + rowCount + " rows (hit the 500,000-row ceiling)."
                : "Exported all " + rowCount + " rows.",
                Toaster.Type.Success, 4000)
        }
        function onExportError(message: string): void {
            _toaster.show("Export failed: " + message, Toaster.Type.Error, 6000)
        }
    }

    // ── Active connection / profile (for status bar + guard) ──────────────────
    readonly property var _activeConn: {
        const conns = ConnectionManager.connections
        for (let i = 0; i < conns.length; i++)
            if (conns[i].name === root.activeConnection) return conns[i]
        return null
    }
    readonly property var _profile: _activeConn
        ? ProfileManager.profile(_activeConn.profileId ?? "")
        : null

    function _activeProfile(): var { return _profile ?? {} }

    property int _limit: AppSettings.queryLimit

    // The limit is pushed down to the server so the database never streams more
    // rows than we can show. We ask for one row *past* it on purpose: that extra
    // row is the only thing that distinguishes "the table has exactly N rows"
    // from "we cut it off at N". The executor fetches up to rowLimit + 1, drops
    // the surplus row and marks the result truncated — which is what colours the
    // limit picker and what makes an export re-run the query unlimited. Asking
    // for exactly N made every limited result look complete.
    function _applyLimit(sql: string): string {
        if (root._limit <= 0) return sql
        const s = sql.trim().replace(/;+\s*$/, "")  // strip trailing semicolons
        // Only inject into SELECT / WITH…SELECT statements
        if (!/^\s*(?:WITH\b[\s\S]*?\bSELECT\b|SELECT\b)/i.test(s)) return sql
        // Skip if a LIMIT clause already exists anywhere
        if (/\bLIMIT\s+\d+/i.test(s)) return sql
        // The marker is what lets a full export strip *our* clause back off
        // without also stripping a LIMIT the user wrote themselves.
        return s + "\nLIMIT " + (root._limit + 1) + " /* qub:limit */"
    }

    // Parse a 1-based line number out of a DB error message, or return null.
    function _parseErrorLine(msg: string): var {
        const m = /\bline\s+(\d+)/i.exec(msg)
        return m ? parseInt(m[1], 10) : null
    }

    // Write decorations for tabId and apply to the editor if it's the current tab.
    function _setGutterDecs(tabId: int, decs: var): void {
        const dm = Object.assign({}, root._tabDecorationMap)
        dm[tabId] = decs
        root._tabDecorationMap = dm
        if (tabId === root._currentTabId) queryEditor.setDecorations(decs)
    }

    function _extractParams(sql: string): var {
        return Params.extractParams(sql)
    }

    function _cancelQuery(): void {
        QueryExecutor.cancel()
        // The cancel flag is only checked between statements / row fetches; a
        // single long-running statement cannot be interrupted mid-execution.
        _toaster.show("Stopping — takes effect once the current statement finishes.",
                      Toaster.Type.Info, 4000)
    }

    function _runQuery(): void {
        if (QueryExecutor.running) {
            _toaster.show("A query is already running — stop it or wait for it to finish.",
                          Toaster.Type.Warning, 4000)
            return
        }
        // Safety boundary: never run against a connection this workspace
        // isn't in this workspace (or that no longer exists).
        if (!root._activeTabUsable) {
            _toaster.show(root.activeConnection === ""
                          ? "This tab has no connection."
                          : "'" + root.activeConnection + "' is not available in this workspace.",
                          Toaster.Type.Warning, 4000)
            return
        }
        const sel = queryEditor.selectedText.trim()
        // Capture the 1-based start line before execution changes focus/selection
        root._execStartLine = sel !== "" ? queryEditor.selectionStartLine : 1
        // Clear previous decorations on this tab
        root._setGutterDecs(root._currentTabId, [])
        const sql = root._applyLimit(sel !== "" ? sel : root.currentSql)

        // Extract table name for inline-edit support (single-table SELECT only)
        const tblMatch = /^\s*SELECT\b[\s\S]*?\bFROM\s+(?:["'`])?(\w+)(?:["'`])?(?:\s|$)/i.exec(sql.trim())
        const tm = Object.assign({}, root._tabTableMap)
        tm[root._currentTabId] = tblMatch ? tblMatch[1] : ""
        root._tabTableMap = tm

        // Detect query parameters — show dialog before executing
        const params = root._extractParams(sql)
        if (params.length > 0) {
            _queryParamsDialog.openWith(params, sql,
                root._tabParamValuesMap[root._currentTabId] ?? {}, "run")
            return
        }

        root._executingSql = sql
        QueryExecutor.activeTabId = root._currentTabId

        const v = Guard.check(QueryExecutor.splitStatements(sql, root.activeConnection), root._activeProfile())
        if (!v) {
            QueryExecutor.execute(root.activeConnection, sql)
        } else if (v.blocked) {
            _toaster.show(v.message, Toaster.Type.Error, 6000)
        } else {
            _confirmDialog.dialogMessage = v.message
            _confirmDialog.open()
        }
    }

    // ── EXPLAIN (query plan) ──────────────────────────────────────────────────
    // Ctrl+E, or the Explain-pane buttons. Runs the selection (or whole editor)
    // through a dialect-aware EXPLAIN and shows the plan tree. `analyze` uses
    // EXPLAIN ANALYZE, which *executes* the statement — the pane only offers it
    // for read-only queries, and we re-check here.
    function _runExplain(analyze: bool): void {
        if (!root._activeTabUsable) {
            _toaster.show(root.activeConnection === ""
                          ? "This tab has no connection."
                          : "'" + root.activeConnection + "' is not available in this workspace.",
                          Toaster.Type.Warning, 4000)
            return
        }
        const sel  = queryEditor.selectedText.trim()
        const base = (sel !== "" ? sel : root.currentSql).trim()
        if (!base) return

        // Parameterised query — collect values first, then explain the filled SQL.
        const params = root._extractParams(base)
        if (params.length > 0) {
            root._pendingExplainAnalyze = analyze
            _queryParamsDialog.openWith(params, base,
                root._tabParamValuesMap[root._currentTabId] ?? {}, "explain")
            return
        }
        root._doExplain(base, analyze)
    }

    // Runs EXPLAIN synchronously (mirrors DatabaseInspector.metrics/tableStats) and
    // stashes the plan on the active tab, then reveals the Explain pane.
    function _doExplain(sql: string, analyze: bool): void {
        root._explaining = true
        const plan = DatabaseInspector.explain(root.activeConnection, sql, analyze === true)

        const em = Object.assign({}, root._tabExplainMap)
        em[root._currentTabId] = plan
        root._tabExplainMap = em

        const sm = Object.assign({}, root._explainSqlMap)
        sm[root._currentTabId] = sql
        root._explainSqlMap = sm

        root._explaining  = false
        root._resultsPane = 4   // Explain tab
    }

    // Persist the active tab's editor content + caret into the per-tab maps.
    function _saveActiveEditorState(): void {
        const t = _queryTabs[_activeQueryTabIdx]
        if (!t) return
        _tabSqlMap[t.id]    = queryEditor.sql
        _tabCursorMap[t.id] = queryEditor.cursorPosition
    }

    // Restore the caret for a tab, if the user opted to preserve it.
    function _applyCursor(tabId: int): void {
        if (AppSettings.preserveCursorPosition)
            queryEditor.setCursorPosition(_tabCursorMap[tabId] ?? 0)
    }

    // Colour for a connection (from its profile), used to tag tabs. Out-of-workspace
    // or globally deleted connections render disabled — the tab keeps its
    // target but can't run against it.
    function _connColor(connName: string): color {
        if (!connName || !_inWorkspace(connName)) return Theme.textDisabled
        const conns = ConnectionManager.connections
        for (let i = 0; i < conns.length; i++) {
            if (conns[i].name === connName) {
                const p = ProfileManager.profile(conns[i].profileId ?? "")
                if (p && p.color) return p.color
                return Theme.textSecondary
            }
        }
        return Theme.textDisabled
    }

    // Point a tab at a different connection. If it's the active tab, the schema
    // tree and editor rebind automatically via the derived activeConnection.
    function _setTabConnection(idx: int, name: string): void {
        const tabs = _queryTabs.slice()
        if (!tabs[idx] || tabs[idx].connectionName === name) return
        tabs[idx] = { id: tabs[idx].id, label: tabs[idx].label, connectionName: name }
        _queryTabs = tabs
        _sessionDirty = true
    }

    function _setActiveTabConnection(name: string): void { _setTabConnection(_activeQueryTabIdx, name) }

    // ── Tab ↔ file binding ───────────────────────────────────────────────────
    function _tabFile(tabId: int): var { return _tabFileMap[tabId] ?? null }

    // The text a tab currently holds. The active tab's lives in the editor;
    // every other one was written to _tabSqlMap when it lost focus.
    function _tabSql(tabId: int): string {
        return tabId === _currentTabId ? currentSql : (_tabSqlMap[tabId] ?? "")
    }

    // A tab opened from a file answers to the file's name — "Query 7" tells you
    // nothing once the tab is bound. Only on open: a later save-as leaves a
    // label the person may well have chosen by hand.
    function _nameTabAfterFile(tabId: int, url: var): void {
        const base = decodeURIComponent(url.toString().split("/").pop() ?? "")
        const name = base.replace(/\.sql$/i, "").slice(0, 32)
        const idx  = _queryTabs.findIndex(t => t.id === tabId)
        if (!name || idx < 0) return
        if (_queryTabs.some((t, i) => i !== idx && t.label === name)) return
        const tabs = _queryTabs.slice()
        tabs[idx]  = { id: tabs[idx].id, label: name, connectionName: tabs[idx].connectionName }
        _queryTabs = tabs
    }

    function _bindTabFile(tabId: int, url: var, sql: string): void {
        const m = Object.assign({}, _tabFileMap)
        m[tabId] = { path: url.toString(), savedSql: sql }
        _tabFileMap   = m
        _sessionDirty = true
    }

    function _unbindTabFile(tabId: int): void {
        if (_tabFileMap[tabId] === undefined) return
        const m = Object.assign({}, _tabFileMap)
        delete m[tabId]
        _tabFileMap = m
    }

    // Write the active tab to a path and bind it there. Shared by Ctrl+S on an
    // already-bound tab and by whatever the Save dialog comes back with.
    function _writeTabFile(url: var): void {
        const tabId = _currentTabId
        const sql   = currentSql
        if (tabId < 0) return
        if (!AppSettings.writeFile(url, sql)) {
            _toaster.show("Could not write file.", Toaster.Type.Error)
            return
        }
        _bindTabFile(tabId, url, sql)
        _toaster.show("File saved.", Toaster.Type.Success)
    }

    // Ctrl+S. A bound tab overwrites its file with no dialog — that is the whole
    // point of the binding; an unbound one falls back to asking where to put it.
    function _saveTabFile(): void {
        if (currentSql.trim() === "") return
        const f = _tabFile(_currentTabId)
        if (f) _writeTabFile(f.path)
        else   _sqlSaveFileDialog.open()
    }

    // Snapshot the flat tab strip for the workspace payload.
    function _collectSessionTabs(): var {
        _saveActiveEditorState()
        return _queryTabs.map((t, i) => ({
            connectionName: t.connectionName || "",
            sql:            _tabSqlMap[t.id] ?? "",
            cursorPosition: _tabCursorMap[t.id] ?? 0,
            title:          t.label,
            isActive:       i === _activeQueryTabIdx,
            filePath:       (_tabFileMap[t.id]?.path) ?? ""
        }))
    }

    // Persist the current tabs into the workspace. Serves both the quit-save
    // and the periodic crash-autosave — invisible plumbing, no history.
    function flushWorkspace(): void {
        if (workspaceId < 0) return
        WorkspaceManager.saveTabs(workspaceId, _collectSessionTabs())
        _sessionDirty = false
    }

    // Rebuild the tab strip from a workspace's stored tabs (or one blank tab).
    function _applyTabs(tabsIn: var): void {
        const tabs      = []
        const sqlMap    = {}
        const cursorMap = {}
        const fileMap   = {}
        let   nextId    = 1
        let   activeIdx = 0
        ;(tabsIn ?? []).forEach(t => {
            const tabId = nextId++
            const label = t.title || ("Query " + (tabs.length + 1))
            tabs.push({ id: tabId, label, connectionName: t.connectionName || "" })
            sqlMap[tabId]    = t.sql || ""
            cursorMap[tabId] = t.cursorPosition || 0
            // Restored clean: the marker means "diverged since qub last wrote
            // it", which is the only divergence qub can vouch for. A file edited
            // outside qub between sessions reads as clean until you touch it.
            if (t.filePath) fileMap[tabId] = { path: t.filePath, savedSql: sqlMap[tabId] }
            if (t.isActive) activeIdx = tabs.length - 1
        })
        if (tabs.length === 0) {
            tabs.push({ id: 1, label: "Query 1", connectionName: _firstUsableConnection() })
            sqlMap[1] = ""; cursorMap[1] = 0
            nextId = 2
        }
        _tabSwitching      = true
        _nextTabId         = nextId
        _tabSqlMap         = sqlMap
        _tabCursorMap      = cursorMap
        _tabFileMap        = fileMap
        _queryTabs         = tabs
        _activeQueryTabIdx = activeIdx
        const at = tabs[activeIdx]
        queryEditor.setSql(sqlMap[at.id] ?? "")
        queryEditor.setDecorations([])
        _applyCursor(at.id)
        QueryExecutor.activeTabId = at.id
        _tabSwitching = false
    }

    // Switch to another workspace in place: flush the outgoing tabs, drop
    // their result models and per-tab UI state, rebuild from the incoming one.
    function loadWorkspace(id: int): void {
        if (id === workspaceId || id < 0) return
        flushWorkspace()
        const ws = WorkspaceManager.workspace(id)
        if (!ws.id) return
        _queryTabs.forEach(t => QueryExecutor.closeTab(t.id))
        _tabStateMap = ({}); _tabTableMap = ({}); _tabDecorationMap = ({})
        _tabExplainMap = ({}); _explainSqlMap = ({}); _tabParamValuesMap = ({})
        _tabExpectationsMap = ({}); _tabBaselineMap = ({})
        workspaceId       = ws.id
        workspaceName     = ws.name
        workspaceConnections = ws.connections
        _applyTabs(ws.tabs)
        WorkspaceManager.activeWorkspaceId = id
        _sessionDirty = false
    }

    // A workspace whose first tab was built before it had any connection keeps
    // an empty target on that tab: nothing runs, and the reconnect button is
    // hidden because it only ever acts on the active tab's connection and there
    // is none. Adding a connection later has to reach that tab, or the
    // workspace stays stuck and the home screen is the only way out — which is
    // exactly what the default workspace does on a first run.
    function _adoptIfUnassigned(name: string): void {
        if (!name || !_inWorkspace(name)) return
        const t = _queryTabs[_activeQueryTabIdx]
        if (t && !t.connectionName) _setActiveTabConnection(name)
    }

    // Bring a connection into this workspace (adding it if needed) and give
    // it a tab. Used by the Home screen's connection cards and new-connection
    // flow — an explicit act, so the implicit add is the low-friction choice.
    // wsId is the workspace to open it in; -1 means the one already loaded.
    // Membership follows the choice: picking a workspace that does not hold this
    // connection is what adds it, which is why the picker on the home screen
    // shows which workspaces already do.
    function openConnection(name: string, wsId: int): void {
        if (!name) return
        if (wsId >= 0 && wsId !== workspaceId) loadWorkspace(wsId)
        if (workspaceId < 0) return
        if (!_inWorkspace(name)) {
            WorkspaceManager.addConnection(workspaceId, name)
            workspaceConnections = WorkspaceManager.connections(workspaceId)
        }
        const t = _queryTabs[_activeQueryTabIdx]
        if (t && t.connectionName === name) return
        if (t && !t.connectionName)
            _setActiveTabConnection(name)
        else
            _newQueryTab(name)
    }

    function _newQueryTab(connName: string): void {
        const newId = _nextTabId
        _nextTabId = _nextTabId + 1
        _saveActiveEditorState()
        // A typed QML parameter cannot be left out: calling this with no argument
        // coerces the missing value into the *string* "undefined", which then
        // sails past an emptiness check and becomes the tab's connection name —
        // an unrunnable tab claiming a connection that never existed. Callers
        // pass "" explicitly; this rejects the sentinel in case one forgets.
        const conn = (connName && connName !== "undefined")
                   ? connName
                   : (root._activeTabUsable ? root.activeConnection
                                            : root._firstUsableConnection())
        const tabs = _queryTabs.concat([{ id: newId, label: "Query " + newId, connectionName: conn }])
        _queryTabs = tabs
        _tabSwitching = true
        _activeQueryTabIdx = tabs.length - 1
        queryEditor.setSql("")
        queryEditor.setDecorations([])
        _applyCursor(newId)
        QueryExecutor.activeTabId = newId
        _tabSwitching = false
        _sessionDirty = true
    }

    function _switchQueryTab(idx: int): void {
        if (idx === _activeQueryTabIdx) return
        _saveActiveEditorState()
        _tabSwitching = true
        _activeQueryTabIdx = idx
        const nextId = _queryTabs[idx].id
        queryEditor.setSql(_tabSqlMap[nextId] ?? "")
        queryEditor.setDecorations(root._tabDecorationMap[nextId] ?? [])
        _applyCursor(nextId)
        QueryExecutor.activeTabId = nextId
        _tabSwitching = false
        _sessionDirty = true
    }

    function _closeQueryTab(idx: int): void {
        if (_queryTabs.length <= 1) return
        const closedId = _queryTabs[idx].id
        delete _tabSqlMap[closedId]
        delete _tabCursorMap[closedId]
        _unbindTabFile(closedId)
        const sm = Object.assign({}, root._tabStateMap)
        delete sm[closedId]
        root._tabStateMap = sm

        const wasActive = (idx === _activeQueryTabIdx)
        const tabs = _queryTabs.filter((_, i) => i !== idx)
        _queryTabs = tabs
        if (wasActive) {
            const newIdx = Math.min(idx, tabs.length - 1)
            _tabSwitching = true
            _activeQueryTabIdx = newIdx
            const newId = tabs[newIdx].id
            queryEditor.setSql(_tabSqlMap[newId] ?? "")
            _applyCursor(newId)
            QueryExecutor.activeTabId = newId
            _tabSwitching = false
        } else if (idx < _activeQueryTabIdx) {
            _activeQueryTabIdx = _activeQueryTabIdx - 1
        }
        QueryExecutor.closeTab(closedId)
        _sessionDirty = true
    }

    Shortcut {
        sequence: "Ctrl+Return"
        onActivated: root._runQuery()
    }

    Shortcut {
        sequence: "Ctrl+Shift+Return"
        onActivated: root._runAiBlock()
    }

    Shortcut {
        sequence: "Ctrl+K"
        onActivated: root._openAiPalette()
    }

    Shortcut {
        sequence: "Ctrl+L"
        onActivated: root.toggleLogs()
    }

    // Also reachable from the Home top bar (the log window is a separate
    // Window, so it shows regardless of which page is active).
    function toggleLogs(): void {
        _logWindow.visible = !_logWindow.visible
    }

    Shortcut {
        sequence: "Ctrl+T"
        onActivated: root._newQueryTab("")
    }

    Shortcut {
        sequence: "Ctrl+W"
        onActivated: root._closeQueryTab(root._activeQueryTabIdx)
    }

    Shortcut {
        sequence: "Ctrl+O"
        onActivated: _sqlOpenDialog.open()
    }

    // Ctrl+S follows the universal "save my file" convention; snippet save
    // lives on the shifted variant. Save-as has no shortcut of its own because
    // Ctrl+Shift+S is already the snippet, and a snippet is the thing people
    // reach for far more often here than a second copy of a file.
    Shortcut {
        sequence: "Ctrl+S"
        onActivated: root._saveTabFile()
    }

    Shortcut {
        sequence: "Ctrl+Shift+S"
        onActivated: {
            // A selection saves just the selected SQL as a snippet.
            const sql = queryEditor.selectedText.trim() !== ""
                        ? queryEditor.selectedText : root.currentSql
            if (sql.trim() !== "")
                _saveDialog.openFor(sql)
        }
    }

    Shortcut {
        sequence: "Ctrl+E"
        onActivated: root._runExplain(false)
    }

    Shortcut {
        sequence: "Ctrl+Shift+F"
        onActivated: queryEditor.setSql(Fmt.format(queryEditor.sql))
    }

    Shortcut {
        sequence: "Ctrl+Shift+E"
        onActivated: {
            const _m = QueryExecutor.tabResultModel(root._currentTabId)
            if (_m && _m.rowCount > 0)
                _csvDialog.open()
        }
    }

    // Open the row viewer (record form) for the selected result row.
    Shortcut {
        sequence: "Ctrl+Shift+R"
        onActivated: {
            if (!_resultsTable.openSelectedRow())
                _toaster.show("Select a cell first to view its row.",
                              Toaster.Type.Info, 2500)
        }
    }

    // Command palette — a searchable index of every action in the workspace.
    Shortcut {
        sequence: "Ctrl+P"
        onActivated: _commandPalette.open()
    }

    // Commands surfaced in the palette. Mahina's CommandPalette reads
    // { label, icon, shortcut, group }; the custom `id` rides along and comes
    // back through triggered(item) for _runCommand() to dispatch on.
    readonly property var _commands: [
        { id: "run",        label: "Run query (or selection)", shortcut: "Ctrl+Enter",   group: "Query",  icon: Icons.play },
        { id: "runAi",      label: "Run AI block",             shortcut: "Ctrl+Shift+Enter", group: "Query",  icon: Icons.sparkle },
        { id: "explain",    label: "Explain query",            shortcut: "Ctrl+E",       group: "Query",  icon: Icons.listMagnifyingGlass },
        { id: "format",     label: "Format SQL",               shortcut: "Ctrl+Shift+F", group: "Editor", icon: Icons.textAlignLeft },
        { id: "ai",         label: "Ask AI…",                  shortcut: "Ctrl+K",       group: "Query",  icon: Icons.sparkle },
        { id: "newTab",     label: "New query tab",            shortcut: "Ctrl+T",       group: "Tabs",   icon: Icons.plus },
        { id: "closeTab",   label: "Close query tab",          shortcut: "Ctrl+W",       group: "Tabs",   icon: Icons.x },
        { id: "openFile",   label: "Open SQL file…",           shortcut: "Ctrl+O",       group: "Editor", icon: Icons.folderOpen },
        { id: "saveFile",   label: "Save SQL to file",         shortcut: "Ctrl+S",       group: "Editor", icon: Icons.floppyDisk },
        { id: "saveFileAs", label: "Save SQL to file as…",                               group: "Editor", icon: Icons.floppyDisk },
        { id: "saveSnippet",label: "Save as snippet…",         shortcut: "Ctrl+Shift+S", group: "Editor", icon: Icons.bookmarkSimple },
        { id: "exportCsv",  label: "Export results as CSV…",   shortcut: "Ctrl+Shift+E", group: "Results",icon: Icons.downloadSimple },
        { id: "viewRow",    label: "View selected row…",       shortcut: "Ctrl+Shift+R", group: "Results",icon: Icons.rows },
        { id: "logs",       label: "Toggle activity log",      shortcut: "Ctrl+L",       group: "View",   icon: Icons.clockCounterClockwise },
        { id: "shortcuts",  label: "Keyboard shortcuts",       shortcut: "?",            group: "View",   icon: Icons.keyboard },
        { id: "toggleSchema",  label: "Toggle schema panel",   shortcut: "Ctrl+1", group: "Panels", icon: Icons.sidebar },
        { id: "toggleQuery",   label: "Toggle query editor",   shortcut: "Ctrl+2", group: "Panels", icon: Icons.code },
        { id: "toggleResults", label: "Toggle results panel",  shortcut: "Ctrl+3", group: "Panels", icon: Icons.table },
        { id: "toggleSidebar", label: "Toggle sidebar",        shortcut: "Ctrl+4", group: "Panels", icon: Icons.sidebarSimple },
        { id: "togglePreview", label: "Toggle preview panel",  shortcut: "Ctrl+5", group: "Panels", icon: Icons.eye },
        { id: "focusSchema",   label: "Focus schema panel",    shortcut: "Ctrl+" + root._focusMod + "+1", group: "Panels", icon: Icons.cornersOut },
        { id: "focusQuery",    label: "Focus query editor",    shortcut: "Ctrl+" + root._focusMod + "+2", group: "Panels", icon: Icons.cornersOut },
        { id: "focusResults",  label: "Focus results panel",   shortcut: "Ctrl+" + root._focusMod + "+3", group: "Panels", icon: Icons.cornersOut },
        { id: "focusSidebar",  label: "Focus sidebar",         shortcut: "Ctrl+" + root._focusMod + "+4", group: "Panels", icon: Icons.cornersOut },
        { id: "focusPreview",  label: "Focus editor and preview", shortcut: "Ctrl+" + root._focusMod + "+5", group: "Panels", icon: Icons.cornersOut },
        { id: "restoreLayout", label: "Restore panel layout",  shortcut: "",             group: "Panels", icon: Icons.cornersIn }
    ]

    function _runCommand(id: string): void {
        switch (id) {
        case "run":         root._runQuery(); break
        case "runAi":       root._runAiBlock(); break
        case "explain":     root._runExplain(false); break
        case "format":      queryEditor.setSql(Fmt.format(queryEditor.sql)); break
        case "ai":          root._openAiPalette(); break
        case "newTab":      root._newQueryTab(""); break
        case "closeTab":    root._closeQueryTab(root._activeQueryTabIdx); break
        case "openFile":    _sqlOpenDialog.open(); break
        case "saveFile":    root._saveTabFile(); break
        case "saveFileAs":
            if (root.currentSql.trim() !== "") _sqlSaveFileDialog.open()
            break
        case "saveSnippet": {
            const sql = queryEditor.selectedText.trim() !== ""
                        ? queryEditor.selectedText : root.currentSql
            if (sql.trim() !== "") _saveDialog.openFor(sql)
            break
        }
        case "exportCsv": {
            const _m = QueryExecutor.tabResultModel(root._currentTabId)
            if (_m && _m.rowCount > 0) _csvDialog.open()
            else _toaster.show("No results to export.", Toaster.Type.Info, 2500)
            break
        }
        case "viewRow":
            if (!_resultsTable.openSelectedRow())
                _toaster.show("Select a cell first to view its row.",
                              Toaster.Type.Info, 2500)
            break
        case "logs":        root.toggleLogs(); break
        case "shortcuts":   _shortcutsPanel.show(); break
        case "toggleSchema":  root._togglePanel("schema");  break
        case "toggleQuery":   root._togglePanel("query");   break
        case "toggleResults": root._togglePanel("results"); break
        case "toggleSidebar": root._togglePanel("sidebar"); break
        case "togglePreview": root._togglePanel("preview"); break
        case "focusSchema":   root._soloPanel("schema");    break
        case "focusQuery":    root._soloPanel("query");     break
        case "focusResults":  root._soloPanel("results");   break
        case "focusSidebar":  root._soloPanel("sidebar");   break
        case "focusPreview":  root._soloPanel("preview");   break
        case "restoreLayout": root._restoreLayout();        break
        }
    }

    // ── Status bar item arrays ────────────────────────────────────────────────
    readonly property var _sbLeft: {
        if (!root.activeConnection)
            return [{ icon: Icons.database, text: "No connection", color: Theme.textDisabled }]
        if (!root._activeTabUsable)
            return [{ icon: Icons.warningCircle,
                      text: root.activeConnection + " — not in workspace",
                      color: Theme.warning }]
        return [
            {
                icon:  _activeConn?.connected ? Icons.checkCircle : Icons.xCircle,
                text:  root.activeConnection,
                color: _activeConn?.connected ? Theme.success : Theme.textSecondary
            },
            {
                icon:  Icons.database,
                text:  _activeConn?.driver ? Drivers.label(_activeConn.driver) : "",
                color: Theme.textDisabled
            }
        ]
    }

    // Compact number: integers get locale grouping, decimals trimmed to 3 places.
    function _fmtNum(x: var): string {
        var n = Number(x)
        if (!isFinite(n)) return String(x)
        if (Math.abs(n - Math.round(n)) < 1e-9)
            return Math.round(n).toLocaleString(Qt.locale(), 'f', 0)
        return (Math.round(n * 1000) / 1000).toString()
    }

    // Excel-style aggregates for the selected column (see ResultModel::columnStats).
    function _statsText(s: var): string {
        if (!s || s.count === undefined || s.count === 0) return ""
        if (s.numeric)
            return "Σ " + _fmtNum(s.sum) + "  ·  avg " + _fmtNum(s.avg)
                 + "  ·  min " + _fmtNum(s.min) + "  ·  max " + _fmtNum(s.max)
                 + "  ·  n " + _fmtNum(s.count)
        return "n " + _fmtNum(s.count) + "  ·  nulls " + _fmtNum(s.nulls)
             + "  ·  distinct " + _fmtNum(s.distinct)
    }

    readonly property var _sbCenter: {
        if (_running)
            return [{ icon: Icons.spinner, text: "Running…", color: Theme.primary }]
        if (_elapsedMs > 0 && !_success)
            return [{ icon: Icons.warningCircle, text: "Query error", color: Theme.error }]
        if (_elapsedMs > 0) {
            const rowLabel = _rowCount > 0
                ? _rowCount + (_rowCount === 1 ? " row" : " rows")
                : (_rowsAffected > 0
                    ? _rowsAffected + (_rowsAffected === 1 ? " row affected" : " rows affected")
                    : "0 rows")
            var items = [
                { icon: Icons.rows,
                  text:  _truncated ? rowLabel + " (limited)" : rowLabel,
                  color: _truncated ? Theme.warning : Theme.textSecondary },
                { icon: Icons.timer, text: _elapsedMs + " ms", color: Theme.textDisabled }
            ]
            // Selection stats — column aggregates for the clicked cell's column.
            const _stTxt = root._statsText(_resultsTable ? _resultsTable.columnStats : null)
            if (_stTxt !== "")
                items.push({ icon: Icons.calculator, text: _stTxt, color: Theme.textSecondary })
            return items
        }
        return []
    }

    readonly property var _sbRight: {
        var items = []
        if (_profile?.name)
            items.push({ text: _profile.name, color: _profile.color ?? Theme.textSecondary })
        items.push({ icon: Icons.question, text: "Shortcuts", color: Theme.textDisabled })
        return items
    }

    // ── Layout ────────────────────────────────────────────────────────────────
    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ── Top bar ───────────────────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            height: 44
            color:  Theme.surface
            border.color: Theme.border
            z: 1

            RowLayout {
                anchors { fill: parent; leftMargin: 6; rightMargin: 12 }
                spacing: 0

                Tooltip {
                    text: "Home"
                    Button {
                        iconOnly: true
                        iconName: Icons.house
                        size:     Button.Size.Sm
                        variant:  Button.Variant.Ghost
                        onClicked: root.goToHome()
                    }
                }

                Rectangle {
                    width: 1; height: 20
                    color: Theme.border
                    Layout.alignment: Qt.AlignVCenter
                }

                Item { Layout.preferredWidth: 10 }

                // ── Workspace switcher ────────────────────────────────────────
                Button {
                    id:       _wsBtn
                    text:     root.workspaceName || "Workspace"
                    iconName: Icons.stack
                    size:     Button.Size.Sm
                    variant:  Button.Variant.Ghost
                    onClicked: _wsMenu.open()
                }

                Menu {
                    id:     _wsMenu
                    anchor: _wsBtn
                    model: {
                        const items = WorkspaceManager.workspaces.map(w => ({
                            label:   w.name,
                            checked: w.id === root.workspaceId,
                            _wsId:   w.id
                        }))
                        items.push(null)
                        items.push({ label: "New workspace…",       icon: Icons.plus,     _act: "new" })
                        items.push({ label: "Rename…",              icon: Icons.pencil,   _act: "rename" })
                        items.push({ label: "Workspace connections…", icon: Icons.database, _act: "conns" })
                        items.push(null)
                        items.push({ label: "Delete workspace…",    icon: Icons.trash,    _act: "delete",
                                     danger: true, disabled: WorkspaceManager.workspaces.length <= 1 })
                        return items
                    }
                    onTriggered: (index, item) => {
                        if (item._wsId !== undefined) { root.loadWorkspace(item._wsId); return }
                        if (item._act === "new")      _wsFormDialog.openCreate([])
                        if (item._act === "rename")   _wsFormDialog.openRename(root.workspaceId)
                        if (item._act === "conns")     _wsFormDialog.openConnections(root.workspaceId)
                        if (item._act === "delete") {
                            _wsDeleteConfirm.dialogMessage =
                                "Delete workspace \"" + root.workspaceName + "\"? Its tabs and " +
                                "their SQL will be permanently deleted. Connections stay in the global pool."
                            _wsDeleteConfirm.open()
                        }
                    }
                }

                Item { Layout.preferredWidth: Theme.sp2 }
                Rectangle { width: 1; height: 14; color: Theme.border; Layout.alignment: Qt.AlignVCenter; opacity: 0.5 }
                Item { Layout.preferredWidth: Theme.sp2 }

                // ── Connection dropdown ───────────────────────────────────────
                // The connection the tab you are on runs against — the same thing
                // that tab's own colour dot picks, and the same name the status
                // bar reports. A second, differently scoped connection name up
                // here read as the current one, and was wrong for every tab but
                // whichever one happened to match it.
                Tooltip {
                    text: "Connection this tab runs on — an offline one connects when picked"
                    Button {
                        id:       _connBtn
                        iconName: Icons.database
                        text:     root.activeConnection || "No connection"
                        size:     Button.Size.Sm
                        variant:  Button.Variant.Ghost
                        onClicked: _connMenu.open()
                    }
                }

                Menu {
                    id:     _connMenu
                    anchor: _connBtn
                    // Only connections in this workspace are offered. The row icon
                    // is the connection's state, in the same two symbols the status
                    // bar uses; the check mark is the one this tab is on.
                    model: {
                        const items = root._usableConnections.map(c => ({
                            label:   c.name,
                            icon:    c.connected ? Icons.checkCircle : Icons.xCircle,
                            checked: c.name === root.activeConnection,
                            _conn:   c.name,
                            _down:   !c.connected
                        }))
                        if (items.length > 0) items.push(null)
                        items.push({ label: "Add connection to workspace…", icon: Icons.plus, _act: "add" })
                        return items
                    }
                    onTriggered: (index, item) => {
                        if (item._conn !== undefined) {
                            root._setActiveTabConnection(item._conn)
                            // Picking an offline connection opens it. Otherwise the
                            // only way in was the reconnect button, which acts on the
                            // active tab's connection alone and hides itself while
                            // that one is up — so a second, offline connection could
                            // only be reached by leaving for the home screen.
                            if (item._down) {
                                _toaster.show("Connecting to " + item._conn + "…", Toaster.Type.Info)
                                ConnectionManager.reconnect(item._conn)
                            }
                        }
                        else if (item._act === "add") _wsFormDialog.openConnections(root.workspaceId)
                    }
                }

                Tooltip {
                    text: "New connection"
                    Button {
                        iconOnly: true
                        iconName: Icons.plus
                        size:     Button.Size.Sm
                        variant:  Button.Variant.Ghost
                        onClicked: root.newConnectionRequested()
                    }
                }

                Tooltip {
                    text: "Database info & health"
                    Button {
                        iconOnly: true
                        iconName: Icons.info
                        size:     Button.Size.Sm
                        variant:  Button.Variant.Ghost
                        enabled:  root._activeTabUsable && (_activeConn?.connected ?? false)
                        onClicked: _dbWindow.openFor(root.activeConnection)
                    }
                }

                Tooltip {
                    text: "Schema graph"
                    Button {
                        iconOnly: true
                        iconName: Icons.graph
                        size:     Button.Size.Sm
                        variant:  Button.Variant.Ghost
                        enabled:  root._activeTabUsable && (_activeConn?.connected ?? false)
                        onClicked: _schemaGraphWindow.openFor(root.activeConnection)
                    }
                }

                Tooltip {
                    text: "Compare schemas"
                    Button {
                        iconOnly: true
                        iconName: Icons.gitDiff
                        size:     Button.Size.Sm
                        variant:  Button.Variant.Ghost
                        enabled:  ConnectionManager.connections.filter(c => c.connected).length >= 2
                        onClicked: _schemaDiffWindow.openWith(root.activeConnection)
                    }
                }

                Tooltip {
                    text: "Schema snapshots"
                    Button {
                        iconOnly: true
                        iconName: Icons.camera
                        size:     Button.Size.Sm
                        variant:  Button.Variant.Ghost
                        enabled:  ConnectionManager.connections.filter(c => c.connected).length >= 1
                        onClicked: _schemaSnapshotsWindow.openWith(root.activeConnection)
                    }
                }

                Item { Layout.fillWidth: true }

                // ── Reconnect (shown only when active connection is down) ──────
                Tooltip {
                    text: "Reconnect"
                    visible: root.activeConnection !== "" && !(_activeConn?.connected ?? true)
                    Button {
                        iconOnly: true
                        iconName: Icons.arrowClockwise
                        size:     Button.Size.Sm
                        variant:  Button.Variant.Ghost
                        onClicked: ConnectionManager.reconnect(root.activeConnection)
                    }
                }

                // ── Disconnect (shown only when active connection is up) ───────
                Tooltip {
                    text: "Disconnect"
                    visible: root.activeConnection !== "" && (_activeConn?.connected ?? false)
                    Button {
                        iconOnly: true
                        iconName: Icons.plugs
                        size:     Button.Size.Sm
                        variant:  Button.Variant.Ghost
                        onClicked: ConnectionManager.closeConnection(root.activeConnection)
                    }
                }

                // ── Panel toggles ─────────────────────────────────────────────
                Rectangle { width: 1; height: 20; color: Theme.border; Layout.alignment: Qt.AlignVCenter }

                Button {
                    id:       _panelsBtn
                    text:     "Panels"
                    iconName: Icons.layout
                    size:     Button.Size.Sm
                    variant:  Button.Variant.Ghost
                    onClicked: _panelsMenu.open()
                }

                Menu {
                    id:     _panelsMenu
                    anchor: _panelsBtn
                    model: [
                        { label: "Schema",       icon: Icons.sidebar,  shortcut: "Ctrl+1", checked: root._showSchema  },
                        { label: "Query editor", icon: Icons.terminal, shortcut: "Ctrl+2", checked: root._showQuery   },
                        { label: "Results",      icon: Icons.rows,     shortcut: "Ctrl+3", checked: root._showResults },
                        { label: "Sidebar",      icon: Icons.layout,   shortcut: "Ctrl+4", checked: root._showSidebar },
                        { label: "Markdown preview", icon: Icons.article, shortcut: "Ctrl+5", checked: root._showPreview },
                    ]
                    onTriggered: (index) => {
                        if (index === 0) root._togglePanel("schema")
                        if (index === 1) root._togglePanel("query")
                        if (index === 2) root._togglePanel("results")
                        if (index === 3) root._togglePanel("sidebar")
                        if (index === 4) root._togglePanel("preview")
                    }
                }

                Rectangle { width: 1; height: 20; color: Theme.border; Layout.alignment: Qt.AlignVCenter; Layout.leftMargin: Theme.sp2; Layout.rightMargin: Theme.sp2 }

                // A live session outlives the moment it was started in, and the
                // only thing saying so is a button that changed colour. So while
                // it lasts the button pings — the same expand-and-fade the data
                // sources page uses for a connection that is still coming up,
                // squared off to the button instead of drawn round a dot.
                Item {
                    implicitWidth:    _liveShareBtn.implicitWidth
                    implicitHeight:   _liveShareBtn.implicitHeight
                    Layout.alignment: Qt.AlignVCenter

                    Rectangle {
                        id: _liveSharePing

                        // 0 → 1 over one ping: the ring grows out of the button's
                        // edge and fades. Radius grows with the inset so the
                        // corners stay concentric with the button's own.
                        property real phase: 0

                        readonly property real spread: 6

                        anchors.fill:    _liveShareBtn
                        anchors.margins: -_liveSharePing.spread * _liveSharePing.phase
                        radius:          Theme.radiusSm + _liveSharePing.spread * _liveSharePing.phase
                        color:           "transparent"
                        border.color:    Theme.error
                        border.width:    1.5
                        visible:         LiveShareServer.active
                        opacity:         0.7 * (1 - _liveSharePing.phase)

                        SequentialAnimation on phase {
                            running: LiveShareServer.active
                            loops:   Animation.Infinite
                            NumberAnimation { from: 0; to: 1; duration: 1100; easing.type: Easing.OutQuad }
                            PauseAnimation  { duration: 700 }
                        }
                    }

                    Button {
                        id:         _liveShareBtn
                        text:       LiveShareServer.active ? "Stop Live Share" : "Live Share"
                        iconName:   LiveShareServer.active ? Icons.stop : Icons.broadcast
                        iconWeight: LiveShareServer.active ? Icon.Weight.Fill : Icon.Weight.Regular
                        size:       Button.Size.Sm
                        variant:    LiveShareServer.active ? Button.Variant.Danger : Button.Variant.Ghost
                        onClicked: {
                            if (LiveShareServer.active) {
                                if (AppSettings.liveShareWarnOnStop)
                                    _liveShareStopPopup.open()
                                else
                                    LiveShareServer.stop()
                            } else if (AppSettings.liveShareWarnOnStart) {
                                _liveShareWarnPopup.open()
                            } else {
                                LiveShareServer.start(AppSettings.liveShareUseTls, AppSettings.liveShareCertPath, AppSettings.liveShareKeyPath, AppSettings.liveShareLanVisible)
                            }
                        }
                    }
                }

            }
        }

        // ── Live Share URL bar ────────────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            visible: LiveShareServer.active
            height:  34
            color:   Theme.panel

            Rectangle {
                anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
                height: 1; color: Theme.border
            }

            RowLayout {
                anchors { fill: parent; leftMargin: Theme.sp3; rightMargin: Theme.sp3 }
                spacing: Theme.sp2

                // ── Live Share label ──────────────────────────────────────────
                Icon { name: Icons.broadcast; size: 13; color: Theme.textSecondary }
                Text {
                    text:  "Live Share"
                    color: Theme.textSecondary
                    font { family: Theme.fontFamily; pixelSize: Theme.textXs; weight: Theme.weightSemibold }
                }

                Rectangle { width: 1; height: 14; color: Theme.border; Layout.alignment: Qt.AlignVCenter }

                // ── Viewer count ──────────────────────────────────────────────
                Icon {
                    name:  Icons.users
                    size:  11
                    color: LiveShareServer.clientCount > 0 ? Theme.textPrimary : Theme.textDisabled
                }
                Text {
                    text:  LiveShareServer.clientCount + (LiveShareServer.clientCount === 1 ? " viewer" : " viewers")
                    color: LiveShareServer.clientCount > 0 ? Theme.textPrimary : Theme.textDisabled
                    font { family: Theme.fontFamily; pixelSize: Theme.textXs }
                }

                Rectangle { width: 1; height: 14; color: Theme.border; Layout.alignment: Qt.AlignVCenter }

                // ── Selected URL ──────────────────────────────────────────────
                Text {
                    text:             root._liveShareSelectedUrl || LiveShareServer.url
                    color:            Theme.textSecondary
                    font { family: Theme.fontFamilyMono; pixelSize: Theme.textXs }
                    elide:            Text.ElideRight
                    Layout.fillWidth: true
                }

                // ── URL picker ────────────────────────────────────────────────
                Tooltip {
                    text: "Switch URL"
                    Button {
                        id:       _urlPickerBtn
                        iconOnly: true
                        iconName: Icons.caretDown
                        size:     Button.Size.Sm
                        variant:  Button.Variant.Ghost
                        onClicked: {
                            LiveShareServer.fetchPublicIp()
                            _urlPickerMenu.open()
                        }
                    }
                }

                Menu {
                    id:       _urlPickerMenu
                    anchor:   _urlPickerBtn
                    position: Menu.Position.BottomRight
                    model: {
                        var cur   = root._liveShareSelectedUrl
                        var items = [
                            { label: "Same machine",  icon: Icons.monitor,  _url: LiveShareServer.url, checked: cur === LiveShareServer.url },
                        ]
                        var lans = LiveShareServer.lanUrls
                        for (var i = 0; i < lans.length; i++)
                            items.push({ label: lans.length > 1 ? "Local network " + (i + 1) : "Local network", icon: Icons.wifiHigh, _url: lans[i], checked: cur === lans[i] })
                        if (LiveShareServer.publicUrl !== "")
                            items.push({ label: "Public internet", icon: Icons.globe, _url: LiveShareServer.publicUrl, checked: cur === LiveShareServer.publicUrl })
                        else
                            items.push({ label: "Public internet", icon: Icons.globe, disabled: true })
                        return items
                    }
                    onTriggered: (index, item) => {
                        if (item._url) root._liveShareSelectedUrl = item._url
                    }
                }

                // ── Copy button ───────────────────────────────────────────────
                Tooltip {
                    text: "Copy link"
                    Button {
                        iconOnly: true
                        iconName: Icons.copy
                        size:     Button.Size.Sm
                        variant:  Button.Variant.Ghost
                        onClicked: {
                            _toaster.copyToClipboard(root._liveShareSelectedUrl || LiveShareServer.url)
                            _toaster.show("Link copied.", Toaster.Type.Success)
                        }
                    }
                }
            }
        }

        // ── Body: empty state + panels share the same space, crossfade ──────────
        Item {
            Layout.fillWidth:  true
            Layout.fillHeight: true

            // Empty state
            Item {
                anchors.fill: parent
                opacity: root._anyPanelVisible ? 0 : 1
                visible: opacity > 0
                Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.InOutQuad } }

                ColumnLayout {
                    anchors.centerIn: parent
                    spacing: 12

                    Icon {
                        name:  Icons.layout
                        size:  52
                        color: Theme.textDisabled
                        Layout.alignment: Qt.AlignHCenter
                    }

                    Text {
                        text:           "No panels are open"
                        color:          Theme.textSecondary
                        font.family:    Theme.fontFamily
                        font.pixelSize: Theme.textBase
                        font.weight:    Theme.weightSemibold
                        Layout.alignment: Qt.AlignHCenter
                    }

                    Text {
                        text:           "Use the buttons in the top bar to show panels and start working"
                        color:          Theme.textDisabled
                        font.family:    Theme.fontFamily
                        font.pixelSize: Theme.textSm
                        Layout.alignment: Qt.AlignHCenter
                    }
                }
            }

            // Panels
            SplitPane {
                anchors.fill: parent
                opacity: root._anyPanelVisible ? 1 : 0
                visible: opacity > 0
                Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.InOutQuad } }

            // Schema:rest split — 17% schema, 83% rest
            ratio:         0.17
            minRatio:      0.10
            maxRatio:      0.35
            firstVisible:  root._showSchema
            secondVisible: root._showQuery || root._showResults || root._showSidebar

            firstItem: SchemaTree {
                // Never render an out-of-workspace connection's schema.
                connectionName: root._activeTabUsable ? root.activeConnection : ""
                onTableDoubleClicked: (name) => {
                    if (!AppSettings.schemaInsertOnDoubleClick) return
                    if (queryEditor.sql.trim() === "")
                        queryEditor.setSql("SELECT * FROM " + name)
                    else
                        queryEditor.insertAtCursor(name)
                }
                onColumnDoubleClicked: (table, column) => {
                    if (AppSettings.schemaInsertOnDoubleClick)
                        queryEditor.insertAtCursor(column)
                }
                onTableQuickBrowseRequested: (name) => {
                    const sql = 'SELECT * FROM "' + name + '"' + (root._limit > 0 ? ' LIMIT ' + root._limit : '')
                    queryEditor.setSql(sql)
                    root._executingSql = sql
                    QueryExecutor.activeTabId = root._currentTabId
                    QueryExecutor.execute(root.activeConnection, sql)
                }
                onTableStatsRequested: (name) => _tableStatsPopup.openFor(root.activeConnection, name)
                onTableDdlRequested:   (name) => _tableDdlPopup.openFor(root.activeConnection, name)
            }

            secondItem: SplitPane {
                // Center:history split — 80% editor, 20% history
                ratio:         0.80
                minRatio:      0.50
                maxRatio:      0.92
                firstVisible:  root._showQuery || root._showResults
                secondVisible: root._showSidebar

                firstItem: ColumnLayout {
                    spacing: 0

                    // ── Query tab bar ─────────────────────────────────────────
                    Rectangle {
                        Layout.fillWidth: true
                        height: 36
                        color:  Theme.panel

                        Rectangle {
                            anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
                            height: 1; color: Theme.border
                        }

                        RowLayout {
                            anchors.fill: parent
                            spacing: 0

                            Flickable {
                                Layout.fillWidth:  true
                                Layout.fillHeight: true
                                contentWidth: _queryTabRow.implicitWidth
                                clip:         true
                                interactive:  contentWidth > width

                                Row {
                                    id: _queryTabRow
                                    height: 36

                                    Repeater {
                                        model: root._queryTabs

                                        delegate: Item {
                                            id: _qtab
                                            required property var modelData
                                            required property int index
                                            readonly property bool _active: _qtab.index === root._activeQueryTabIdx
                                            property bool _editing: false

                                            // The tab is bound to a .sql file, and what it holds
                                            // is no longer what went to disk. Reads _tabFileMap
                                            // and the live editor text, so it re-evaluates as you
                                            // type — which is what makes it a marker and not a
                                            // stamp left over from the last save.
                                            readonly property var  _file:  root._tabFileMap[_qtab.modelData.id] ?? null
                                            readonly property bool _dirty: _qtab._file !== null
                                                && root._tabSql(_qtab.modelData.id) !== _qtab._file.savedSql

                                            function _nameOf(path: string): string {
                                                return decodeURIComponent(path.split("/").pop() ?? "")
                                            }

                                            height: 36
                                            width:  Math.max(112, _qtabLabel.implicitWidth
                                                    + (root._queryTabs.length > 1 ? 68 : 46)
                                                    + (_qtab._file ? 14 : 0))

                                            // Tab-click area; double-click starts rename
                                            MouseArea {
                                                anchors.fill: parent
                                                cursorShape:  Qt.PointingHandCursor
                                                onClicked:    root._switchQueryTab(_qtab.index)
                                                onDoubleClicked: {
                                                    root._switchQueryTab(_qtab.index)
                                                    _qtab._editing = true
                                                    _qtabEdit.text = _qtab.modelData.label
                                                    _qtabEdit.selectAll()
                                                    _qtabEdit.forceActiveFocus()
                                                }
                                            }

                                            // Active underline
                                            Rectangle {
                                                anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
                                                height: 2; color: Theme.primary
                                                visible: _qtab._active
                                            }

                                            RowLayout {
                                                anchors { fill: parent; leftMargin: 10; rightMargin: 4 }
                                                spacing: 4

                                                // Connection dot — click to retarget this tab
                                                Rectangle {
                                                    id: _qtabConnDot
                                                    width: 9; height: 9; radius: 4.5
                                                    Layout.alignment: Qt.AlignVCenter
                                                    color: root._connColor(_qtab.modelData.connectionName)
                                                    border.width: 1
                                                    border.color: Qt.rgba(0, 0, 0, 0.15)

                                                    MouseArea {
                                                        anchors.fill: parent
                                                        cursorShape:  Qt.PointingHandCursor
                                                        onClicked:    _qtabConnMenu.open()
                                                    }

                                                    Menu {
                                                        id:     _qtabConnMenu
                                                        anchor: _qtabConnDot
                                                        // Only this workspace's connections are
                                                        // valid retarget candidates.
                                                        model: {
                                                            const items = root._usableConnections.map(c => ({
                                                                label:   c.name,
                                                                checked: c.name === _qtab.modelData.connectionName,
                                                                _conn:   c.name
                                                            }))
                                                            if (items.length > 0) items.push(null)
                                                            items.push({ label: "Add connection to workspace…",
                                                                         icon: Icons.plus, _act: "add" })
                                                            return items
                                                        }
                                                        onTriggered: (index, item) => {
                                                            if (item._conn !== undefined)
                                                                root._setTabConnection(_qtab.index, item._conn)
                                                            else if (item._act === "add")
                                                                _wsFormDialog.openConnections(root.workspaceId)
                                                        }
                                                    }
                                                }

                                                // Static label (shown when not editing)
                                                Text {
                                                    id: _qtabLabel
                                                    visible: !_qtab._editing
                                                    text: _qtab.modelData.label
                                                    color: _qtab._active ? Theme.primary : Theme.textSecondary
                                                    font.family:    Theme.fontFamily
                                                    font.pixelSize: Theme.textSm
                                                    font.weight:    _qtab._active ? Theme.weightMedium : Theme.weightRegular
                                                    elide: Text.ElideRight
                                                    Layout.fillWidth: true
                                                    Behavior on color { ColorAnimation { duration: Theme.durationFast } }
                                                }

                                                // Inline rename input (shown when editing)
                                                TextInput {
                                                    id: _qtabEdit
                                                    visible: _qtab._editing
                                                    Layout.fillWidth: true
                                                    color:          Theme.textPrimary
                                                    font.family:    Theme.fontFamily
                                                    font.pixelSize: Theme.textSm
                                                    font.weight:    Theme.weightMedium
                                                    clip:           true
                                                    selectByMouse:  true
                                                    maximumLength:  32

                                                    function _commit(): void {
                                                        const label = text.trim()
                                                        const idx   = _qtab.index
                                                        _qtab._editing = false
                                                        if (!label || idx >= root._queryTabs.length) return
                                                        const taken = root._queryTabs.some((t, i) => i !== idx && t.label === label)
                                                        if (taken) {
                                                            _toaster.show('A tab named "' + label + '" already exists.', Toaster.Type.Error)
                                                            return
                                                        }
                                                        const tabs = root._queryTabs.slice()
                                                        tabs[idx]  = { id: tabs[idx].id, label: label,
                                                                       connectionName: tabs[idx].connectionName }
                                                        root._queryTabs = tabs
                                                    }

                                                    Keys.onReturnPressed: _commit()
                                                    Keys.onEscapePressed: { _qtab._editing = false }
                                                    onActiveFocusChanged: { if (!activeFocus) _commit() }
                                                }

                                                // Unsaved-changes marker. Only a bound tab can
                                                // show it: an unbound tab has no file to diverge
                                                // from, and its text is already safe in the
                                                // workspace, so a dot there would mean nothing.
                                                Tooltip {
                                                    visible: _qtab._file !== null
                                                    Layout.alignment: Qt.AlignVCenter
                                                    // Guarded: `visible` does not stop a binding
                                                    // from evaluating, and an unbound tab has no
                                                    // path to read.
                                                    text: _qtab._file === null ? ""
                                                        : _qtab._dirty
                                                        ? "Unsaved changes — " + _qtab._nameOf(_qtab._file.path)
                                                        : _qtab._nameOf(_qtab._file.path)

                                                    Text {
                                                        text:  _qtab._dirty ? "●" : "○"
                                                        color: _qtab._dirty ? Theme.warning : Theme.textDisabled
                                                        font.pixelSize: 9
                                                    }
                                                }

                                                Rectangle {
                                                    visible: root._queryTabs.length > 1
                                                    width: 20; height: 20; radius: Theme.radiusSm
                                                    color: _qtabCloseHov.hovered ? Theme.border : "transparent"
                                                    Behavior on color { ColorAnimation { duration: Theme.durationFast } }

                                                    Text {
                                                        anchors.centerIn: parent
                                                        text: "×"; font.pixelSize: 14
                                                        color: Theme.textDisabled
                                                    }

                                                    HoverHandler { id: _qtabCloseHov }
                                                    MouseArea {
                                                        anchors.fill: parent
                                                        cursorShape:  Qt.PointingHandCursor
                                                        onClicked:    root._closeQueryTab(_qtab.index)
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }

                            // [+] new tab
                            Tooltip {
                                text: "New query tab"
                                Layout.leftMargin:    Theme.sp2
                                Layout.rightMargin:   Theme.sp2
                                Layout.alignment:     Qt.AlignVCenter
                                Button {
                                    iconOnly:             true
                                    iconName:             Icons.plus
                                    size:                 Button.Size.Sm
                                    variant:              Button.Variant.Ghost
                                    onClicked:            root._newQueryTab("")
                                }
                            }

                            Rectangle { width: 1; height: 20; color: Theme.border; Layout.alignment: Qt.AlignVCenter }

                            // [Limit ▾] [▶ Run / ⏹ Stop]
                            Row {
                                spacing:             Theme.sp2
                                Layout.leftMargin:   Theme.sp3
                                Layout.rightMargin:  Theme.sp3
                                Layout.alignment:    Qt.AlignVCenter

                                Tooltip {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: root._truncated
                                          ? "The limit cut this result — the query returns more rows"
                                          : "Row limit applied to SELECT results"

                                QQC.ComboBox {
                                    id: _limitPicker
                                    // Wide enough for "No limit", the longest preset, with the
                                    // caret beside it rather than on top of it.
                                    implicitWidth:  100
                                    implicitHeight: 26
                                    editable: true
                                    leftPadding:  0
                                    rightPadding: 24

                                    readonly property var _presets: [50, 100, 500, 1000, 5000, 10000, 0]
                                    model: _presets.map(v => v === 0 ? "No limit" : v.toString())

                                    currentIndex: {
                                        const idx = _presets.indexOf(root._limit)
                                        return idx >= 0 ? idx : -1
                                    }
                                    onActivated: (idx) => root._limit = _presets[idx]
                                    onAccepted: {
                                        const v = parseInt(editText, 10)
                                        root._limit = isNaN(v) || v < 0 ? 0 : v
                                    }

                                    contentItem: TextInput {
                                        leftPadding:  8
                                        text:         _limitPicker.displayText
                                        color:        root._truncated ? Theme.warning : Theme.textPrimary
                                        font { family: Theme.fontFamily; pixelSize: Theme.textSm }
                                        verticalAlignment: Text.AlignVCenter
                                        selectByMouse: true
                                    }

                                    // The default indicator is an unstyled up/down
                                    // pair — the only such control in the toolbar,
                                    // and wide enough to push "No limit" off its own
                                    // left edge. One caret, matching Mahina's.
                                    indicator: Icon {
                                        x:     _limitPicker.width - width - 8
                                        y:     (_limitPicker.height - height) / 2
                                        name:  _limitPicker.popup.visible ? Icons.caretUp : Icons.caretDown
                                        size:  12
                                        color: root._truncated ? Theme.warning : Theme.textSecondary
                                    }

                                    // A limit that is merely set is not news; a limit
                                    // that actually cut the result is. Quiet until it
                                    // hides something, then loud — the same rule the
                                    // status bar uses for a dropped connection.
                                    background: Rectangle {
                                        color:        Theme.surface
                                        radius:       Theme.radiusSm
                                        border.color: _limitPicker.popup.visible ? Theme.primary
                                                    : root._truncated             ? Theme.warning
                                                    : Theme.border
                                        border.width: _limitPicker.popup.visible || root._truncated ? 2 : 1
                                        Behavior on border.color { ColorAnimation { duration: Theme.durationFast } }
                                    }
                                    popup: QQC.Popup {
                                        y: _limitPicker.height + 2
                                        width: _limitPicker.width
                                        height: Math.min(contentItem.implicitHeight, 220)
                                        padding: 1
                                        contentItem: ListView {
                                            implicitHeight: contentHeight
                                            model: _limitPicker.delegateModel
                                            clip:  true
                                        }
                                        background: Rectangle {
                                            color: Theme.surface; radius: Theme.radiusSm
                                            border.color: Theme.border; border.width: 1
                                        }
                                    }
                                    delegate: QQC.ItemDelegate {
                                        required property string modelData
                                        required property int    index
                                        width: parent ? parent.width : 0
                                        implicitHeight: 28
                                        highlighted: _limitPicker.highlightedIndex === index
                                        contentItem: Text {
                                            leftPadding: 8
                                            text:  modelData
                                            color: _limitPicker._presets[index] === root._limit ? Theme.primary : Theme.textPrimary
                                            font { family: Theme.fontFamily; pixelSize: Theme.textSm }
                                            verticalAlignment: Text.AlignVCenter
                                        }
                                        background: Rectangle {
                                            color: highlighted
                                                ? Qt.rgba(Qt.color(Theme.primary).r, Qt.color(Theme.primary).g, Qt.color(Theme.primary).b, 0.08)
                                                : "transparent"
                                        }
                                    }
                                }
                                }

                                Button {
                                    text:     root._running ? "Stop" : "Run"
                                    iconName: root._running ? Icons.stop : Icons.play
                                    variant:  root._running ? Button.Variant.Danger : Button.Variant.Filled
                                    size:     Button.Size.Sm
                                    enabled:  root._activeTabUsable || root._running
                                    anchors.verticalCenter: parent.verticalCenter
                                    onClicked: root._running ? root._cancelQuery() : root._runQuery()
                                }

                                Tooltip {
                                    text: "Explain query plan ("
                                          + KeyLabels.sequence("Ctrl+E") + ")"
                                    anchors.verticalCenter: parent.verticalCenter
                                    Button {
                                        iconOnly: true
                                        iconName: Icons.lightning
                                        size:     Button.Size.Sm
                                        variant:  Button.Variant.Ghost
                                        enabled:  root._activeTabUsable
                                        onClicked: root._runExplain(false)
                                    }
                                }

                                Tooltip {
                                    text: "Generate SQL with AI"
                                    anchors.verticalCenter: parent.verticalCenter
                                    Button {
                                        iconOnly: true
                                        iconName: Icons.sparkle
                                        size:     Button.Size.Sm
                                        variant:  Button.Variant.Ghost
                                        enabled:  root._activeTabUsable && AppSettings.aiProvider !== ""
                                        onClicked: root._openAiPalette()
                                    }
                                }
                            }

                            Rectangle { width: 1; height: 20; color: Theme.border; Layout.alignment: Qt.AlignVCenter }

                            // [···]
                            Tooltip {
                                text: "More actions"
                                Layout.leftMargin:  Theme.sp1
                                Layout.rightMargin: Theme.sp2
                                Layout.alignment:   Qt.AlignVCenter
                                Button {
                                id:             _editorMoreBtn
                                iconOnly:       true
                                iconName:       Icons.dotsThree
                                size:           Button.Size.Sm
                                variant:        Button.Variant.Ghost
                                onClicked:      _editorMenu.open()

                                Menu {
                                    id:       _editorMenu
                                    anchor:   _editorMoreBtn
                                    position: Menu.Position.BottomRight
                                    model: [
                                        { label: "Format SQL",      icon: Icons.textAa,         shortcut: "Ctrl+Shift+F" },
                                        null,
                                        { label: "Open .sql file",  icon: Icons.folderOpen,     shortcut: "Ctrl+O" },
                                        { label: "Save as snippet", icon: Icons.code,           shortcut: "Ctrl+Shift+S" },
                                        { label: "Save to file",    icon: Icons.downloadSimple, shortcut: "Ctrl+S" },
                                        { label: "Save to file as…", icon: Icons.downloadSimple },
                                        { label: "Export as Markdown…", icon: Icons.article },
                                        { label: "Export as Markdown + results…", icon: Icons.article },
                                        null,
                                        { label: "Share SQL…",      icon: Icons.shareNetwork },
                                    ]
                                    onTriggered: (index) => {
                                        if (index === 0) queryEditor.setSql(Fmt.format(queryEditor.sql))
                                        if (index === 2) _sqlOpenDialog.open()
                                        if (index === 3) _saveDialog.openFor(
                                            queryEditor.selectedText.trim() !== ""
                                            ? queryEditor.selectedText : root.currentSql)
                                        if (index === 4) root._saveTabFile()
                                        if (index === 5) _sqlSaveFileDialog.open()
                                        if (index === 6) { _mdExportDialog.includeResults = false; _mdExportDialog.openSuggested() }
                                        if (index === 7) { _mdExportDialog.includeResults = true;  _mdExportDialog.openSuggested() }
                                        if (index === 9) _shareMenu.open()
                                    }
                                }
                                }
                            }
                        }
                    }

                    // Out-of-workspace warning: the active tab targets a
                    // connection that isn't in this workspace (or no longer exists).
                    // SQL stays editable; running is blocked — never retarget.
                    Banner {
                        Layout.fillWidth: true
                        visible: root.activeConnection !== "" && !root._activeTabUsable
                        type:    Banner.Type.Warning
                        message: root._connExists(root.activeConnection)
                                 ? "Connection '" + root.activeConnection + "' is not available in this workspace."
                                 : "Connection '" + root.activeConnection + "' no longer exists."
                        actionText: root._connExists(root.activeConnection) ? "Add to workspace" : ""
                        onActionClicked: {
                            WorkspaceManager.addConnection(root.workspaceId, root.activeConnection)
                            root.workspaceConnections = WorkspaceManager.connections(root.workspaceId)
                        }
                    }

                    // Vertical split: editor | results
                    SplitPane {
                        Layout.fillWidth:  true
                        Layout.fillHeight: true
                        orientation:   SplitPane.Orientation.Vertical
                        ratio:         0.45
                        minRatio:      0.15
                        maxRatio:      0.85
                        firstVisible:  root._showQuery
                        secondVisible: root._showResults

                        // Horizontal split: editor | markdown preview
                        firstItem: SplitPane {
                            orientation:   SplitPane.Orientation.Horizontal
                            ratio:         0.55
                            minRatio:      0.25
                            maxRatio:      0.8
                            firstVisible:  true
                            secondVisible: root._showPreview

                            firstItem: QueryEditor {
                                id:             queryEditor
                                connectionName: root._activeTabUsable ? root.activeConnection : ""
                            }

                            secondItem: MarkdownPreview {
                                sql: root.currentSql
                            }
                        }

                        secondItem: ColumnLayout {
                            spacing: 0

                            // ── Results header ────────────────────────────────
                            Rectangle {
                                Layout.fillWidth: true
                                height: 36
                                color:  Theme.panel

                                Rectangle {
                                    anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
                                    height: 1; color: Theme.border
                                }

                                RowLayout {
                                    anchors { fill: parent; leftMargin: Theme.sp3; rightMargin: Theme.sp3 }
                                    spacing: Theme.sp2

                                    // Results | Output tabs (underline style, flush
                                    // with the header's bottom border)
                                    TabBar {
                                        Layout.fillHeight: true
                                        tabHeight:   36
                                        tabMinWidth: 72
                                        model: ["Results",
                                                root._outputUnseenErrors > 0
                                                ? "Output · " + (root._outputUnseenErrors > 9 ? "9+" : root._outputUnseenErrors)
                                                : "Output",
                                                "Chart",
                                                "Profile",
                                                "Explain",
                                                "Pivot",
                                                "Checks",
                                                "Diff"]
                                        currentIndex: root._resultsPane
                                        onTabClicked: (i) => root._resultsPane = i
                                    }

                                    Item { Layout.fillWidth: true }

                                    // What the run produced. It sits by the export
                                    // button rather than by the tabs: a short "97
                                    // rows" immediately after "Diff", in the same
                                    // strip and the same size, reads as one more tab.
                                    Divider {
                                        vertical: true
                                        visible:  _resultSummary.visible
                                        Layout.preferredHeight: 18
                                    }

                                    RowLayout {
                                        id:      _resultSummary
                                        visible: root._rowCount > 0 || root._elapsedMs > 0
                                        spacing: Theme.sp2

                                        // Row count. When the limit cut the result the
                                        // count alone reads as the whole answer, so it
                                        // says so.
                                        Text {
                                            visible: root._rowCount > 0
                                            text:    root._rowCount + (root._rowCount === 1 ? " row" : " rows")
                                                     + (root._truncated ? " (limited)" : "")
                                            color:   root._truncated ? Theme.warning : Theme.textSecondary
                                            font { family: Theme.fontFamily; pixelSize: Theme.textSm }
                                        }
                                        Text {
                                            visible: root._rowCount > 0 && root._elapsedMs > 0
                                            text:    "·"
                                            color:   Theme.textDisabled
                                            font { family: Theme.fontFamily; pixelSize: Theme.textSm }
                                        }
                                        Text {
                                            visible: root._elapsedMs > 0
                                            text:    root._elapsedMs + " ms"
                                            color:   Theme.textDisabled
                                            font { family: Theme.fontFamily; pixelSize: Theme.textSm }
                                        }
                                    }

                                    Divider {
                                        vertical: true
                                        visible:  _resultSummary.visible
                                        Layout.preferredHeight: 18
                                    }

                                    // Export
                                    Tooltip {
                                        text: "Export results"
                                        Button {
                                        id:        _exportBtn
                                        iconOnly:  true
                                        iconName:  Icons.downloadSimple
                                        size:      Button.Size.Sm
                                        variant:   Button.Variant.Ghost
                                        enabled:   root._rowCount > 0
                                        onClicked: _exportMenu.open()

                                        Menu {
                                            id:       _exportMenu
                                            anchor:   _exportBtn
                                            position: Menu.Position.BottomRight
                                            model: [
                                                { label: "CSV",         icon: Icons.fileCsv         },
                                                { label: "TSV",         icon: Icons.fileText         },
                                                { label: "JSON",        icon: Icons.bracketsCurly    },
                                                { label: "Excel",       icon: Icons.fileXls          },
                                                { label: "SQL INSERTs", icon: Icons.fileSql          },
                                            ]
                                            onTriggered: (index) => {
                                                if (index === 0) _csvDialog.open()
                                                if (index === 1) _tsvDialog.open()
                                                if (index === 2) _jsonDialog.open()
                                                if (index === 3) _xlsxDialog.open()
                                                if (index === 4) {
                                                    _sqlTable.text = root._tabTableMap[root._currentTabId] || "table_name"
                                                    _sqlExportDialog.open()
                                                }
                                            }
                                        }
                                        }
                                    }
                                }
                            }

                            StackLayout {
                                Layout.fillWidth:  true
                                Layout.fillHeight: true
                                currentIndex: root._resultsPane

                                ResultsTable {
                                    id:           _resultsTable
                                    model:        QueryExecutor.tabResultModel(root._currentTabId)
                                    errorMessage: root._lastError
                                    hasRun:       root._tabStateMap[root._currentTabId] !== undefined
                                    editable:     root._resultEditable
                                    tableName:    root._tabTableMap[root._currentTabId] ?? ""
                                    pkColumns:    root._currentPkCols
                                    foreignKeys:  root._fkList
                                    driver:       root._activeConn ? (root._activeConn.driver ?? "") : ""
                                    onCellCopied: (value) => _toaster.show(
                                        "Copied to clipboard.",
                                        Toaster.Type.Info, 1500
                                    )
                                    onExportRequested: _csvDialog.open()
                                    onEditCommitted: (row, col, colName, newValue, oldValue) =>
                                        root._applyInlineEdit(row, col, colName, newValue)
                                    onNavigateRequested: (sql, title) => root._openFkTab(sql, title)
                                }

                                // DataGrip-style session console for the active connection
                                OutputConsole {
                                    connectionName: root._activeTabUsable ? root.activeConnection : ""
                                }

                                // Plot the active result set
                                ChartView {
                                    model:  QueryExecutor.tabResultModel(root._currentTabId)
                                    hasRun: root._tabStateMap[root._currentTabId] !== undefined
                                }

                                // df.describe()-style per-column profile
                                ProfilePanel {
                                    model:  QueryExecutor.tabResultModel(root._currentTabId)
                                    hasRun: root._tabStateMap[root._currentTabId] !== undefined
                                }

                                // Dialect-aware query plan visualisation (Ctrl+E)
                                ExplainView {
                                    plan:    root._tabExplainMap[root._currentTabId] ?? null
                                    loading: root._explaining
                                    sql:     root._explainSqlMap[root._currentTabId] ?? ""
                                    onRunRequested: (analyze) => root._runExplain(analyze)
                                }

                                // Cross-tab / pivot of the active result set
                                PivotView {
                                    model:  QueryExecutor.tabResultModel(root._currentTabId)
                                    hasRun: root._tabStateMap[root._currentTabId] !== undefined
                                }

                                // Data-quality checks against the active result set
                                ExpectationsView {
                                    model:  QueryExecutor.tabResultModel(root._currentTabId)
                                    hasRun: root._tabStateMap[root._currentTabId] !== undefined
                                    rules:  root._tabExpectationsMap[root._currentTabId] ?? []
                                    onRulesEdited: (newRules) => {
                                        const m = Object.assign({}, root._tabExpectationsMap)
                                        m[root._currentTabId] = newRules
                                        root._tabExpectationsMap = m
                                    }
                                }

                                // Diff the active result set against a saved baseline
                                DiffView {
                                    model:    QueryExecutor.tabResultModel(root._currentTabId)
                                    hasRun:   root._tabStateMap[root._currentTabId] !== undefined
                                    connectionName: root.activeConnection
                                    sql:            root.currentSql
                                    baselineSnap: root._tabBaselineMap[root._currentTabId] ?? null
                                    onBaselineRequested: (snap) => {
                                        const m = Object.assign({}, root._tabBaselineMap)
                                        if (snap === null) delete m[root._currentTabId]
                                        else               m[root._currentTabId] = snap
                                        root._tabBaselineMap = m
                                    }
                                }
                            }
                        }
                    }
                }

                secondItem: ColumnLayout {
                    spacing: 0

                    // ── Sidebar tab bar ────────────────────────────────────────
                    Rectangle {
                        Layout.fillWidth: true
                        height: 36
                        color:  Theme.panel

                        Rectangle {
                            anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
                            height: 1; color: Theme.border
                        }

                        Row {
                            anchors { left: parent.left; right: parent.right; top: parent.top; bottom: parent.bottom }
                            spacing: 0

                            Repeater {
                                model: [
                                    { label: "History", icon: Icons.clockCounterClockwise, tab: "history" },
                                    { label: "Snippets", icon: Icons.code,                 tab: "snippets" },
                                ]
                                delegate: Item {
                                    id: delegateItem
                                    required property var modelData
                                    readonly property bool _active: root._sidebarTab === modelData.tab
                                    height: 36
                                    width:  Math.floor(parent.width / 2)

                                    Rectangle {
                                        anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
                                        height: 2; color: Theme.primary
                                        visible: _active
                                    }

                                    Row {
                                        id: _tabInner
                                        anchors.centerIn: parent
                                        spacing: 5

                                        Icon {
                                            name:  delegateItem.modelData.icon
                                            size:  13
                                            color: _active ? Theme.primary : Theme.textSecondary
                                            anchors.verticalCenter: parent.verticalCenter
                                        }
                                        Text {
                                            text:  delegateItem.modelData.label
                                            color: _active ? Theme.primary : Theme.textSecondary
                                            font.family:    Theme.fontFamily
                                            font.pixelSize: Theme.textSm
                                            font.weight:    _active ? Theme.weightMedium : Theme.weightRegular
                                            anchors.verticalCenter: parent.verticalCenter
                                        }
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        cursorShape:  Qt.PointingHandCursor
                                        onClicked:    root._sidebarTab = delegateItem.modelData.tab
                                    }
                                }
                            }
                        }
                    }

                    // ── Sidebar content area ───────────────────────────────────
                    Rectangle {
                        Layout.fillWidth:  true
                        Layout.fillHeight: true
                        // Was transparent, which let Theme.background show through
                        // and gave the sidebar a ground no other panel used.
                        color: Theme.surface

                        // History
                        ListView {
                            id:           _historyList
                            anchors.fill: parent
                            visible:      root._sidebarTab === "history"
                            clip:         true
                            model:        root._historyEntries

                            delegate: SidebarEntry {
                                id: delegateItem2
                                required property var modelData
                                width:    ListView.view.width
                                label:    root._firstLine(modelData.sql)
                                detail:   root._relativeTime(modelData.executedAt) + " · " + modelData.connectionName
                                severity: modelData.success ? "" : "error"
                                onClicked: queryEditor.insertAtCursor(modelData.sql)

                                // No confirmation: one history row is a record
                                // of something already done, and re-running the
                                // query puts it back.
                                actionIcon:      Icons.trash
                                actionTooltip:   "Remove from history"
                                onActionClicked: HistoryManager.remove(delegateItem2.modelData.id)
                            }
                        }

                        EmptyState {
                            anchors.centerIn: parent
                            width:            parent.width - Theme.sp6
                            visible:          root._sidebarTab === "history" && _historyList.count === 0
                            icon:             Icons.clockCounterClockwise
                            title:            "No history yet"
                            description:      "Queries you run will appear here."
                            iconSize:         36
                        }

                        // Snippets, grouped under collapsible folder headers.
                        // Unfoldered snippets come first (SnippetManager orders
                        // by folder, then name).
                        ListView {
                            id:           _snippetList
                            anchors.fill: parent
                            visible:      root._sidebarTab === "snippets"
                            clip:         true

                            property var _collapsed: ({})
                            function _toggleFolder(f: string): void {
                                const m = Object.assign({}, _collapsed)
                                m[f] = !m[f]
                                _collapsed = m
                            }

                            model: {
                                const rows = []
                                let current = null
                                for (const s of SnippetManager.snippets) {
                                    if (s.folder !== "" && s.folder !== current)
                                        rows.push({ kind: "folder", folder: s.folder,
                                                    collapsed: !!_collapsed[s.folder] })
                                    current = s.folder
                                    if (s.folder === "" || !_collapsed[s.folder])
                                        rows.push({ kind: "snippet", snip: s })
                                }
                                return rows
                            }

                            // Both row shapes live in the one delegate and
                            // qualify their data through _snipRow. The folder
                            // header and the entry used to be Components loaded
                            // by a Loader that carried the row on a property of
                            // its own — which this file's `pragma
                            // ComponentBehavior: Bound` forbids a Component from
                            // reading, so every binding in them resolved to
                            // undefined and the whole list rendered blank.
                            delegate: Item {
                                id: _snipRow

                                required property var modelData

                                readonly property bool isFolder: _snipRow.modelData.kind === "folder"
                                readonly property var  snip:     _snipRow.modelData.snip ?? null

                                width:  ListView.view.width
                                height: _snipRow.isFolder ? 30 : _snipEntry.implicitHeight

                                Item {
                                    anchors.fill: parent
                                    visible:      _snipRow.isFolder

                                    Row {
                                        anchors {
                                            left: parent.left; leftMargin: Theme.sp2
                                            verticalCenter: parent.verticalCenter
                                        }
                                        spacing: 6

                                        Icon {
                                            name:  _snipRow.modelData.collapsed ? Icons.caretRight : Icons.caretDown
                                            size:  11
                                            color: Theme.textSecondary
                                            anchors.verticalCenter: parent.verticalCenter
                                        }
                                        Text {
                                            text:  _snipRow.modelData.folder ?? ""
                                            color: Theme.textSecondary
                                            font.family:    Theme.fontFamily
                                            font.pixelSize: Theme.textXs
                                            font.weight:    Theme.weightSemibold
                                            anchors.verticalCenter: parent.verticalCenter
                                        }
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        cursorShape:  Qt.PointingHandCursor
                                        onClicked:    _snippetList._toggleFolder(_snipRow.modelData.folder)
                                    }
                                }

                                SidebarEntry {
                                    id: _snipEntry

                                    anchors.fill: parent
                                    // Indent snippets that sit under a folder header.
                                    anchors.leftMargin: (_snipRow.snip?.folder ?? "") !== "" ? 10 : 0
                                    visible:            !_snipRow.isFolder

                                    readonly property bool _orphaned:
                                        (_snipRow.snip?.connectionName ?? "") !== "" &&
                                        ConnectionManager.connections.every(
                                            c => c.name !== _snipRow.snip.connectionName)

                                    label:    _snipRow.snip?.name ?? ""
                                    severity: _snipEntry._orphaned ? "warning" : ""
                                    detail:   _snipEntry._orphaned
                                        ? "⚠ connection not found"
                                        : (_snipRow.snip?.connectionName ?? "")

                                    onClicked: queryEditor.insertAtCursor(_snipRow.snip.sql)
                                }
                            }
                        }

                        EmptyState {
                            anchors.centerIn: parent
                            width:            parent.width - Theme.sp6
                            visible:          root._sidebarTab === "snippets" && _snippetList.count === 0
                            icon:             Icons.code
                            title:            "No snippets"
                            description:      "Select SQL and press " + KeyLabels.sequence("Ctrl+Shift+S")
                                              + ", or use the editor's ··· menu, to save a snippet. Clicking one inserts it at the cursor."
                            iconSize:         36
                        }

                    }
                }
            }
        }   // end SplitPane
        }   // end body wrapper Item

        // ── Bottom status bar (full width) ────────────────────────────────────
        StatusBar {
            Layout.fillWidth: true
            leftItems:   root._sbLeft
            centerItems: root._sbCenter
            rightItems:  root._sbRight
            onItemClicked: (section, index) => {
                if (section === "right" && index === root._sbRight.length - 1)
                    _shortcutsPanel.show()
            }
        }
    }

    // ── Plumbing ──────────────────────────────────────────────────────────────
    Connections {
        target: ConnectionManager
        function onConnectionAdded(name: string): void {
            // A genuinely new connection created from inside this workspace:
            // add it to the workspace (an explicit act) and give it a tab. This
            // one already names its destination by being raised here.
            root.openConnection(name, -1)
        }
        // The auto-reconnect retry belongs here rather than on connectionAdded,
        // which fires when a connection is *saved*. reconnect() reopens one that
        // already exists and emits connectionOpened alone, so the retry never ran
        // and the pending flag stayed true — which then blocked the next
        // auto-reconnect, the guard being !_reconnectRetryPending.
        function onConnectionOpened(name: string): void {
            if (!root._reconnectRetryPending || name !== root.activeConnection) return
            root._reconnectRetryPending = false
            _toaster.show("Reconnected. Retrying query…", Toaster.Type.Success)
            QueryExecutor.execute(root.activeConnection, root._executingSql)
        }
        function onConnectionRenamed(oldName: string, newName: string): void {
            if (!oldName || !newName || oldName === newName) return

            const conns = []
            for (let i = 0; i < root.workspaceConnections.length; ++i) {
                const name = root.workspaceConnections[i] === oldName
                           ? newName : root.workspaceConnections[i]
                if (conns.indexOf(name) === -1)
                    conns.push(name)
            }
            root.workspaceConnections = conns

            let changed = false
            const tabs = root._queryTabs.map(t => {
                if (t.connectionName !== oldName) return t
                changed = true
                return { id: t.id, label: t.label, connectionName: newName }
            })
            if (changed) {
                root._queryTabs = tabs
                root._sessionDirty = true
            }
        }
        function onConnectionError(name: string, error: string): void {
            if (root._reconnectRetryPending && name === root.activeConnection) {
                root._reconnectRetryPending = false
                _toaster.show("Reconnect failed: " + error, Toaster.Type.Error, 6000)
            }
        }
    }

    Connections {
        target: WorkspaceManager
        function onWorkspaceDeleted(id: int): void {
            // Current workspace deleted from elsewhere (e.g. Home): don't
            // flush into the dead row — just load whatever became active.
            if (id === root.workspaceId) {
                root.workspaceId = -1
                root.loadWorkspace(WorkspaceManager.activeWorkspaceId)
            }
        }
    }

    Connections {
        target: HistoryManager
        function onChanged() { root._historyEntries = HistoryManager.entries(50) }
    }

    Connections {
        target: QueryExecutor
        function onExecutionStarted(connectionName: string): void {
            const tabId = QueryExecutor.activeTabId
            const m = Object.assign({}, root._tabStateMap)
            m[tabId] = Object.assign({}, m[tabId] ?? {}, { error: "" })
            root._tabStateMap = m

            // Gutter: a spinner where the check mark or the red X will land, on
            // the same line, so the run is marked from the moment it starts
            // rather than only once it is over. Hung here rather than in
            // _runQuery because every path into execution — the confirm dialog,
            // the parameters dialog, an inline cell edit — arrives through this
            // signal and none of them can skip it.
            root._setGutterDecs(tabId, [{ line: root._execStartLine,
                                          icon:  Icons.spinner,
                                          color: Theme.primary,
                                          spin:  true }])
        }
        function onExecutionError(message: string): void {
            const isConnErr = /connect|network|lost|gone|closed|refused|timeout|broken pipe/i.test(message)
            if (isConnErr && AppSettings.autoReconnect && !root._reconnectRetryPending) {
                root._reconnectRetryPending = true
                _toaster.show("Connection lost — reconnecting…", Toaster.Type.Warning, 4000)
                ConnectionManager.reconnect(root.activeConnection)
                return
            }
            root._reconnectRetryPending = false
            _toaster.show(message, Toaster.Type.Error, 6000)
            const tabId = QueryExecutor.activeTabId
            const m = Object.assign({}, root._tabStateMap)
            m[tabId] = Object.assign({}, m[tabId] ?? {}, { error: message })
            root._tabStateMap = m

            // Gutter: red X on the error line (parsed from message) or the run start line
            const errLine = root._parseErrorLine(message) ?? root._execStartLine
            root._setGutterDecs(tabId, [{ line: errLine, icon: Icons.xCircle, color: Theme.error }])
        }
        function onExecutionFinished(success: bool, elapsedMs: var, rowCount: int, rowsAffected: int): void {
            const tabId = QueryExecutor.activeTabId
            const m = Object.assign({}, root._tabStateMap)
            m[tabId] = {
                success,
                rowCount,
                rowsAffected,
                elapsedMs,
                error: m[tabId]?.error ?? "",
                // setResult() ran before this signal, so the model already knows
                // whether the surplus row _applyLimit asked for came back.
                truncated: QueryExecutor.tabResultModel(tabId).truncated
            }
            root._tabStateMap = m

            // Refresh the FK list for the active connection so cell navigation works.
            if (success) root._ensureFks()

            // Gutter: green check on success, leave error icon (set by onExecutionError) on failure
            if (success)
                root._setGutterDecs(tabId, [{ line: root._execStartLine, icon: Icons.checkCircle, color: Theme.success }])

            // Inline edit: on success, update the cell in-place
            if (root._pendingCellEdit) {
                const pe = root._pendingCellEdit
                root._pendingCellEdit = null
                if (success)
                    QueryExecutor.tabResultModel(pe.tabId).setCellValue(pe.row, pe.col, pe.value)
            } else {
                HistoryManager.add(root.activeConnection, root._executingSql,
                                   success, rowCount > 0 ? rowCount : rowsAffected, elapsedMs)
            }
        }
    }

    Dialog {
        id:       _saveDialog
        title:    "Save Snippet"
        subtitle: "Name this SQL to reuse it from the sidebar or the Home Snippets page"

        property string _pendingSql: ""
        property string _nameError:  ""

        function openFor(sql: string): void {
            _pendingSql  = sql
            _nameError   = ""
            _saveNameInput.clear()
            _saveFolderInput.clear()
            open()
        }

        ColumnLayout {
            width:   parent.width
            spacing: 12

            Input {
                id:              _saveNameInput
                label:           "Name"
                placeholderText: "My query"
                Layout.fillWidth: true
                errorText:       _saveDialog._nameError
                onTextEdited:    _saveDialog._nameError = ""
            }

            Input {
                id:              _saveFolderInput
                label:           "Folder (optional)"
                placeholderText: "Reports"
                Layout.fillWidth: true
                onTextEdited:    _saveDialog._nameError = ""
            }

            // Existing folders, one click to reuse (avoids "DDL" vs "ddl" drift).
            Flow {
                Layout.fillWidth: true
                spacing: 6
                visible: _folderChips.count > 0

                Repeater {
                    id: _folderChips
                    model: {
                        const folders = []
                        for (const s of SnippetManager.snippets)
                            if (s.folder !== "" && folders.indexOf(s.folder) === -1)
                                folders.push(s.folder)
                        return folders
                    }
                    delegate: Chip {
                        id: delegateItem4
                        required property string modelData
                        text:     modelData
                        selected: _saveFolderInput.text.trim() === modelData
                        onClicked: {
                            _saveFolderInput.text = delegateItem4.modelData
                            _saveDialog._nameError = ""
                        }
                    }
                }
            }
        }

        footer: [
            Button {
                text:    "Cancel"
                variant: Button.Variant.Ghost
                onClicked: _saveDialog.close()
            },
            Button {
                text:    "Save"
                variant: Button.Variant.Filled
                enabled: _saveNameInput.text.trim() !== ""
                onClicked: {
                    if (SnippetManager.nameInUse(_saveNameInput.text, _saveFolderInput.text)) {
                        _saveDialog._nameError =
                            "A snippet with this name already exists"
                            + (_saveFolderInput.text.trim() !== "" ? " in this folder." : ".")
                        return
                    }
                    SnippetManager.save(
                        _saveNameInput.text.trim(),
                        _saveFolderInput.text.trim(),
                        _saveDialog._pendingSql,
                        root.activeConnection
                    )
                    _saveDialog.close()
                    _toaster.show("Snippet saved.", Toaster.Type.Success)
                }
            }
        ]
    }

    FileDialog {
        id:       _sqlOpenDialog
        title:    "Open SQL File"
        fileMode: FileDialog.OpenFile
        nameFilters: ["SQL files (*.sql)", "All files (*)"]
        onAccepted: {
            const text = AppSettings.readFile(selectedFile)
            if (text === "") {
                _toaster.show("Could not read file.", Toaster.Type.Error)
                return
            }
            _newQueryTab("")
            queryEditor.setSql(text)
            root._nameTabAfterFile(root._currentTabId, selectedFile)
            root._bindTabFile(root._currentTabId, selectedFile, text)
        }
    }

    FileDialog {
        id:            _sqlSaveFileDialog
        title:         "Save SQL to File"
        fileMode:      FileDialog.SaveFile
        defaultSuffix: "sql"
        nameFilters:   ["SQL files (*.sql)", "All files (*)"]
        onAccepted: root._writeTabFile(selectedFile)
    }

    FileDialog {
        id:            _mdExportDialog
        title:         "Export as Markdown"
        fileMode:      FileDialog.SaveFile
        defaultSuffix: "md"
        nameFilters:   ["Markdown files (*.md)", "All files (*)"]
        // Append the tab's latest result set as a markdown table.
        property bool includeResults: false
        // Suggest the active tab's name, slugified — same pattern as theme export.
        function openSuggested(): void {
            const label = root._queryTabs.find(t => t.id === root._currentTabId)?.label ?? ""
            const slug  = label.toLowerCase().replace(/\s+/g, "-").replace(/[^a-z0-9-]/g, "")
            selectedFile = StandardPaths.writableLocation(StandardPaths.DocumentsLocation)
                           + "/" + (slug || "query") + ".md"
            open()
        }
        onAccepted: {
            const results = includeResults
                          ? QueryExecutor.tabResultModel(root._currentTabId).toMarkdown(100)
                          : ""
            const ok = MarkdownDoc.exportMarkdown(root.currentSql, selectedFile, results)
            _toaster.show(
                ok ? "Exported as Markdown." : "Export failed. Could not write file.",
                ok ? Toaster.Type.Success : Toaster.Type.Error
            )
        }
    }

    FileDialog {
        id:            _csvDialog
        title:         "Export results as CSV"
        fileMode:      FileDialog.SaveFile
        defaultSuffix: "csv"
        nameFilters:   ["CSV files (*.csv)", "All files (*)"]
        onAccepted: root._exportResults("csv", selectedFile, "")
    }

    FileDialog {
        id:            _tsvDialog
        title:         "Export results as TSV"
        fileMode:      FileDialog.SaveFile
        defaultSuffix: "tsv"
        nameFilters:   ["TSV files (*.tsv)", "All files (*)"]
        onAccepted: root._exportResults("tsv", selectedFile, "")
    }

    FileDialog {
        id:            _jsonDialog
        title:         "Export results as JSON"
        fileMode:      FileDialog.SaveFile
        defaultSuffix: "json"
        nameFilters:   ["JSON files (*.json)", "All files (*)"]
        onAccepted: root._exportResults("json", selectedFile, "")
    }

    FileDialog {
        id:            _xlsxDialog
        title:         "Export results as Excel"
        fileMode:      FileDialog.SaveFile
        defaultSuffix: "xlsx"
        nameFilters:   ["Excel files (*.xlsx)", "All files (*)"]
        onAccepted: root._exportResults("xlsx", selectedFile, "")
    }

    // SQL INSERTs need a target table name, so ask for it before choosing a file.
    Dialog {
        id:             _sqlExportDialog
        title:          "Export as SQL INSERTs"
        subtitle:       "Generate one INSERT statement per row for the target table."
        preferredWidth: 440

        ColumnLayout {
            width:   parent.width
            spacing: Theme.sp2
            Text {
                text:  "Target table"
                color: Theme.textSecondary
                font { family: Theme.fontFamily; pixelSize: Theme.textXs }
            }
            Input {
                id:               _sqlTable
                Layout.fillWidth: true
                placeholderText:  "table_name"
                onAccepted:       if (_sqlConfirm.enabled) _sqlConfirm.clicked()
            }
            Text {
                text:  "Identifiers and value literals follow the "
                       + (root._aiDialect || "current") + " dialect."
                color: Theme.textDisabled
                font { family: Theme.fontFamily; pixelSize: Theme.textXs }
            }
        }

        footer: Row {
            spacing: Theme.sp2
            Button { text: "Cancel"; variant: Button.Variant.Ghost; onClicked: _sqlExportDialog.close() }
            Button {
                id:       _sqlConfirm
                text:     "Choose file…"
                iconName: Icons.fileSql
                variant:  Button.Variant.Filled
                enabled:  _sqlTable.text.trim().length > 0
                onClicked: { _sqlExportDialog.close(); _sqlFileDialog.open() }
            }
        }
    }

    FileDialog {
        id:            _sqlFileDialog
        title:         "Export results as SQL"
        fileMode:      FileDialog.SaveFile
        defaultSuffix: "sql"
        nameFilters:   ["SQL files (*.sql)", "All files (*)"]
        onAccepted: root._exportResults("sql", selectedFile, _sqlTable.text)
    }

    // ── Live Share warning popup ──────────────────────────────────────────────
    QQC.Popup {
        id:      _liveShareWarnPopup
        parent:  QQC.Overlay.overlay
        width:   400
        padding: 0
        x:       Math.round((parent.width  - width)  / 2)
        y:       Math.round((parent.height - height) / 2)
        modal:   true
        closePolicy: QQC.Popup.CloseOnEscape

        background: Rectangle {
            color:        Theme.surface
            border.color: Theme.border
            border.width: 1
            radius:       Theme.radiusMd
        }

        property bool _dontShowAgain: false

        onOpened: _dontShowAgain = false

        Column {
            width: parent.width
            padding: 24
            spacing: 16

            // Header
            Row {
                spacing: 10
                Icon {
                    name: Icons.broadcast
                    size: 20
                    color: Theme.primary
                    anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                    text: "Start Live Share?"
                    color: Theme.textPrimary
                    font { family: Theme.fontFamily; pixelSize: Theme.textBase; weight: Theme.weightSemibold }
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            // Body
            Column {
                width: parent.width - 48
                spacing: 8

                Text {
                    width: parent.width
                    text: "Live Share starts a local web server on your computer. Anyone you share the link with can:"
                    color: Theme.textSecondary
                    font { family: Theme.fontFamily; pixelSize: Theme.textSm }
                    wrapMode: Text.WordWrap
                }

                Column {
                    width: parent.width
                    spacing: 4
                    Repeater {
                        model: [
                            "See every SQL query you run in real time",
                            "See the full result sets returned by the database",
                            "Follow along while the session is active",
                        ]
                        delegate: Row {
                            id: delegateItem5
                            required property string modelData
                            spacing: 8
                            Text {
                                text: "•"
                                color: Theme.primary
                                font { family: Theme.fontFamily; pixelSize: Theme.textSm }
                            }
                            Text {
                                text: delegateItem5.modelData
                                color: Theme.textSecondary
                                font { family: Theme.fontFamily; pixelSize: Theme.textSm }
                                wrapMode: Text.WordWrap
                                width: 330
                            }
                        }
                    }
                }

                // Both facts follow the settings rather than being asserted
                // once. The old line said the link was local-only "unless you
                // forward the port", which stopped being true the moment the
                // LAN setting was added, and it never mentioned that without a
                // certificate the whole session is plain HTTP — the one thing
                // someone about to broadcast their result sets should be told.
                Text {
                    width: parent.width
                    text: {
                        const reach = AppSettings.liveShareLanVisible
                            ? "The link is reachable from anywhere on your network."
                            : "The link is only reachable from this machine unless you forward the port."
                        const crypto = AppSettings.liveShareUseTls
                            ? "Traffic is encrypted."
                            : "Traffic is not encrypted: queries and results travel in plain text. "
                              + "Turn on TLS in Settings to change that."
                        return "The link only works while qub is running. " + reach + " " + crypto
                    }
                    color: AppSettings.liveShareUseTls ? Theme.textDisabled : Theme.warning
                    font { family: Theme.fontFamily; pixelSize: 11 }
                    wrapMode: Text.WordWrap
                }
            }

            // Don't show again
            Toggle {
                text: "Don't show this again"
                checked: _liveShareWarnPopup._dontShowAgain
                onCheckedChanged: _liveShareWarnPopup._dontShowAgain = checked
            }

            // Buttons
            Row {
                spacing: 8
                layoutDirection: Qt.RightToLeft
                width: parent.width - 48

                Button {
                    text: "Start"
                    variant: Button.Variant.Filled
                    onClicked: {
                        if (_liveShareWarnPopup._dontShowAgain)
                            AppSettings.liveShareWarnOnStart = false
                        _liveShareWarnPopup.close()
                        LiveShareServer.start(AppSettings.liveShareUseTls, AppSettings.liveShareCertPath, AppSettings.liveShareKeyPath, AppSettings.liveShareLanVisible)
                    }
                }
                Button {
                    text: "Cancel"
                    onClicked: _liveShareWarnPopup.close()
                }
            }
        }
    }

    // ── Live Share stop confirmation ──────────────────────────────────────────
    QQC.Popup {
        id:      _liveShareStopPopup
        parent:  QQC.Overlay.overlay
        width:   400
        padding: 0
        x:       Math.round((parent.width  - width)  / 2)
        y:       Math.round((parent.height - height) / 2)
        modal:   true
        closePolicy: QQC.Popup.CloseOnEscape

        background: Rectangle {
            color:        Theme.surface
            border.color: Theme.border
            border.width: 1
            radius:       Theme.radiusMd
        }

        property bool _dontShowAgain: false

        onOpened: _dontShowAgain = false

        Column {
            width: parent.width
            padding: 24
            spacing: 16

            Row {
                spacing: 10
                Icon {
                    name: Icons.broadcast
                    size: 20
                    color: Theme.error
                    anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                    text: "Stop Live Share?"
                    color: Theme.textPrimary
                    font { family: Theme.fontFamily; pixelSize: Theme.textBase; weight: Theme.weightSemibold }
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            Column {
                width: parent.width - 48
                spacing: 8

                Text {
                    width: parent.width
                    text: "Stopping Live Share will immediately:"
                    color: Theme.textSecondary
                    font { family: Theme.fontFamily; pixelSize: Theme.textSm }
                    wrapMode: Text.WordWrap
                }

                Column {
                    width: parent.width
                    spacing: 4
                    Repeater {
                        model: [
                            "Disconnect all " + (LiveShareServer.clientCount > 0
                                ? LiveShareServer.clientCount === 1
                                    ? "1 active viewer"
                                    : LiveShareServer.clientCount + " active viewers"
                                : "viewers"),
                            "Invalidate the share link — it cannot be reused",
                        ]
                        delegate: Row {
                            id: delegateItem6
                            required property string modelData
                            spacing: 8
                            Text {
                                text: "•"
                                color: Theme.error
                                font { family: Theme.fontFamily; pixelSize: Theme.textSm }
                            }
                            Text {
                                text: delegateItem6.modelData
                                color: Theme.textSecondary
                                font { family: Theme.fontFamily; pixelSize: Theme.textSm }
                                wrapMode: Text.WordWrap
                                width: 330
                            }
                        }
                    }
                }
            }

            Toggle {
                text: "Don't show this again"
                checked: _liveShareStopPopup._dontShowAgain
                onCheckedChanged: _liveShareStopPopup._dontShowAgain = checked
            }

            Row {
                spacing: 8
                layoutDirection: Qt.RightToLeft
                width: parent.width - 48

                Button {
                    text: "Stop"
                    variant: Button.Variant.Danger
                    onClicked: {
                        if (_liveShareStopPopup._dontShowAgain)
                            AppSettings.liveShareWarnOnStop = false
                        _liveShareStopPopup.close()
                        LiveShareServer.stop()
                    }
                }
                Button {
                    text: "Keep sharing"
                    onClicked: _liveShareStopPopup.close()
                }
            }
        }
    }

    // ── Share menu ────────────────────────────────────────────────────────────
    QQC.Popup {
        id:     _shareMenu
        parent: QQC.Overlay.overlay
        width:  260
        padding: 0
        x:      Math.round((parent.width  - width)  / 2)
        y:      Math.round((parent.height - height) / 2)

        background: Rectangle {
            color:        Theme.surface
            border.color: Theme.border
            border.width: 1
            radius:       Theme.radiusMd
        }

        readonly property bool _tooLong: root.currentSql.length > 1400

        Column {
            width: parent.width
            padding: 6
            spacing: 2

            Repeater {
                model: [
                    { icon: Icons.link,         label: "Copy deep link",      sub: _shareMenu._tooLong ? "⚠ SQL may be too long for some apps" : "qub://query?sql=…" },
                    { icon: Icons.code,         label: "Copy as Markdown",    sub: "```sql … ```" },
                    { icon: Icons.clipboardText, label: "Copy plain SQL",     sub: "" },
                ]
                delegate: Rectangle {
                    id: delegateItem7
                    required property var  modelData
                    required property int  index
                    width:  parent ? parent.width - 12 : 248
                    height: 52
                    radius: Theme.radiusSm
                    color:  _rowHov.hovered ? Theme.surfaceVariant : "transparent"
                    HoverHandler { id: _rowHov }

                    Row {
                        anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter
                                  leftMargin: 12; rightMargin: 12 }
                        spacing: 12
                        Icon {
                            name:  delegateItem7.modelData.icon; size: 16
                            color: delegateItem7.index === 0 && _shareMenu._tooLong ? Theme.warning : Theme.primary
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        Column {
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 2
                            Text {
                                text:           delegateItem7.modelData.label
                                color:          Theme.textPrimary
                                font { family: Theme.fontFamily; pixelSize: Theme.textSm; weight: Theme.weightMedium }
                            }
                            Text {
                                visible:        delegateItem7.modelData.sub !== ""
                                text:           delegateItem7.modelData.sub
                                color:          delegateItem7.index === 0 && _shareMenu._tooLong ? Theme.warning : Theme.textDisabled
                                font { family: Theme.fontFamilyMono; pixelSize: 10 }
                            }
                        }
                    }

                    MouseArea {
                        anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            _shareMenu.close()
                            let text = ""
                            if (delegateItem7.index === 0) {
                                text = "qub://query?sql=" + encodeURIComponent(root.currentSql)
                            } else if (delegateItem7.index === 1) {
                                text = "```sql\n" + root.currentSql + "\n```"
                            } else {
                                text = root.currentSql
                            }
                            _toaster.copyToClipboard(text)
                            _toaster.show("Copied to clipboard.", Toaster.Type.Success)
                        }
                    }
                }
            }
        }
    }

    DatabaseWindow     { id: _dbWindow }
    SchemaGraphWindow  { id: _schemaGraphWindow }
    SchemaDiffWindow   { id: _schemaDiffWindow }
    SchemaSnapshotsWindow { id: _schemaSnapshotsWindow }
    TableStatsPopup    { id: _tableStatsPopup }
    TableDdlPopup      { id: _tableDdlPopup }

    ConfirmDialog {
        id:            _wsDeleteConfirm
        dialogTitle:   "Delete workspace"
        confirmText:   "Delete"
        isDestructive: true
        onConfirmed:   WorkspaceManager.deleteWorkspace(root.workspaceId)
    }

    WorkspaceFormDialog {
        id: _wsFormDialog
        anchors.fill: parent
        onDone: (id) => {
            // Refresh local mirrors: a rename or membership change may target the
            // currently loaded workspace; a create is switched into.
            if (_wsFormDialog.mode === "create") {
                root.loadWorkspace(id)
            } else if (id === root.workspaceId) {
                const ws = WorkspaceManager.workspace(id)
                root.workspaceName     = ws.name ?? root.workspaceName
                root.workspaceConnections = ws.connections ?? []
                root._adoptIfUnassigned(root._firstUsableConnection())
            }
        }
    }

    LogWindow {
        id: _logWindow
        onOpenSqlInEditor: (sql) => queryEditor.setSql(sql)
    }

    AiCommandPalette {
        id:      _aiPalette
        anchors.fill: parent
        dialect: root._aiDialect
        onPromptSubmitted: (payload) => {
            root._aiMode = ""
            if (payload.startsWith("__insert__:"))
                queryEditor.insertAtCursor(payload.substring(11))
            else if (payload.startsWith("__replace__:"))
                queryEditor.setSql(payload.substring(12))
        }
    }
    QueryParamsDialog  {
        id: _queryParamsDialog
        onAccepted: (filledSql) => {
            // Remember the entered values for this tab so the dialog prefills.
            const pm = Object.assign({}, root._tabParamValuesMap)
            pm[root._currentTabId] = Object.assign({}, _queryParamsDialog._values)
            root._tabParamValuesMap = pm

            if (_queryParamsDialog.purpose === "explain") {
                root._doExplain(filledSql, root._pendingExplainAnalyze)
            } else {
                root._executingSql = filledSql
                QueryExecutor.activeTabId = root._currentTabId
                QueryExecutor.execute(root.activeConnection, filledSql)
            }
        }
    }

    // Mahina's command launcher (Ctrl+P). Items carry a custom `id` that the
    // triggered() signal hands back verbatim, so _runCommand dispatches on it.
    CommandPalette {
        id:           _commandPalette
        model:        root._commands
        maxResults:   root._commands.length
        onTriggered:  (item) => root._runCommand(item.id)
    }

    Toaster { id: _toaster; anchors.fill: parent }

    KeyboardShortcutsPanel {
        id: _shortcutsPanel
        sections: [
            { heading: "Query", shortcuts: [
                { keys: ["Ctrl", "Enter"],       desc: "Run query (or selection)" },
                { keys: ["Ctrl", "E"],           desc: "EXPLAIN query" },
                { keys: ["Ctrl", "Shift", "F"],  desc: "Format SQL" },
                { keys: ["Ctrl", "O"],           desc: "Open .sql file" },
                { keys: ["Ctrl", "S"],           desc: "Save query to .sql file" },
                { keys: ["Ctrl", "Shift", "S"],  desc: "Save query as snippet" },
                { keys: ["Ctrl", "Shift", "E"],  desc: "Export results as CSV" },
                { keys: ["Ctrl", "Shift", "R"],  desc: "View selected row" },
            ]},
            { heading: "Editor", shortcuts: [
                { keys: ["Tab"],                desc: "Accept autocomplete" },
                { keys: ["Ctrl", "Z"],          desc: "Undo" },
                { keys: ["Ctrl", "Shift", "Z"], desc: "Redo" },
                { keys: ["Ctrl", "A"],          desc: "Select all" },
                { keys: ["Ctrl", "F"],          desc: "Find in editor" },
                { keys: ["Ctrl", "H"],          desc: "Find and replace" },
            ]},
            { heading: "Tabs", shortcuts: [
                { keys: ["Ctrl", "T"],        desc: "New query tab" },
                { keys: ["Ctrl", "W"],        desc: "Close current tab" },
            ]},
            { heading: "Panels", shortcuts: [
                { keys: ["Ctrl", "1"], desc: "Toggle schema panel" },
                { keys: ["Ctrl", "2"], desc: "Toggle query editor" },
                { keys: ["Ctrl", "3"], desc: "Toggle results" },
                { keys: ["Ctrl", "4"], desc: "Toggle sidebar" },
                { keys: ["Ctrl", "5"], desc: "Toggle markdown preview" },
                { keys: ["Ctrl", root._focusMod, "1"], desc: "Focus schema panel (again to restore)" },
                { keys: ["Ctrl", root._focusMod, "2"], desc: "Focus query editor" },
                { keys: ["Ctrl", root._focusMod, "3"], desc: "Focus results" },
                { keys: ["Ctrl", root._focusMod, "4"], desc: "Focus sidebar" },
                { keys: ["Ctrl", root._focusMod, "5"], desc: "Focus editor and preview" },
            ]},
            { heading: "Navigation", shortcuts: [
                { keys: ["Ctrl", "P"],      desc: "Command palette" },
                { keys: ["?"],              desc: "Show this panel" },
                { keys: ["Ctrl", "L"],      desc: "Toggle activity log" },
            ]},
        ]
    }

    Shortcut { sequence: "Ctrl+1"; onActivated: root._togglePanel("schema")  }
    Shortcut { sequence: "Ctrl+2"; onActivated: root._togglePanel("query")   }
    Shortcut { sequence: "Ctrl+3"; onActivated: root._togglePanel("results") }
    Shortcut { sequence: "Ctrl+4"; onActivated: root._togglePanel("sidebar") }
    Shortcut { sequence: "Ctrl+5"; onActivated: root._togglePanel("preview") }

    // Focus one panel, and the same key again to get the layout back. The
    // Ctrl+Alt alias is for macOS: Qt maps Ctrl to Command there, and the
    // system claims Cmd+Shift+3 and Cmd+Shift+4 for screenshots before the
    // application is ever asked.
    Shortcut { sequences: ["Ctrl+Shift+1", "Ctrl+Alt+1"]; onActivated: root._soloPanel("schema")  }
    Shortcut { sequences: ["Ctrl+Shift+2", "Ctrl+Alt+2"]; onActivated: root._soloPanel("query")   }
    Shortcut { sequences: ["Ctrl+Shift+3", "Ctrl+Alt+3"]; onActivated: root._soloPanel("results") }
    Shortcut { sequences: ["Ctrl+Shift+4", "Ctrl+Alt+4"]; onActivated: root._soloPanel("sidebar") }
    Shortcut { sequences: ["Ctrl+Shift+5", "Ctrl+Alt+5"]; onActivated: root._soloPanel("preview") }

    Shortcut {
        sequence: "?"
        onActivated: _shortcutsPanel.show()
    }

    ConfirmDialog {
        id:            _confirmDialog
        anchors.fill:  parent
        dialogTitle:   "Confirm action"
        confirmText:   "Run anyway"
        isDestructive: true
        onConfirmed:   QueryExecutor.execute(root.activeConnection, root._executingSql)
    }

    // SQL arriving via the qub:// URI scheme is attacker-controllable (any
    // webpage can link to it), so it is never inserted silently.
    ConfirmDialog {
        id:            _externalSqlDialog
        anchors.fill:  parent
        dialogTitle:   "Insert SQL from external link?"
        confirmText:   "Insert into editor"
        isDestructive: true
        onConfirmed:   queryEditor.setSql(root.initialSql)
    }

}
