import ApplicationServices
import Foundation

/// One row of Chrome's Task Manager: the Task column ("Tab: Inbox - Gmail")
/// split into kind and title, plus the Process ID column.
public struct TaskManagerRow: Sendable, Hashable {
    public var kind: String
    public var title: String
    public var pid: pid_t
    /// The Memory Footprint column in bytes; nil while Chrome shows "–".
    public var memory: UInt64?

    public init(kind: String, title: String, pid: pid_t, memory: UInt64? = nil) {
        self.kind = kind
        self.title = title
        self.pid = pid
        self.memory = memory
    }

    /// Builds a row from the Task, Memory Footprint and Process ID cells. The
    /// header row ("Column Task", "Column Process ID") and rows without a pid give nil.
    public init?(task: String, memory: String = "", pid: String) {
        guard let pid = pid_t(pid.trimmingCharacters(in: .whitespaces)), pid > 0 else { return nil }
        let bytes = Self.bytes(memory)
        if let colon = task.range(of: ": ") {
            let title = task[colon.upperBound...].unicodeScalars.filter { !Self.directionMarks.contains($0) }
            self.init(kind: String(task[..<colon.lowerBound]), title: String(String.UnicodeScalarView(title)), pid: pid, memory: bytes)
        } else {
            self.init(kind: task, title: "", pid: pid, memory: bytes)  // "Browser", "GPU Process"
        }
    }

    /// "1,012 MB" → bytes. Nil for "–" or anything unreadable.
    static func bytes(_ text: String) -> UInt64? {
        guard let m = text.wholeMatch(of: /([\d.,]+) ?([KMGT]?)B/),
              let n = Double(m.1.replacingOccurrences(of: ",", with: "")) else { return nil }
        let power: Double = switch m.2 { case "K": 1; case "M": 2; case "G": 3; case "T": 4; default: 0 }
        return UInt64(n * pow(1024, power))
    }

    /// Parses a row's accessibility title, "<task>, <memory>, <cpu>, <network>, and <pid>",
    /// optionally followed by ". Other 2 tasks in the same task group: …" (or
    /// ". Another task …"). The task may itself contain commas, and memory can
    /// have a thousands separator ("1,007 MB"), so the columns are matched from the end.
    public init?(rowTitle: String) {
        var text = Substring(rowTitle)
        if let r = text.firstMatch(of: /\. (?:Another task|Other \d+ tasks) in the same task group/) {
            text = text[..<r.range.lowerBound]
        }
        guard let and = text.range(of: ", and ", options: .backwards) else { return nil }
        let pid = String(text[and.upperBound...])
        let head = text[..<and.lowerBound]
        guard let columns = head.firstMatch(of: /, ([\d.,]+ ?[KMGT]?B|–|-|N\/A), (?:[\d.,]+|–|-|N\/A), (?:[\d.,]+(?: ?[KMGT]?B(?:\/s)?)?|–|-|N\/A)$/)
        else { return nil }
        self.init(task: String(head[..<columns.range.lowerBound]), memory: String(columns.1), pid: pid)
    }

    /// Finds rows in a flat run of cell texts: five cells (task, memory, CPU,
    /// network, pid) where the second is a memory size and the fifth a pid.
    public static func rows(fromCells cells: [String]) -> [TaskManagerRow] {
        var rows: [TaskManagerRow] = []
        var i = 0
        while i + 4 < cells.count {
            if cells[i + 1].wholeMatch(of: /[\d.,]+ ?[KMGT]?B|–|-|N\/A/) != nil,
               let row = TaskManagerRow(task: cells[i], memory: cells[i + 1], pid: cells[i + 4]) {
                rows.append(row)
                i += 5
            } else {
                i += 1
            }
        }
        return rows
    }

    /// Invisible bidi marks Chrome wraps right-to-left titles in.
    private static let directionMarks = Set("\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}".unicodeScalars)

    /// Rows that are browser tabs (as opposed to extensions, subframes, workers…).
    public var isTab: Bool { ["Tab", "Incognito Tab", "App", "Incognito App"].contains(kind) && !title.isEmpty }
}

public struct TaskManagerReading: Sendable {
    public var rows: [TaskManagerRow]
    /// True when the table is sorted by Memory Footprint, largest first, so the
    /// rows Chrome exposes (only the on-screen ones) are the largest processes.
    public var sortedByMemory: Bool

    /// True once Chrome has filled in memory figures (and, when sorted by
    /// memory, applied that order) for the rows on screen.
    static func isSettled(_ rows: [TaskManagerRow], sortedByMemory: Bool) -> Bool {
        let sizes = rows.compactMap(\.memory)
        guard sizes.count >= min(5, rows.count), !sizes.isEmpty else { return false }
        return !sortedByMemory || zip(sizes, sizes.dropFirst()).allSatisfy { $0 >= $1 }
    }
}

/// What RAMcap shows per tab process.
public struct TabNameReading: Sendable, Hashable {
    /// Tab titles per process, in Task Manager order. Several when one process
    /// holds several tabs of one site.
    public var tabs: [pid_t: [String]]
    /// For processes that hold no tab: what they hold instead, e.g. "Subframe: https://linkedin.com/".
    public var other: [pid_t: String]
    public var sortedByMemory: Bool
    public var date: Date

    public init(rows: [TaskManagerRow], sortedByMemory: Bool, date: Date = Date()) {
        var tabs: [pid_t: [String]] = [:], other: [pid_t: String] = [:]
        for row in rows {
            if row.isTab {
                if !(tabs[row.pid]?.contains(row.title) ?? false) { tabs[row.pid, default: []].append(row.title) }
            } else if other[row.pid] == nil {
                other[row.pid] = row.title.isEmpty ? row.kind : "\(row.kind): \(row.title)"
            }
        }
        self.tabs = tabs
        self.other = other.filter { tabs[$0.key] == nil }
        self.sortedByMemory = sortedByMemory
        self.date = date
    }
}

public enum TabNamesError: Error, Sendable {
    case notTrusted
    case noTaskManagerMenu
    case taskManagerDidNotOpen
    case tableNotFound
}

/// Reads tab names per process from Chrome's own Task Manager, through the
/// Accessibility API. Needs Accessibility permission. Opens the Task Manager
/// window (Window › Task Manager) if it isn't open, and closes it again.
/// English-locale Chrome only: it matches menu and window titles.
///
/// Chrome exposes only the on-screen rows (about 38 in a full-height window)
/// and no scroll bar element, and its column headers can't be pressed through
/// accessibility. So names are complete for the largest processes only when
/// the user has sorted the table by Memory Footprint once; Chrome remembers
/// that sort (Local State, task_manager.column_visibility.sort_column_id).
public enum TabNames {
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that adds the app to Accessibility settings.
    public static func requestTrust() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Titles per tab process. One process can hold several tabs of one site.
    public static func read(chromePID: pid_t) throws(TabNamesError) -> TabNameReading {
        let reading = try readRows(chromePID: chromePID)
        return TabNameReading(rows: reading.rows, sortedByMemory: reading.sortedByMemory)
    }

    /// The rows Chrome exposes, header excluded, and how the table is sorted.
    public static func readRows(chromePID: pid_t) throws(TabNamesError) -> TaskManagerReading {
        guard isTrusted else { throw .notTrusted }
        let app = AXUIElementCreateApplication(chromePID)
        AXUIElementSetMessagingTimeout(app, 2)
        var window = taskManagerWindow(app)
        let openedByUs = window == nil
        if window == nil {
            try openTaskManager(app)
            for _ in 0..<40 where window == nil {
                usleep(50_000)
                window = taskManagerWindow(app)
            }
        }
        guard let window else { throw .taskManagerDidNotOpen }
        defer { if openedByUs { close(window) } }

        var table: AXUIElement?
        for _ in 0..<20 where table == nil {
            table = find(role: "AXTable", in: window, depth: 16)
            if table == nil { usleep(50_000) }
        }
        guard var table else { throw .tableNotFound }


        // A freshly opened Task Manager lists rows in its default order with no
        // memory figures, and applies the sort 1–2 s later. Wait until the rows
        // carry memory figures in the expected order (at most 4 s).
        var rows: [TaskManagerRow] = [], sorted = false
        for attempt in 0..<40 {
            if let t = find(role: "AXTable", in: window, depth: 16) { table = t }
            let header = elements(table, kAXChildrenAttribute).first.flatMap(cellText) ?? ""
            sorted = header.contains("Memory Footprint sorted in descending order")
            rows = visibleRows(table)
            if TaskManagerReading.isSettled(rows, sortedByMemory: sorted) || (!openedByUs && attempt > 0) { break }
            usleep(100_000)
        }
        return TaskManagerReading(rows: rows, sortedByMemory: sorted)
    }

    /// The rows Chrome currently exposes. Usually whole rows with five cells;
    /// sometimes a flat mix of rows (text in the title) and loose cells.
    private static func visibleRows(_ table: AXUIElement) -> [TaskManagerRow] {
        var rows: [TaskManagerRow] = [], loose: [String] = []
        for child in elements(table, kAXChildrenAttribute) {
            if string(child, kAXRoleAttribute) == "AXCell" {
                loose.append(cellText(child) ?? "")
                continue
            }
            let cells = elements(child, kAXChildrenAttribute)
            if cells.count >= 5, let task = cellText(cells[0]), let pid = cellText(cells[cells.count - 1]),
               let row = TaskManagerRow(task: task, memory: cellText(cells[1]) ?? "", pid: pid) {
                rows.append(row)
            } else if let row = cellText(child).flatMap(TaskManagerRow.init(rowTitle:)) {
                rows.append(row)
            }
        }
        return rows + TaskManagerRow.rows(fromCells: loose)
    }

    /// Opens Chrome's Task Manager and leaves it open (for the one-time sort step).
    public static func showTaskManager(chromePID: pid_t) throws(TabNamesError) {
        guard isTrusted else { throw .notTrusted }
        let app = AXUIElementCreateApplication(chromePID)
        if taskManagerWindow(app) == nil { try openTaskManager(app) }
    }

    /// Whether an already-open Task Manager is sorted by Memory Footprint,
    /// largest first. Nil when it isn't open. Never opens it.
    public static func openTaskManagerIsSortedByMemory(chromePID: pid_t) -> Bool? {
        guard isTrusted, let window = taskManagerWindow(AXUIElementCreateApplication(chromePID)),
              let table = find(role: "AXTable", in: window, depth: 16) else { return nil }
        let header = elements(table, kAXChildrenAttribute).first.flatMap(cellText) ?? ""
        return header.contains("Memory Footprint sorted in descending order")
    }

    // MARK: - AX helpers

    private static func taskManagerWindow(_ app: AXUIElement) -> AXUIElement? {
        elements(app, kAXWindowsAttribute).first { string($0, kAXTitleAttribute) == "Task Manager" }
    }

    private static func openTaskManager(_ app: AXUIElement) throws(TabNamesError) {
        guard let bar = element(app, kAXMenuBarAttribute),
              let windowItem = elements(bar, kAXChildrenAttribute).first(where: { string($0, kAXTitleAttribute) == "Window" }),
              let menu = elements(windowItem, kAXChildrenAttribute).first,
              let item = elements(menu, kAXChildrenAttribute).first(where: { string($0, kAXTitleAttribute) == "Task Manager" }),
              AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
        else { throw .noTaskManagerMenu }
    }

    private static func close(_ window: AXUIElement) {
        if let button = element(window, kAXCloseButtonAttribute) {
            AXUIElementPerformAction(button, kAXPressAction as CFString)
        }
    }

    private static func cellText(_ cell: AXUIElement) -> String? {
        for attr in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            if let s = string(cell, attr), !s.isEmpty { return s }
        }
        return nil
    }

    private static func find(role: String, in root: AXUIElement, depth: Int) -> AXUIElement? {
        if string(root, kAXRoleAttribute) == role { return root }
        guard depth > 0 else { return nil }
        for child in elements(root, kAXChildrenAttribute) {
            if let hit = find(role: role, in: child, depth: depth - 1) { return hit }
        }
        return nil
    }

    private static func value(_ e: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success ? v : nil
    }

    private static func string(_ e: AXUIElement, _ attr: String) -> String? { value(e, attr) as? String }

    private static func element(_ e: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let v = value(e, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private static func elements(_ e: AXUIElement, _ attr: String) -> [AXUIElement] {
        (value(e, attr) as? [AXUIElement]) ?? []
    }
}
