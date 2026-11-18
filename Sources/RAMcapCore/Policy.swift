import Foundation

public let bytesPerGB: Double = 1_073_741_824  // GiB, as Activity Monitor and top report

public struct Limits: Sendable, Hashable {
    public var warn: UInt64
    public var hard: UInt64
    public var perTab: UInt64

    public init(warn: UInt64, hard: UInt64, perTab: UInt64) {
        self.warn = warn
        self.hard = hard
        self.perTab = perTab
    }

    public init(warnGB: Double, hardGB: Double, perTabGB: Double) {
        self.init(warn: UInt64(warnGB * bytesPerGB), hard: UInt64(hardGB * bytesPerGB),
                  perTab: UInt64(perTabGB * bytesPerGB))
    }

    /// Warn at 50%, hard limit at 65%, per-tab cap at 25% of physical RAM,
    /// each rounded to the nearest whole GB (12 / 16 / 6 on a 24 GB Mac).
    public static func defaults(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Limits {
        let ram = Double(physicalMemory) / bytesPerGB
        return Limits(warnGB: (ram * 0.50).rounded(), hardGB: (ram * 0.65).rounded(),
                      perTabGB: (ram * 0.25).rounded())
    }
}

public enum Action: Sendable, Hashable {
    case warn(total: UInt64)
    case stop(BrowserProcess)
}

public enum Policy {
    public static let maxStopsPerPass = 5
    public static let warnInterval: TimeInterval = 30 * 60

    /// The v1 rules, as a pure function.
    ///
    /// 1. Any tab at or above the per-tab cap is stopped.
    /// 2. If the total is still at or above the hard limit, stop the largest
    ///    remaining tabs until the projected total is under it.
    /// 3. At most `maxStopsPerPass` stops.
    /// 4. Otherwise warn at or above the warning level, at most once per `warnInterval`.
    /// 5. While paused, nothing.
    ///
    /// Tabs in `protected` are never stopped; they still count toward the total.
    public static func evaluate(
        _ snapshot: Snapshot,
        limits: Limits,
        lastWarning: Date? = nil,
        pausedUntil: Date? = nil,
        protected: Set<ProcessIdentity> = [],
        now: Date = Date()
    ) -> [Action] {
        if let pausedUntil, now < pausedUntil { return [] }

        let total = snapshot.total
        let tabs = snapshot.tabs.filter { !protected.contains($0.identity) }  // largest first
        var victims = tabs.filter { $0.footprint >= limits.perTab }
        var projected = total - victims.reduce(0) { $0 + $1.footprint }
        for tab in tabs where projected >= limits.hard && !victims.contains(tab) {
            victims.append(tab)
            projected -= tab.footprint
        }
        if !victims.isEmpty {
            return victims.prefix(maxStopsPerPass).map { .stop($0) }
        }

        if total >= limits.warn {
            if let lastWarning, now.timeIntervalSince(lastWarning) < warnInterval { return [] }
            return [.warn(total: total)]
        }
        return []
    }
}
