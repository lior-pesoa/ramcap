import Darwin

/// What a process is inside the browser. Only `.tab` is ever eligible to be stopped.
public enum ProcessKind: String, Sendable, Hashable, CaseIterable {
    case browser
    case tab
    case extension_ = "extension"
    case gpu
    case utility
    case other
}

/// Identifies one specific process, so a reused pid is never mistaken for it.
public struct ProcessIdentity: Sendable, Hashable {
    public var path: String
    /// Process start time in microseconds since 1970.
    public var startTime: UInt64

    public init(path: String, startTime: UInt64) {
        self.path = path
        self.startTime = startTime
    }
}

public struct BrowserProcess: Sendable, Hashable {
    public var pid: pid_t
    /// `ri_phys_footprint` in bytes: the number Activity Monitor shows, including
    /// compressed and swapped memory. RSS undercounts badly under pressure.
    public var footprint: UInt64
    public var kind: ProcessKind
    /// The raw `--type=` value (or "browser" / "tab" / "extension"), for display.
    public var typeName: String
    public var identity: ProcessIdentity

    public init(pid: pid_t, footprint: UInt64, kind: ProcessKind, typeName: String, identity: ProcessIdentity) {
        self.pid = pid
        self.footprint = footprint
        self.kind = kind
        self.typeName = typeName
        self.identity = identity
    }
}

public struct Snapshot: Sendable, Hashable {
    /// Largest footprint first.
    public var processes: [BrowserProcess]

    public init(processes: [BrowserProcess]) {
        self.processes = processes.sorted(by: Snapshot.largestFirst)
    }

    public var total: UInt64 { processes.reduce(0) { $0 + $1.footprint } }
    public var tabs: [BrowserProcess] { processes.filter { $0.kind == .tab } }

    /// Largest footprint first; ties go to the higher pid (matches the Python guard).
    static func largestFirst(_ a: BrowserProcess, _ b: BrowserProcess) -> Bool {
        a.footprint != b.footprint ? a.footprint > b.footprint : a.pid > b.pid
    }
}
