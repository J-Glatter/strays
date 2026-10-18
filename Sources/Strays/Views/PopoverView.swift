import StraysCore
import SwiftUI

/// The panel. Only this view observes the Store; everything below gets plain values plus
/// an unobserved Store reference for actions, and rows are Equatable, so a refresh only
/// redraws the rows whose text changed.
struct PopoverView: View {
    @EnvironmentObject private var store: Store

    /// Debug snapshots (`--snapshot … --tall --expand-first`) lift the cap and open the first row.
    static var maxListHeight: CGFloat = 600
    static var expandFirst = false

    var body: some View {
        let panel = store.panel
        VStack(spacing: 0) {
            HeaderView(showLegend: panel.showLegend, store: store)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if panel.showLegend { LegendView() }
                    ForEach(panel.warnings) { WarningRow(warning: $0, store: store) }
                    if let battery = panel.battery { BatterySection(model: battery).equatable() }
                    HiddenSection(rows: panel.hidden, exposed: panel.exposedCount, loaded: panel.loaded, store: store)
                    if !panel.sessions.isEmpty {
                        ClaudeSection(sessions: panel.sessions, summary: panel.sessionsSummary, idleCount: panel.idleSessionCount, store: store)
                    }
                    if !panel.blockers.isEmpty {
                        SectionHeader(title: "Keeping the Mac awake", count: panel.blockers.count,
                                      blurb: "These stop your Mac going to sleep when you leave it.")
                        ForEach(panel.blockers) { BlockerRow(blocker: $0, store: store).equatable() }
                    }
                    if !panel.machines.isEmpty {
                        SectionHeader(title: "VMs & simulators", count: panel.machines.count,
                                      blurb: "Each runs a whole extra operating system. Quit the ones you aren't using.")
                        ForEach(panel.machines) { StrayRow(row: $0, store: store).equatable() }
                    }
                    if panel.showIgnored, !panel.ignored.isEmpty {
                        SectionHeader(title: "Ignored", count: panel.ignored.count,
                                      blurb: "Hidden from the count. Right-click to un-ignore.")
                        ForEach(panel.ignored) { StrayRow(row: $0, store: store).equatable() }
                    }
                }
                .padding(.bottom, 8)
            }
            // Size the list to its content, capped; the panel grows and shrinks with it.
            .frame(maxHeight: Self.maxListHeight)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            FooterView(ignoredCount: panel.ignoredCount, showIgnored: panel.showIgnored, store: store)
        }
        .frame(width: 420)
        .background(WindowVisibility { store.setOpen($0) })
    }
}

/// Reports whether the panel's window is actually on screen. `onAppear`/`onDisappear` aren't
/// reliable for a MenuBarExtra panel, and a missed "closed" would leave the fast refresh running.
private struct WindowVisibility: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView { ObserverView(onChange: onChange) }
    func updateNSView(_ view: ObserverView, context: Context) {}

    final class ObserverView: NSView {
        private let onChange: (Bool) -> Void
        private var tokens: [NSObjectProtocol] = []

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens = []
            guard let window else { return onChange(false) }
            let names: [Notification.Name] = [
                NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification, NSWindow.willCloseNotification,
            ]
            for name in names {
                tokens.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    let closing = note.name == NSWindow.willCloseNotification
                    MainActor.assumeIsolated { self?.report(closing: closing) }
                })
            }
            report(closing: false)
        }

        private func report(closing: Bool) {
            guard let window else { return }
            onChange(!closing && window.isVisible && window.occlusionState.contains(.visible))
        }
    }
}

// MARK: - Header, legend, footer

private struct HeaderView: View {
    let showLegend: Bool
    let store: Store

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "pawprint.fill").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text("Strays").font(.headline)
                Text("Things running on your Mac that nothing is watching")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                store.showLegend.toggle()
            } label: {
                Image(systemName: showLegend ? "questionmark.circle.fill" : "questionmark.circle")
            }
            .buttonStyle(.borderless)
            .help("What am I looking at?")
            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh now")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct LegendView: View {
    private let entries: [(String, String, String)] = [
        ("pawprint", "Hidden & orphaned", "Still running after the terminal or Claude session that started it closed. Nothing is attached to it, so stopping it is safe unless you're using it."),
        ("flame.fill", "Orange", "Using a lot of power right now (15%+ CPU or 1 W+, sustained)."),
        ("cpu", "% CPU", "100% means one processor core is fully busy."),
        ("bolt", "W (watts)", "Its power draw, from macOS's own energy accounting. Your whole Mac idles at a few watts."),
        ("network", ":5173", "A network port it's listening on. Orange means other devices on your network can connect to it."),
        ("stop.circle", "Stop", "Asks it to quit, then force-quits after 3 seconds. Click a row for details, right-click for more."),
        ("eye.slash", "Ignore", "Hides something you want running from the count and the menu bar."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(entries, id: \.1) { icon, term, text in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: icon).frame(width: 16).foregroundStyle(.secondary)
                    (Text(term).fontWeight(.semibold) + Text("  " + text).foregroundColor(.secondary))
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }
}

private struct FooterView: View {
    let ignoredCount: Int
    let showIgnored: Bool
    let store: Store
    @State private var openAtLogin = LoginItem.isEnabled
    @State private var notifyHot = Prefs.notifyHot
    @State private var notifyLeftovers = Prefs.notifyLeftovers
    @State private var hookInstalled = ClaudeHook.isInstalled
    @State private var hookMessage: String?

    var body: some View {
        HStack(spacing: 12) {
            Menu {
                if LoginItem.isAvailable {
                    Toggle("Open at login", isOn: Binding(get: { openAtLogin }, set: { openAtLogin = $0; LoginItem.set($0) }))
                }
                Toggle("Notify when something hidden drains the battery",
                       isOn: Binding(get: { notifyHot }, set: { notifyHot = $0; Prefs.notifyHot = $0 }))
                Toggle("Notify when a Claude session leaves things running",
                       isOn: Binding(get: { notifyLeftovers }, set: { notifyLeftovers = $0; Prefs.notifyLeftovers = $0 }))
                Divider()
                if hookInstalled {
                    Text("Claude Code hook: installed")
                } else {
                    Button("Set up Claude Code hook…") {
                        hookMessage = ClaudeHook.install()
                        hookInstalled = ClaudeHook.isInstalled
                    }
                }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Settings")

            if let hookMessage {
                Text(hookMessage).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if ignoredCount > 0 {
                Button(showIgnored ? "Hide ignored" : "Ignored (\(ignoredCount))") { store.showIgnored.toggle() }
            }
            Button("Quit") { NSApp.terminate(nil) }
        }
        .buttonStyle(.link)
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

// MARK: - Sections

struct SectionHeader<Trailing: View>: View {
    let title: String
    var count: Int?
    var blurb: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                if let count { Text(String(count)).font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary) }
                Spacer()
                trailing
            }
            if let blurb {
                Text(blurb).font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String, count: Int? = nil, blurb: String? = nil) {
        self.init(title: title, count: count, blurb: blurb) { EmptyView() }
    }
}

/// A button that needs a second click within 4 s, for anything that stops several things.
struct ConfirmButton: View {
    let label: String
    let confirmLabel: String
    let action: () -> Void
    @State private var armed = false

    var body: some View {
        Button(armed ? confirmLabel : label) {
            if armed {
                action()
                armed = false
            } else {
                armed = true
                Task {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    armed = false
                }
            }
        }
        .buttonStyle(.link)
        .font(.caption)
        .foregroundStyle(armed ? Color.red : Color.accentColor)
    }
}

private struct BatterySection: View, Equatable {
    let model: BatteryModel

    nonisolated static func == (a: BatterySection, b: BatterySection) -> Bool { a.model == b.model }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Battery").padding(.horizontal, -14)
            Text(model.now).font(.callout)
            if let stray = model.strayLine {
                Text(stray)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(model.strayHot ? Color.orange : Color.secondary)
            }
            if model.points.count > 1 {
                Sparkline(points: model.points, deaths: model.deathXs)
                    .frame(height: 38)
                    .padding(.top, 2)
                HStack {
                    Text("24 hours ago")
                    Spacer()
                    Label("charging", systemImage: "circle.fill").foregroundStyle(.green).labelStyle(DotLabel())
                    Label("on battery", systemImage: "circle.fill").foregroundStyle(Color.accentColor).labelStyle(DotLabel())
                    if !model.deathXs.isEmpty {
                        Label("ran flat", systemImage: "circle.fill").foregroundStyle(.red).labelStyle(DotLabel())
                    }
                    Spacer()
                    Text("now")
                }
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            }
            if let flat = model.flatLine {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "battery.0percent").foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(flat).font(.caption).fixedSize(horizontal: false, vertical: true)
                        if let detail = model.flatDetail {
                            Text(detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 14)
    }
}

private struct DotLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 5))
            configuration.title.foregroundStyle(.secondary)
        }
    }
}

/// Charge over the last 24 h: green while charging, accent colour on battery, red dots where it died.
private struct Sparkline: View {
    let points: [BatteryModel.Point]
    let deaths: [Double]

    var body: some View {
        Canvas { ctx, size in
            func pt(_ p: BatteryModel.Point) -> CGPoint {
                CGPoint(x: p.x * size.width, y: (1 - p.y) * (size.height - 4) + 2)
            }
            var grid = Path()
            for level in [0.2, 0.5, 0.8] {
                let y = (1 - level) * (size.height - 4) + 2
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: size.width, y: y))
            }
            ctx.stroke(grid, with: .color(.secondary.opacity(0.15)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))

            for i in 1..<points.count {
                var seg = Path()
                seg.move(to: pt(points[i - 1]))
                seg.addLine(to: pt(points[i]))
                ctx.stroke(seg, with: .color(points[i].onAC ? .green : .accentColor), lineWidth: 1.5)
            }
            for x in deaths {
                let c = CGPoint(x: x * size.width, y: size.height - 3)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)), with: .color(.red))
            }
        }
        .accessibilityLabel("Battery charge over the last 24 hours")
    }
}

private struct HiddenSection: View {
    let rows: [RowModel]
    let exposed: Int
    let loaded: Bool
    let store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Hidden & orphaned", count: rows.count,
                          blurb: "Still running after the terminal or Claude session that started them closed.") {
                if rows.count > 1 {
                    ConfirmButton(label: "Stop all", confirmLabel: "Stop all \(rows.count)?") { store.stopAll(rows.map(\.id)) }
                }
            }
            if exposed > 0 {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "network").foregroundStyle(.orange)
                    Text("\(exposed) of these can be reached by other devices on your network.")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    ConfirmButton(label: "Stop those", confirmLabel: "Stop \(exposed)?") { store.stopExposed() }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.1)))
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
            }
            if rows.isEmpty {
                EmptyRow(text: loaded ? "Nothing hidden right now." : "Scanning…")
            } else {
                ForEach(rows) { row in
                    StrayRow(row: row, store: store, expanded: PopoverView.expandFirst && row.id == rows.first?.id)
                        .equatable()
                }
            }
        }
    }
}

private struct ClaudeSection: View {
    let sessions: [SessionModel]
    let summary: String
    let idleCount: Int
    let store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Claude sessions", count: sessions.count,
                          blurb: "Claude Code sessions that are still open (\(summary)). Idle ones still hold memory.") {
                if idleCount > 0 {
                    ConfirmButton(label: "End \(idleCount) idle", confirmLabel: "End \(idleCount) idle for 1d+?") { store.endIdleSessions() }
                        .help("Ends Claude sessions that are idle and over a day old, with anything they're running")
                }
            }
            ForEach(sessions) { ClaudeSessionRow(session: $0, store: store).equatable() }
        }
    }
}

private struct BlockerRow: View, Equatable {
    let blocker: BlockerModel
    let store: Store

    nonisolated static func == (a: BlockerRow, b: BlockerRow) -> Bool { a.blocker == b.blocker }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "cup.and.saucer").foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(blocker.process).font(.system(size: 13, weight: .medium))
                Text(blocker.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if let left = blocker.timeLeft {
                Text(left).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if blocker.canStop {
                StopButton(busy: blocker.stopping, help: "Stop \(blocker.process)") { store.stopBlocker(blocker.id) }
            } else {
                Color.clear.frame(width: 20, height: 1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

// MARK: - Small pieces

struct EmptyRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle").foregroundStyle(.green)
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

struct WarningRow: View {
    let warning: SystemWarning
    let store: Store
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(warning.title).font(.system(size: 12, weight: .semibold))
                Text(warning.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let fix = warning.fix {
                    HStack(spacing: 8) {
                        Text(fix).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        Button(copied ? "Copied" : "Copy") {
                            store.copy(fix)
                            copied = true
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                    .padding(.top, 2)
                    Text("Paste into Terminal; it asks for your password.").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }
}

struct Metrics: View {
    let cpu: String
    let secondary: String
    var hot = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(cpu)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(hot ? Color.orange : Color.primary)
            Text(secondary)
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 76, alignment: .trailing)
    }
}

struct StopButton: View {
    let busy: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Group {
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Button(action: action) {
                    Image(systemName: "stop.circle").font(.system(size: 15))
                }
                .buttonStyle(.borderless)
                .help(help)
            }
        }
        .frame(width: 20, height: 20)
    }
}

struct PortBadge: View {
    let port: ListeningPort

    var body: some View {
        Text(verbatim: ":\(port.port)")
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .fixedSize()
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Capsule().fill(port.exposed ? Color.orange.opacity(0.2) : Color.primary.opacity(0.08)))
            .help(port.exposed ? "Port \(port.port): other devices on your network can connect" : "Port \(port.port): this Mac only")
    }
}
