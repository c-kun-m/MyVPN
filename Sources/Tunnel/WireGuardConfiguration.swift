import Foundation
import NPVCore
import WireGuardKit

enum WireGuardConfiguration {
    static func make(profile: TunnelProfile, identity: DeviceIdentity) throws -> TunnelConfiguration {
        try profile.validate()
        guard profile.identityID == identity.id,
              let privateKey = PrivateKey(rawValue: identity.privateKey),
              let publicKey = PublicKey(base64Key: profile.serverPublicKey),
              let v4 = IPAddressRange(from: profile.ipv4Address),
              let v6 = IPAddressRange(from: profile.ipv6Address),
              let route4 = IPAddressRange(from: "0.0.0.0/0"),
              let route6 = IPAddressRange(from: "::/0"),
              let endpoint = Endpoint(from: profile.endpoint.wireGuardValue) else { throw TunnelFault.invalidConfiguration }
        let dns = profile.dnsServers.compactMap(DNSServer.init(from:))
        guard dns.count == profile.dnsServers.count else { throw TunnelFault.invalidConfiguration }
        var interface = InterfaceConfiguration(privateKey: privateKey)
        interface.addresses = [v4, v6]
        interface.dns = dns
        interface.mtu = UInt16(profile.mtu)
        var peer = PeerConfiguration(publicKey: publicKey)
        peer.endpoint = endpoint
        peer.allowedIPs = [route4, route6]
        peer.persistentKeepAlive = UInt16(profile.keepaliveSeconds)
        return TunnelConfiguration(name: profile.name, interface: interface, peers: [peer])
    }
}
