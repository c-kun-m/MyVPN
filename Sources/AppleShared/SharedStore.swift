import Foundation
import NPVCore

enum SharedStore {
    static func save(_ profile: TunnelProfile) throws { try write(profile.encoded(), name: "profile.json") }
    static func loadProfile() throws -> TunnelProfile? {
        guard let data = try read(name: "profile.json", limit: TunnelProfile.maximumBytes) else { return nil }
        return try TunnelProfile.decode(data)
    }
    static func saveEvent(_ event: DiagnosticEvent) throws {
        try write(JSONEncoder().encode(event), name: "last-event.json")
    }
    static func loadEvent() throws -> DiagnosticEvent? {
        guard let data = try read(name: "last-event.json", limit: 2_048) else { return nil }
        return try JSONDecoder().decode(DiagnosticEvent.self, from: data)
    }
    private static func write(_ data: Data, name: String) throws {
        let url = try AppEnvironment.containerURL.appendingPathComponent(name)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var resourceURL = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try resourceURL.setResourceValues(values)
    }
    private static func read(name: String, limit: Int) throws -> Data? {
        let url = try AppEnvironment.containerURL.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size <= limit else { throw ProfileError.oversizedProfile }
        return try Data(contentsOf: url)
    }
}
