#pragma once
#include <QObject>
#include <QString>
#include "QmlSingleton.h"

class HelpManager : public QObject {
    Q_OBJECT
    QUB_QML_SINGLETON(HelpManager)

public:
    explicit HelpManager(QObject *parent = nullptr);
    Q_INVOKABLE void openHelp();


private:
    QString m_extractedPath;
    bool extract();
};

QUB_QML_SINGLETON_FOREIGN(HelpManager)
