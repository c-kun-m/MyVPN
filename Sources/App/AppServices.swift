import Foundation

@MainActor
final class AppServices {
    let controller: TunnelController
    #if DEBUG && targetEnvironment(simulator)
    let simulation: SimulationSession
    #endif

    init() {
        #if DEBUG && targetEnvironment(simulator)
        let selected = ProcessInfo.processInfo.environment["NPV_SIM_SCENARIO"].flatMap(SimulationScenario.init(rawValue:)) ?? .normal
        let session = SimulationSession(scenario: selected)
        simulation = session
        controller = TunnelController(backend: SimulatedTunnelBackend(session: session), identities: session,
                                      diagnostics: session, scheduler: SystemDeadlineScheduler(), isSimulation: true)
        #else
        controller = TunnelController(backend: SystemTunnelBackend(), identities: KeychainIdentityStore(),
                                      diagnostics: SharedDiagnosticStore(), scheduler: SystemDeadlineScheduler())
        #endif
    }
}
