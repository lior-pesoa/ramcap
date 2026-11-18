import AppKit
import RAMcapCore
import SwiftUI

/// The opt-in flow for tab names: explain → Accessibility permission → sort
/// Chrome's Task Manager by memory once. Figma: "Tab Names — Opt-in".
struct TabNamesSetupView: View {
    let model: AppModel
    @State private var step: Step
    @State private var sorted = false
    @Environment(\.dismissWindow) private var dismissWindow

    enum Step { case explain, permission, sort }

    init(model: AppModel, step: Step? = nil) {
        self.model = model
        _step = State(initialValue: step ?? (!model.tabNamesOn ? .explain : TabNames.isTrusted ? .sort : .permission))
    }

    var body: some View {
        Group {
            switch step {
            case .explain: explain
            case .permission: permission
            case .sort: sort
            }
        }
        .padding(.horizontal, 32).padding(.top, 8).padding(.bottom, 24)
        .frame(width: 458, alignment: .leading)
        .background(Palette.panel)
        .foregroundStyle(Palette.primary)
    }

    // MARK: 1 · Ask first

    private var explain: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
            Text("Show which tab is which?").font(.system(size: 20, weight: .semibold))
            Text("macOS doesn’t tell apps which Chrome tab lives in which process. Chrome’s own Task Manager does, so RAMcap can read the names from there.")
                .font(.system(size: 13)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            box {
                Text("WHAT YOU’LL SEE").font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(Palette.tertiary)
                item(1, "Chrome’s Task Manager opens for a moment, then closes.",
                     "It may flash on screen. That’s RAMcap reading it, not Chrome misbehaving.")
                item(2, "It happens when you open RAMcap’s menu, and just before RAMcap stops a tab.",
                     "Never in the background otherwise.")
                item(3, "macOS asks once to let RAMcap use Accessibility.",
                     "That’s the permission that lets one app read another app’s window.")
                item(4, "RAMcap reads tab titles, memory and process IDs. Nothing else.",
                     "It never reads page contents, and nothing leaves your Mac.")
            }
            Text("With names on you can also pin tabs RAMcap must never stop.")
                .font(.system(size: 12)).foregroundStyle(Palette.secondary)
            HStack(spacing: 8) {
                Spacer()
                Button("Not Now") { dismissWindow() }.controlSize(.large)
                Button("Turn On Tab Names") {
                    model.tabNamesOn = true
                    if TabNames.isTrusted {
                        step = .sort
                    } else {
                        TabNames.requestTrust()
                        step = .permission
                    }
                }
                .buttonStyle(.borderedProminent).tint(Palette.cap).controlSize(.large).keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: 2 · Grant permission

    private var permission: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Allow RAMcap in Accessibility").font(.system(size: 20, weight: .semibold))
            Text("macOS keeps this switch in System Settings. RAMcap can’t turn it on for you.")
                .font(.system(size: 13)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            box {
                step(1, "Click Open System Settings below.")
                step(2, "Find RAMcap in the list and turn it on.")
                step(3, "Come back here. RAMcap notices on its own.")
            }
            status(model.accessibilityTrusted ? "Allowed" : "Waiting for permission…", done: model.accessibilityTrusted)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") {
                    model.tabNamesOn = false
                    dismissWindow()
                }.controlSize(.large)
                Button("Open System Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
                .buttonStyle(.borderedProminent).tint(Palette.cap).controlSize(.large).keyboardShortcut(.defaultAction)
            }
        }
        .task {
            while !Task.isCancelled {
                model.refreshAccessibility()
                if model.accessibilityTrusted {
                    try? await Task.sleep(for: .seconds(0.6))
                    step = .sort
                    NSApp.activate()
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: 3 · Sort by memory, once

    private var sort: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sort by memory, once").font(.system(size: 20, weight: .semibold))
            Text("Chrome shows RAMcap only the rows that fit on screen. Sorted by memory, those are the largest tabs, which are the ones RAMcap needs to name. Chrome remembers the order.")
                .font(.system(size: 13)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            box {
                step(1, "Click Open Task Manager below.")
                step(2, "Click the Memory Footprint column twice, a second apart, so the biggest numbers are at the top. A third click turns sorting off again.")
                step(3, "Close the Task Manager.")
            }
            status(sorted ? "Sorted. Tab names are on." : model.chromeRunning ? "Waiting for the sort…" : "Open Google Chrome first.", done: sorted)
            HStack(spacing: 8) {
                Spacer()
                if sorted {
                    Button("Done") {
                        dismissWindow()
                        Task { await model.readNames() }
                    }
                    .buttonStyle(.borderedProminent).tint(Palette.cap).controlSize(.large).keyboardShortcut(.defaultAction)
                } else {
                    Button("Skip") { dismissWindow() }.controlSize(.large)
                    Button("Open Task Manager") { model.showTaskManager() }
                        .buttonStyle(.borderedProminent).tint(Palette.cap).controlSize(.large).keyboardShortcut(.defaultAction)
                        .disabled(!model.chromeRunning)
                }
            }
        }
        .task {
            while !Task.isCancelled && !sorted {
                sorted = await model.checkTaskManagerSorted()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: Bits

    private func box<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) { content() }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(light: 0xFFFFFF, dark: 0x2A2A2E), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.separator))
    }

    private func number(_ n: Int) -> some View {
        Text("\(n)").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.secondary)
            .frame(width: 20, height: 20).background(Palette.tintNeutral, in: Circle())
    }

    private func item(_ n: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            number(n)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                Text(detail).font(.system(size: 11)).foregroundStyle(Palette.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            number(n).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            Text(text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func status(_ text: String, done: Bool) -> some View {
        HStack(spacing: 8) {
            Circle().fill(done ? Palette.ok : Palette.warn).frame(width: 8, height: 8)
            Text(text).font(.system(size: 12)).foregroundStyle(Palette.secondary)
        }
    }
}
