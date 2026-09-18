import Foundation

/// Where the licensing code asks what time it is. Production uses the system
/// clock; tests inject a fixed one so expiry, grace and poll deadlines are
/// asserted against known instants instead of wall time.
public protocol Clock: Sendable {
    func now() -> Date
}

public struct SystemClock: Clock {
    public init() {}
    public func now() -> Date { Date() }
}

/// A clock that only moves when a test moves it.
public final class FixedClock: Clock, @unchecked Sendable {
    public private(set) var current: Date

    public init(_ current: Date) {
        self.current = current
    }

    public func now() -> Date { current }

    public func advance(by interval: TimeInterval) {
        current = current.addingTimeInterval(interval)
    }
}
