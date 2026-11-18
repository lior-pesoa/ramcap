import AppKit
import SwiftUI

@main
enum Main {
    @MainActor static func main() {
        if let i = CommandLine.arguments.firstIndex(of: "--render") {
            let dir = CommandLine.arguments.indices.contains(i + 1) ? CommandLine.arguments[i + 1] : "."
            Renderer.renderStates(to: URL(fileURLWithPath: dir))
            return
        }
        RAMcapApp.main()
    }
}

struct RAMcapApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            Image(nsImage: model.labelImage)
        }
        .menuBarExtraStyle(.window)

        Window("Tab Names", id: "tab-names") {
            TabNamesSetupView(model: model)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
    }
}

/// `RAMcap --render <dir>` draws the panel in each design state to PNGs, for
/// checking the UI against Figma. Uses fixed data; scans and stops nothing.
@MainActor
enum Renderer {
    static func renderStates(to dir: URL) {
        _ = NSApplication.shared
        let warnEvents: [(Event.Kind, String, TimeInterval)] = [
            (.warn, "Passed the 12 GB warning level (12.1 GB)", 60),
            (.stop, "Stopped 1 tab using 6.1 GB. Chrome was at 16.2 GB", 86_400),
            (.info, "Started watching Google Chrome", 3 * 86_400)]
        let states: [(String, NSAppearance.Name, AppModel)] = [
            ("warning-dark", .darkAqua, .preview(total: 13.2, tabs: [1.01, 0.75, 0.62, 0.53, 0.53], status: .warn, events: warnEvents)),
            ("normal-light", .aqua, .preview(total: 8.4, tabs: [0.84, 0.61, 0.40, 0.33, 0.29], status: .ok, events: Array(warnEvents.dropFirst()))),
            ("stopped-dark", .darkAqua, .preview(total: 10.3, tabs: [0.98, 0.62, 0.53, 0.53, 0.41], status: .stopped,
                                                  events: [(.stop, "Stopped 1 tab using 6.1 GB. Chrome was at 16.4 GB", 60)] + warnEvents.dropLast())),
            ("stopping-dark", .darkAqua, .preview(total: 16.3, tabs: [6.1, 0.98, 0.62, 0.53, 0.41], status: .stopping,
                                                   events: [(.warn, "About to stop 1 tab using 6.1 GB. Chrome is at 16.3 GB", 0)] + warnEvents.dropLast())),
            ("paused-light", .aqua, .preview(total: 14.6, tabs: [1.22, 0.93, 0.75, 0.62, 0.55], status: .paused,
                                              events: [(.pause, "Paused for 1 hour", 480)] + warnEvents.dropLast())),
        ]
        let named = AppModel.preview(total: 9.6, tabs: [1.01, 0.75, 0.62, 0.53, 0.53], status: .ok, events: Array(warnEvents.dropFirst()),
                                     names: [["Figma — Design file"], ["Google Docs — Quarterly plan"], ["YouTube — Conference talk"],
                                             ["GitHub", "GitHub — Pull requests", "GitHub — Issues"], ["Gmail — Inbox"]], protectedIndex: 1)
        render(PanelView(model: named), "panel-named-dark", .darkAqua, dir)
        render(PanelView(model: named), "panel-named-light", .aqua, dir)
        render(TabNamesSetupView(model: named, step: .explain), "setup-1-explain", .aqua, dir)
        render(TabNamesSetupView(model: named, step: .permission), "setup-2-permission", .aqua, dir)
        render(TabNamesSetupView(model: named, step: .sort), "setup-3-sort", .darkAqua, dir)
        for (name, appearance, model) in states {
            render(PanelView(model: model), "panel-\(name)", appearance, dir)
        }
        let label = StatusLabel.image(text: "13.2 GB", color: Palette.menuWarn, dimmed: false)
        if let tiff = label.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent("label-warn.png"))
        }
    }

    private static func render(_ root: some View, _ name: String, _ appearance: NSAppearance.Name, _ dir: URL) {
        let view = NSHostingView(rootView: root)
        view.appearance = NSAppearance(named: appearance)
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        view.layoutSubtreeIfNeeded()
        // 2x, so the images stay sharp on Retina screens (README, Figma).
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return }
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        let url = dir.appendingPathComponent("\(name).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print(url.path)
    }
}
