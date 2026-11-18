import Darwin
import Testing
@testable import RAMcapCore

@Suite struct ClassifierTests {
    @Test(arguments: [
        ([], ProcessKind.browser, "browser"),
        (["--type=renderer", "--lang=en"], .tab, "tab"),
        (["--type=renderer", "--extension-process"], .extension_, "extension"),
        (["--type=gpu-process"], .gpu, "gpu-process"),
        (["--type=utility", "--utility-sub-type=network.mojom.NetworkService"], .utility, "utility"),
        (["--type=crashpad-handler"], .other, "crashpad-handler"),
    ] as [([String], ProcessKind, String)])
    func classify(args: [String], kind: ProcessKind, name: String) {
        let result = Classifier.classify(args)
        #expect(result.kind == kind)
        #expect(result.typeName == name)
    }
}

@Suite struct ScannerTests {
    @Test func parsesProcArgsAndSkipsEnvironment() {
        var bytes: [UInt8] = [2, 0, 0, 0]
        bytes += Array("/bin/exe".utf8) + [0, 0, 0, 0]
        bytes += Array("/bin/exe".utf8) + [0] + Array("--type=renderer".utf8) + [0]
        bytes += Array("HOME=/Users/x".utf8) + [0]
        #expect(Scanner.parseProcArgs(bytes) == ["/bin/exe", "--type=renderer"])
    }

    @Test func rejectsTruncatedProcArgs() {
        #expect(Scanner.parseProcArgs([UInt8]([1, 0])) == nil)
    }

    @Test func readsOwnProcess() throws {
        let pid = getpid()
        #expect(Scanner.allPids().contains(pid))
        #expect(try #require(Scanner.footprint(pid)) > 0)
        #expect(!Scanner.path(pid).isEmpty)
        #expect(Scanner.identity(pid) == Scanner.identity(pid))
        #expect(try #require(Scanner.arguments(pid)).first?.isEmpty == false)
    }

    @Test func enforcerRefusesNonTabsAndReusedPids() {
        let me = getpid()
        let id = Scanner.identity(me)!
        let browser = BrowserProcess(pid: me, footprint: 1, kind: .browser, typeName: "browser", identity: id)
        #expect(Enforcer.stop(browser) == .notATab)
        var stale = id
        stale.startTime -= 1
        let reused = BrowserProcess(pid: me, footprint: 1, kind: .tab, typeName: "tab", identity: stale)
        #expect(Enforcer.stop(reused) == .replaced)
    }
}
