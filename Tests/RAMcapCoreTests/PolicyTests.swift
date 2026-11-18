import Foundation
import Testing
@testable import RAMcapCore

private let GB: UInt64 = 1 << 30
private let limits = Limits(warn: 12 * GB, hard: 16 * GB, perTab: 6 * GB)

private func proc(_ pid: pid_t, _ gb: Double, _ kind: ProcessKind = .tab) -> BrowserProcess {
    BrowserProcess(pid: pid, footprint: UInt64(gb * Double(GB)), kind: kind, typeName: kind.rawValue,
                   identity: ProcessIdentity(path: "/x", startTime: UInt64(pid)))
}

private func stopped(_ actions: [Action]) -> [pid_t] {
    actions.compactMap { if case .stop(let p) = $0 { p.pid } else { nil } }
}

@Suite struct PolicyTests {
    @Test func underWarnDoesNothing() {
        let s = Snapshot(processes: [proc(1, 3), proc(2, 2, .browser), proc(3, 1, .gpu)])
        #expect(Policy.evaluate(s, limits: limits).isEmpty)
    }

    @Test func warnsAtWarnLevel() {
        let s = Snapshot(processes: [proc(1, 5), proc(2, 5), proc(3, 2, .browser)])
        #expect(Policy.evaluate(s, limits: limits) == [.warn(total: 12 * GB)])
    }

    @Test func warnIsRateLimitedToEvery30Minutes() {
        let s = Snapshot(processes: [proc(1, 5), proc(2, 5), proc(3, 3, .browser)])
        let now = Date()
        #expect(Policy.evaluate(s, limits: limits, lastWarning: now.addingTimeInterval(-29 * 60), now: now).isEmpty)
        #expect(Policy.evaluate(s, limits: limits, lastWarning: now.addingTimeInterval(-30 * 60), now: now).count == 1)
    }

    @Test func stopsAnyTabAtPerTabCap() {
        let s = Snapshot(processes: [proc(1, 6), proc(2, 1), proc(3, 1, .browser)])
        #expect(stopped(Policy.evaluate(s, limits: limits)) == [1])
    }

    @Test func perTabCapNeverAppliesToNonTabs() {
        let s = Snapshot(processes: [proc(1, 7, .gpu), proc(2, 7, .extension_), proc(3, 1)])
        #expect(Policy.evaluate(s, limits: limits) == [.warn(total: 15 * GB)])
    }

    @Test func atHardLimitStopsLargestTabsUntilUnder() {
        // 16 GB total; stopping the 5 GB tab leaves 11, which is under 16.
        let s = Snapshot(processes: [proc(1, 5), proc(2, 4), proc(3, 4), proc(4, 3, .browser)])
        #expect(stopped(Policy.evaluate(s, limits: limits)) == [1])
    }

    @Test func keepsStoppingUntilProjectedTotalIsUnderHardLimit() {
        // 20 GB total, needs > 4 GB freed: 3 + 3 = 6.
        let s = Snapshot(processes: [proc(1, 3), proc(2, 3), proc(3, 2), proc(4, 12, .browser)])
        #expect(stopped(Policy.evaluate(s, limits: limits)) == [2, 1])  // tie → higher pid first
    }

    @Test func perTabStopCountsTowardHardLimit() {
        // 18 GB total; the 6 GB tab goes by rule 1 and brings it to 12, so nothing else goes.
        let s = Snapshot(processes: [proc(1, 6), proc(2, 5), proc(3, 7, .browser)])
        #expect(stopped(Policy.evaluate(s, limits: limits)) == [1])
    }

    @Test func atMostFiveStopsPerPass() {
        let tabs = (1...10).map { proc(pid_t($0), 0.5) }
        let s = Snapshot(processes: tabs + [proc(99, 20, .browser)])
        #expect(stopped(Policy.evaluate(s, limits: limits)).count == 5)
    }

    @Test func neverStopsNonTabsEvenOverHardLimit() {
        let s = Snapshot(processes: [proc(1, 10, .browser), proc(2, 8, .gpu), proc(3, 1, .extension_)])
        #expect(Policy.evaluate(s, limits: limits) == [.warn(total: 19 * GB)])
    }

    @Test func pausedDoesNothing() {
        let s = Snapshot(processes: [proc(1, 20)])
        let now = Date()
        #expect(Policy.evaluate(s, limits: limits, pausedUntil: now.addingTimeInterval(60), now: now).isEmpty)
        #expect(!Policy.evaluate(s, limits: limits, pausedUntil: now.addingTimeInterval(-1), now: now).isEmpty)
    }

    @Test func protectedTabsAreSkippedButStillCount() {
        // 17 GB total; the 6 GB tab is protected, so the next largest goes instead.
        let s = Snapshot(processes: [proc(1, 6), proc(2, 3), proc(3, 8, .browser)])
        let shield: Set = [proc(1, 6).identity]
        #expect(stopped(Policy.evaluate(s, limits: limits, protected: shield)) == [2])
    }

    @Test func onlyProtectedTabsLeftMeansWarn() {
        let s = Snapshot(processes: [proc(1, 7), proc(2, 10, .browser)])
        #expect(Policy.evaluate(s, limits: limits, protected: [proc(1, 7).identity]) == [.warn(total: 17 * GB)])
    }

    @Test func defaultsOn24GBMacMatchPythonGuard() {
        #expect(Limits.defaults(physicalMemory: 24 * GB) == limits)
        #expect(Limits.defaults(physicalMemory: 16 * GB) == Limits(warn: 8 * GB, hard: 10 * GB, perTab: 4 * GB))
    }
}
