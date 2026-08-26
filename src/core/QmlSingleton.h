#pragma once

#include <QtQml/qqml.h>
#include <QJSEngine>

class QQmlEngine;

// Declares a C++ object that main() owns as a QML singleton.
//
// These were context properties. A context property is dynamically scoped and
// carries no type, so qmlcachegen and qmllint cannot resolve anything reached
// through one: every binding that touches it drops out of ahead-of-time
// compilation and shows up as an "unqualified access" warning. Declaring the
// type instead puts it in the module's type information, where both tools find
// it.
//
// The instances are built in main() in dependency order and outlive the engine,
// so the engine must be handed the existing object rather than allowed to make
// one of its own. That is why the registration goes through a QML_FOREIGN
// wrapper instead of living on the class: qqmlprivate.h's
// singletonConstructionMode() tests std::is_default_constructible BEFORE it
// looks for a create() factory, and every manager here takes
// `QObject *parent = nullptr`. Declared in-class, the engine would silently
// pick Constructor mode and `new` a second instance, leaving QML talking to an
// object main() never wired up. A wrapper type wins that race: FactoryWrapper
// mode is tested first.
//
// Place after Q_OBJECT; the macro leaves the class in a private section, so
// follow it with the access specifier the rest of the class needs.
#define QUB_QML_SINGLETON(Class)                                                \
public:                                                                        \
    static void setInstance(Class *inst) { s_instance = inst; }                \
    static Class *qmlInstance()                                                \
    {                                                                          \
        Q_ASSERT_X(s_instance, #Class "::qmlInstance",                         \
                   "setInstance() was not called before QML loaded");          \
        QJSEngine::setObjectOwnership(s_instance, QJSEngine::CppOwnership);    \
        return s_instance;                                                     \
    }                                                                          \
                                                                               \
private:                                                                       \
    inline static Class *s_instance = nullptr;

// Pairs with QUB_QML_SINGLETON. Place at file scope after the class body.
#define QUB_QML_SINGLETON_FOREIGN(Class)                                       \
    struct Class##Foreign                                                      \
    {                                                                          \
        Q_GADGET                                                               \
        QML_FOREIGN(Class)                                                     \
        QML_NAMED_ELEMENT(Class)                                               \
        QML_SINGLETON                                                          \
    public:                                                                    \
        static Class *create(QQmlEngine *, QJSEngine *)                        \
        {                                                                      \
            return Class::qmlInstance();                                       \
        }                                                                      \
    };
