import Combine
import Foundation
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
    @Published private(set) var activity: [ActivityEntry] = []
    let isSimulation: Bool
    private let backend: any TunnelBackend
    private let identities: any IdentityStore
    private let diagnostics: any DiagnosticStore
    private let scheduler: any DeadlineScheduler
    private var gate = OperationGate()
    private var startupTimeout: ScheduledAction?
    private var pollTask: Task<Void, Never>?
    private var isForeground = false
    private var activeAttemptID: UUID?
    private var requests = ConnectionRequestTracker()
    private var statisticsGeneration = UUID()
    private let log = Logger(subsystem: "NPV", category: "Connection")

    init(backend: any TunnelBackend, identities: any IdentityStore, diagnostics: any DiagnosticStore,
         scheduler: any DeadlineScheduler, isSimulation: Bool = false) {
        self.backend = backend; self.identities = identities; self.diagnostics = diagnostics
        self.scheduler = scheduler; self.isSimulation = isSimulation
        backend.onStateChange = { [weak self] in self?.refreshState() }
    }
    deinit { startupTimeout?.cancel(); pollTask?.cancel() }

    var stateLabel: String {
        guard isSimulation else { return state.label }
        switch state {
        case .connected: return "模拟连接已建立"
        case .connecting: return "模拟连接中"
        case .reasserting: return "模拟恢复中"
        case .disconnecting: return "模拟断开中"
        default: return state.label
        }
    }

    func bootstrap() async {
        guard !busy, requests.request == nil else { return }
        await perform {
            self.ready = false
            self.statisticsGeneration = UUID(); self.stats = nil
            self.profile = try await self.backend.loadConfiguration()
            if let identity = try self.identities.load() {
                self.identityID = identity.id; self.publicKey = try identity.publicKey
            } else { self.identityID = nil; self.publicKey = "" }
            self.refreshState()
            self.ready = true
            self.record(.loaded)
        }
    }

    func generateIdentity() async {
        guard ready, state.canEdit, requests.request == nil else { return }
        await perform {
            if self.profile != nil, try self.identities.load() == nil { throw ControllerError.savedIdentityMissing }
            let identity = try self.identities.createIfMissing()
            self.identityID = identity.id; self.publicKey = try identity.publicKey
            self.notice = self.isSimulation ? "实验身份已生成，仅用于本次模拟。" : "请将此设备公钥登记到测试服务器；手机私钥不会导出。"
            self.record(.identityReady)
        }
    }

    @discardableResult
    func save(_ candidate: TunnelProfile) async -> Bool {
        guard ready, !busy, state.canEdit, requests.request == nil else { return false }
        return await perform {
            try candidate.validate()
            guard let identity = try self.identities.load(), identity.id == candidate.identityID else { throw EnvironmentError.missingIdentity }
            try await self.backend.save(candidate, identityReference: self.identities.persistentReference())
            // Read the authoritative configuration back, including any system changes.
            self.profile = try await self.backend.loadConfiguration()
            guard self.profile != nil else { throw ControllerError.noConfiguration }
            self.statisticsGeneration = UUID(); self.stats = nil
            do { try self.diagnostics.saveProfile(candidate) }
            catch { self.log.error("Non-sensitive configuration cache could not be written") }
            self.refreshState()
            self.notice = self.isSimulation ? "模拟配置已保存，本次运行结束后清除。" : "配置已保存。连接前请确认服务器已授权设备公钥，并配置 IPv4 和 IPv6 转发。"
            self.record(.saved)
        }
    }

    func connect() async {
        guard ready, state.canEdit, requests.request == nil else { return }
        await perform {
            guard let previouslyDisplayed = self.profile else { throw ControllerError.noConfiguration }
            guard let saved = try await self.backend.loadConfiguration() else {
                self.profile = nil; self.refreshState()
                throw ControllerError.noConfiguration
            }
            guard saved == previouslyDisplayed else {
                self.profile = saved; self.refreshState()
                throw ControllerError.configurationChanged
            }
            guard let identity = try self.identities.load(), identity.id == saved.identityID else { throw EnvironmentError.missingIdentity }
            guard self.backend.isEnabled else { throw ControllerError.disabledConfiguration }
            guard let attempt = self.requests.begin(.connect, now: self.scheduler.now) else { return }
            self.activeAttemptID = attempt
            self.statisticsGeneration = UUID(); self.stats = nil
            self.synchronizePendingAction()
            do {
                try self.diagnostics.saveEvent(DiagnosticEvent(attemptID: attempt, fault: nil))
                try self.backend.start(attemptID: attempt)
            } catch {
                self.requests.cancel(attempt); self.activeAttemptID = nil
                self.synchronizePendingAction(); self.refreshState()
                throw error
            }
            self.record(.startRequested)
            self.scheduleTimeout(attempt)
            self.refreshState()
        }
    }

    func disconnect() {
        guard !busy, state.canStop || pendingAction == .connect else { return }
        requestDisconnection()
    }

    private func requestDisconnection() {
        guard let token = requests.begin(.disconnect, now: scheduler.now) else { return }
        activeAttemptID = nil; stats = nil; statisticsGeneration = UUID()
        synchronizePendingAction()
        scheduleTimeout(token)
        backend.stop()
        refreshState()
        record(.stopRequested)
    }

    func setForeground(_ foreground: Bool) {
        isForeground = foreground
        pollTask?.cancel(); pollTask = nil
        statisticsGeneration = UUID()
        guard foreground else { stats = nil; return }
        // Do not retain the controller across the sleep between samples.
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshState()
                await self?.refreshStats()
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }

    private func refreshState() {
        let previousState = state
        state = backend.state
        if state != .connected { stats = nil }
        if state != previousState { statisticsGeneration = UUID(); record(.stateChanged) }
        requests.observe(state)
        synchronizePendingAction()
        if let event = try? diagnostics.loadEvent(), event.attemptID == activeAttemptID, let fault = event.fault {
            errorMessage = fault.localizedDescription
        }
    }

    // Internal so controller tests can exercise late replies without a real timer.
    func refreshStats() async {
        guard isForeground, state == .connected else { return }
        let generation = statisticsGeneration
        let value = await backend.statistics()
        guard !Task.isCancelled, isForeground, state == .connected, statisticsGeneration == generation else { return }
        stats = value
    }

    private func synchronizePendingAction() {
        pendingAction = requests.request?.action
        if requests.request == nil { startupTimeout?.cancel() }
    }

    private func scheduleTimeout(_ token: UUID) {
        startupTimeout?.cancel()
        guard let request = requests.request, request.token == token else { return }
        startupTimeout = scheduler.schedule(at: request.deadline) { [weak self] in
            guard let self else { return }
            self.refreshState()
            guard let action = self.requests.expire(token, now: self.scheduler.now) else { return }
            self.synchronizePendingAction()
            if action == .connect {
                self.errorMessage = TunnelFault.startupTimeout.localizedDescription
                self.requestDisconnection()
            } else {
                self.errorMessage = self.isSimulation ? "模拟后端尚未确认断开。" : "系统尚未确认隧道已断开。请检查 iOS 的 VPN 设置；当前状态未被标记为断开。"
            }
            self.record(.failed)
        }
    }

    @discardableResult
    private func perform(_ work: () async throws -> Void) async -> Bool {
        guard let token = gate.begin() else { return false }
        busy = true; errorMessage = nil; notice = nil
        defer { gate.finish(token); busy = gate.isBusy }
        do { try await work(); return true }
        catch {
            if let e = error as? ProfileError { errorMessage = e.localizedDescription }
            else if let e = error as? EnvironmentError { errorMessage = e.localizedDescription }
            else if let e = error as? ControllerError { errorMessage = e.localizedDescription }
            else if let e = error as? TunnelFault { errorMessage = e.localizedDescription }
            else {
                let scope = isSimulation ? "模拟操作" : "系统 VPN 操作"
                errorMessage = "\(scope)失败（\((error as NSError).code)）。请检查授权和配置后重试。"
            }
            record(.failed)
            log.error("Connection operation failed")
            return false
        }
    }

    private func record(_ kind: ActivityKind) {
        activity.insert(ActivityEntry(date: scheduler.now, kind: kind), at: 0)
        if activity.count > 30 { activity.removeLast(activity.count - 30) }
    }
}
