#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QFontDatabase>
#include <QUrl>
#include <QUrlQuery>
#include <QStandardPaths>
#include <QDir>
#include <QFile>

#include "core/AppSettings.h"
#include "core/CredentialStore.h"
#include "core/ConnectionManager.h"
#include "core/ProfileManager.h"
#include "core/SshManager.h"
#include "core/ThemeManager.h"
#include "core/QueryExecutor.h"
#include "core/HistoryManager.h"
#include "core/HelpManager.h"
#include "core/Startup.h"
#include "core/SnippetManager.h"
#include "core/SchemaSnapshotManager.h"
#include "core/HealthAlertManager.h"
#include "core/ResultSnapshotManager.h"
#include "core/WorkspaceManager.h"
#include "core/SqlHighlighter.h"
#include "core/LiveShareServer.h"
#include "core/AiClient.h"
#include "core/DatabaseInspector.h"
#include "core/LogManager.h"
#include "core/MarkdownDoc.h"
#include "core/CsvImporter.h"
#include "core/DockerDiscovery.h"

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);
    app.setOrganizationName("qub");
    app.setApplicationName("qub");
    app.setApplicationVersion(QStringLiteral(QUB_VERSION));

    // Query history, sessions and connection metadata live here — keep the
    // whole directory owner-only before any manager creates files in it.
    const QString dataDir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    QDir().mkpath(dataDir);
    QFile::setPermissions(dataDir, QFileDevice::ReadOwner | QFileDevice::WriteOwner |
                                   QFileDevice::ExeOwner);

    const QString fontBase = ":/qt/qml/Mahina/assets/fonts/";
    QFontDatabase::addApplicationFont(fontBase + "InterVariable.ttf");
    QFontDatabase::addApplicationFont(fontBase + "JetBrainsMonoVariable.ttf");
    QFontDatabase::addApplicationFont(fontBase + "Phosphor-Regular.ttf");
    QFontDatabase::addApplicationFont(fontBase + "Phosphor-Thin.ttf");
    QFontDatabase::addApplicationFont(fontBase + "Phosphor-Light.ttf");
    QFontDatabase::addApplicationFont(fontBase + "Phosphor-Bold.ttf");
    QFontDatabase::addApplicationFont(fontBase + "Phosphor-Fill.ttf");
    QFontDatabase::addApplicationFont(fontBase + "Phosphor-Duotone.ttf");

    CredentialStore      credentialStore;
    AppSettings          appSettings;
    ProfileManager       profileManager;
    SshManager           sshManager(&credentialStore);
    ThemeManager         themeManager;
    LogManager           logManager;
    ConnectionManager    connectionManager(&credentialStore, &sshManager, &logManager);
    QueryExecutor        queryExecutor(&connectionManager, &logManager);
    HistoryManager       historyManager;
    HelpManager          helpManager;
    SnippetManager       snippetManager;
    SchemaSnapshotManager schemaSnapshotManager;
    HealthAlertManager   healthAlertManager(&logManager);
    ResultSnapshotManager resultSnapshotManager;
    WorkspaceManager     workspaceManager;
    LiveShareServer      liveShareServer;
    AiClient             aiClient(&credentialStore, &logManager);
    DatabaseInspector    dbInspector(&connectionManager);
    MarkdownDoc          markdownDoc;
    CsvImporter          csvImporter;
    DockerDiscovery      dockerDiscovery;

    QObject::connect(&queryExecutor, &QueryExecutor::executionStarted,
                     &liveShareServer, &LiveShareServer::onExecutionStarted);
    QObject::connect(&queryExecutor, &QueryExecutor::executionFinished,
                     &liveShareServer, &LiveShareServer::onExecutionFinished);
    QObject::connect(&queryExecutor, &QueryExecutor::executionError,
                     &liveShareServer, &LiveShareServer::onExecutionError);
    QObject::connect(&queryExecutor, &QueryExecutor::resultsReady,
                     &liveShareServer, &LiveShareServer::onResultsReady);
    QObject::connect(&connectionManager, &ConnectionManager::connectionRenamed,
                     &workspaceManager, &WorkspaceManager::renameConnectionReferences);

    // Parse qub://query?sql=… from command-line argument (URI scheme launch)
    Startup  startup;
    QString startupSql;
    const QStringList args = QCoreApplication::arguments();
    for (int i = 1; i < args.size(); ++i) {
        if (args[i].startsWith("qub://")) {
            const QUrl url(args[i]);
            const QUrlQuery q(url.query());
            startupSql = QUrl::fromPercentEncoding(q.queryItemValue("sql").toUtf8());
            break;
        }
    }

    startup.setSql(startupSql);

    // Hand the engine the instances main() owns, before any QML loads.
    Startup::setInstance(&startup);
    HelpManager::setInstance(&helpManager);
    DockerDiscovery::setInstance(&dockerDiscovery);
    MarkdownDoc::setInstance(&markdownDoc);
    ResultSnapshotManager::setInstance(&resultSnapshotManager);
    SchemaSnapshotManager::setInstance(&schemaSnapshotManager);
    CsvImporter::setInstance(&csvImporter);
    HealthAlertManager::setInstance(&healthAlertManager);
    HistoryManager::setInstance(&historyManager);
    ProfileManager::setInstance(&profileManager);
    SshManager::setInstance(&sshManager);
    ThemeManager::setInstance(&themeManager);
    AiClient::setInstance(&aiClient);
    SnippetManager::setInstance(&snippetManager);
    DatabaseInspector::setInstance(&dbInspector);
    LogManager::setInstance(&logManager);
    WorkspaceManager::setInstance(&workspaceManager);
    LiveShareServer::setInstance(&liveShareServer);
    QueryExecutor::setInstance(&queryExecutor);
    ConnectionManager::setInstance(&connectionManager);
    AppSettings::setInstance(&appSettings);

    QQmlApplicationEngine engine;
    engine.loadFromModule("Qub", "Main");

    if (engine.rootObjects().isEmpty())
        return -1;

    return app.exec();
}
