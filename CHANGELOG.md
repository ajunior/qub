# Changelog

All notable changes to qub are documented here.

Entry prefixes: **New** (new feature), **Feat** (new capability on an existing
feature), **Fix** (bug fix), **Break** (breaking change), **Docs**.

## Unreleased

- **Fix** Typing one dot too many no longer makes the completion popup ask a
  null for its columns. It never showed anything wrong — it stopped mid-refresh
  and left the previous suggestions on screen
- **Feat** A live share can end by itself. `Settings → Sharing → Stop sharing
  after` takes a number of minutes; the toolbar counts down, warns a minute out
  and says so when the session closes. The failure mode of live share was never
  starting it by accident — it was forgetting it was on, and a share that ends
  on its own needs nobody to remember it. 0, the default, keeps the old
  behaviour of running until stopped
- **Feat** A profile can forbid live share on the connections that carry it.
  Turning off `Allow Live Share` disables the button on those connections, and
  stops a session already running the moment you switch to one. It is a guard
  against inattention rather than against the person — anyone who can turn it
  off can also edit the profile — and it closes the case where the share is
  already up, you switch tabs to check something, and the tab is production
- **Feat** The ring that pulses around the Live Share button while a session
  runs can be switched off. The button is red and reads "Stop Live Share"
  either way, so the pulse was reinforcement, not the only signal

- **New** First public release. qub is a SQL editor for people who work in SQL
  all day and want the editor out of the way: the query is the centre of the
  window, and everything else is a keystroke from it rather than a menu dive.
  - **Connections** — PostgreSQL, MySQL/MariaDB, SQLite, Oracle, Firebird and
    ODBC, open simultaneously, each tab carrying its own. Passwords go to the
    OS keychain, never to disk. Reusable SSH tunnel definitions, each testable
    on its own, and per-connection TLS. Named safety profiles (read-only,
    destructive-query guards) assigned per connection. A running database
    container can fill the connection form in for itself, host-mapped port
    included.
  - **Writing SQL** — completion that knows the columns of the tables actually
    in scope, through aliases; `:name` and `$1` parameters that prompt for
    typed values and remember them per tab; SQL generated from plain language
    against the live schema and dialect (Anthropic, OpenAI or a local Ollama);
    `/* @md */` blocks that turn a query file into a literate document; and a
    command palette that reaches every action in the workspace.
  - **Reading results** — the same result set opens as a grid, a chart, a
    per-column profile, a pivot table, a query plan, a set of data-quality
    checks, or a diff against an earlier run. Cells and whole rows expand into
    a reader, and a foreign key opens the rows it points at in a new tab.
    The row limit says so when it actually cut a result, rather than letting a
    partial answer read as the whole one. Exports go out as CSV, TSV, JSON,
    Excel, Markdown or SQL `INSERT`s, and are never truncated to what the grid
    happens to be displaying. Every statement also leaves a stamped line in the
    connection's Output console — `84 rows retrieved in 1 m 10 s 542 ms
    (execution: 1 m 9 s 980 ms, fetching: 530 ms)` — that copies out together
    with the statement above it, which is what you paste back to whoever asked
    you to run it.
  - **Around the database** — searchable history of everything you have run,
    with slow-query aggregation by fingerprint; named snippets; workspaces that
    restore their own tabs and restrict themselves to the connections you
    allow; live database metrics with threshold alerts; schema snapshots and
    schema-to-schema comparison; a token-protected link that streams a live
    result set to any browser on your network; and four themes with a fully
    editable palette. Every one of those saved lists — connections, SSH
    configurations, workspaces, snippets — searches and sorts, each remembering
    the key and direction you left it on.
  - **Installing** — the macOS DMG is signed with a Developer ID certificate,
    notarized by Apple and stapled, so it opens with two clicks and no trip
    through System Settings, offline included. The Windows installer and the
    Linux AppImage are unsigned; SmartScreen warns once on Windows.
