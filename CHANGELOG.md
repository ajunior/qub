# Changelog

All notable changes to qub are documented here.

Entry prefixes: **New** (new feature), **Feat** (new capability on an existing
feature), **Fix** (bug fix), **Break** (breaking change), **Docs**.

## 0.44.10

A patch on the first public release: four things that were visible the moment
you opened it.

- **Fix** A date column reads `2026-08-28 21:00:00` instead of
  `Fri Aug 28 21:0…`. Qt renders a timestamp as `Fri Aug 28 21:00:00 2026` by
  default — 24 characters that lead with the one field nobody scans for, wide
  enough to elide in a column that would otherwise have fit. The cost was not
  the width, though: the grid sorts a non-numeric column as text, so a date
  column came out ordered by weekday name — every Friday before every Monday,
  every August before every February — and typing `2026-08` into the filter
  matched nothing, because that string does not appear anywhere in what was
  being compared. The grid, the filter, the sort key, a copied cell or row and
  every export now read one function, so all of them agree with what is on
  screen; a time keeps `HH:mm:ss`, and a timestamp shows milliseconds only when
  it has any
- **Fix** The Y axis of a chart prints labels that are actually different
  numbers. It drew five gridlines at fixed quarters of the tallest value and
  rounded every caption to a whole number, so a result peaking at 2 put its
  lines at 0, 0.5, 1, 1.5 and 2 and labelled them 0, 1, 1, 2, 2 — the same
  number twice, against gridlines at different heights, on any peak that is not
  a multiple of four. The step is chosen first now and snapped to a 1-2-5
  figure, so the axis runs in increments a reader recognises
- **Fix** The Pivot pane's value picker stays inside the pane. Its row of
  controls could not fit the width it was given once the History panel was
  open, and nothing in it was allowed to shrink, so the surplus ran off the
  right edge and took the picker with it — the control you need for every
  aggregation except Count
- **Fix** The Pivot pane no longer flickers a row of empty headers each time a
  new result arrives. The column pickers still hold the previous result's
  columns for the instant the new one lands, and the pivot built from them was
  empty — but empty and *absent* are different things, and the pane could not
  tell them apart, so it drew the empty one

## 0.44.9

The first public release of qub.

- **Feat** Pointing at a table opens it in a tab of its own, named after it.
  Browsing `flights` from the schema panel gives you a tab called `flights`,
  and following a foreign key gives you one called `aircrafts` — instead of
  replacing the query you were in the middle of writing, and instead of a strip
  reading "Query 2 | Query 3 | Query 4", which told you only how many times you
  had asked something. A name another tab already answers to is left alone
  rather than repeated, and double-clicking a tab still renames it by hand. The
  browse runs through the same path the Run button does, so the grid is
  editable for a single-table browse, the connection's safety profile is
  consulted, and the row limit is applied with the marker that lets a full
  export strip it back off
- **Feat** A result column can be fitted to what is actually in it: double-click
  the edge of a header, or right-click the header for **Fit "column" to
  contents**, **Fit all columns to contents** and **Reset column widths**.
  Columns otherwise split the grid evenly and stay there, which gives a column
  of two-letter status codes the same room as one holding a timestamp — half
  the cell padding, the other half elided into `...`. A fit reads the first 500
  rows and stops at 600 px, so one cell holding a page of JSON cannot push
  every column after it off the screen
- **Feat** A schema draws itself as a graph of its tables and the foreign keys
  between them, from that row's `···` menu in the browser. It pans by dragging
  and zooms on the wheel, with `−` / `+` / `Fit` buttons in its header, and
  labels appear once the tables have room to carry one, so a crowded graph
  shows plain nodes and zooming in reveals the names. Above 150 tables it says
  so instead of drawing, and offers to draw only the tables that do have
  foreign keys where those fit: the layout compares every table against every
  other one on the GUI thread, and on a 754-table database that is seconds of
  frozen window around a ring of labels nobody could read
- **Feat** `Copy name` in the schema browser: on a table row's `···` menu, and
  on a schema row, which now has a menu of its own. Copying a table name meant
  running the table and lifting the name back out of the SQL qub had written.
  The table name arrives qualified with its schema exactly where an unqualified
  one would resolve against a different table — the rule the browse button
  already follows
- **Feat** The status bar names the database and the schema a statement is about
  to run against — `PostgreSQL | sctai_platform_study_db | public` — in place of
  the connection's name, which the picker two rows up was already showing. The
  name is a label you chose; it cannot tell you which `orders` you are about to
  touch, and on a connection whose `search_path` has moved it says nothing at
  all. Both are asked of the server rather than read off the saved connection,
  so a `SET search_path` or a `USE` updates them. The schema gets an icon of its
  own instead of borrowing the database's, and is shown only where a schema is a
  different thing from a database: MySQL and SQLite would have repeated the
  database name under a second label
- **Feat** Double-clicking a schema in the browser inserts its name in the
  editor, and a table outside the default schema is now qualified with it —
  both when double-clicked and when its browse button runs a query. The tree
  could show you every schema and only query one: an unqualified name resolves
  against exactly one of them (`search_path` in PostgreSQL, the current
  database in MySQL), so browsing `analytics.users` ran `SELECT * FROM users`
  and failed on a table `public` does not have. Qualified only where the
  connection exposes more than one schema, so SQLite never grows a `"main".`
  prefix
- **Feat** The Output console is one selectable text buffer instead of a list
  of rows, and a statement takes two stamped lines: the SQL at the moment it
  was sent, the outcome at the moment it came back. Rows could only ever hand
  you a row at a time — a console you can drag a cursor through copies the
  three lines you want as readily as the whole session, which is the thing
  people go to a console for. Right-click adds Copy, Select all and Copy
  console. The stamp on the statement is a real one: `QueryExecutor` now
  records when the statement went out, rather than the console dating it by
  the moment it finished
- **Feat** `Settings → Editor → Keyword case in generated SQL` chooses between
  `SELECT * FROM users` and `select * from users` for the SQL qub writes for
  you — a table's browse button, a double-clicked table, a foreign-key jump.
  Everyone types SQL in one case and reads a pasted line in the other as
  somebody else's. It touches keywords only: an identifier keeps the case the
  database gave it, since lowercasing `Users` would name a different table on
  a case-sensitive server. Upper is the default
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

- **New** qub is a SQL editor for people who work in SQL all day and want the
  editor out of the way: the query is the centre of the window, and everything
  else is a keystroke from it rather than a menu dive.
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
    command palette that reaches every action in the workspace. A tab opened
    from a `.sql` file stays bound to it — Ctrl+S writes back to that file with
    no dialog, and the tab marks whether what you are looking at still matches
    what is on disk.
  - **Reading results** — the same result set opens as a grid, a chart, a
    per-column profile, a pivot table, a query plan, a set of data-quality
    checks, or a diff against an earlier run — and the panes you never reach
    for switch off, so the tab bar carries only what you use. Cells and whole
    rows expand into a reader, and a foreign key opens the rows it points at
    in a new tab.
    The row limit says so when it actually cut a result, rather than letting a
    partial answer read as the whole one. Exports go out as CSV, TSV, JSON,
    Excel, Markdown or SQL `INSERT`s, and are never truncated to what the grid
    happens to be displaying. Every statement also leaves a stamped line in the
    connection's Output console — `84 rows retrieved in 1 m 10 s 542 ms
    (execution: 1 m 9 s 980 ms, fetching: 530 ms)` — that copies out together
    with the statement above it, which is what you paste back to whoever asked
    you to run it.
  - **Around the database** — searchable history of everything you have run,
    droppable one entry at a time or all at once, with slow-query aggregation
    by fingerprint; named snippets; workspaces that restore their own tabs and
    restrict themselves to the connections you allow; live database metrics
    with threshold alerts; schema snapshots and schema-to-schema comparison; a
    token-protected link that streams a live result set to any browser on your
    network, saying plainly how far it reaches and whether it is encrypted; and
    four themes with a fully editable palette, light or dark or following
    whichever one the desktop is on. Every one of those saved lists —
    connections, SSH configurations, workspaces, snippets — searches and sorts,
    each remembering the key and direction you left it on.
  - **Installing** — the macOS DMG is signed with a Developer ID certificate,
    notarized by Apple and stapled, so it opens with two clicks and no trip
    through System Settings, offline included. It also carries a MySQL driver
    compiled for it, which Qt does not ship for macOS at all. The Windows
    installer and the Linux AppImage are unsigned; SmartScreen warns once on
    Windows.
