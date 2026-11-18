import AppKit
import Foundation
import Observation
import RAMcapCore
import ServiceManagement

struct Event: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case warn, stop, info, pause }
    var id = UUID()
    var date: Date
    var kind: Kind
    var message: String
}

struct StopSummary: Hashable {
    var date: Date
    var count: Int
    var freed: UInt64
    var total: UInt64
}

/// A tab the policy wants stopped, held for a grace period first.
struct PendingStop: Hashable {
    var process: BrowserProcess
    var deadline: Date
}

enum Status { case ok, warn, stopping, stopped, paused }

@MainActor @Observable
final class AppModel {
    // Live state
    private(set) var snapshot = Snapshot(processes: [])
    private(set) var hasScanned = false
    private(set) var events: [Event] = []
    private(set) var lastStop: StopSummary?
    private(set) var pausedUntil: Date?
    private(set) var openAtLogin = false
    private(set) var now = Date()
    /// Tabs about to be stopped, keyed by identity. Empty when nothing is pending.
    private(set) var pending: [ProcessIdentity: PendingStop] = [:]
    /// Tabs the user chose to keep. Forgotten when the process exits.
    private(set) var protected: Set<ProcessIdentity> = []

    static let grace: TimeInterval = 20

    // Tab names (opt-in; read from Chrome's Task Manager)
    var tabNamesOn: Bool {
        didSet {
            defaults.set(tabNamesOn, forKey: Keys.tabNames)
            if !tabNamesOn { names = nil }
        }
    }
    private(set) var accessibilityTrusted = TabNames.isTrusted
    private(set) var names: TabNameReading?
    private(set) var readingNames = false

    /// The hard limit in whole GB; warn level and per-tab cap follow from it.
    var hardLimitGB: Int {
        didSet { defaults.set(hardLimitGB, forKey: Keys.hard) }
    }

    var panelOpen = false {
        didSet {
            guard panelOpen != oldValue else { return }
            restartLoop()
            if panelOpen { refreshNamesIfStale() }
        }
    }

    let ramGB: Int
    private let defaults: UserDefaults
    private let notifier: Notifier?
    private var lastWarning: Date?
    private var loop: Task<Void, Never>?
    private var deadlineTick: Task<Void, Never>?

    private enum Keys {
        static let hard = "hardLimitGB", paused = "pausedUntil", warned = "lastWarning", events = "events"
        static let tabNames = "tabNamesOn"
    }

    init(defaults: UserDefaults = .standard, notifier: Notifier? = Notifier(), startLoop: Bool = true) {
        self.defaults = defaults
        self.notifier = notifier
        ramGB = Int((Double(ProcessInfo.processInfo.physicalMemory) / bytesPerGB).rounded())
        let defaultHard = Int((Double(Limits.defaults().hard) / bytesPerGB).rounded())
        hardLimitGB = (defaults.object(forKey: Keys.hard) as? Int) ?? defaultHard
        tabNamesOn = defaults.bool(forKey: Keys.tabNames)
        pausedUntil = defaults.object(forKey: Keys.paused) as? Date
        lastWarning = defaults.object(forKey: Keys.warned) as? Date
        if let data = defaults.data(forKey: Keys.events), let saved = try? JSONDecoder().decode([Event].self, from: data) {
            events = saved
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
        if startLoop {
            notifier?.requestAuthorization()
            Notifier.onResponse = { [weak self] response in
                switch response {
                case .protect: self?.protectPending()
                case .stopNow: self?.stopPendingNow()
                }
            }
            if events.isEmpty { log(.info, "Started watching Google Chrome") }
            restartLoop()
        }
    }

    // MARK: - Derived

    var limits: Limits {
        let hard = Double(hardLimitGB)
        let perTab = min((Double(Limits.defaults().perTab) / bytesPerGB).rounded(), hard)
        return Limits(warnGB: (hard * 0.75).rounded(), hardGB: hard, perTabGB: perTab)
    }

    var isPaused: Bool { pausedUntil.map { $0 > now } ?? false }

    var status: Status {
        if isPaused { return .paused }
        if !pending.isEmpty { return .stopping }
        if let s = lastStop, now.timeIntervalSince(s.date) < 10 * 60 { return .stopped }
        return snapshot.total >= limits.warn ? .warn : .ok
    }

    var chromeRunning: Bool { !snapshot.processes.isEmpty }

    var labelImage: NSImage {
        let text = !hasScanned ? "…" : isPaused ? "Paused" : chromeRunning ? Format.gb(snapshot.total) : "—"
        let recentStop = !pending.isEmpty || (lastStop.map { now.timeIntervalSince($0.date) < 10 } ?? false)
        let color: NSColor? = isPaused || !chromeRunning ? nil
            : (recentStop || snapshot.total >= limits.hard) ? Palette.menuDanger
            : snapshot.total >= limits.warn ? Palette.menuWarn : nil
        return StatusLabel.image(text: text, color: color, dimmed: isPaused)
    }

    // MARK: - Loop

    private func restartLoop() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                let open = self?.panelOpen ?? false
                try? await Task.sleep(for: .seconds(open ? 2 : 15))
            }
        }
    }

    func tick() async {
        let snap = await Task.detached(priority: .utility) { Scanner().scan() }.value
        now = Date()
        snapshot = snap
        hasScanned = true
        if let p = pausedUntil, p <= now {
            pausedUntil = nil
            defaults.removeObject(forKey: Keys.paused)
            log(.pause, "Resumed after pause")
        }
        let alive = Set(snap.processes.map(\.identity))
        protected.formIntersection(alive)
        let actions = Policy.evaluate(snap, limits: limits, lastWarning: lastWarning, pausedUntil: pausedUntil,
                                      protected: protected, now: now)
        apply(actions, to: snap)
    }

    private func apply(_ actions: [Action], to snap: Snapshot) {
        // Stops go through a grace period: a new victim becomes pending and is
        // stopped on a later pass if the policy still wants it once its deadline passes.
        let wanted = actions.compactMap { if case .stop(let p) = $0 { p } else { nil } }
        let wantedIDs = Set(wanted.map(\.identity))
        let hadPending = !pending.isEmpty
        pending = pending.filter { wantedIDs.contains($0.key) }
        if hadPending && pending.isEmpty && wanted.isEmpty {
            log(.info, "Chrome dropped below the limit, so no tab was stopped")
            notifier?.clearPending()
        }

        var stopped: [BrowserProcess] = []
        var fresh: [BrowserProcess] = []
        for p in wanted {
            if let entry = pending[p.identity] {
                pending[p.identity]?.process = p
                guard entry.deadline <= now else { continue }
                pending[p.identity] = nil
                switch Enforcer.stop(p) {
                case .stopped: stopped.append(p)
                case .gone, .replaced: break
                case let other: log(.info, "Couldn’t stop pid \(p.pid) (\(other))")
                }
            } else {
                pending[p.identity] = PendingStop(process: p, deadline: now.addingTimeInterval(Self.grace))
                fresh.append(p)
            }
        }
        if !fresh.isEmpty {
            let total = snap.total
            Task { [weak self] in
                await self?.readNames()
                self?.announcePending(total: total)
            }
        }
        if pending.isEmpty && (hadPending || !stopped.isEmpty) { notifier?.clearPending() }
        scheduleDeadlineTick()

        for action in actions {
            switch action {
            case .stop: break
            case .warn(let total):
                lastWarning = now
                defaults.set(now, forKey: Keys.warned)
                log(.warn, "Passed the \(Format.gbWhole(limits.warn)) warning level (\(Format.gb(total)))")
                notifier?.send(title: "Chrome is using \(Format.gb(total))",
                               body: "Tabs get stopped at \(Format.gbWhole(limits.hard)). Close a few heavy tabs to stay under.")
            }
        }
        guard !stopped.isEmpty else { return }
        let freed = stopped.reduce(0) { $0 + $1.footprint }
        let n = stopped.count, tabs = n == 1 ? "tab" : "tabs"
        lastStop = StopSummary(date: now, count: n, freed: freed, total: snap.total)
        let named = n == 1 ? displayName(stopped[0]).map { " (“\($0.title)”)" } ?? "" : ""
        log(.stop, "Stopped \(n) \(tabs)\(named) using \(Format.gb(freed)). Chrome was at \(Format.gb(snap.total))")
        notifier?.send(title: "Stopped \(n) Chrome \(tabs)",
                       body: "Chrome hit \(Format.gb(snap.total)). Stopped \(n) \(tabs) using \(Format.gb(freed)). Reload the “Aw, Snap” \(tabs) to restore.")
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            await self?.tick()
        }
    }

    // MARK: - Grace period

    private func announcePending(total: UInt64) {
        guard !pending.isEmpty else { return }
        let victims = pending.values.map(\.process).sorted { $0.footprint > $1.footprint }
        let n = victims.count, tabs = n == 1 ? "tab" : "tabs"
        let size = Format.gb(victims.reduce(0) { $0 + $1.footprint })
        let seconds = max(1, Int((nextDeadline ?? now).timeIntervalSinceNow.rounded()))
        if n == 1, let name = displayName(victims[0]) {
            log(.warn, "About to stop “\(name.title)” using \(size). Chrome is at \(Format.gb(total))")
            let more = name.count > 1 ? " It shares a process with \(name.count - 1) more tab\(name.count == 2 ? "" : "s"), which stop too." : ""
            notifier?.sendPending(
                title: "Stopping “\(name.title)” in \(seconds) s",
                body: "Chrome is at \(Format.gb(total)). This tab uses \(size).\(more) Protect to keep it, or stop now.")
        } else {
            log(.warn, "About to stop \(n) \(tabs) using \(size). Chrome is at \(Format.gb(total))")
            let named = victims.compactMap { displayName($0)?.title }.prefix(3).map { "“\($0)”" }
            let which = named.isEmpty ? "" : " (\(named.joined(separator: ", "))\(n > named.count ? ", …" : ""))"
            notifier?.sendPending(
                title: "Stopping \(n) Chrome \(tabs) in \(seconds) s",
                body: "Chrome is at \(Format.gb(total)). RAMcap will stop \(n == 1 ? "a tab" : "\(n) tabs")\(which) using \(size). Protect to keep \(n == 1 ? "it" : "them"), or stop now.")
        }
    }

    // MARK: - Tab names

    /// The tab title(s) Chrome's Task Manager showed for this process.
    func displayName(_ p: BrowserProcess) -> (title: String, count: Int)? {
        guard let titles = names?.tabs[p.pid], let first = titles.first else { return nil }
        return (first, titles.count)
    }

    /// What a process holds when it holds no tab, e.g. "Frame: linkedin.com".
    func otherName(_ p: BrowserProcess) -> String? {
        guard let other = names?.other[p.pid] else { return nil }
        if other.hasPrefix("Subframe: "), let host = URL(string: String(other.dropFirst(10)))?.host() {
            return "Frame: \(host)"
        }
        return other
    }

    func refreshAccessibility() { accessibilityTrusted = TabNames.isTrusted }

    private func refreshNamesIfStale() {
        guard tabNamesOn else { return }
        if let date = names?.date, Date().timeIntervalSince(date) < 60 { return }
        Task { await readNames() }
    }

    /// Reads names from Chrome's Task Manager (about 2 s; it opens and closes
    /// that window). Does nothing unless tab names are on and allowed.
    func readNames() async {
        refreshAccessibility()
        guard tabNamesOn, accessibilityTrusted, !readingNames,
              let browser = snapshot.processes.first(where: { $0.kind == .browser }) else { return }
        readingNames = true
        defer { readingNames = false }
        let pid = browser.pid
        let result = await Task.detached(priority: .userInitiated) {
            Result { () throws(TabNamesError) in try TabNames.read(chromePID: pid) }
        }.value
        switch result {
        case .success(let reading): names = reading
        case .failure(let error): log(.info, "Couldn’t read tab names (\(error))")
        }
    }

    private var chromePID: pid_t? { snapshot.processes.first(where: { $0.kind == .browser })?.pid }

    func showTaskManager() {
        guard let pid = chromePID else { return }
        do { try TabNames.showTaskManager(chromePID: pid) } catch { log(.info, "Couldn’t open Chrome’s Task Manager (\(error))") }
    }

    /// For the setup's sort step: true once an open Task Manager (or the
    /// latest reading) is sorted by memory, largest first.
    func checkTaskManagerSorted() async -> Bool {
        if names?.sortedByMemory == true { return true }
        guard let pid = chromePID else { return false }
        return await Task.detached { TabNames.openTaskManagerIsSortedByMemory(chromePID: pid) ?? false }.value
    }

    func protect(_ process: BrowserProcess) {
        protected.insert(process.identity)
        if pending.removeValue(forKey: process.identity) != nil, pending.isEmpty { notifier?.clearPending() }
        Task { await tick() }
    }

    /// Wakes the loop when the earliest pending deadline passes.
    private func scheduleDeadlineTick() {
        deadlineTick?.cancel()
        guard let next = pending.values.map(\.deadline).min() else { return }
        let delay = max(0, next.timeIntervalSinceNow) + 0.2
        deadlineTick = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.tick()
        }
    }

    var nextDeadline: Date? { pending.values.map(\.deadline).min() }

    func protectPending() {
        guard !pending.isEmpty else { return }
        let n = pending.count
        protected.formUnion(pending.keys)
        pending = [:]
        deadlineTick?.cancel()
        notifier?.clearPending()
        log(.info, "Protected \(n) tab\(n == 1 ? "" : "s") until \(n == 1 ? "it closes" : "they close")")
        Task { await tick() }
    }

    func stopPendingNow() {
        guard !pending.isEmpty else { return }
        for id in pending.keys { pending[id]?.deadline = .distantPast }
        Task { await tick() }
    }

    func unprotect(_ process: BrowserProcess) {
        protected.remove(process.identity)
        Task { await tick() }
    }

    // MARK: - Actions from the panel

    func stop(_ process: BrowserProcess) {
        pending[process.identity] = nil
        if pending.isEmpty { notifier?.clearPending() }
        let result = Enforcer.stop(process)
        if result == .stopped {
            let named = displayName(process).map { " “\($0.title)”" } ?? ""
            log(.stop, "Stopped a tab\(named) using \(Format.gb(process.footprint)) (by hand)")
        } else {
            log(.info, "Couldn’t stop pid \(process.pid) (\(result))")
        }
        Task { await tick() }
    }

    func pauseForAnHour() {
        pausedUntil = Date().addingTimeInterval(3600)
        defaults.set(pausedUntil, forKey: Keys.paused)
        now = Date()
        log(.pause, "Paused for 1 hour")
    }

    func resume() {
        pausedUntil = nil
        defaults.removeObject(forKey: Keys.paused)
        now = Date()
        log(.pause, "Resumed")
        Task { await tick() }
    }

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log(.info, "Couldn’t change Open at login: \(error.localizedDescription)")
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Log

    private func log(_ kind: Event.Kind, _ message: String) {
        events.insert(Event(date: Date(), kind: kind, message: message), at: 0)
        if events.count > 50 { events.removeLast(events.count - 50) }
        if let data = try? JSONEncoder().encode(events) { defaults.set(data, forKey: Keys.events) }
    }

    // MARK: - Previews

    /// A model with fixed data, for `--render` and previews. Never scans or stops anything.
    static func preview(total gb: Double, tabs: [Double], hard: Int = 16, status: Status, events: [(Event.Kind, String, TimeInterval)],
                        names: [[String]]? = nil, protectedIndex: Int? = nil) -> AppModel {
        let suite = UserDefaults(suiteName: "RAMcapPreview-\(UUID().uuidString)")!
        let m = AppModel(defaults: suite, notifier: nil, startLoop: false)
        m.hardLimitGB = hard
        let GB = bytesPerGB
        var procs = tabs.enumerated().map { i, t in
            BrowserProcess(pid: pid_t(91838 - i * 9137), footprint: UInt64(t * GB), kind: .tab, typeName: "tab",
                           identity: ProcessIdentity(path: "", startTime: .random(in: 1 ... .max)))
        }
        let rest = max(0, gb - tabs.reduce(0, +))
        procs.append(BrowserProcess(pid: 32514, footprint: UInt64(rest * GB), kind: .browser, typeName: "browser",
                                    identity: ProcessIdentity(path: "", startTime: .random(in: 1 ... .max))))
        for i in 0..<40 {
            procs.append(BrowserProcess(pid: pid_t(40000 + i), footprint: 1, kind: .tab, typeName: "tab",
                                        identity: ProcessIdentity(path: "", startTime: .random(in: 1 ... .max))))
        }
        m.snapshot = Snapshot(processes: procs)
        if let names {
            m.tabNamesOn = true
            m.accessibilityTrusted = true
            let rows = zip(procs, names).flatMap { p, titles in titles.map { TaskManagerRow(kind: "Tab", title: $0, pid: p.pid) } }
            m.names = TabNameReading(rows: rows, sortedByMemory: true, date: Date())
            if let i = protectedIndex { m.protected = [procs[i].identity] }
        }
        m.hasScanned = true
        m.now = Date()
        m.events = events.map { Event(date: Date().addingTimeInterval(-$0.2), kind: $0.0, message: $0.1) }
        switch status {
        case .paused: m.pausedUntil = Date().addingTimeInterval(52 * 60)
        case .stopping:
            let victim = procs[0]
            m.pending = [victim.identity: PendingStop(process: victim, deadline: Date().addingTimeInterval(14))]
        case .stopped: m.lastStop = StopSummary(date: Date().addingTimeInterval(-60), count: 1, freed: UInt64(6.1 * GB), total: UInt64(16.4 * GB))
        default: break
        }
        return m
    }
}

enum Format {
    static func gb(_ bytes: UInt64) -> String { String(format: "%.1f GB", Double(bytes) / bytesPerGB) }
    static func gb2(_ bytes: UInt64) -> String { String(format: "%.2f GB", Double(bytes) / bytesPerGB) }
    static func gbWhole(_ bytes: UInt64) -> String { String(format: "%g GB", (Double(bytes) / bytesPerGB).rounded()) }

    static func when(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.abbreviated))
    }
}
