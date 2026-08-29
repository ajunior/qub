#pragma once

#include <QObject>
#include "core/Types.h"

class DatabaseAdapter : public QObject {
    Q_OBJECT
public:
    explicit DatabaseAdapter(QObject *parent = nullptr) : QObject(parent) {}
    ~DatabaseAdapter() override = default;

    virtual bool        open(const ConnectionParams &params) = 0;
    virtual void        close()                              = 0;
    virtual bool        isOpen() const                       = 0;
    virtual QueryResult  execute(const QString &sql)          = 0;
    virtual QString      driverName() const                  = 0;
    virtual QString      connectionName() const              = 0;
    virtual QString      connectionId() const               = 0;
    virtual QStringList  tables() const                      = 0;
    virtual QVariantList columns(const QString &table) const = 0;
    // Primary-key column names for one table. Separate from schema() because
    // asking the whole database about every table is the expensive way to
    // learn one table's key.
    virtual QStringList  primaryKeys(const QString &table) const = 0;
    virtual QVariantList schema() const                      = 0;
    virtual QVariantList schemas() const                     = 0;

signals:
    void opened(const QString &name);
    void closed(const QString &name);
    void errorOccurred(const QString &message);
};
