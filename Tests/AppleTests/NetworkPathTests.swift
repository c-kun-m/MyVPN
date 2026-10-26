import Foundation
import Network
import NetworkExtension
import XCTest
@testable import NPV

final class NetworkPathTests: XCTestCase {
    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["NPV_RUN_NETWORK_TESTS"] == "1" else {
            throw XCTSkip("Requires explicit opt-in, a signed physical iPhone, an active NPV tunnel and the lab fixture server.")
        }
        let all = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[NETunnelProviderManager], Error>) in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: managers ?? []) }
            }
        }
        let providerID = try AppEnvironment.providerBundleID
        guard all.contains(where: { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerID && $0.connection.status == .connected }) else {
            XCTFail("Network tests opted in but NPV is not connected.")
            throw ProbeError.noActiveTunnel
        }
    }
    func testTCPIPv4() async throws { try await echo(host: "10.77.0.1", udp: false) }
    func testTCPIPv6() async throws { try await echo(host: "fd77::1", udp: false) }
    func testUDPIPv4() async throws { try await echo(host: "10.77.0.1", udp: true) }
    func testUDPIPv6() async throws { try await echo(host: "fd77::1", udp: true) }
    func testSystemDNSAThenTCP() async throws { try await echo(host: "npv-v4.test", udp: false) }
    func testSystemDNSAAAAThenTCP() async throws { try await echo(host: "npv-v6.test", udp: false) }

    private func echo(host: String, udp: Bool) async throws {
        let marker = Data("NPV/1 \(UUID().uuidString)\n".utf8)
        let parameters = udp ? NWParameters.udp : NWParameters.tcp
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: udp ? 9000 : 8080)!, using: parameters)
        let queue = DispatchQueue(label: "NPV.NetworkProbe")
        let received: Data = try await withCheckedThrowingContinuation { continuation in
            let result = ProbeReply(continuation: continuation, connection: connection)
            queue.asyncAfter(deadline: .now() + 8) { result.complete(.failure(ProbeError.timeout)) }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: marker, completion: .contentProcessed { error in
                        if let error { result.complete(.failure(error)); return }
                        if udp {
                            connection.receiveMessage { data, _, _, error in
                                if let error { result.complete(.failure(error)) }
                                else { result.complete(.success(data ?? Data())) }
                            }
                        } else {
                            connection.receive(minimumIncompleteLength: marker.count, maximumLength: marker.count) { data, _, _, error in
                                if let error { result.complete(.failure(error)) }
                                else { result.complete(.success(data ?? Data())) }
                            }
                        }
                    })
                case .failed(let error): result.complete(.failure(error))
                default: break
                }
            }
            connection.start(queue: queue)
        }
        XCTAssertEqual(received, marker, "The controlled server must return this request's exact nonce.")
    }
}

private enum ProbeError: Error { case timeout, noActiveTunnel }
private final class ProbeReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private let connection: NWConnection
    init(continuation: CheckedContinuation<Data, Error>, connection: NWConnection) { self.continuation = continuation; self.connection = connection }
    func complete(_ value: Result<Data, Error>) {
        lock.lock(); let current = continuation; continuation = nil; lock.unlock()
        guard let current else { return }
        connection.stateUpdateHandler = nil
        connection.cancel()
        current.resume(with: value)
    }
}
