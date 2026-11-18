import RAMcapCore
import SwiftUI

struct PanelView: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    private let width: CGFloat = 308

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            total
            if model.chromeRunning { gauge }
            banner
            separator
            tabs
            separator
            limit
            separator
            recent
            separator
            footer
        }
        .padding(16)
        .frame(width: 340)
        .background(Palette.panel)
        .foregroundStyle(Palette.primary)
        .onAppear { model.panelOpen = true }
        .onDisappear { model.panelOpen = false }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            HStack(spacing: 6) {
                GlyphShape().fill(Palette.primary).frame(width: 14, height: 14)
                Text("RAMcap").font(.system(size: 13, weight: .semibold))
            }
            Spacer()
            pill
        }
    }

    private var pill: some View {
        let (label, color, tint): (String, Color, Color) = switch model.status {
        case .ok: ("Under limit", Palette.ok, Palette.tintOK)
        case .warn: ("Warning", Palette.warn, Palette.tintWarn)
        case .stopping: ("Stopping in \(secondsLeft) s", Palette.danger, Palette.tintDanger)
        case .stopped: ("Stopped \(model.lastStop?.count ?? 1) tab\(model.lastStop?.count == 1 ? "" : "s")", Palette.danger, Palette.tintDanger)
        case .paused: ("Paused · \(minutesLeft) min", Palette.secondary, Palette.tintNeutral)
        }
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
        }
        .padding(.leading, 7).padding(.trailing, 8).padding(.vertical, 2)
        .background(tint, in: Capsule())
    }

    private var secondsLeft: Int {
        max(0, Int((model.nextDeadline ?? model.now).timeIntervalSince(model.now).rounded(.up)))
    }

    private var minutesLeft: Int {
        max(1, Int(((model.pausedUntil ?? model.now).timeIntervalSince(model.now) / 60).rounded(.up)))
    }

    // MARK: Total + gauge

    private var total: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.chromeRunning ? "Chrome is using" : "Google Chrome")
                .font(.system(size: 12)).foregroundStyle(Palette.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.chromeRunning ? Format.gb(model.snapshot.total) : (model.hasScanned ? "Not running" : "Measuring…"))
                    .font(.system(size: 32, weight: .semibold)).monospacedDigit().tracking(-0.5)
                if model.chromeRunning {
                    Text("of \(model.hardLimitGB) GB limit").font(.system(size: 13)).foregroundStyle(Palette.secondary)
                }
            }
        }
    }

    private var gaugeColor: Color {
        switch model.status {
        case .paused: Palette.tertiary
        case .warn: Palette.warn
        default: model.snapshot.total >= model.limits.hard ? Palette.danger
            : model.snapshot.total >= model.limits.warn ? Palette.warn : Palette.ok
        }
    }

    private var gauge: some View {
        let hard = Double(model.limits.hard), fraction = min(Double(model.snapshot.total) / hard, 1)
        let warnX = width * Double(model.limits.warn) / hard
        return VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track).frame(width: width, height: 8)
                Capsule().fill(gaugeColor).frame(width: max(8, width * fraction), height: 8)
                RoundedRectangle(cornerRadius: 1).fill(Palette.secondary).frame(width: 2, height: 14).offset(x: warnX - 1)
            }
            .frame(height: 14)
            ZStack(alignment: .leading) {
                Text("0")
                Text("warn \(Int(Double(model.limits.warn) / bytesPerGB))").fixedSize().position(x: warnX, y: 6)
                Text("\(model.hardLimitGB) GB").fontWeight(.medium).foregroundStyle(Palette.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.system(size: 10)).foregroundStyle(Palette.tertiary)
            .frame(width: width, height: 12)
        }
    }

    @ViewBuilder private var banner: some View {
        if model.status == .paused, let until = model.pausedUntil {
            bannerBox("Paused until \(until.formatted(date: .omitted, time: .shortened)). RAMcap keeps measuring but won’t warn or stop tabs.", tint: Palette.tintNeutral)
        } else if model.status == .stopping {
            let n = model.pending.count
            let size = Format.gb(model.pending.values.reduce(0) { $0 + $1.process.footprint })
            let what = n == 1 ? "its largest tab (\(size))" : "\(n) tabs (\(size))"
            VStack(alignment: .leading, spacing: 8) {
                Text("Chrome is at \(Format.gb(model.snapshot.total)). RAMcap will stop \(what) in \(secondsLeft) s. Protect keeps \(n == 1 ? "it" : "them") until \(n == 1 ? "it closes" : "they close").")
                    .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Protect") { model.protectPending() }.controlSize(.small)
                    Button("Stop now") { model.stopPendingNow() }.controlSize(.small)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.tintDanger, in: RoundedRectangle(cornerRadius: 8))
        } else if model.status == .stopped, let s = model.lastStop {
            let what = s.count == 1 ? "its largest tab" : "its \(s.count) largest tabs"
            let it = s.count == 1 ? "The tab is still open as “Aw, Snap”. Reload it" : "The tabs are still open as “Aw, Snap”. Reload them"
            bannerBox("Chrome hit \(Format.gb(s.total)), so RAMcap stopped \(what) (\(Format.gb(s.freed))). \(it) to bring \(s.count == 1 ? "it" : "them") back.", tint: Palette.tintDanger)
        }
    }

    private func bannerBox(_ text: String, tint: Color) -> some View {
        Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Largest tabs

    private var namesOn: Bool { model.tabNamesOn && model.accessibilityTrusted }

    private var tabsTrailing: String? {
        guard model.chromeRunning else { return nil }
        if namesOn {
            if model.readingNames { return "reading names…" }
            if let r = model.names { return "from Chrome’s Task Manager · \(r.date.formatted(date: .omitted, time: .shortened))" }
        }
        return "\(model.snapshot.tabs.count) tab processes · \(model.snapshot.processes.count) total"
    }

    private var tabs: some View {
        let all = model.snapshot.tabs
        let top = Array(all.prefix(5))
        let largest = Double(top.first?.footprint ?? 1)
        return VStack(alignment: .leading, spacing: 8) {
            sectionHeader("LARGEST TABS", trailing: tabsTrailing)
            if top.isEmpty {
                Text(model.chromeRunning ? "No tab processes." : "Open Chrome and its tabs show up here.")
                    .font(.system(size: 12)).foregroundStyle(Palette.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(top, id: \.pid) { p in
                        if namesOn { namedRow(p) } else { tabRow(p, fraction: Double(p.footprint) / largest) }
                    }
                }
                namesCallout
            }
        }
    }

    @ViewBuilder private var namesCallout: some View {
        if !model.tabNamesOn {
            callout("See which tab is which, and protect tabs from being stopped.", button: "Turn On…")
        } else if !model.accessibilityTrusted {
            callout("Tab names need Accessibility permission for RAMcap.", button: "Allow…")
        } else if model.names?.sortedByMemory == false {
            callout("Sort Chrome’s Task Manager by Memory Footprint once, so the largest tabs get names.", button: "Show Me…")
        } else {
            Text("Stopped tabs stay open as “Aw, Snap”. Reload one to bring it back.")
                .font(.system(size: 11)).foregroundStyle(Palette.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func callout(_ text: String, button: String) -> some View {
        HStack(spacing: 8) {
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(button) { openSetup() }.controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Palette.tintNeutral, in: RoundedRectangle(cornerRadius: 8))
    }

    private func openSetup() {
        openWindow(id: "tab-names")
        NSApp.activate()
    }

    private func namedRow(_ p: BrowserProcess) -> some View {
        let name = model.displayName(p)
        let isProtected = model.protected.contains(p.identity)
        let pending = model.pending[p.identity] != nil
        var detail = "\(Format.gb2(p.footprint)) · pid \(String(p.pid))"
        if let name, name.count > 1 { detail += " · closes all \(name.count)" }
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name.map { $0.count > 1 ? "\($0.title) (\($0.count) tabs)" : $0.title }
                     ?? model.otherName(p) ?? (model.readingNames ? "Reading name…" : "Name not available"))
                    .font(.system(size: 13, weight: name == nil ? .regular : .medium))
                    .foregroundStyle(name == nil ? Palette.secondary : Palette.primary)
                    .lineLimit(1).truncationMode(.tail)
                HStack(spacing: 6) {
                    Text(detail).font(.system(size: 11)).foregroundStyle(Palette.tertiary).monospacedDigit().lineLimit(1)
                    if pending { Text("stopping").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.danger) }
                }
            }
            Spacer(minLength: 4)
            if isProtected {
                Button { model.unprotect(p) } label: {
                    Label("Protected", systemImage: "pin.fill").font(.system(size: 12)).foregroundStyle(Palette.cap)
                }
                .buttonStyle(.plain).help("Protected: RAMcap won’t stop this tab. Click to unprotect.")
            } else {
                Button { model.protect(p) } label: {
                    Image(systemName: "pin").font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                }
                .buttonStyle(.plain).help("Protect: RAMcap won’t stop this tab until it closes.")
                Button("Stop") { model.stop(p) }.controlSize(.small)
            }
        }
        .padding(.vertical, 7)
    }

    private func tabRow(_ p: BrowserProcess, fraction: Double) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Format.gb2(p.footprint)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    Text("pid \(String(p.pid))").font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                    if model.pending[p.identity] != nil {
                        Text("stopping").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.danger)
                    } else if model.protected.contains(p.identity) {
                        Text("protected").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.ok)
                    }
                }
                Capsule().fill(Palette.track).frame(height: 4)
                    .overlay(alignment: .leading) {
                        GeometryReader { g in
                            Capsule().fill(Palette.secondary).frame(width: max(4, g.size.width * fraction), height: 4)
                        }
                    }
            }
            if model.protected.contains(p.identity) {
                Button("Unprotect") { model.unprotect(p) }.controlSize(.small)
            } else {
                Button("Stop") { model.stop(p) }.controlSize(.small)
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: Limit

    private var limit: some View {
        let binding = Binding<Double>(get: { Double(model.hardLimitGB) }, set: { model.hardLimitGB = Int($0.rounded()) })
        let warn = Int(Double(model.limits.warn) / bytesPerGB), perTab = Int(Double(model.limits.perTab) / bytesPerGB)
        return VStack(alignment: .leading, spacing: 8) {
            sectionHeader("LIMIT", trailing: nil)
            HStack {
                Text("Stop tabs above").font(.system(size: 13))
                Spacer()
                Text("\(model.hardLimitGB) GB").font(.system(size: 13, weight: .semibold)).monospacedDigit()
            }
            Slider(value: binding, in: 4...Double(max(model.ramGB, 5)), step: 1).tint(Palette.cap).controlSize(.small)
            HStack {
                Text("4 GB")
                Spacer()
                Text("\(model.ramGB) GB · all RAM")
            }
            .font(.system(size: 10)).foregroundStyle(Palette.tertiary)
            Text("Warns at \(warn) GB. Any single tab over \(perTab) GB is stopped too.")
                .font(.system(size: 11)).foregroundStyle(Palette.secondary)
        }
    }

    // MARK: Recent

    private var recent: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("RECENT", trailing: nil)
            if model.events.isEmpty {
                Text("Nothing yet.").font(.system(size: 12)).foregroundStyle(Palette.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.events.prefix(3)) { e in
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(color(for: e.kind)).frame(width: 6, height: 6).padding(.top, 5)
                        Text(e.message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Text(Format.when(e.date, now: model.now)).font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                    }
                }
            }
        }
    }

    private func color(for kind: Event.Kind) -> Color {
        switch kind {
        case .warn: Palette.warn
        case .stop: Palette.danger
        case .info: Palette.ok
        case .pause: Palette.tertiary
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 12) {
            HStack {
                if model.isPaused {
                    Button("Resume now") { model.resume() }.buttonStyle(.borderedProminent).tint(Palette.cap)
                } else {
                    Button("Pause for 1 hour") { model.pauseForAnHour() }
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            HStack {
                Text("Show tab names").font(.system(size: 13))
                Spacer()
                Toggle("Show tab names", isOn: Binding(get: { model.tabNamesOn }, set: { on in
                    if on { openSetup() } else { model.tabNamesOn = false }
                }))
                .toggleStyle(.switch).controlSize(.small).labelsHidden()
            }
            HStack {
                Text("Open at login").font(.system(size: 13))
                Spacer()
                Toggle("Open at login", isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
            }
        }
    }

    // MARK: Bits

    private var separator: some View { Rectangle().fill(Palette.separator).frame(height: 1) }

    private func sectionHeader(_ title: String, trailing: String?) -> some View {
        HStack {
            Text(title).font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(Palette.tertiary)
            Spacer()
            if let trailing { Text(trailing).font(.system(size: 10)).foregroundStyle(Palette.tertiary) }
        }
    }
}
