#include "Startup.h"

Startup::Startup(QObject *parent)
    : QObject(parent)
{
}

QString Startup::sql() const
{
    return m_sql;
}

void Startup::setSql(const QString &sql)
{
    m_sql = sql;
}
