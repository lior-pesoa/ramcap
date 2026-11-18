import Darwin
import Testing
@testable import RAMcapCore

@Suite struct TaskManagerRowTests {
    @Test func parsesCells() {
        let r = TaskManagerRow(task: "Tab: Inbox - Gmail", pid: "40690")
        #expect(r == TaskManagerRow(kind: "Tab", title: "Inbox - Gmail", pid: 40690))
        #expect(r?.isTab == true)
    }

    @Test func headerAndNonTabs() {
        #expect(TaskManagerRow(task: "Column Task", pid: "Column Process ID") == nil)
        #expect(TaskManagerRow(task: "Browser", pid: "32514")?.isTab == false)
        #expect(TaskManagerRow(task: "Subframe: https://linkedin.com/", pid: "77128")?.isTab == false)
    }

    @Test(arguments: [
        ("Tab: Notifications | LinkedIn, 571 MB, 0.3, 0, and 77074", "Notifications | LinkedIn", 77074),
        ("Tab: Lior Pesoa CV, 125 MB, 0.1, 0, and 81476", "Lior Pesoa CV", 81476),
        ("Tab: Hello, world, 1,007 MB, –, 0, and 42", "Hello, world", 42),
        ("Tab: AI Creator Studio for Video & Images | OpenArt, 322 MB, 0.0, 0, and 32899. Other 2 tasks in the same task group: Dedicated Worker: blob:https://openart.ai/x", "AI Creator Studio for Video & Images | OpenArt", 32899),
        ("Tab: Docs, 2.1 GB, 12.5, 1.2 KB, and 7. Another task in the same task group: Service Worker: https://a.b/", "Docs", 7),
    ])
    func parsesRowTitles(text: String, title: String, pid: Int) {
        let r = TaskManagerRow(rowTitle: text)
        #expect(r?.title == title)
        #expect(r?.pid == pid_t(pid))
        #expect(r?.kind == "Tab")
    }

    @Test func parsesNonTabRowTitles() {
        #expect(TaskManagerRow(rowTitle: "GPU Process, 1,007 MB, –, 0, and 32714") == TaskManagerRow(kind: "GPU Process", title: "", pid: 32714, memory: 1007 << 20))
        #expect(TaskManagerRow(rowTitle: "Column Task, Column Memory Footprint, Column CPU, Column Network, Column Process ID") == nil)
    }

    @Test func stripsDirectionMarks() {
        let r = TaskManagerRow(task: "Tab: \u{200E}\u{202B}ללמוד Langfuse\u{202C}\u{200E}", pid: "1")
        #expect(r?.title == "ללמוד Langfuse")
    }

    @Test func rowsFromLooseCells() {
        let cells = ["32766", "", "Tab: Hacker News", "120 MB", "0.0", "0", "68533",
                     "Subframe: https://a.b/", "–", "–", "0", "11", "Tab: A, B", "1,007 MB", "–", "", "9"]
        #expect(TaskManagerRow.rows(fromCells: cells) == [
            TaskManagerRow(kind: "Tab", title: "Hacker News", pid: 68533, memory: 120 << 20),
            TaskManagerRow(kind: "Subframe", title: "https://a.b/", pid: 11),
            TaskManagerRow(kind: "Tab", title: "A, B", pid: 9, memory: 1007 << 20),
        ])
    }

    @Test func parsesMemory() {
        #expect(TaskManagerRow(rowTitle: "GPU Process, 1,012 MB, 0.7, 0, and 32714")?.memory == 1012 << 20)
        #expect(TaskManagerRow(rowTitle: "GPU Process, 1.0 GB, –, 0, and 32714")?.memory == 1 << 30)
        #expect(TaskManagerRow(rowTitle: "Browser, –, –, –, and 32514")?.memory == nil)
    }

    @Test func settlesOnceSortedFiguresArrive() {
        let blank = (1...6).map { TaskManagerRow(kind: "Tab", title: "t", pid: pid_t($0)) }
        let ordered = (1...6).map { TaskManagerRow(kind: "Tab", title: "t", pid: pid_t($0), memory: UInt64(100 - $0)) }
        #expect(!TaskManagerReading.isSettled(blank, sortedByMemory: true))
        #expect(TaskManagerReading.isSettled(ordered, sortedByMemory: true))
        #expect(!TaskManagerReading.isSettled(ordered.reversed(), sortedByMemory: true))
        #expect(TaskManagerReading.isSettled(ordered.reversed(), sortedByMemory: false))
    }
}
