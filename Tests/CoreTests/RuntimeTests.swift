import Foundation
import XCTest
@testable import NPVCore

final class RuntimeTests: XCTestCase {
    func testStatsStripSecretsAndEndpointMetadata() throws {
        let secret = String(repeating: "abcdef", count: 10)
        let raw = "private_key=\(secret)\npublic_key=abc\npreshared_key=\(secret)\nendpoint=203.0.113.9:51820\nrx_bytes=123\ntx_bytes=456\nlast_handshake_time_sec=1700000000\n"
        let stats = try XCTUnwrap(RuntimeStats.parse(raw))
        XCTAssertEqual(stats.receivedBytes, 123); XCTAssertEqual(stats.sentBytes, 456)
        XCTAssertEqual(stats.lastHandshakeUnixSeconds, 1_700_000_000)
        let encoded = String(decoding: try JSONEncoder().encode(stats), as: UTF8.self)
        for forbidden in [secret, "private_key", "preshared_key", "203.0.113.9", "endpoint"] { XCTAssertFalse(encoded.contains(forbidden)) }
    }
    func testNoHandshakeIsNotSuccessfulConnection() throws {
        let stats = try XCTUnwrap(RuntimeStats.parse("rx_bytes=0\ntx_bytes=0\nlast_handshake_time_sec=0\n"))
        XCTAssertNil(stats.lastHandshakeUnixSeconds)
    }
    func testAbsentHandshakeAllowedButNotInvented() throws {
        XCTAssertNil(try XCTUnwrap(RuntimeStats.parse("rx_bytes=5\ntx_bytes=10\n")).lastHandshakeUnixSeconds)
    }
    func testMissingCountersRejected() {
        for raw in ["", "rx_bytes=1", "tx_bytes=2", "private_key=secret"] { XCTAssertNil(RuntimeStats.parse(raw)) }
    }
    func testMalformedAndOverflowCountersRejected() {
        for value in ["-1", "+1", "1.5", " 1", "", "18446744073709551616", "1=2"] {
            XCTAssertNil(RuntimeStats.parse("rx_bytes=\(value)\ntx_bytes=0\n"), value)
        }
    }
    func testMaximumCounterDoesNotOverflow() {
        XCTAssertEqual(RuntimeStats.parse("rx_bytes=18446744073709551615\ntx_bytes=0")?.receivedBytes, UInt64.max)
    }
    func testDuplicatePeerCountersRejectedRatherThanMisattributed() {
        XCTAssertNil(RuntimeStats.parse("rx_bytes=1\ntx_bytes=2\nrx_bytes=3\ntx_bytes=4\n"))
    }
    func testOversizedRuntimeResponseRejected() {
        XCTAssertNil(RuntimeStats.parse(String(repeating: "x", count: 65_537)))
    }
    func testStatisticsSamplingTimeIsExplicit() {
        let date = Date(timeIntervalSince1970: 123)
        XCTAssertEqual(RuntimeStats.parse("rx_bytes=1\ntx_bytes=2", now: date)?.sampledAt, date)
    }
    func testProviderMessageValidation() throws {
        let data = try JSONEncoder().encode(ProviderMessage(request: .statistics))
        XCTAssertEqual(ProviderMessage.decode(data)?.request, .statistics)
        for invalid in ["{}", "{\"version\":2,\"request\":\"statistics\"}", "{\"version\":1,\"request\":\"privateKey\"}"] {
            XCTAssertNil(ProviderMessage.decode(Data(invalid.utf8)))
        }
        XCTAssertNil(ProviderMessage.decode(Data(repeating: 32, count: 257)))
    }
    func testDiagnosticEventContainsOnlyBoundedFaultAndAttempt() throws {
        let event = DiagnosticEvent(attemptID: UUID(), fault: .keyUnavailable)
        let data = try JSONEncoder().encode(event)
        XCTAssertEqual(try JSONDecoder().decode(DiagnosticEvent.self, from: data), event)
        XCTAssertLessThan(data.count, 512)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("privateKey"))
    }
    func testActiveStatesCannotEditConfiguration() {
        for state in [TunnelState.connecting, .connected, .reasserting, .disconnecting] { XCTAssertFalse(state.canEdit) }
        for state in [TunnelState.unconfigured, .disconnected, .invalid] { XCTAssertTrue(state.canEdit) }
    }
    func testStopAvailableWhileConnectingOrRecovering() {
        XCTAssertTrue(TunnelState.connecting.canStop)
        XCTAssertTrue(TunnelState.reasserting.canStop)
        XCTAssertFalse(TunnelState.disconnecting.canStop)
    }
    func testGateRejectsOverlappingOperations() throws {
        var gate = OperationGate()
        let token = try XCTUnwrap(gate.begin())
        XCTAssertTrue(gate.isBusy); XCTAssertNil(gate.begin())
        gate.finish(token); XCTAssertFalse(gate.isBusy)
    }
    func testLateCompletionCannotReleaseNewOperation() throws {
        var gate = OperationGate()
        let first = try XCTUnwrap(gate.begin()); gate.finish(first)
        let second = try XCTUnwrap(gate.begin()); gate.finish(first)
        XCTAssertTrue(gate.isBusy); XCTAssertNil(gate.begin())
        gate.finish(second); XCTAssertFalse(gate.isBusy)
    }
}
