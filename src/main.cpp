#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQuickWindow>
#include <QQmlContext>
#include <QFontDatabase>
#include <QUrl>
#include <QUrlQuery>
#include <QStandardPaths>
#include <QDir>
#include <QFile>

#include <atomic>
#include <chrono>
#include <cstdio>

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

namespace {

// Startup trace — six timestamps and a printf, and only when asked for. It is
// compiled into the shipped binary on purpose: a number measured on a build
// nobody runs is a number about that build. QUB_STARTUP_TRACE turns it on,
// QUB_STARTUP_TRACE=exit also closes the window as soon as it has drawn once,
// which is what scripts/startup-trace.sh uses to take a sample.
//
// Every mark is microseconds since the zero, and the zero is QUB_STARTUP_T0
// when the caller supplies one — nanoseconds since the epoch, taken in the
// shell *before* exec, so that fork, exec and the dynamic linker land inside
// the number instead of before it. Left to itself the zero is the first
// statement of main(), which silently gives away the ~20 ms it takes to get
// there. That is also why the clock is the wall one: it is the only clock the
// shell and the process can both read.
class StartupTrace
{
public:
    StartupTrace()
        : m_on(qEnvironmentVariableIsSet("QUB_STARTUP_TRACE"))
        , m_quit(qgetenv("QUB_STARTUP_TRACE") == "exit")
    {
        if (!m_on)
            return;
        bool ok = false;
        const qint64 t0 = qEnvironmentVariable("QUB_STARTUP_T0").toLongLong(&ok);
        m_zero = (ok && t0 > 0) ? t0 / 1000 : nowUs();
    }

    bool enabled()   const { return m_on; }
    bool quitAfter() const { return m_quit; }

    // Safe to call from the render thread, which is where frameSwapped lives.
    void mark(const char *phase) const
    {
        if (!m_on)
            return;
        std::fprintf(stderr, "qub-startup %s %lld\n", phase,
                     static_cast<long long>(nowUs() - m_zero));
        std::fflush(stderr);
    }

private:
    static qint64 nowUs()
    {
        using namespace std::chrono;
        return duration_cast<microseconds>(system_clock::now().time_since_epoch()).count();
    }

    const bool m_on;
    const bool m_quit;
    qint64     m_zero = 0;
};

} // namespace

int main(int argc, char *argv[])
{
    const StartupTrace trace;

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
    trace.mark("qguiapplication");

    const QString fontBase = ":/qt/qml/Mahina/assets/fonts/";
    QFontDatabase::addApplicationFont(fontBase + "InterVariable.ttf");
    QFontDatabase::addApplicationFont(fontBase + "JetBrainsMonoVariable.ttf");
    QFontDatabase::addApplicationFont(fontBase + "Phosphor-Regular.ttf");
    QFontDatabase::addApplicationFont(fontBase + "Phosphor-Thin.ttf");
    QFontDatabase::addApplicationFont(fontBase + "Phosphor-Light.ttf");
    QFontDatabase::addApplicationFont(fontBase + "Phosphor-Bold.ttf");
    QFontDatabase::addApplicationFont(fontBase + "Phosphor-Fill.ttf");
    QFontDatabase::addApplicationFont(fontBase + "Phosphor-Duotone.ttf");
    trace.mark("fonts");

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
    trace.mark("objects");

    QQmlApplicationEngine engine;
    engine.loadFromModule("Qub", "Main");

    if (engine.rootObjects().isEmpty())
        return -1;
    trace.mark("engine");

    // The window is not the last word on startup — the first frame is, and it
    // is emitted on the render thread, so the mark is taken there directly
    // rather than queued back to this one, which would time the event loop.
    if (trace.enabled()) {
        if (auto *window = qobject_cast<QQuickWindow *>(engine.rootObjects().constFirst())) {
            QObject::connect(window, &QQuickWindow::frameSwapped, window, [&trace, &app] {
                static std::atomic<bool> drawn { false };
                if (drawn.exchange(true))
                    return;
                trace.mark("firstframe");
                if (trace.quitAfter())
                    QMetaObject::invokeMethod(&app, "quit", Qt::QueuedConnection);
            }, Qt::DirectConnection);
        }
    }

    return app.exec();
}
