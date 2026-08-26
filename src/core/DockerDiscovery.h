#pragma once

#include <QObject>
#include "QmlSingleton.h"
#include <QVariantList>
#include <QByteArray>

// Discover running Docker containers that expose a database on a published host
// port and offer their connection details to prefill a new connection.
//
// Discovery only — qub never starts, stops, or otherwise manages containers; it
// owns no lifecycle. When the `docker` CLI is absent or the daemon is
// unreachable, available() is false and discover() returns an empty list, so
// the UI can hide the affordance entirely.
//
// parseContainers() is pure (the `docker inspect` JSON in, candidates out) so
// the engine/port/env parsing is unit-tested without a live Docker daemon —
// mirrors the ExplainPlan / SchemaDiff extraction pattern.
class DockerDiscovery : public QObject {
    Q_OBJECT
    QUB_QML_SINGLETON(DockerDiscovery)

public:
    explicit DockerDiscovery(QObject *parent = nullptr);

    // True when a `docker` executable is on PATH. The UI hides the discover
    // button when this is false. Cache the result (PATH scan) rather than
    // binding to it.
    Q_INVOKABLE bool available() const;

    // Run `docker ps` + `docker inspect` and return one candidate map per
    // running database container that publishes a host port. Empty on any
    // failure (docker missing, daemon down, non-zero exit, no matching
    // containers). Each map:
    //   { name, image, driver (Qt SQL key), host, port (int),
    //     database, username, password }
    // `password` may be empty when the container exposes no password in its
    // env (trust auth, secret mount) — the caller should say so, not fail.
    Q_INVOKABLE QVariantList discover() const;

    // Pure parser: the JSON array printed by `docker inspect <ids…>` →
    // candidate list (same shape as discover()). Containers whose image is not
    // a supported engine, or that publish no host port for the engine's port,
    // are skipped.
    static QVariantList parseContainers(const QByteArray &inspectJson);
};

QUB_QML_SINGLETON_FOREIGN(DockerDiscovery)
