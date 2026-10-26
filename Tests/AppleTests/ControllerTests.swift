import XCTest
import NPVCore
@testable import NPV

@MainActor
final class ControllerTests: XCTestCase {
    func testFirstUseSavesAndLoadsAuthoritativeProfile() async throws {
        let h = Harness(configured: false)
        await h.controller.bootstrap()
        XCTAssertTrue(h.controller.ready)
        XCTAssertNil(h.controller.profile)
        await h.controller.generateIdentity()
        XCTAssertEqual(h.controller.identityID, h.identity.value?.id)
        let saved = await h.controller.save(h.profile)
        XCTAssertTrue(saved)
        XCTAssertEqual(h.controller.profile, h.profile)
        XCTAssertEqual(h.backend.saveCalls, 1)
        XCTAssertEqual(h.controller.state, .disconnected)
    }

    func testSaveDenialKeepsExistingProfileAndAllowsRetry() async {
        let h = Harness()
        await h.controller.bootstrap()
        h.backend.saveError = ControllerError.authorizationDenied
        var changed = h.profile; changed.name = "Changed"
        let rejected = await h.controller.save(changed)
        XCTAssertFalse(rejected)
        XCTAssertEqual(h.controller.profile, h.profile)
        XCTAssertNotNil(h.controller.errorMessage)
        XCTAssertFalse(h.controller.busy)
        h.backend.saveError = nil
        let accepted = await h.controller.save(changed)
        XCTAssertTrue(accepted)
        XCTAssertNil(h.controller.errorMessage)
    }

    func testDuplicateStartAndCancellationWhileSystemStillDisconnected() async {
        let h = Harness()
        await h.controller.bootstrap()
        await h.controller.connect()
        await h.controller.connect()
        XCTAssertEqual(h.backend.startCalls, 1)
        XCTAssertEqual(h.controller.pendingAction, .connect)
        h.controller.disconnect()
        XCTAssertEqual(h.backend.stopCalls, 1)
        XCTAssertNil(h.controller.pendingAction)
        h.scheduler.advance(60)
        XCTAssertEqual(h.backend.stopCalls, 1, "Cancelled timeout must not affect a later operation")
    }

    func testBusyReloadRejectsSecondConnectBeforeFirstStart() async {
        let h = Harness()
        await h.controller.bootstrap()
        h.backend.holdLoad = true
        let first = Task { await h.controller.connect() }
        for _ in 0..<30 where h.backend.pendingLoad == nil { await Task.yield() }
        XCTAssertTrue(h.controller.busy)
        await h.controller.connect()
        XCTAssertEqual(h.backend.startCalls, 0)
        h.backend.pendingLoad?.resume(returning: h.profile); h.backend.pendingLoad = nil
        await first.value
        XCTAssertEqual(h.backend.startCalls, 1)
        h.controller.disconnect()
    }

    func testTimeoutStopsEvenBeforeConnectingNotification() async {
        let h = Harness()
        await h.controller.bootstrap(); await h.controller.connect()
        h.scheduler.advance(29)
        XCTAssertEqual(h.backend.stopCalls, 0)
        h.scheduler.advance(1)
        XCTAssertEqual(h.backend.stopCalls, 1)
        XCTAssertEqual(h.controller.errorMessage, TunnelFault.startupTimeout.localizedDescription)
        XCTAssertNil(h.controller.pendingAction)
    }

    func testStopTimeoutDoesNotInventDisconnectedState() async {
        let h = Harness()
        await h.controller.bootstrap(); await h.controller.connect()
        h.backend.publish(.connected)
        h.backend.confirmStop = false
        h.controller.disconnect()
        h.scheduler.advance(10)
        XCTAssertEqual(h.controller.state, .connected)
        XCTAssertNil(h.controller.pendingAction)
        XCTAssertNotNil(h.controller.errorMessage)
    }

    func testSavedConfigurationChangeRequiresReview() async {
        let h = Harness()
        await h.controller.bootstrap()
        var changed = h.profile; changed.endpoint.host = "changed.example.invalid"
        h.backend.profile = changed
        await h.controller.connect()
        XCTAssertEqual(h.backend.startCalls, 0)
        XCTAssertEqual(h.controller.profile, changed)
        XCTAssertEqual(h.controller.errorMessage, ControllerError.configurationChanged.localizedDescription)
        await h.controller.connect()
        XCTAssertEqual(h.backend.startCalls, 1)
        h.controller.disconnect()
    }

    func testMissingSavedIdentityIsNeverReplaced() async {
        let h = Harness()
        h.identity.value = nil
        await h.controller.bootstrap(); await h.controller.generateIdentity()
        XCTAssertEqual(h.identity.createCalls, 0)
        XCTAssertEqual(h.controller.errorMessage, ControllerError.savedIdentityMissing.localizedDescription)
        await h.controller.connect()
        XCTAssertEqual(h.backend.startCalls, 0)
    }

    func testIdentityFailureAndBootstrapFailureCanRecover() async {
        let h = Harness()
        h.identity.error = EnvironmentError.keychain(-25308)
        await h.controller.bootstrap()
        XCTAssertFalse(h.controller.ready)
        await h.controller.connect()
        XCTAssertEqual(h.backend.startCalls, 0)
        h.identity.error = nil
        await h.controller.bootstrap()
        XCTAssertTrue(h.controller.ready)
        XCTAssertNil(h.controller.errorMessage)
    }

    func testDisabledConfigurationAndStartFailureAreRetryable() async {
        let h = Harness()
        await h.controller.bootstrap()
        h.backend.isEnabled = false
        await h.controller.connect()
        XCTAssertEqual(h.backend.startCalls, 0)
        h.backend.isEnabled = true
        h.backend.startError = TunnelFault.backendStartFailed
        await h.controller.connect()
        XCTAssertNil(h.controller.pendingAction)
        XCTAssertEqual(h.controller.errorMessage, TunnelFault.backendStartFailed.localizedDescription)
        h.backend.startError = nil
        await h.controller.connect()
        XCTAssertEqual(h.controller.pendingAction, .connect)
        h.controller.disconnect()
    }

    func testDiagnosticWriteFailurePreventsUntrackedStart() async {
        let h = Harness()
        await h.controller.bootstrap()
        h.store.eventError = CocoaError(.fileWriteNoPermission)
        await h.controller.connect()
        XCTAssertEqual(h.backend.startCalls, 0)
        XCTAssertNil(h.controller.pendingAction)
    }

    func testCacheFailureDoesNotOverrideSystemSavedConfiguration() async {
        let h = Harness()
        await h.controller.bootstrap()
        h.store.profileError = CocoaError(.fileWriteNoPermission)
        var changed = h.profile; changed.name = "Authoritative"
        let accepted = await h.controller.save(changed)
        XCTAssertTrue(accepted)
        XCTAssertEqual(h.controller.profile, changed)
    }

    func testLateStatisticsCannotCrossConnectionGeneration() async {
        let h = Harness()
        await h.controller.bootstrap(); await h.controller.connect()
        h.backend.publish(.connected)
        h.backend.holdStatistics = true
        h.controller.setForeground(true)
        for _ in 0..<30 where h.backend.pendingStatistics == nil { await Task.yield() }
        XCTAssertNotNil(h.backend.pendingStatistics)
        h.controller.disconnect()
        await h.controller.connect(); h.backend.publish(.connected)
        h.backend.pendingStatistics?.resume(returning: RuntimeStats(receivedBytes: 999, sentBytes: 999, lastHandshakeUnixSeconds: 1))
        h.backend.pendingStatistics = nil
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(h.controller.stats)
        h.controller.setForeground(false); h.controller.disconnect()
    }

    func testBackgroundClearsStatisticsAndForegroundReloadsConfiguration() async {
        let h = Harness()
        await h.controller.bootstrap(); await h.controller.connect()
        h.backend.publish(.connected)
        h.controller.setForeground(true)
        for _ in 0..<30 where h.controller.stats == nil { await Task.yield() }
        XCTAssertNotNil(h.controller.stats)
        h.controller.setForeground(false)
        XCTAssertNil(h.controller.stats)
        var changed = h.profile; changed.name = "Reloaded"
        h.backend.profile = changed
        await h.controller.bootstrap()
        XCTAssertEqual(h.controller.profile, changed)
        h.controller.disconnect()
    }

    func testRecoveryCanBeStoppedAndForeignDiagnosticIsIgnored() async {
        let h = Harness()
        await h.controller.bootstrap(); await h.controller.connect()
        h.store.event = DiagnosticEvent(attemptID: UUID(), fault: .keyUnavailable)
        h.backend.publish(.reasserting)
        XCTAssertNil(h.controller.errorMessage)
        XCTAssertTrue(h.controller.state.canStop)
        h.controller.disconnect()
        XCTAssertEqual(h.backend.stopCalls, 1)
    }

    func testUnknownErrorContentNeverReachesUIOrHistoryAndHistoryIsBounded() async {
        let h = Harness()
        h.backend.loadError = NSError(domain: "private_key=SECRET", code: 9, userInfo: [NSLocalizedDescriptionKey: "private_key=SECRET"])
        for _ in 0..<40 { await h.controller.bootstrap() }
        XCTAssertFalse(h.controller.errorMessage?.contains("SECRET") ?? true)
        XCTAssertEqual(h.controller.activity.count, 30)
        XCTAssertTrue(h.controller.activity.allSatisfy { $0.kind == .failed })
    }

    #if DEBUG && targetEnvironment(simulator)
    func testSimulationCancellationCannotResurrectConnection() async throws {
        let h = Harness()
        let session = SimulationSession()
        let backend = SimulatedTunnelBackend(session: session)
        try await backend.save(h.profile, identityReference: Data([1]))
        try backend.start(attemptID: UUID())
        XCTAssertEqual(backend.state, .connecting)
        backend.stop()
        // Wait past the simulator adapter's 1 second completion, not the
        // controller deadline (which is covered using TestScheduler above).
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(backend.state, .disconnected)
        let statistics = await backend.statistics()
        XCTAssertNil(statistics)
    }
    #endif
}

@MainActor
private final class Harness {
    let backend = TestBackend()
    let identity = TestIdentityStore()
    let store = TestDiagnosticStore()
    let scheduler = TestScheduler()
    let profile: TunnelProfile
    let controller: TunnelController
    init(configured: Bool = true) {
        profile = TunnelProfile(identityID: identity.value!.id, name: "Test", endpoint: TunnelEndpoint(host: "vpn.example.invalid", port: 51820),
                                serverPublicKey: Data(repeating: 7, count: 32).base64EncodedString(),
                                ipv4Address: "10.77.0.2/32", ipv6Address: "fd77::2/128", dnsServers: ["10.77.0.1"])
        backend.profile = configured ? profile : nil
        backend.state = configured ? .disconnected : .unconfigured
        controller = TunnelController(backend: backend, identities: identity, diagnostics: store, scheduler: scheduler)
    }
}

@MainActor
private final class TestBackend: TunnelBackend {
    var state: TunnelState = .unconfigured
    var isEnabled = true
    var onStateChange: (() -> Void)?
    var profile: TunnelProfile?
    var saveError: Error?
    var startError: Error?
    var loadError: Error?
    var startCalls = 0, stopCalls = 0, saveCalls = 0
    var confirmStop = true, holdStatistics = false, holdLoad = false
    var pendingStatistics: CheckedContinuation<RuntimeStats?, Never>?
    var pendingLoad: CheckedContinuation<TunnelProfile?, Never>?
    func loadConfiguration() async throws -> TunnelProfile? {
        if let loadError { throw loadError }
        if holdLoad { return await withCheckedContinuation { pendingLoad = $0 } }
        return profile
    }
    func save(_ profile: TunnelProfile, identityReference: Data) async throws {
        saveCalls += 1
        if let saveError { throw saveError }
        self.profile = profile; publish(.disconnected)
    }
    func start(attemptID: UUID) throws { startCalls += 1; if let startError { throw startError } }
    func stop() { stopCalls += 1; if confirmStop { publish(.disconnected) } }
    func statistics() async -> RuntimeStats? {
        if holdStatistics { return await withCheckedContinuation { pendingStatistics = $0 } }
        return RuntimeStats(receivedBytes: 100, sentBytes: 50, lastHandshakeUnixSeconds: 1)
    }
    func publish(_ state: TunnelState) { self.state = state; onStateChange?() }
}

@MainActor
private final class TestIdentityStore: IdentityStore {
    var value: DeviceIdentity? = DeviceIdentity(id: UUID(), privateKey: Data(repeating: 3, count: 32))
    var error: Error?
    var createCalls = 0
    func load() throws -> DeviceIdentity? { if let error { throw error }; return value }
    func createIfMissing() throws -> DeviceIdentity {
        createCalls += 1
        if let saved = try load() { return saved }
        let created = DeviceIdentity(id: UUID(), privateKey: Data(repeating: 4, count: 32))
        value = created; return created
    }
    func persistentReference() throws -> Data { Data([1]) }
}

@MainActor
private final class TestDiagnosticStore: DiagnosticStore {
    var event: DiagnosticEvent?
    var eventError: Error?
    var profileError: Error?
    func saveProfile(_ profile: TunnelProfile) throws { if let profileError { throw profileError } }
    func saveEvent(_ event: DiagnosticEvent) throws { if let eventError { throw eventError }; self.event = event }
    func loadEvent() throws -> DiagnosticEvent? { event }
}

@MainActor
final class TestScheduler: DeadlineScheduler {
    var now = Date(timeIntervalSince1970: 1000)
    private var entries: [(Date, ScheduledAction, @MainActor () -> Void)] = []
    func schedule(at date: Date, action: @escaping @MainActor () -> Void) -> ScheduledAction {
        let token = ScheduledAction(); entries.append((date, token, action)); return token
    }
    func advance(_ seconds: TimeInterval) {
        now.addTimeInterval(seconds)
        let due = entries.filter { $0.0 <= now }
        entries.removeAll { $0.0 <= now }
        for (_, token, action) in due where !token.isCancelled { action() }
    }
}
