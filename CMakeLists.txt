cmake_minimum_required(VERSION 3.21)

project(qub VERSION 0.44.9 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

find_package(OpenSSL REQUIRED)

find_package(Qt6 6.4 REQUIRED COMPONENTS
    Core
    Quick
    QuickControls2
    QuickDialogs2
    Sql
    WebSockets
    HttpServer
    Network
    Concurrent
)

include(FetchContent)
FetchContent_Declare(
    qtkeychain
    GIT_REPOSITORY https://github.com/frankosterfeld/qtkeychain.git
    # Commit hash of tag 0.14.3 — pinned to a hash (not the tag) so a
    # re-pointed tag upstream cannot silently change what we build.
    GIT_TAG        38ff50766c7e4ec490fecb2d9939b7cdc4b74b8e
)
set(BUILD_TEST_APPLICATION OFF CACHE BOOL "" FORCE)
set(BUILD_WITH_QT6         ON  CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(qtkeychain)

# Mahina — the QML component library qub's UI is built on.
# https://github.com/ajunior/mahina
#
# A sibling checkout at ../mahina wins when it exists, so mahina and qub can be
# developed side by side; every other build takes the pinned published commit.
# Force the fetch with -DFETCHCONTENT_SOURCE_DIR_MAHINA= (empty).
set(MAHINA_EXTRAS OFF CACHE BOOL "" FORCE)

if(NOT DEFINED FETCHCONTENT_SOURCE_DIR_MAHINA
   AND EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/../mahina/CMakeLists.txt")
    get_filename_component(FETCHCONTENT_SOURCE_DIR_MAHINA
        "${CMAKE_CURRENT_SOURCE_DIR}/../mahina" ABSOLUTE)
endif()

FetchContent_Declare(
    mahina
    GIT_REPOSITORY https://github.com/ajunior/mahina.git
    # Commit hash of v0.45.13 — pinned to a hash (not a branch or tag) so a
    # re-pointed ref upstream cannot silently change what we build.
    GIT_TAG        9fb595a6fe623fa9fbbffe013904bc9640145804
)
FetchContent_MakeAvailable(mahina)

if(FETCHCONTENT_SOURCE_DIR_MAHINA)
    message(STATUS "Mahina: local checkout ${FETCHCONTENT_SOURCE_DIR_MAHINA}")
else()
    message(STATUS "Mahina: pinned commit from github.com/ajunior/mahina")
endif()

qt_add_executable(qub
    MACOSX_BUNDLE
    WIN32
    src/main.cpp
    src/core/AppSettings.cpp
    src/core/CredentialStore.cpp
    src/core/ProfileManager.cpp
    src/core/SshManager.cpp
    src/core/SshTunnel.cpp
    src/core/ConnectionManager.cpp
    src/core/QueryExecutor.cpp
    src/core/SqlUtils.cpp
    src/core/MarkdownDoc.cpp
    src/core/ResultModel.cpp
    src/core/ResultDiff.cpp
    src/core/CsvImporter.cpp
    src/core/DockerDiscovery.cpp
    src/core/HistoryManager.cpp
    src/core/HelpManager.cpp
    src/core/SnippetManager.cpp
    src/core/SchemaSnapshotManager.cpp
    src/core/HealthAlertManager.cpp
    src/core/ResultSnapshotManager.cpp
    src/core/WorkspaceManager.cpp
    src/core/SqlHighlighter.cpp
    src/core/ThemeManager.cpp
    src/core/LiveShareServer.cpp
    src/core/AiClient.cpp
    src/core/DatabaseInspector.cpp
    src/core/ExplainPlan.cpp
    src/core/SchemaDiff.cpp
    src/core/LogManager.cpp
    src/core/Startup.cpp
    src/core/adapters/DatabaseAdapter.cpp
    src/core/adapters/QtSqlAdapter.cpp
)

qt_policy(SET QTP0001 NEW)
qt_policy(SET QTP0004 NEW)
# Lets DEPENDENCIES take a CMake target rather than a bare URI, which is how
# Qt resolves the dependency's module directory (see DEPENDENCIES below).
qt_policy(SET QTP0005 NEW)

qt_add_qml_module(qub
    URI Qub
    VERSION 1.0
    # Declaring the dependency is what puts Mahina's module directory on the
    # import path Qt hands to qmlcachegen (Qt6QmlMacros builds qmlcachegen's -I
    # list purely from the QT_QML_IMPORT_PATH target property, which this fills
    # in). Without it the AOT compiler resolves no Mahina type and every binding
    # touching one falls back to the interpreter.
    DEPENDENCIES TARGET Mahina
    QML_FILES
        src/qml/drivers.js
        src/qml/format.js
        src/qml/guard.js
        src/qml/complete.js
        src/qml/fk.js
        src/qml/cellview.js
        src/qml/params.js
        src/qml/listsort.js
        src/qml/Main.qml
        src/qml/screens/WorkspaceScreen.qml
        src/qml/screens/HomeScreen.qml
        src/qml/components/SchemaTree.qml
        src/qml/components/ConnectionDialog.qml
        src/qml/components/ConnectionForm.qml
        src/qml/components/QueryEditor.qml
        src/qml/components/ResultsTable.qml
        src/qml/components/ThemeEditorForm.qml
        src/qml/components/DatabaseWindow.qml
        src/qml/components/SchemaGraphWindow.qml
        src/qml/components/SchemaDiffWindow.qml
        src/qml/components/SchemaSnapshotsWindow.qml
        src/qml/components/TableStatsPopup.qml
        src/qml/components/TableDdlPopup.qml
        src/qml/components/QueryParamsDialog.qml
        src/qml/components/AiCommandPalette.qml
        src/qml/components/LogWindow.qml
        src/qml/components/LogView.qml
        src/qml/components/ListToolbar.qml
        src/qml/components/SlowQueriesView.qml
        src/qml/components/WorkspaceFormDialog.qml
        src/qml/components/MarkdownPreview.qml
        src/qml/components/OutputConsole.qml
        src/qml/components/ChartView.qml
        src/qml/components/ProfilePanel.qml
        src/qml/components/ExplainView.qml
        src/qml/components/PivotView.qml
        src/qml/components/ExpectationsView.qml
        src/qml/components/DiffView.qml
        src/qml/components/CsvImportDialog.qml
    RESOURCES
        resources/live/index.html
        resources/docs/help.html
        assets/cube.svg
)

# src/core is on the path because qmltyperegistrar emits <Header.h> for every
# QML_ELEMENT class using the bare file name, without its directory.
target_include_directories(qub PRIVATE src src/core ${qtkeychain_SOURCE_DIR} ${qtkeychain_BINARY_DIR})

# Single source of truth for the version the app reports. It used to be a literal
# in main.cpp and two more in HomeScreen.qml, which is three places to forget on
# a release; QML reads it back through Qt.application.version.
target_compile_definitions(qub PRIVATE QUB_VERSION="${PROJECT_VERSION}")

target_link_libraries(qub
    PRIVATE
        Qt6::Core
        Qt6::Quick
        Qt6::QuickControls2
        Qt6::QuickDialogs2
        Qt6::Sql
        Qt6::WebSockets
        Qt6::HttpServer
        Qt6::Network
        Qt6::Concurrent
        qt6keychain
        Mahina
        Mahinaplugin
        OpenSSL::SSL
        OpenSSL::Crypto
)

qt_import_qml_plugins(qub)

# ── Tests ─────────────────────────────────────────────────────────────────────
enable_testing()
find_package(Qt6 REQUIRED COMPONENTS Test Qml)

qt_add_executable(qub_tests
    tests/tst_core.cpp
    src/core/SqlUtils.cpp
    src/core/MarkdownDoc.cpp
    src/core/ResultModel.cpp
    src/core/ResultDiff.cpp
    src/core/CsvImporter.cpp
    src/core/DockerDiscovery.cpp
    src/core/ExplainPlan.cpp
    src/core/SchemaDiff.cpp
    src/core/SchemaSnapshotManager.cpp
    src/core/HealthAlertManager.cpp
    src/core/ResultSnapshotManager.cpp
    src/core/HistoryManager.cpp
    src/core/LogManager.cpp
)
target_include_directories(qub_tests PRIVATE src src/core)
# guard.js is loaded from the source tree so the tests exercise the same file
# that ships in the QML module.
target_compile_definitions(qub_tests PRIVATE
    GUARD_JS_PATH="${CMAKE_CURRENT_SOURCE_DIR}/src/qml/guard.js"
    COMPLETE_JS_PATH="${CMAKE_CURRENT_SOURCE_DIR}/src/qml/complete.js"
    FK_JS_PATH="${CMAKE_CURRENT_SOURCE_DIR}/src/qml/fk.js"
    CELLVIEW_JS_PATH="${CMAKE_CURRENT_SOURCE_DIR}/src/qml/cellview.js"
    DRIVERS_JS_PATH="${CMAKE_CURRENT_SOURCE_DIR}/src/qml/drivers.js"
    PARAMS_JS_PATH="${CMAKE_CURRENT_SOURCE_DIR}/src/qml/params.js"
    LISTSORT_JS_PATH="${CMAKE_CURRENT_SOURCE_DIR}/src/qml/listsort.js")
target_link_libraries(qub_tests PRIVATE Qt6::Test Qt6::Qml Qt6::Sql)
add_test(NAME qub_tests COMMAND qub_tests)

qt_add_executable(qub_workspace_tests
    tests/tst_workspace.cpp
    src/core/WorkspaceManager.cpp
)
target_include_directories(qub_workspace_tests PRIVATE src src/core)
target_link_libraries(qub_workspace_tests PRIVATE Qt6::Test Qt6::Qml Qt6::Sql)
add_test(NAME qub_workspace_tests COMMAND qub_workspace_tests)

qt_add_executable(qub_snippet_tests
    tests/tst_snippets.cpp
    src/core/SnippetManager.cpp
)
target_include_directories(qub_snippet_tests PRIVATE src src/core)
target_link_libraries(qub_snippet_tests PRIVATE Qt6::Test Qt6::Qml Qt6::Sql)
add_test(NAME qub_snippet_tests COMMAND qub_snippet_tests)

# Query and connection error paths, tested at the QtSqlAdapter layer (the
# synchronous engine under QueryExecutor/ConnectionManager) so the assertions
# stay deterministic — no worker thread, no OS keychain.
qt_add_executable(qub_adapter_tests
    tests/tst_query.cpp
    src/core/adapters/QtSqlAdapter.cpp
    src/core/adapters/DatabaseAdapter.cpp
)
target_include_directories(qub_adapter_tests PRIVATE src src/core)
target_link_libraries(qub_adapter_tests PRIVATE Qt6::Test Qt6::Sql)
add_test(NAME qub_adapter_tests COMMAND qub_adapter_tests)

# QueryExecutor async orchestration (guards, error propagation, result
# plumbing, cancellation, full export) driven through a fake AdapterProvider,
# so no keychain/SSH stack is pulled in — only the query engine.
qt_add_executable(qub_executor_tests
    tests/tst_executor.cpp
    src/core/QueryExecutor.cpp
    src/core/ResultModel.cpp
    src/core/ResultDiff.cpp
    src/core/SqlUtils.cpp
    src/core/LogManager.cpp
    src/core/adapters/QtSqlAdapter.cpp
    src/core/adapters/DatabaseAdapter.cpp
)
target_include_directories(qub_executor_tests PRIVATE src src/core)
target_link_libraries(qub_executor_tests PRIVATE Qt6::Test Qt6::Qml Qt6::Sql Qt6::Concurrent)
add_test(NAME qub_executor_tests COMMAND qub_executor_tests)

# ── macOS bundle metadata ─────────────────────────────────────────────────────
if(APPLE)
    configure_file(packaging/macos/Info.plist.in
                   ${CMAKE_BINARY_DIR}/Info.plist @ONLY)

    # The icon has to be a real file inside Contents/Resources; a plist naming
    # one that was never generated is exactly how the app shipped with the
    # default macOS icon. MACOSX_PACKAGE_LOCATION puts it there.
    add_custom_command(
        OUTPUT  ${CMAKE_BINARY_DIR}/qub.icns
        COMMAND bash ${CMAKE_CURRENT_SOURCE_DIR}/packaging/macos/make-icns.sh
                     ${CMAKE_CURRENT_SOURCE_DIR}/assets/qub.png
                     ${CMAKE_BINARY_DIR}/qub.icns
        DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/assets/qub.png
                ${CMAKE_CURRENT_SOURCE_DIR}/packaging/macos/make-icns.sh
        COMMENT "Generating qub.icns"
        VERBATIM
    )
    target_sources(qub PRIVATE ${CMAKE_BINARY_DIR}/qub.icns)
    set_source_files_properties(${CMAKE_BINARY_DIR}/qub.icns PROPERTIES
        MACOSX_PACKAGE_LOCATION Resources)

    set_target_properties(qub PROPERTIES
        MACOSX_BUNDLE_INFO_PLIST "${CMAKE_BINARY_DIR}/Info.plist"
        MACOSX_BUNDLE_BUNDLE_NAME        "qub"
        MACOSX_BUNDLE_BUNDLE_VERSION     "${PROJECT_VERSION}"
        MACOSX_BUNDLE_SHORT_VERSION_STRING "${PROJECT_VERSION}"
        MACOSX_BUNDLE_GUI_IDENTIFIER     "dev.ajunior.qub"
        MACOSX_BUNDLE_ICON_FILE          "qub.icns"
    )
endif()

# ── Windows: embed version + icon resource ────────────────────────────────────
if(WIN32)
    # The icon is copied next to the generated qub.rc so the script can name it
    # with no path at all: rc.exe resolves a bare filename against its own
    # directory, and a backslash inside a quoted path is an escape character
    # there — a rule that is easy to get wrong and impossible to test off
    # Windows.
    configure_file(assets/qub.ico ${CMAKE_BINARY_DIR}/qub.ico COPYONLY)
    configure_file(packaging/windows/qub.rc.in
                   ${CMAKE_BINARY_DIR}/qub.rc @ONLY)
    target_sources(qub PRIVATE ${CMAKE_BINARY_DIR}/qub.rc)
endif()
