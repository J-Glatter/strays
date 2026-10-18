import AppKit
import StraysCore

/// What the menu bar icon shows. Equatable so a refresh that changes nothing visible
/// doesn't make SwiftUI re-render anything.
struct Badge: Equatable {
    var count = 0
    var hot = false
    /// Rounded to 0.1 W / whole percent so jitter doesn't churn the label.
    var hotFigure = ""
}

/// User preferences, persisted in UserDefaults.
enum Prefs {
    static var notifyHot: Bool {
        get { UserDefaults.standard.object(forKey: "notifyHot") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "notifyHot") }
    }

    static var notifyLeftovers: Bool {
        get { UserDefaults.standard.object(forKey: "notifyLeftovers") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "notifyLeftovers") }
    }
}

@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    /// Refresh cadence while the panel is open, and how often its slower lookups run.
    static let openInterval: TimeInterval = 3
    static let extrasInterval: TimeInterval = 10
    static let settingsInterval: TimeInterval = 60
    /// pmset's power log is ~7 MB and ~2 s of CPU to read.
    static let powerLogInterval: TimeInterval = 3_600
    static let historyInterval: TimeInterval = 300
    /// How long something hidden must stay hot on battery before a notification
    /// (STRAYS_HOT_AFTER=<seconds> shortens it for testing).
    static let hotNotifyAfter: TimeInterval = ProcessInfo.processInfo.environment["STRAYS_HOT_AFTER"].flatMap(TimeInterval.init) ?? 600
    /// Claude sessions idle and older than this are offered for "End idle".
    static let idleSessionAge: TimeInterval = 86_400

    /// What the panel draws. Only published while it's open, and only when something on
    /// screen actually changed.
    @Published private(set) var panel = PanelModel()
    @Published private(set) var badge = Badge()

    private(set) var isOpen = false
    var showIgnored = false { didSet { publishPanel() } }
    var showLegend = false { didSet { publishPanel() } }

    private var latest = ScanResult(report: .empty, battery: nil)
    private var warnings: [SystemWarning] = []
    private var containers: [DockerContainer] = []
    private var pages: [String: [DevToolsPage]] = [:]
    private var stopping: Set<String> = [] { didSet { publishPanel() } }
    private var ignored: Set<String>
    private let engine = Engine(persistProvenance: true)
    private var loop: Task<Void, Never>?
    private var lastExtras = Date.distantPast
    private var lastSettings = Date.distantPast

    private var powerLog: PowerLog.Summary?
    private var readingPowerLog = false
    private var samples: [HistorySample] = []
    private var lastSample = Date.distantPast
    private var lastSampleOnAC: Bool?
    private var story: BatteryStory?

    private var hotSince: [String: Date] = [:]
    private var notifiedHot: Set<String> = []
    private var handledSessionEnds: Set<String> = []

    private init() {
        ignored = Set(UserDefaults.standard.stringArray(forKey: "ignored") ?? [])
        HistoryStore.prune()
        samples = HistoryStore.load(since: Date().addingTimeInterval(-7 * 86_400))
        story = BatteryStory(log: nil, samples: samples)
    }

    // MARK: Publishing

    private func visible(_ strays: [Stray]) -> [Stray] {
        strays.filter { !ignored.contains($0.signature) }
    }

    private func updateBadge() {
        let strays = visible(latest.report.hidden) + visible(latest.report.machines)
        let hot = strays.filter(\.isHot)
        let watts = hot.reduce(0) { $0 + $1.watts }
        let figure = hot.isEmpty ? "" : watts >= 0.1 ? Fmt.watts(watts) : Fmt.cpu(hot.reduce(0) { $0 + $1.cpuPercent })
        let next = Badge(count: strays.count, hot: !hot.isEmpty, hotFigure: figure)
        if next != badge { badge = next }
    }

    private func publishPanel() {
        guard isOpen else { return }
        let next = PanelModel(PanelInputs(
            report: latest.report, battery: latest.battery, story: story, warnings: warnings,
            containers: containers, pages: pages, stopping: stopping, ignored: ignored,
            showIgnored: showIgnored, showLegend: showLegend, idleAge: Self.idleSessionAge
        ))
        if next != panel { panel = next }
    }

    // MARK: Refresh loop

    func start() {
        Notifier.shared.setUp()
        DistributedNotificationCenter.default().addObserver(
            forName: StraysPaths.sessionEndedNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { Store.shared.sessionEnded() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [engine] _ in engine.flush() }
        restartLoop()
    }

    func setOpen(_ open: Bool) {
        guard open != isOpen else { return }
        isOpen = open
        if open {
            lastExtras = .distantPast
            lastSettings = .distantPast
            // Show the last scan instantly; the restarted loop refreshes straight away.
            publishPanel()
        }
        restartLoop()
    }

    /// Steady while you're looking, slow (slower still on battery) while you're not.
    private var interval: TimeInterval {
        if isOpen { return Self.openInterval }
        return latest.battery?.onExternalPower == false ? 30 : 15
    }

    private func restartLoop() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(nanoseconds: UInt64(self.interval * 1_000_000_000))
            }
        }
    }

    func refresh() async {
        latest = await engine.scan()
        updateBadge()
        recordHistory()
        trackHot()
        guard isOpen else { return }
        if Date().timeIntervalSince(lastExtras) >= Self.extrasInterval {
            lastExtras = Date()
            await refreshExtras()
        }
        publishPanel()
    }

    /// Subprocess and HTTP lookups: only while the panel is open, and not every refresh.
    private func refreshExtras() async {
        let report = latest.report
        let hasDocker = report.machines.contains { $0.title == "Docker Desktop" }
        let browsers = report.hidden.filter { $0.devtoolsPort != nil }
        let probeSettings = Date().timeIntervalSince(lastSettings) >= Self.settingsInterval
        if probeSettings { lastSettings = Date() }

        async let system = Task.detached { probeSettings ? SystemProbe.read() : nil }.value
        async let docker = Task.detached { hasDocker ? (Docker.containers() ?? []) : [] }.value
        var newPages: [String: [DevToolsPage]] = [:]
        for browser in browsers {
            if let port = browser.devtoolsPort { newPages[browser.id] = await DevTools.pages(port: port) }
        }
        if let system = await system { warnings = SystemWarnings.evaluate(system) }
        containers = await docker
        pages = newPages
        readPowerLogIfStale()
    }

    private func readPowerLogIfStale() {
        guard !readingPowerLog, Date().timeIntervalSince(powerLog?.readAt ?? .distantPast) >= Self.powerLogInterval else { return }
        readingPowerLog = true
        Task {
            let summary = await Task.detached(priority: .utility) { PowerLog.read() }.value
            readingPowerLog = false
            if let summary { powerLog = summary }
            story = BatteryStory(log: powerLog, samples: samples)
            publishPanel()
        }
    }

    // MARK: History & notifications

    /// A battery sample every 5 minutes, and whenever the charger goes in or out.
    private func recordHistory() {
        guard let b = latest.battery else { return }
        let now = Date()
        guard now.timeIntervalSince(lastSample) >= Self.historyInterval || lastSampleOnAC != b.onExternalPower else { return }
        lastSample = now
        lastSampleOnAC = b.onExternalPower
        let strays = visible(latest.report.hidden) + visible(latest.report.machines)
        let sample = HistorySample(
            at: now, percent: b.percent, onAC: b.onExternalPower, drawWatts: b.drawWatts,
            strayWatts: strays.reduce(0) { $0 + $1.watts },
            top: strays.sorted(by: Stray.byImpact).prefix(3).map { .init(title: $0.title, watts: $0.watts) }
        )
        samples.append(sample)
        samples.removeAll { $0.at < now.addingTimeInterval(-7 * 86_400) }
        story = BatteryStory(log: powerLog, samples: samples)
        Task.detached(priority: .utility) { HistoryStore.append(sample) }
    }

    /// Notify once when something hidden has stayed hot for 10 minutes on battery.
    private func trackHot() {
        guard let b = latest.battery, !b.onExternalPower else {
            hotSince.removeAll()
            return
        }
        let now = Date()
        let hot = visible(latest.report.hidden).filter(\.isHot)
        hotSince = hotSince.filter { entry in hot.contains { $0.id == entry.key } }
        for s in hot {
            let since = hotSince[s.id] ?? now
            hotSince[s.id] = since
            guard Prefs.notifyHot, now.timeIntervalSince(since) >= Self.hotNotifyAfter, !notifiedHot.contains(s.id) else { continue }
            notifiedHot.insert(s.id)
            let where_ = s.project.map { " in \($0)" } ?? ""
            var body = "\(Fmt.watts(s.watts)), \(Fmt.cpu(s.cpuPercent)) CPU for over \(Fmt.duration(Self.hotNotifyAfter)). Running \(Fmt.duration(now.timeIntervalSince(s.started)))\(where_)"
            if let origin = s.origin.label { body += " · \(origin)" }
            Notifier.shared.post(
                id: "hot-\(s.id)", title: "\(s.title) is draining your battery", body: body,
                category: Notifier.Category.hot, refs: s.members, signature: s.signature
            )
        }
    }

    /// The SessionEnd hook just recorded what a Claude session leaves behind. Give the session a
    /// moment to actually exit, then say what survived it.
    func sessionEnded() {
        engine.mergeSessionLedger()
        Task {
            for delay in [6.0, 20.0, 60.0] {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                let recent = SessionLedger.read().filter { $0.endedAt > Date().addingTimeInterval(-300) }
                var pending = false
                for record in recent {
                    let key = "\(record.claudePid)-\(record.endedAt.timeIntervalSince1970)"
                    guard !handledSessionEnds.contains(key) else { continue }
                    let claudeAlive = !Stopper.alive([PidRef(pid: record.claudePid, start: record.claudeStart)]).isEmpty
                    if claudeAlive && delay < 60 {
                        pending = true
                        continue
                    }
                    handledSessionEnds.insert(key)
                    notifyLeftovers(record)
                }
                await refresh()
                if !pending { return }
            }
        }
    }

    private func notifyLeftovers(_ record: SessionEndRecord) {
        let groups = SessionEnd.survivors(of: record)
        ActivityLog.write("session ended in \(record.project ?? "?") (claude pid \(record.claudePid)): \(record.groups.count) recorded, \(groups.count) still running")
        guard Prefs.notifyLeftovers, !groups.isEmpty else { return }
        let names: [String] = groups.compactMap { group in
            guard let p = record.processes.first(where: { $0.pid == group[0].pid }) else { return nil }
            return p.title + (p.ports.first.map { " :\($0)" } ?? "")
        }
        let where_ = record.project.map { " in \($0)" } ?? ""
        let count = groups.count == 1 ? "1 thing" : "\(groups.count) things"
        Notifier.shared.post(
            id: "session-\(record.claudePid)-\(Int(record.endedAt.timeIntervalSince1970))",
            title: "Claude session\(where_) left \(count) running",
            body: names.prefix(4).joined(separator: ", ") + (names.count > 4 ? " and \(names.count - 4) more" : ""),
            category: Notifier.Category.leftovers, refs: groups.flatMap { $0 }
        )
    }

    // MARK: Actions (by id, resolved against the latest scan)

    private func stray(_ id: String) -> Stray? {
        let r = latest.report
        return (r.hidden + r.machines + r.claudeSessions.flatMap(\.backgroundTasks)).first { $0.id == id }
    }

    /// The row's stop button: simulators shut down, Docker quits, everything else is stopped.
    func primaryAction(_ id: String) {
        guard let s = stray(id) else { return }
        if s.kind == .simulator, let udid = s.simulatorUDID {
            run(ids: [id]) { Simulators.shutdown(udid: udid) }
        } else if s.kind == .vm, s.title == "Docker Desktop" {
            let members = s.members
            run(ids: [id]) {
                let clean = Docker.quitDesktop()
                // Give it a few seconds to exit on its own, then stop anything left (e.g. the window app).
                let deadline = Date().addingTimeInterval(8)
                while !Stopper.alive(members).isEmpty, Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
                let leftover = Stopper.alive(members)
                Stopper.stop(leftover)
                ActivityLog.write("quit Docker Desktop: " + (clean ? "docker desktop stop" : "quit request")
                    + (leftover.isEmpty ? "" : ", then stopped \(leftover.count) leftover processes"))
            }
        } else {
            stop(members: s.members, ids: [id], force: false)
        }
    }

    func stop(_ id: String, force: Bool = false) {
        guard let s = stray(id) else { return }
        stop(members: s.members, ids: [id], force: force)
    }

    func stopAll(_ ids: [String]) {
        let strays = ids.compactMap(stray)
        stop(members: strays.flatMap(\.members), ids: strays.map(\.id), force: false)
    }

    /// Hidden servers other devices on the network can reach.
    func stopExposed() {
        stopAll(visible(latest.report.hidden).filter(\.isExposed).map(\.id))
    }

    /// From a notification button: these exact processes, whatever the panel currently shows.
    func stop(refs: [PidRef]) {
        stop(members: refs, ids: [], force: false)
    }

    func endSession(_ id: String) {
        guard let s = latest.report.claudeSessions.first(where: { $0.id == id }) else { return }
        stop(members: s.members, ids: [id], force: false)
    }

    func endIdleSessions() {
        let cutoff = Date().addingTimeInterval(-Self.idleSessionAge)
        let idle = latest.report.claudeSessions.filter { $0.isIdle && $0.started < cutoff }
        stop(members: idle.flatMap(\.members), ids: idle.map(\.id), force: false)
    }

    func stopBlocker(_ id: String) {
        guard let b = latest.report.sleepBlockers.first(where: { $0.id == id }) else { return }
        stop(members: [b.ref], ids: [id], force: false)
    }

    func stopContainer(_ id: String) {
        run(ids: [id]) { Docker.stop(containerID: id) }
    }

    private func stop(members: [PidRef], ids: [String], force: Bool) {
        stopping.formUnion(ids)
        Task {
            _ = await Task.detached { Stopper.stop(members, force: force) }.value
            stopping.subtract(ids)
            await refresh()
        }
    }

    private func run(ids: [String], _ work: @escaping @Sendable () -> Void) {
        stopping.formUnion(ids)
        Task {
            await Task.detached(operation: work).value
            stopping.subtract(ids)
            lastExtras = .distantPast
            await refresh()
        }
    }

    func setIgnored(_ id: String, _ ignore: Bool) {
        guard let signature = stray(id)?.signature else { return }
        updateIgnored { if ignore { $0.insert(signature) } else { $0.remove(signature) } }
    }

    func ignore(signature: String) {
        updateIgnored { $0.insert(signature) }
    }

    private func updateIgnored(_ change: (inout Set<String>) -> Void) {
        change(&ignored)
        UserDefaults.standard.set(Array(ignored).sorted(), forKey: "ignored")
        updateBadge()
        publishPanel()
    }

    // MARK: Finder / Terminal / clipboard

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func openTerminal(at path: String) {
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
