#pragma once

#include <QSqlDatabase>

// Every manager — history, snippets, workspaces, logs, snapshots, alerts —
// opens the same SQLite file under its own connection name. So the schema
// version belongs to the file, not to any one of them, and there is exactly one
// number to keep.
//
// Nothing migrates yet, and nothing needs to: 0.44.9 is the first published
// shape. What it needs is for that shape to be identifiable, because the
// alternative is a later migration guessing at an old database with
// `pragma table_info` and guessing wrong in silence — which is the failure this
// stamp exists to make impossible.
namespace AppDatabase {

// The shape 0.44.9 ships. Bump it in the same commit that changes a table.
constexpr int kSchemaVersion = 1;

// The version recorded in the file, or 0 for a database written before there
// was any versioning.
int schemaVersion(const QSqlDatabase &db);

// Stamp the current version, but only on a database that has no tables yet.
//
// A database from before this existed also reads 0, and stamping it would be a
// lie: nobody recorded its shape, so nobody can claim it matches this one. 0
// has to keep meaning "unknown", or a future migration skips exactly the
// database that needed it. Called by each manager before it creates its tables;
// whichever one opens the file first does the stamping and the rest see a
// database that already has tables and leave it alone.
void stampIfNew(QSqlDatabase &db);

} // namespace AppDatabase
