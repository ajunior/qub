#pragma once

#include <QString>

class DatabaseAdapter;

// The single thing QueryExecutor needs from ConnectionManager: resolve a
// connection name to its open adapter. Extracting it as an interface lets the
// executor be driven by a fake in tests, instead of pulling the whole
// ConnectionManager (and with it the OS keychain and SSH stack) into scope.
class AdapterProvider {
public:
    virtual ~AdapterProvider() = default;
    virtual DatabaseAdapter *adapter(const QString &name) const = 0;
};
