import Darwin

public enum StopResult: Sendable, Hashable {
    case stopped
    /// The process already exited.
    case gone
    /// The pid now belongs to a different process; nothing was signalled.
    case replaced
    /// Refused: only tab processes are ever stopped.
    case notATab
    case failed(errno: Int32)
}

public enum Enforcer {
    /// Sends SIGKILL to a tab process after confirming the pid still belongs to
    /// the same process (same executable and start time). The tab stays open in
    /// Chrome as "Aw, Snap"; reloading it restores it.
    public static func stop(_ process: BrowserProcess) -> StopResult {
        guard process.kind == .tab else { return .notATab }
        guard let current = Scanner.identity(process.pid) else { return .gone }
        guard current == process.identity else { return .replaced }
        if kill(process.pid, SIGKILL) == 0 { return .stopped }
        return errno == ESRCH ? .gone : .failed(errno: errno)
    }
}
