# Changelog

All notable changes to qub are documented here.

Entry prefixes: **New** (new feature), **Feat** (new capability on an existing
feature), **Fix** (bug fix), **Break** (breaking change), **Docs**.

## Unreleased

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
    Exports go out as CSV, TSV, JSON, Excel, Markdown or SQL `INSERT`s, and are
    never truncated to what the grid happens to be displaying.
  - **Around the database** — searchable history of everything you have run,
    with slow-query aggregation by fingerprint; named snippets; workspaces that
    restore their own tabs and restrict themselves to the connections you
    allow; live database metrics with threshold alerts; schema snapshots and
    schema-to-schema comparison; a token-protected link that streams a live
    result set to any browser on your network; and four themes with a fully
    editable palette.
