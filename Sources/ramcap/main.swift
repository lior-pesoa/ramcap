import Foundation
import RAMcapCore

let usage = """
    usage: ramcap status   [--warn GB] [--hard GB] [--tab GB]
           ramcap dry-run  [--warn GB] [--hard GB] [--tab GB]
           ramcap names    [--raw]   (--raw: every Task Manager row)

      status   show Chrome's memory and its largest processes
      dry-run  also show what would be stopped or warned about; changes nothing
      names    name the largest tab processes, read from Chrome's Task Manager
               (needs Accessibility permission; opens and closes that window)

    Limits default to 50% / 65% / 25% of physical RAM.
    """

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first, ["status", "dry-run", "names"].contains(command) else {
    print(usage)
    exit(args.isEmpty || ["-h", "--help", "help"].contains(args[0]) ? 0 : 64)
}
args.removeFirst()

if command == "names" {
    let snap = Scanner().scan()
    guard let browser = snap.processes.first(where: { $0.kind == .browser }) else {
        print("Chrome is not running.")
        exit(0)
    }
    do {
        let start = Date()
        if args.first == "--raw" {
            for row in try TabNames.readRows(chromePID: browser.pid).rows { print("\(row.pid)\t\(row.kind)\t\(row.title)") }
        } else {
            let names = try TabNames.read(chromePID: browser.pid)
            let tabs = snap.tabs
            let named = tabs.filter { names.tabs[$0.pid] != nil || names.other[$0.pid] != nil }.count
            print("Named \(named) of \(tabs.count) tab processes in \(String(format: "%.1f", Date().timeIntervalSince(start))) s"
                  + (names.sortedByMemory ? "" : "\nTip: in Chrome's Task Manager, sort by Memory Footprint (largest first) once; Chrome remembers it."))
            for p in tabs.prefix(10) {
                let titles = names.tabs[p.pid] ?? []
                let label = titles.isEmpty ? (names.other[p.pid].map { "(\($0))" } ?? "?")
                    : titles.count > 1 ? "\(titles[0]) (+\(titles.count - 1) more)" : titles[0]
                print(String(format: "  %5.2f GB  pid %-6d  ", Double(p.footprint) / bytesPerGB, p.pid) + label)
            }
        }
    } catch {
        FileHandle.standardError.write(Data("ramcap: couldn’t read Chrome’s Task Manager (\(error))\n".utf8))
        exit(1)
    }
    exit(0)
}

var limits = Limits.defaults()
while !args.isEmpty {
    let flag = args.removeFirst()
    guard let value = args.first.flatMap(Double.init), value > 0 else {
        FileHandle.standardError.write(Data("ramcap: \(flag) needs a positive number of GB\n".utf8))
        exit(64)
    }
    args.removeFirst()
    let bytes = UInt64(value * bytesPerGB)
    switch flag {
    case "--warn": limits.warn = bytes
    case "--hard": limits.hard = bytes
    case "--tab": limits.perTab = bytes
    default:
        FileHandle.standardError.write(Data("ramcap: unknown option \(flag)\n\(usage)\n".utf8))
        exit(64)
    }
}

func gb(_ bytes: UInt64) -> Double { Double(bytes) / bytesPerGB }
func g(_ bytes: UInt64) -> String { String(format: "%g", gb(bytes)) }

let snapshot = Scanner().scan()
guard !snapshot.processes.isEmpty else {
    print("Chrome is not running.")
    exit(0)
}

print(String(format: "Chrome total: %.1f GB in %d processes ", gb(snapshot.total), snapshot.processes.count)
      + "(warn \(g(limits.warn)), kill-largest \(g(limits.hard)), per-tab \(g(limits.perTab)))")
for p in snapshot.processes.prefix(8) {
    print(String(format: "  %5.2f GB  pid %-6d  ", gb(p.footprint), p.pid) + p.typeName)
}
guard command == "dry-run" else { exit(0) }

let actions = Policy.evaluate(snapshot, limits: limits)
if actions.isEmpty { print("nothing to do") }
for action in actions {
    switch action {
    case .stop(let p):
        print(String(format: "would kill tab process %d (%.1f GB)", p.pid, gb(p.footprint)))
    case .warn(let total):
        print(String(format: "would warn: %.1f GB >= ", gb(total)) + "\(g(limits.warn)) GB")
    }
}
