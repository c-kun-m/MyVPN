import Foundation
import Security

enum AppEnvironment {
    static func value(_ key: String) throws -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty, !value.contains("$(") else { throw EnvironmentError.signingConfiguration }
        return value
    }
    static var providerBundleID: String { get throws { try value("NPVProviderBundleID") } }
    static var keychainGroup: String { get throws { try value("NPVKeychainGroup") } }
    static var containerURL: URL {
        get throws {
            let group = try value("NPVAppGroup")
            guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
                throw EnvironmentError.sharedContainer
            }
            return url
        }
    }
}

enum EnvironmentError: Error, LocalizedError {
    case signingConfiguration, sharedContainer, keychain(OSStatus), malformedIdentity, missingIdentity
    var errorDescription: String? {
        switch self {
        case .signingConfiguration: "请检查构建时的 Bundle ID、开发者团队和权限配置。"
        case .sharedContainer: "无法打开 App Group，请检查主 App 和扩展的签名权限。"
        case .keychain(let status): "Keychain 操作失败（\(status)），请解锁设备并检查权限。"
        case .malformedIdentity: "设备身份数据损坏，禁止自动覆盖已有密钥。"
        case .missingIdentity: "设备身份不存在，请先生成设备密钥。"
        }
    }
}
