import Darwin

/// Finds the watched browser's processes and measures them. Works on processes
/// owned by the same user with no entitlements, helper or root.
public struct Scanner: Sendable {
    /// A process is watched when its executable lives inside one of these bundles.
    public var bundlePaths: [String]

    public static let chrome = "/Applications/Google Chrome.app/"

    public init(bundlePaths: [String] = [Scanner.chrome]) {
        self.bundlePaths = bundlePaths
    }

    public func scan() -> Snapshot {
        var found: [BrowserProcess] = []
        for pid in Self.allPids() {
            let path = Self.path(pid)
            guard bundlePaths.contains(where: { path.hasPrefix($0) }),
                  let footprint = Self.footprint(pid),
                  let start = Self.startTime(pid)
            else { continue }
            let (kind, typeName) = Classifier.classify(Self.arguments(pid) ?? [])
            found.append(BrowserProcess(
                pid: pid, footprint: footprint, kind: kind, typeName: typeName,
                identity: ProcessIdentity(path: path, startTime: start)))
        }
        return Snapshot(processes: found)
    }

    // MARK: - Darwin calls

    public static func allPids() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = proc_listallpids(&pids, Int32(MemoryLayout<pid_t>.size * pids.count))
        return n > 0 ? Array(pids.prefix(Int(n))).filter { $0 > 0 } : []
    }

    public static func footprint(_ pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return r == 0 ? info.ri_phys_footprint : nil
    }

    public static func path(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self) : ""
    }

    /// Start time in microseconds since 1970.
    public static func startTime(_ pid: pid_t) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }

    public static func identity(_ pid: pid_t) -> ProcessIdentity? {
        let p = path(pid)
        guard !p.isEmpty, let start = startTime(pid) else { return nil }
        return ProcessIdentity(path: p, startTime: start)
    }

    public static func arguments(_ pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        return parseProcArgs(buf.prefix(size))
    }

    /// Parses a `KERN_PROCARGS2` buffer: a 32-bit argc, the executable path,
    /// NUL padding, then argc NUL-terminated arguments, then the environment
    /// (which is skipped).
    public static func parseProcArgs<C: Collection<UInt8>>(_ bytes: C) -> [String]? where C.Index == Int {
        let b = Array(bytes)
        guard b.count >= 4 else { return nil }
        let argc = Int(b[0]) | Int(b[1]) << 8 | Int(b[2]) << 16 | Int(b[3]) << 24
        var i = 4
        while i < b.count, b[i] != 0 { i += 1 }  // executable path
        while i < b.count, b[i] == 0 { i += 1 }  // padding
        var args: [String] = []
        while args.count < argc, i < b.count {
            let start = i
            while i < b.count, b[i] != 0 { i += 1 }
            args.append(String(decoding: b[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }
}
