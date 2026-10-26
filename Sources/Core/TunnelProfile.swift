import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum ProfileError: String, Error, LocalizedError, Sendable {
    case unsupportedVersion, invalidName, invalidEndpoint, invalidPort, invalidPublicKey
    case invalidIPv4, invalidIPv6, invalidDNS, invalidMTU, invalidKeepalive, oversizedProfile

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion: "配置版本不受支持。"
        case .invalidName: "名称须为 1–64 个字符，不能包含控制字符。"
        case .invalidEndpoint: "服务器地址须为有效 IP 或 ASCII 域名，不含协议、端口或路径。"
        case .invalidPort: "服务器端口须在 1–65535 之间。"
        case .invalidPublicKey: "服务器公钥须为非零的 32 字节 Base64 公钥。"
        case .invalidIPv4: "请填写有效的 IPv4 隧道地址，例如 10.77.0.2/32。"
        case .invalidIPv6: "请填写有效的 IPv6 隧道地址，例如 fd77::2/128。"
        case .invalidDNS: "请填写 1–3 个有效的 DNS 服务器 IP 地址。"
        case .invalidMTU: "MTU 须在 1280–1420 之间。"
        case .invalidKeepalive: "保活间隔须为 0（关闭）或 15–120 秒。"
        case .oversizedProfile: "配置超出大小限制。"
        }
    }
}

public struct TunnelEndpoint: Codable, Equatable, Sendable {
    public var host: String
    public var port: Int

    public init(host: String, port: Int) { self.host = host; self.port = port }
    public var wireGuardValue: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }
    public func validate() throws {
        guard (1...65535).contains(port) else { throw ProfileError.invalidPort }
        guard IPAddress.isUnicast(host) || Self.isHostname(host) else { throw ProfileError.invalidEndpoint }
    }
    private static func isHostname(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 253, !value.contains(":"),
              !value.allSatisfy({ $0.isNumber || $0 == "." }) else { return false }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        return labels.allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
            label.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
    }
}

public struct TunnelProfile: Codable, Equatable, Sendable {
    public static let maximumBytes = 16_384
    public var schemaVersion: Int = 1
    public var id: UUID
    public var identityID: UUID
    public var name: String
    public var endpoint: TunnelEndpoint
    public var serverPublicKey: String
    public var ipv4Address: String
    public var ipv6Address: String
    public var dnsServers: [String]
    public var mtu: Int
    public var keepaliveSeconds: Int

    public init(id: UUID = UUID(), identityID: UUID, name: String, endpoint: TunnelEndpoint,
                serverPublicKey: String, ipv4Address: String, ipv6Address: String,
                dnsServers: [String], mtu: Int = 1280, keepaliveSeconds: Int = 25) {
        self.id = id; self.identityID = identityID; self.name = name; self.endpoint = endpoint
        self.serverPublicKey = serverPublicKey; self.ipv4Address = ipv4Address
        self.ipv6Address = ipv6Address; self.dnsServers = dnsServers
        self.mtu = mtu; self.keepaliveSeconds = keepaliveSeconds
    }

    public func validate() throws {
        guard schemaVersion == 1 else { throw ProfileError.unsupportedVersion }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 64,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw ProfileError.invalidName }
        try endpoint.validate()
        guard let key = Data(base64Encoded: serverPublicKey), key.count == 32,
              key.base64EncodedString() == serverPublicKey, key.contains(where: { $0 != 0 }) else { throw ProfileError.invalidPublicKey }
        guard IPAddress.isCIDR(ipv4Address, family: AF_INET) else { throw ProfileError.invalidIPv4 }
        guard IPAddress.isCIDR(ipv6Address, family: AF_INET6) else { throw ProfileError.invalidIPv6 }
        guard (1...3).contains(dnsServers.count), dnsServers.allSatisfy(IPAddress.isUnicast) else { throw ProfileError.invalidDNS }
        guard (1280...1420).contains(mtu) else { throw ProfileError.invalidMTU }
        guard keepaliveSeconds == 0 || (15...120).contains(keepaliveSeconds) else { throw ProfileError.invalidKeepalive }
    }

    public func encoded() throws -> Data {
        try validate()
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumBytes else { throw ProfileError.oversizedProfile }
        return data
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw ProfileError.oversizedProfile }
        let result = try JSONDecoder().decode(Self.self, from: data)
        try result.validate()
        return result
    }
}

enum IPAddress {
    static func bytes(_ value: String, family: Int32) -> [UInt8]? {
        guard !value.contains("\0") else { return nil }
        var result = [UInt8](repeating: 0, count: family == AF_INET ? 4 : 16)
        let status = value.withCString { input in result.withUnsafeMutableBytes { inet_pton(family, input, $0.baseAddress) } }
        return status == 1 ? result : nil
    }
    static func isUnicast(_ value: String) -> Bool {
        if let v4 = bytes(value, family: AF_INET) {
            return v4[0] != 0 && v4[0] != 127 && v4[0] < 224 && !(v4[0] == 169 && v4[1] == 254)
        }
        if let v6 = bytes(value, family: AF_INET6) {
            guard v6.contains(where: { $0 != 0 }), v6 != Array(repeating: 0, count: 15) + [1],
                  v6[0] != 255, !(v6[0] == 0xfe && v6[1] & 0xc0 == 0x80) else { return false }
            // Mapped IPv4 literals obscure address-family policy; require native literals.
            return !(v6.prefix(10).allSatisfy { $0 == 0 } && v6[10] == 255 && v6[11] == 255)
        }
        return false
    }
    static func isCIDR(_ value: String, family: Int32) -> Bool {
        let pieces = value.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 2, let prefix = Int(pieces[1]), String(prefix) == pieces[1],
              (1...(family == AF_INET ? 32 : 128)).contains(prefix) else { return false }
        return bytes(String(pieces[0]), family: family) != nil && isUnicast(String(pieces[0]))
    }
}
