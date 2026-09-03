// Unit tests for the Live Share auto-stop countdown: that arming it is tied to
// a server that actually came up, that the number the toolbar shows counts
// down, and — the point of the whole thing — that reaching zero stops the
// session on its own.
//
// The server binds a real plaintext port on localhost. That is what start()
// does, and a countdown armed against a stubbed-out server would not be
// testing the code that ships.
//
// Run with: ctest --test-dir build  (or ./build/qub_liveshare_tests)

#include <QtTest>
#include <QSignalSpy>

#include "core/LiveShareServer.h"

class TestLiveShare : public QObject {
    Q_OBJECT

private slots:
    void noTimerByDefault();
    void armsAndCountsDown();
    void stopDisarms();
    void reachingZeroStopsTheShare();
    void failedStartArmsNothing();
};

void TestLiveShare::noTimerByDefault()
{
    LiveShareServer s;
    s.start(false, {}, {}, false, 0);
    QVERIFY(s.isActive());
    QCOMPARE(s.secondsLeft(), 0);

    // A share with no timer must still be there a couple of ticks later.
    QTest::qWait(2200);
    QVERIFY(s.isActive());
    QCOMPARE(s.secondsLeft(), 0);
    s.stop();
}

void TestLiveShare::armsAndCountsDown()
{
    LiveShareServer s;
    QSignalSpy spy(&s, &LiveShareServer::secondsLeftChanged);

    s.start(false, {}, {}, false, 30);
    QVERIFY(s.isActive());
    QCOMPARE(s.secondsLeft(), 30);
    QCOMPARE(spy.count(), 1);   // the arming itself is a change worth showing

    QTest::qWait(2200);
    // Two ticks have certainly landed; a third may have. Anything outside that
    // is a clock running at the wrong rate, which is the bug this catches.
    QVERIFY2(s.secondsLeft() == 28 || s.secondsLeft() == 27,
             qPrintable(QString("secondsLeft = %1").arg(s.secondsLeft())));
    QVERIFY(s.isActive());
    s.stop();
}

void TestLiveShare::stopDisarms()
{
    LiveShareServer s;
    s.start(false, {}, {}, false, 30);
    QCOMPARE(s.secondsLeft(), 30);

    s.stop();
    QVERIFY(!s.isActive());
    QCOMPARE(s.secondsLeft(), 0);

    // The countdown must not outlive the share it was counting: a stale timer
    // would fire into a stopped server and toast about a session nobody has.
    QTest::qWait(2200);
    QCOMPARE(s.secondsLeft(), 0);
}

void TestLiveShare::reachingZeroStopsTheShare()
{
    LiveShareServer s;
    QSignalSpy stopped(&s, &LiveShareServer::autoStopped);

    s.start(false, {}, {}, false, 2);
    QVERIFY(s.isActive());

    QVERIFY(stopped.wait(5000));
    QCOMPARE(stopped.count(), 1);
    QVERIFY(!s.isActive());
    QCOMPARE(s.secondsLeft(), 0);

    // And it stops once. A timer left running would keep re-firing on a
    // session that is already down.
    QTest::qWait(2200);
    QCOMPARE(stopped.count(), 1);
}

void TestLiveShare::failedStartArmsNothing()
{
    LiveShareServer s;
    QSignalSpy failed(&s, &LiveShareServer::startFailed);

    // LAN visibility without TLS is refused before anything binds.
    s.start(false, {}, {}, true, 30);
    QCOMPARE(failed.count(), 1);
    QVERIFY(!s.isActive());
    QCOMPARE(s.secondsLeft(), 0);
}

QTEST_GUILESS_MAIN(TestLiveShare)
#include "tst_liveshare.moc"
