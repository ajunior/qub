#include "HelpManager.h"
#include <QDir>
#include <QFile>
#include <QStandardPaths>
#include <QDesktopServices>
#include <QUrl>

HelpManager::HelpManager(QObject *parent) : QObject(parent) {}

bool HelpManager::extract() {
    const QString tmp = QStandardPaths::writableLocation(QStandardPaths::TempLocation)
                        + "/qub";
    QDir().mkpath(tmp);
    m_extractedPath = tmp + "/help.html";

    QFile src(":/qt/qml/Qub/resources/docs/help.html");
    if (!src.open(QIODevice::ReadOnly))
        return false;

    QFile dst(m_extractedPath);
    dst.remove();
    if (!dst.open(QIODevice::WriteOnly))
        return false;

    dst.write(src.readAll());
    return true;
}

void HelpManager::openHelp() {
    if (extract())
        QDesktopServices::openUrl(QUrl::fromLocalFile(m_extractedPath));
}
