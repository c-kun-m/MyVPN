import Foundation
import NetworkExtension
import NPVCore

@MainActor
final class SystemTunnelBackend: TunnelBackend {
    var onStateChange: (() -> Void)?
    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.onStateChange?() }
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    var state: TunnelState {
        guard let manager else { return .unconfigured }
        switch manager.connection.status {
        case .invalid: return .invalid
        case .disconnected: return .disconnected
        case .connecting: return .connecting
        case .connected: return .connected
        case .reasserting: return .reasserting
        case .disconnecting: return .disconnecting
        @unknown default: return .invalid
        }
    }
    var isEnabled: Bool { manager?.isEnabled ?? false }

    func loadConfiguration() async throws -> TunnelProfile? {
        let bundleID = try AppEnvironment.providerBundleID
        let all = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[NETunnelProviderManager], Error>) in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: managers ?? []) }
            }
        }
        let own = all.filter { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == bundleID }
        guard own.count <= 1 else { throw ControllerError.duplicateConfigurations }
        manager = own.first
        guard let data = (manager?.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?["profile"] as? Data else { return nil }
        return try TunnelProfile.decode(data)
    }

    func save(_ profile: TunnelProfile, identityReference: Data) async throws {
        let config = NETunnelProviderProtocol()
        config.providerBundleIdentifier = try AppEnvironment.providerBundleID
        config.serverAddress = profile.endpoint.host
        config.providerConfiguration = ["profile": try profile.encoded()]
        config.passwordReference = identityReference
        config.disconnectOnSleep = false
        config.includeAllNetworks = true
        config.excludeLocalNetworks = false
        config.excludeAPNs = false
        config.excludeCellularServices = false
        let target = manager ?? NETunnelProviderManager()
        target.protocolConfiguration = config
        target.localizedDescription = "NPV · \(profile.name)"
        target.isEnabled = true
        target.isOnDemandEnabled = false
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            target.saveToPreferences { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            target.loadFromPreferences { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        manager = target
    }

    func start(attemptID: UUID) throws {
        guard let session = manager?.connection as? NETunnelProviderSession else { throw ControllerError.noConfiguration }
        try session.startTunnel(options: ["attemptID": attemptID.uuidString as NSString])
    }
    func stop() { manager?.connection.stopVPNTunnel() }

    func statistics() async -> RuntimeStats? {
        guard state == .connected, let session = manager?.connection as? NETunnelProviderSession,
              let message = try? JSONEncoder().encode(ProviderMessage(request: .statistics)) else { return nil }
        let data: Data? = await withCheckedContinuation { continuation in
            let reply = ProviderReply(continuation)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { reply.complete(nil) }
            do { try session.sendProviderMessage(message) { data in reply.complete(data) } }
            catch { reply.complete(nil) }
        }
        guard let data, data.count <= 2_048 else { return nil }
        return try? JSONDecoder().decode(RuntimeStats.self, from: data)
    }
}

private final class ProviderReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data?, Never>?
    init(_ continuation: CheckedContinuation<Data?, Never>) { self.continuation = continuation }
    func complete(_ value: Data?) {
        lock.lock(); let current = continuation; continuation = nil; lock.unlock()
        current?.resume(returning: value)
    }
}
