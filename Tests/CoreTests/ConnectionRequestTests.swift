import Foundation
import XCTest
@testable import NPVCore

final class ConnectionRequestTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1000)

    func testInitialDisconnectedObservationDoesNotCancelStartDeadline() throws {
        var tracker = ConnectionRequestTracker()
        let token = try XCTUnwrap(tracker.begin(.connect, now: now))
        tracker.observe(.disconnected)
        XCTAssertEqual(tracker.request?.token, token)
        XCTAssertNil(tracker.begin(.connect, now: now))
        XCTAssertEqual(tracker.expire(token, now: now.addingTimeInterval(30)), .connect)
    }
    func testSuccessfulStartResolvesRequest() {
        var tracker = ConnectionRequestTracker()
        tracker.begin(.connect, now: now)
        tracker.observe(.connecting)
        tracker.observe(.connected)
        XCTAssertNil(tracker.request)
    }
    func testFailedStartResolvesAfterConnectingWasObserved() {
        var tracker = ConnectionRequestTracker()
        tracker.begin(.connect, now: now)
        tracker.observe(.connecting)
        tracker.observe(.disconnected)
        XCTAssertNil(tracker.request)
    }
    func testDisconnectSupersedesStartAndRejectsOldTimer() throws {
        var tracker = ConnectionRequestTracker()
        let first = try XCTUnwrap(tracker.begin(.connect, now: now))
        let stop = try XCTUnwrap(tracker.begin(.disconnect, now: now.addingTimeInterval(1)))
        XCTAssertNil(tracker.expire(first, now: now.addingTimeInterval(40)))
        tracker.cancel(first)
        XCTAssertEqual(tracker.request?.token, stop)
        XCTAssertEqual(tracker.request?.action, .disconnect)
    }
    func testDisconnectCannotBeOvertakenByConnect() {
        var tracker = ConnectionRequestTracker()
        tracker.begin(.disconnect, now: now)
        XCTAssertNil(tracker.begin(.connect, now: now))
        XCTAssertNil(tracker.begin(.disconnect, now: now))
        tracker.observe(.disconnecting)
        XCTAssertNotNil(tracker.request)
        tracker.observe(.disconnected)
        XCTAssertNil(tracker.request)
    }
    func testStopTimeoutIsBoundedAndNotPremature() throws {
        var tracker = ConnectionRequestTracker()
        let token = try XCTUnwrap(tracker.begin(.disconnect, now: now))
        XCTAssertNil(tracker.expire(token, now: now.addingTimeInterval(9)))
        XCTAssertEqual(tracker.expire(token, now: now.addingTimeInterval(10)), .disconnect)
        XCTAssertNil(tracker.expire(token, now: now.addingTimeInterval(11)))
    }
    func testInvalidConfigurationTerminatesPendingStart() {
        var tracker = ConnectionRequestTracker()
        tracker.begin(.connect, now: now)
        tracker.observe(.invalid)
        XCTAssertNil(tracker.request)
    }
    func testReassertingAcknowledgesAnEstablishedTunnel() {
        var tracker = ConnectionRequestTracker()
        tracker.begin(.connect, now: now)
        tracker.observe(.reasserting)
        XCTAssertNil(tracker.request)
    }
}
