#if DEBUG && targetEnvironment(simulator)
import CryptoKit
import Foundation
import NPVCore
import Combine

enum SimulationScenario: String, CaseIterable, Identifiable {
    case normal, timeout, startFailure, saveDenied, keyUnavailable, noHandshake, recovery
    var id: String { rawValue }
    var title: String {
        switch self {
        case .normal: "正常连接"
        case .timeout: "连接超时"
        case .startFailure: "隧道启动失败"
        case .saveDenied: "保存被拒绝"
        case .keyUnavailable: "密钥不可读取"
        case .noHandshake: "启动但没有握手"
        case .recovery: "连接后恢复"
        }
    }
}

/// Session-only fixtures: no real VPN preferences, Keychain or App Group access.
@MainActor
final class SimulationSession: ObservableObject, IdentityStore, DiagnosticStore {
    @Published var scenario: SimulationScenario
    private var identity: DeviceIdentity?
    private var event: DiagnosticEvent?
    init(scenario: SimulationScenario = .normal) { self.scenario = scenario }
    func load() throws -> DeviceIdentity? {
        guard scenario != .keyUnavailable else { throw EnvironmentError.keychain(-25308) }
        return identity
    }
    func createIfMissing() throws -> DeviceIdentity {
        if let saved = try load() { return saved }
        let value = DeviceIdentity(id: UUID(), privateKey: Curve25519.KeyAgreement.PrivateKey().rawRepresentation)
        identity = value
        return value
    }
    func persistentReference() throws -> Data {
        guard try load() != nil else { throw EnvironmentError.missingIdentity }
        return Data("simulation-reference-only".utf8)
    }
    func saveProfile(_ profile: TunnelProfile) throws {}
    func saveEvent(_ event: DiagnosticEvent) throws { self.event = event }
    func loadEvent() throws -> DiagnosticEvent? { event }
}

@MainActor
final class SimulatedTunnelBackend: TunnelBackend {
    var onStateChange: (() -> Void)?
    private(set) var state: TunnelState = .unconfigured
    var isEnabled: Bool { profile != nil }
    private var profile: TunnelProfile?
    private let session: SimulationSession
    private var transition: Task<Void, Never>?
    private var generation = UUID()
    private var samples: UInt64 = 0
    private var handshake: UInt64?

    init(session: SimulationSession) { self.session = session }
    deinit { transition?.cancel() }
    func loadConfiguration() async throws -> TunnelProfile? { profile }
    func save(_ profile: TunnelProfile, identityReference: Data) async throws {
        guard session.scenario != .saveDenied else { throw ControllerError.authorizationDenied }
        try profile.validate()
        self.profile = profile
        update(.disconnected)
    }
    func start(attemptID: UUID) throws {
        guard profile != nil else { throw ControllerError.noConfiguration }
        guard session.scenario != .startFailure else { throw TunnelFault.backendStartFailed }
        transition?.cancel()
        let token = UUID(); generation = token
        let scenario = session.scenario
        samples = 0; handshake = nil
        update(.connecting)
        guard scenario != .timeout else { return }
        transition = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard let self, self.generation == token, !Task.isCancelled else { return }
            self.handshake = scenario == .noHandshake ? nil : UInt64(Date().timeIntervalSince1970)
            self.update(.connected)
            if scenario == .recovery {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard self.generation == token, !Task.isCancelled else { return }
                self.update(.reasserting)
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard self.generation == token, !Task.isCancelled else { return }
                self.handshake = UInt64(Date().timeIntervalSince1970)
                self.update(.connected)
            }
        }
    }
    func stop() {
        generation = UUID(); transition?.cancel(); transition = nil
        handshake = nil; samples = 0
        update(profile == nil ? .unconfigured : .disconnected)
    }
    func statistics() async -> RuntimeStats? {
        guard state == .connected else { return nil }
        samples += 1
        return RuntimeStats(receivedBytes: handshake == nil ? 0 : samples * 4096,
                            sentBytes: samples * 1024, lastHandshakeUnixSeconds: handshake)
    }
    private func update(_ state: TunnelState) { self.state = state; onStateChange?() }
}
#endif
