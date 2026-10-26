import Foundation

// Main actor owner serializes system preference changes and rejects overlapping actions.
// Tokens prevent a late completion from ending a newer operation.
public struct OperationGate: Sendable {
    public private(set) var token: UUID?
    public init() {}
    public mutating func begin() -> UUID? {
        guard token == nil else { return nil }
        let newToken = UUID(); token = newToken; return newToken
    }
    public mutating func finish(_ finishedToken: UUID) {
        if token == finishedToken { token = nil }
    }
    public var isBusy: Bool { token != nil }
}
