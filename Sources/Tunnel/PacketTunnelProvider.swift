import Foundation
import NetworkExtension
import NPVCore
import OSLog
import WireGuardKit

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let log = Logger(subsystem: "NPV", category: "Tunnel")
    private var attemptID = UUID()
    private lazy var adapter = WireGuardAdapter(with: self) { [weak self] level, _ in
        // Upstream messages may contain endpoints and configuration. Never forward raw messages.
        if case .error = level { self?.log.error("WireGuard backend reported an error; details suppressed") }
    }

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        attemptID = (options?["attemptID"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
        record(nil)
        let profile: TunnelProfile
        let reference: Data
        do {
            guard let config = protocolConfiguration as? NETunnelProviderProtocol,
                  let data = config.providerConfiguration?["profile"] as? Data,
                  let ref = config.passwordReference else { throw TunnelFault.invalidConfiguration }
            profile = try TunnelProfile.decode(data)
            reference = ref
        } catch { fail(.invalidConfiguration, completionHandler); return }
        let identity: DeviceIdentity
        do { identity = try KeychainIdentity.load(reference: reference) }
        catch { fail(.keyUnavailable, completionHandler); return }
        let tunnel: TunnelConfiguration
        do { tunnel = try WireGuardConfiguration.make(profile: profile, identity: identity) }
        catch { fail(.invalidConfiguration, completionHandler); return }
        log.info("Tunnel start requested")
        adapter.start(tunnelConfiguration: tunnel) { [weak self] error in
            guard let error else {
                self?.log.info("Tunnel interface started; peer reachability is not yet verified")
                completionHandler(nil)
                return
            }
            let fault: TunnelFault
            switch error {
            case .cannotLocateTunnelFileDescriptor: fault = .interfaceUnavailable
            case .dnsResolution: fault = .endpointResolutionFailed
            case .setNetworkSettings: fault = .networkSettingsFailed
            case .startWireGuardBackend: fault = .backendStartFailed
            case .invalidState: fault = .invalidBackendState
            }
            if let self { self.fail(fault, completionHandler) }
            else { completionHandler(fault) }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        log.info("Tunnel stop requested, system reason \(reason.rawValue, privacy: .public)")
        adapter.stop { [weak self] error in
            // Keep the original startup error; cleanup failure must not overwrite it.
            if error != nil { self?.log.error("Backend cleanup returned an error") }
            completionHandler()
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        guard let completionHandler else { return }
        guard ProviderMessage.decode(messageData) != nil else { completionHandler(nil); return }
        adapter.getRuntimeConfiguration { raw in
            guard let raw, let stats = RuntimeStats.parse(raw) else { completionHandler(nil); return }
            completionHandler(try? JSONEncoder().encode(stats))
        }
    }

    private func record(_ fault: TunnelFault?) {
        do { try SharedStore.saveEvent(DiagnosticEvent(attemptID: attemptID, fault: fault)) }
        catch { log.error("Unable to persist sanitized diagnostic event") }
    }
    private func fail(_ fault: TunnelFault, _ completion: @escaping (Error?) -> Void) {
        record(fault)
        log.error("Tunnel start failed: \(fault.rawValue, privacy: .public)")
        completion(fault)
    }
}
