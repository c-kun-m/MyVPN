import SwiftUI

@main
struct NPVApp: App {
    private let services: AppServices
    @StateObject private var controller: TunnelController
    @Environment(\.scenePhase) private var scenePhase
    init() {
        let services = AppServices()
        self.services = services
        _controller = StateObject(wrappedValue: services.controller)
    }
    var body: some Scene {
        WindowGroup {
            ConnectionView(controller: controller)
                #if DEBUG && targetEnvironment(simulator)
                .environmentObject(services.simulation)
                #endif
                .task { await controller.bootstrap(); controller.setForeground(true) }
                .onChange(of: scenePhase) { _, phase in
                    controller.setForeground(phase == .active)
                    if phase == .active { Task { await controller.bootstrap() } }
                }
        }
    }
}
