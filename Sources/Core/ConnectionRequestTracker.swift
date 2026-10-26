import Foundation

public enum ConnectionAction: String, Sendable { case connect, disconnect }

/// Tracks an outstanding user request separately from the authoritative OS state.
/// The OS may still report `disconnected` immediately after accepting a start request.
public struct ConnectionRequestTracker: Sendable {
    public struct Request: Sendable {
        public let token: UUID
        public let action: ConnectionAction
        public let deadline: Date
        fileprivate var observedConnecting = false
    }
    public private(set) var request: Request?
    public init() {}

    @discardableResult
    public mutating func begin(_ action: ConnectionAction, now: Date = Date()) -> UUID? {
        if request != nil && !(action == .disconnect && request?.action == .connect) { return nil }
        let token = UUID()
        request = Request(token: token, action: action, deadline: now.addingTimeInterval(action == .connect ? 30 : 10))
        return token
    }

    public mutating func observe(_ state: TunnelState) {
        guard var current = request else { return }
        switch current.action {
        case .connect:
            if state == .connecting { current.observedConnecting = true; request = current }
            if state == .connected || state == .reasserting || state == .invalid || state == .unconfigured ||
                (state == .disconnected && current.observedConnecting) { request = nil }
        case .disconnect:
            if state == .disconnected || state == .invalid || state == .unconfigured { request = nil }
        }
    }

    public mutating func cancel(_ token: UUID) {
        if request?.token == token { request = nil }
    }

    public mutating func expire(_ token: UUID, now: Date = Date()) -> ConnectionAction? {
        guard let current = request, current.token == token, now >= current.deadline else { return nil }
        request = nil
        return current.action
    }
}
