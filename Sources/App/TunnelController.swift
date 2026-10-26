import Combine
import Foundation
import NetworkExtension
import NPVCore
import OSLog

@MainActor
final class TunnelController: ObservableObject {
    @Published private(set) var state: TunnelState = .unconfigured
    @Published private(set) var profile: TunnelProfile?
    @Published private(set) var publicKey = ""
    @Published private(set) var identityID: UUID?
    @Published private(set) var stats: RuntimeStats?
    @Published private(set) var busy = false
    @Published private(set) var ready = false
    @Published private(set) var pendingAction: ConnectionAction?
    @Published var errorMessage: String?
    @Published private(set) var notice: String?
    private var manager: NETunnelProviderManager?
    private var gate = OperationGate()
    private var statusObserver: NSObjectProtocol?
    private var startupTimeout: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var activeAttemptID: UUID?
    private var requests = ConnectionRequestTracker()
    private var statisticsGeneration = UUID()
    private let log = Logger(subsystem: "NPV", category: "Connection")

    init() {
        statusObserver = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshState() }
        }
    }
    deinit {
        if let statusObserver { NotificationCenter.default.removeObserver(statusObserver) }
        startupTimeout?.cancel(); pollTask?.cancel()
    }

    func bootstrap() async {
        guard !busy, requests.request == nil else { return }
        await perform {
            self.ready = false
            let bundleID = try AppEnvironment.providerBundleID
            let all = try await self.loadManagers()
            let own = all.filter { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == bundleID }
            guard own.count <= 1 else { throw ControllerError.duplicateConfigurations }
            self.manager = own.first
            self.statisticsGeneration = UUID()
            self.stats = nil
            if let data = (own.first?.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?["profile"] as? Data {
                self.profile = try TunnelProfile.decode(data)
            } else { self.profile = nil }
            if let identity = try KeychainIdentity.load() {
                self.identityID = identity.id
                self.publicKey = try identity.publicKey
            } else {
                self.identityID = nil; self.publicKey = ""
            }
            self.refreshState()
            self.ready = true
        }
    }

    func generateIdentity() async {
        guard ready, state.canEdit, requests.request == nil else { return }
        await perform {
            // Never silently replace a missing identity referenced by a saved VPN profile.
            if self.profile != nil, try KeychainIdentity.load() == nil { throw ControllerError.savedIdentityMissing }
            let identity = try KeychainIdentity.createIfMissing()
            self.identityID = identity.id; self.publicKey = try identity.publicKey
            self.notice = "请将此设备公钥登记到测试服务器；手机私钥不会导出。"
        }
    }

    func save(_ candidate: TunnelProfile) async {
        guard ready, state.canEdit, requests.request == nil else { return }
        await perform {
            try candidate.validate()
            guard let identity = try KeychainIdentity.load(), identity.id == candidate.identityID else { throw EnvironmentError.missingIdentity }
            let config = NETunnelProviderProtocol()
            config.providerBundleIdentifier = try AppEnvironment.providerBundleID
            config.serverAddress = candidate.endpoint.host
            config.providerConfiguration = ["profile": try candidate.encoded()]
            config.passwordReference = try KeychainIdentity.persistentReference()
            config.disconnectOnSleep = false
            config.includeAllNetworks = true
            config.excludeLocalNetworks = false
            config.excludeAPNs = false
            config.excludeCellularServices = false
            let target = self.manager ?? NETunnelProviderManager()
            target.protocolConfiguration = config
            target.localizedDescription = "NPV · \(candidate.name)"
            target.isEnabled = true
            target.isOnDemandEnabled = false // Stage 1: explicit connection, no auto-connect promise.
            try await self.savePreferences(target)
            try await self.reloadPreferences(target)
            self.manager = target; self.profile = candidate
            self.statisticsGeneration = UUID()
            // The system's saved provider configuration is authoritative, never this cache.
            do { try SharedStore.save(candidate) }
            catch { self.log.error("Non-sensitive configuration cache could not be written") }
            self.refreshState()
            self.notice = "配置已保存。连接前请确认服务器已授权设备公钥，并配置 IPv4 和 IPv6 转发。"
        }
    }

    func connect() async {
        guard ready, state.canEdit, requests.request == nil else { return }
        await perform {
            guard let target = self.manager, let previouslyDisplayed = self.profile else { throw ControllerError.noConfiguration }
            try await self.reloadPreferences(target)
            guard let saved = target.protocolConfiguration as? NETunnelProviderProtocol,
                  saved.providerBundleIdentifier == (try AppEnvironment.providerBundleID),
                  let data = saved.providerConfiguration?["profile"] as? Data else { throw ControllerError.noConfiguration }
            let profile = try TunnelProfile.decode(data)
            guard profile == previouslyDisplayed else {
                self.profile = profile
                self.refreshState()
                throw ControllerError.configurationChanged
            }
            guard let identity = try KeychainIdentity.load(), identity.id == profile.identityID else { throw EnvironmentError.missingIdentity }
            guard target.isEnabled else { throw ControllerError.disabledConfiguration }
            guard let session = target.connection as? NETunnelProviderSession else { throw ControllerError.noConfiguration }
            guard let attempt = self.requests.begin(.connect) else { return }
            self.activeAttemptID = attempt
            self.statisticsGeneration = UUID()
            self.stats = nil
            self.synchronizePendingAction()
            do {
                try SharedStore.saveEvent(DiagnosticEvent(attemptID: attempt, fault: nil))
                try session.startTunnel(options: ["attemptID": attempt.uuidString as NSString])
            } catch {
                self.requests.cancel(attempt)
                self.synchronizePendingAction()
                throw error
            }
            self.log.info("User requested tunnel connection")
            self.scheduleTimeout(attempt)
            self.refreshState()
        }
    }

    func disconnect() {
        guard !busy, state.canStop || pendingAction == .connect else { return }
        requestDisconnection()
    }

    private func requestDisconnection() {
        // A timed-out start must be cancelled even if the last OS observation is
        // still disconnected. Do not reuse the UI's state-based action guard.
        guard let token = requests.begin(.disconnect) else { return }
        activeAttemptID = nil; stats = nil; statisticsGeneration = UUID()
        synchronizePendingAction()
        scheduleTimeout(token)
        manager?.connection.stopVPNTunnel()
        refreshState()
        log.info("Tunnel disconnection requested")
    }

    func setForeground(_ foreground: Bool) {
        pollTask?.cancel(); pollTask = nil
        guard foreground else { stats = nil; return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refreshState()
                await self.refreshStats()
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }

    private func refreshState() {
        let previousState = state
        if let manager {
            switch manager.connection.status {
            case .invalid: state = .invalid
            case .disconnected: state = .disconnected
            case .connecting: state = .connecting
            case .connected: state = .connected
            case .reasserting: state = .reasserting
            case .disconnecting: state = .disconnecting
            @unknown default: state = .invalid
            }
        } else { state = .unconfigured }
        if state != .connected { stats = nil }
        if state != previousState { statisticsGeneration = UUID() }
        requests.observe(state)
        synchronizePendingAction()
        if let event = try? SharedStore.loadEvent(), event.attemptID == activeAttemptID, let fault = event.fault {
            errorMessage = fault.localizedDescription
        }
    }

    private func refreshStats() async {
        guard state == .connected, let session = manager?.connection as? NETunnelProviderSession else { return }
        guard let message = try? JSONEncoder().encode(ProviderMessage(request: .statistics)) else { return }
        let generation = statisticsGeneration
        let data: Data? = await withCheckedContinuation { continuation in
            let reply = ProviderReply(continuation)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { reply.complete(nil) }
            do { try session.sendProviderMessage(message) { data in reply.complete(data) } }
            catch { reply.complete(nil) }
        }
        guard !Task.isCancelled, state == .connected, statisticsGeneration == generation else { return }
        guard let data, data.count <= 2_048, let value = try? JSONDecoder().decode(RuntimeStats.self, from: data) else { stats = nil; return }
        stats = value
    }

    private func synchronizePendingAction() {
        pendingAction = requests.request?.action
        if requests.request == nil { startupTimeout?.cancel() }
    }

    private func scheduleTimeout(_ token: UUID) {
        startupTimeout?.cancel()
        guard let request = requests.request, request.token == token else { return }
        let delay = max(0, request.deadline.timeIntervalSinceNow)
        startupTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self else { return }
            self.refreshState()
            guard let action = self.requests.expire(token) else { return }
            self.synchronizePendingAction()
            if action == .connect {
                self.errorMessage = TunnelFault.startupTimeout.localizedDescription
                self.requestDisconnection()
            } else {
                self.errorMessage = "系统尚未确认隧道已断开。请检查 iOS 的 VPN 设置；当前状态未被标记为断开。"
            }
        }
    }

    private func perform(_ work: () async throws -> Void) async {
        guard let token = gate.begin() else { return }
        busy = true; errorMessage = nil; notice = nil
        defer { gate.finish(token); busy = gate.isBusy }
        do { try await work() }
        catch {
            // Display own messages or system code, not arbitrary underlying descriptions/configuration.
            if let e = error as? ProfileError { errorMessage = e.localizedDescription }
            else if let e = error as? EnvironmentError { errorMessage = e.localizedDescription }
            else if let e = error as? ControllerError { errorMessage = e.localizedDescription }
            else { errorMessage = "系统 VPN 操作失败（\((error as NSError).code)）。请检查授权和签名配置。" }
            log.error("Connection operation failed")
        }
    }
    private func loadManagers() async throws -> [NETunnelProviderManager] {
        try await withCheckedThrowingContinuation { continuation in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: managers ?? []) }
            }
        }
    }
    private func savePreferences(_ target: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            target.saveToPreferences { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
    private func reloadPreferences(_ target: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            target.loadFromPreferences { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
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

private enum ControllerError: Error, LocalizedError {
    case duplicateConfigurations, noConfiguration, disabledConfiguration, savedIdentityMissing, configurationChanged
    var errorDescription: String? {
        switch self {
        case .duplicateConfigurations: "检测到多个本 App 的 VPN 配置，请在系统设置中保留一个后重新载入。"
        case .noConfiguration: "请先保存服务器配置。"
        case .disabledConfiguration: "系统配置已停用，请重新保存配置并授权。"
        case .savedIdentityMissing: "已保存配置的设备密钥不存在。请先在系统设置中删除此 NPV 配置并重新载入，再生成新身份并在服务器重新授权。"
        case .configurationChanged: "系统中的服务器配置发生变化，已重新载入。请核对地址和服务器公钥后再次连接。"
        }
    }
}
