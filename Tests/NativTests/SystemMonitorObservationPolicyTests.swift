import XCTest

final class SystemMonitorObservationPolicyTests: XCTestCase {
    func testSamplingStartsForFirstObserverAndStopsAfterLastObserver() {
        var policy = SystemMonitorObservationPolicy()
        let first = UUID()
        let second = UUID()

        XCTAssertTrue(policy.begin(first))
        XCTAssertFalse(policy.begin(second))
        XCTAssertFalse(policy.end(first))
        XCTAssertTrue(policy.end(second))
    }

    func testDuplicateObservationEventsAreIdempotent() {
        var policy = SystemMonitorObservationPolicy()
        let observer = UUID()

        XCTAssertTrue(policy.begin(observer))
        XCTAssertFalse(policy.begin(observer))
        XCTAssertTrue(policy.end(observer))
        XCTAssertFalse(policy.end(observer))
    }

    func testPausedObservationRestartsOnlyWhenAnObserverRemains() {
        var policy = SystemMonitorObservationPolicy()
        let observer = UUID()

        XCTAssertTrue(policy.begin(observer))
        XCTAssertTrue(policy.pause())
        XCTAssertFalse(policy.pause())
        XCTAssertTrue(policy.resume())

        XCTAssertTrue(policy.pause())
        XCTAssertFalse(policy.end(observer))
        XCTAssertFalse(policy.resume())
    }
}
