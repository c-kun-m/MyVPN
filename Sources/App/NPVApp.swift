import SwiftUI

@main
struct NPVApp: App {
    @StateObject private var controller = TunnelController()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            ConnectionView(controller: controller)
                .task { await controller.bootstrap(); controller.setForeground(true) }
                .onChange(of: scenePhase) { _, phase in
                    controller.setForeground(phase == .active)
                    if phase == .active { Task { await controller.bootstrap() } }
                }
        }
    }
}
