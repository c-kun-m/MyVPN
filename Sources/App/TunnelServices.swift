import Foundation
import NPVCore

/// The controller owns request ordering; adapters own platform operations only.
@MainActor
protocol TunnelBackend: AnyObject {
    var state: TunnelState { get }
    var isEnabled: Bool { get }
    var onStateChange: (() -> Void)? { get set }
    func loadConfiguration() async throws -> TunnelProfile?
    func save(_ profile: TunnelProfile, identityReference: Data) async throws
    func start(attemptID: UUID) throws
    func stop()
    func statistics() async -> RuntimeStats?
}

@MainActor
protocol IdentityStore {
    func load() throws -> DeviceIdentity?
    func createIfMissing() throws -> DeviceIdentity
    func persistentReference() throws -> Data
}

@MainActor
protocol DiagnosticStore {
    func saveProfile(_ profile: TunnelProfile) throws
    func saveEvent(_ event: DiagnosticEvent) throws
    func loadEvent() throws -> DiagnosticEvent?
}

struct KeychainIdentityStore: IdentityStore {
    func load() throws -> DeviceIdentity? { try KeychainIdentity.load() }
    func createIfMissing() throws -> DeviceIdentity { try KeychainIdentity.createIfMissing() }
    func persistentReference() throws -> Data { try KeychainIdentity.persistentReference() }
}

struct SharedDiagnosticStore: DiagnosticStore {
    func saveProfile(_ profile: TunnelProfile) throws { try SharedStore.save(profile) }
    func saveEvent(_ event: DiagnosticEvent) throws { try SharedStore.saveEvent(event) }
    func loadEvent() throws -> DiagnosticEvent? { try SharedStore.loadEvent() }
}

// Used only on the main actor. Keeping cancellation independent of the actor
// also lets the controller cancel pending work during deinitialization.
final class ScheduledAction {
    private(set) var isCancelled = false
    var task: Task<Void, Never>?
    func cancel() { isCancelled = true; task?.cancel() }
}

@MainActor
protocol DeadlineScheduler {
    var now: Date { get }
    func schedule(at date: Date, action: @escaping @MainActor () -> Void) -> ScheduledAction
}

struct SystemDeadlineScheduler: DeadlineScheduler {
    var now: Date { Date() }
    func schedule(at date: Date, action: @escaping @MainActor () -> Void) -> ScheduledAction {
        let work = ScheduledAction()
        let delay = max(0, date.timeIntervalSinceNow)
        work.task = Task { @MainActor [weak work] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let work, !work.isCancelled else { return }
            action()
        }
        return work
    }
}

enum ControllerError: Error, LocalizedError {
    case duplicateConfigurations, noConfiguration, disabledConfiguration, savedIdentityMissing, configurationChanged, authorizationDenied
    var errorDescription: String? {
        switch self {
        case .duplicateConfigurations: "检测到多个本 App 的 VPN 配置，请在系统设置中保留一个后重新载入。"
        case .noConfiguration: "请先保存服务器配置。"
        case .disabledConfiguration: "系统配置已停用，请重新保存配置并授权。"
        case .savedIdentityMissing: "已保存配置的设备密钥不存在。请先在系统设置中删除此 NPV 配置并重新载入，再生成新身份并在服务器重新授权。"
        case .configurationChanged: "系统中的服务器配置发生变化，已重新载入。请核对地址和服务器公钥后再次连接。"
        case .authorizationDenied: "配置保存未获授权。请确认授权设置后重新保存。"
        }
    }
}

enum ActivityKind: String {
    case loaded, identityReady, saved, startRequested, stopRequested, stateChanged, failed
    var title: String {
        switch self {
        case .loaded: "已重新载入配置"
        case .identityReady: "设备身份已就绪"
        case .saved: "配置已保存"
        case .startRequested: "已请求连接"
        case .stopRequested: "已请求断开"
        case .stateChanged: "连接状态已更新"
        case .failed: "操作未完成，请查看错误提示"
        }
    }
}

struct ActivityEntry: Identifiable {
    let id = UUID()
    let date: Date
    let kind: ActivityKind
}
