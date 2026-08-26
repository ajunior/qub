#pragma once

#include <QObject>
#include <QString>
#include "QmlSingleton.h"

// Launch-time parameters, parsed from the qub:// URI the app was invoked with.
//
// This exists so nothing has to be a context property. A context property is
// untyped and dynamically scoped, so the one binding that read the startup SQL
// could not be resolved by qmlcachegen or qmllint; as a declared singleton with
// a real property, it can.
class Startup : public QObject {
    Q_OBJECT
    QUB_QML_SINGLETON(Startup)

    // Set once before QML loads and never changes.
    Q_PROPERTY(QString sql READ sql CONSTANT)

public:
    explicit Startup(QObject *parent = nullptr);

    QString sql() const;
    void setSql(const QString &sql);

private:
    QString m_sql;
};

QUB_QML_SINGLETON_FOREIGN(Startup)
