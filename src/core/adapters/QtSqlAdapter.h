#pragma once

#include "DatabaseAdapter.h"
#include <QSqlDatabase>

class QtSqlAdapter : public DatabaseAdapter {
    Q_OBJECT
public:
    explicit QtSqlAdapter(QObject *parent = nullptr);
    ~QtSqlAdapter() override;

    bool        open(const ConnectionParams &params) override;
    void        close() override;
    bool        isOpen() const override;
    QueryResult  execute(const QString &sql)          override;
    QString      driverName() const                  override;
    QString      connectionName() const              override;
    QString      connectionId() const               override { return m_connectionId; }
    QStringList  tables() const                      override;
    QVariantList columns(const QString &table) const override;
    QStringList  primaryKeys(const QString &table) const override;
    QVariantList schema() const                      override;
    QVariantList schemas() const                     override;

private:
    QSqlDatabase     m_db;
    ConnectionParams m_params;
    QString          m_connectionId;
};
