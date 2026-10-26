import Foundation

public enum TunnelState: String, Codable, Sendable {
    case unconfigured, disconnected, connecting, connected, reasserting, disconnecting, invalid
    public var label: String {
        switch self {
        case .unconfigured: "尚未配置"
        case .disconnected: "已断开"
        case .connecting: "系统正在建立隧道"
        case .connected: "隧道已启动"
        case .reasserting: "系统正在恢复隧道"
        case .disconnecting: "正在断开"
        case .invalid: "系统配置无效"
        }
    }
    public var canEdit: Bool { self == .unconfigured || self == .disconnected || self == .invalid }
    public var canStop: Bool { self == .connecting || self == .connected || self == .reasserting }
}

public struct RuntimeStats: Codable, Equatable, Sendable {
    public let receivedBytes: UInt64
    public let sentBytes: UInt64
    public let lastHandshakeUnixSeconds: UInt64?
    public let sampledAt: Date

    public init(receivedBytes: UInt64, sentBytes: UInt64, lastHandshakeUnixSeconds: UInt64?, sampledAt: Date = Date()) {
        self.receivedBytes = receivedBytes; self.sentBytes = sentBytes
        self.lastHandshakeUnixSeconds = lastHandshakeUnixSeconds; self.sampledAt = sampledAt
    }
    // Parse only allowlisted numeric counters. Never return/log the raw runtime configuration:
    // the upstream UAPI response may include private_key and preshared_key.
    public static func parse(_ text: String, now: Date = Date()) -> Self? {
        guard text.utf8.count <= 65_536 else { return nil }
        var counters: [String: UInt64] = [:]
        let allowed: Set<String> = ["rx_bytes", "tx_bytes", "last_handshake_time_sec"]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, allowed.contains(String(parts[0])) else { continue }
            let field = String(parts[0])
            guard counters[field] == nil, !parts[1].isEmpty, parts[1].utf8.allSatisfy({ (48...57).contains($0) }),
                  let value = UInt64(parts[1]) else { return nil }
            counters[field] = value
        }
        guard let rx = counters["rx_bytes"], let tx = counters["tx_bytes"] else { return nil }
        let handshake = counters["last_handshake_time_sec"].flatMap { $0 == 0 ? nil : $0 }
        return Self(receivedBytes: rx, sentBytes: tx, lastHandshakeUnixSeconds: handshake, sampledAt: now)
    }
}

public enum TunnelFault: String, Codable, Error, LocalizedError, Sendable {
    case invalidConfiguration, keyUnavailable, endpointResolutionFailed, networkSettingsFailed
    case backendStartFailed, invalidBackendState, interfaceUnavailable, backendStopped, startupTimeout
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "扩展读取配置失败，请断开后重新保存。"
        case .keyUnavailable: "无法读取设备密钥。请先解锁设备，并检查签名和 Keychain 权限。"
        case .endpointResolutionFailed: "无法解析服务器地址，请检查网络和地址配置。"
        case .networkSettingsFailed: "系统未能应用隧道路由或 DNS 配置。"
        case .backendStartFailed: "加密隧道核心未能启动。"
        case .invalidBackendState: "隧道核心状态冲突，请断开后重试。"
        case .interfaceUnavailable: "系统未提供可用的隧道接口。"
        case .backendStopped: "隧道核心停止时出现错误。"
        case .startupTimeout: "系统未在限定时间内启动隧道，已请求停止。"
        }
    }
}

public struct DiagnosticEvent: Codable, Equatable, Sendable {
    public let attemptID: UUID
    public let date: Date
    public let fault: TunnelFault?
    public init(attemptID: UUID, date: Date = Date(), fault: TunnelFault?) {
        self.attemptID = attemptID; self.date = date; self.fault = fault
    }
}

public enum ProviderRequest: String, Codable, Sendable { case statistics }
public struct ProviderMessage: Codable, Sendable {
    public let version: Int
    public let request: ProviderRequest
    public init(request: ProviderRequest) { version = 1; self.request = request }
    public static func decode(_ data: Data) -> Self? {
        guard data.count <= 256, let message = try? JSONDecoder().decode(Self.self, from: data), message.version == 1 else { return nil }
        return message
    }
}
