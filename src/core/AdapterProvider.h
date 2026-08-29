#pragma once

#include <QString>
#include <QtGlobal>

class DatabaseAdapter;

// What QueryExecutor needs from ConnectionManager: resolve a connection name
// to its open adapter, and tell it when a statement may have invalidated what
// it knows about that connection. Extracting it as an interface lets the
// executor be driven by a fake in tests, instead of pulling the whole
// ConnectionManager (and with it the OS keychain and SSH stack) into scope.
class AdapterProvider {
public:
    virtual ~AdapterProvider() = default;
    virtual DatabaseAdapter *adapter(const QString &name) const = 0;

    // Told after a statement that could have changed `name`'s schema, so
    // memoised introspection for it is dropped. Default no-op: the fake in the
    // executor tests has no cache to drop.
    virtual void invalidateMetadata(const QString &name) { Q_UNUSED(name) }
};
