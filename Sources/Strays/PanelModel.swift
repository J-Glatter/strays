import Foundation
import StraysCore

/// Everything the panel draws, already formatted. Equatable end to end: a refresh that changes
/// nothing on screen publishes nothing, and rows whose text didn't change skip their body.
/// Actions go back to the Store by id, so a row never acts on a stale process list.
struct PanelModel: Equatable {
    var loaded = false
    var showLegend = false
    var battery: BatteryModel?
    var warnings: [SystemWarning] = []
    var hidden: [RowModel] = []
    var duplicates: [DuplicateModel] = []
    var cleanup: CleanupModel?
    var exposedCount = 0
    var sessions: [SessionModel] = []
    var sessionsSummary = ""
    var idleSessionCount = 0
    var blockers: [BlockerModel] = []
    var machines: [RowModel] = []
    var ignored: [RowModel] = []
    var ignoredCount = 0
    var showIgnored = false
}

struct DuplicateModel: Identifiable, Equatable, Sendable {
    var id: String
    /// "5 copies of server/index.js in games/panel-skirmish"
    var text: String
    var extraCount: Int
}

struct CleanupModel: Equatable, Sendable {
    /// "Auto-cleanup stops 3 leftovers from ended Claude sessions in 8 min"
    var text: String
    var names: String
}

struct BatteryModel: Equatable, Sendable {
    struct EnergyRow: Equatable, Sendable, Identifiable {
        var name: String
        var wh: String
        var fraction: Double
        var id: String { name }
    }

    struct Point: Equatable, Sendable {
        var x: Double
        var y: Double
        var onAC: Bool
    }

    /// "38% · on battery · Mac drawing 8 W · ~2h 46m left"
    var now: String
    /// "Hidden processes are using ≈ 4.1 W, about 35% of that"
    var strayLine: String?
    var strayHot = false
    /// Last 24 hours of charge, x and y in 0…1.
    var points: [Point] = []
    var deathXs: [Double] = []
    var flatLine: String?
    var flatDetail: String?
    var flatCount = 0
    /// "Since you unplugged 2h 10m ago" / "Last time on battery, 12:15–15:31"
    var energyTitle: String?
    var energyRows: [EnergyRow] = []
    var energyNote: String?
    /// "Last sleep 23:00–08:49 (9h 49m): 34 background wake-ups, used 2%"
    var sleepLine: String?
}

struct RowModel: Identifiable, Equatable, Sendable {
    struct Fact: Equatable, Sendable, Identifiable {
        var label: String
        var value: String
        var id: String { label }
    }

    var id: String
    var icon: String
    var title: String
    /// "Server left by a Claude session · 61d · games/panel-skirmish"
    var subtitle: String
    var cpu: String
    var secondary: String
    var hot: Bool
    var ports: [ListeningPort]
    var command: String
    var cwd: String?
    /// Labelled lines for the expanded view: What it is, Started by, Running for…
    var facts: [Fact]
    var pages: [DevToolsPage]
    var containers: [ContainerModel]
    var stopping: Bool
    var ignored: Bool
    var stopLabel: String
    var stopHelp: String
    var canForceKill: Bool
    /// When set, stopping needs a second click and this explains what will happen.
    var confirm: String? = nil
}

struct ContainerModel: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var subtitle: String
    var stopping: Bool
}

struct SessionModel: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var subtitle: String
    var cpu: String
    var secondary: String
    var idle: Bool
    var tasks: [RowModel]
    var mcp: String?
    var pid: Int32
    var childCount: Int
    var stopping: Bool
}

struct BlockerModel: Identifiable, Equatable, Sendable {
    var id: String
    var process: String
    var subtitle: String
    var timeLeft: String?
    var canStop: Bool
    var stopping: Bool
}

struct PanelInputs {
    var report: Report
    var battery: BatteryState?
    var story: BatteryStory?
    var ledger: EnergyLedger?
    var warnings: [SystemWarning]
    var containers: [DockerContainer]
    var pages: [String: [DevToolsPage]]
    var stopping: Set<String>
    var ignored: Set<String>
    var showIgnored: Bool
    var showLegend: Bool
    var idleAge: TimeInterval
    var pendingCleanup: [String: Date] = [:]
    var now = Date()
}

extension PanelModel {
    init(_ input: PanelInputs) {
        let r = input.report
        let visible = { (s: Stray) in !input.ignored.contains(s.signature) }
        let hidden = r.hidden.filter(visible)
        let machines = r.machines.filter(visible)
        let ignored = (r.hidden + r.machines).filter { !visible($0) }

        loaded = r.generatedAt != .distantPast
        showLegend = input.showLegend
        battery = Self.battery(input, strays: hidden + machines)
        warnings = input.warnings
        self.hidden = hidden.map { Self.row($0, input) }
        let visibleIds = Set(hidden.map(\.id))
        duplicates = r.duplicates.compactMap { dup in
            let ids = dup.strayIds.filter(visibleIds.contains)
            guard ids.count > 1 else { return nil }
            let place = dup.place.map { " in \($0)" } ?? ""
            return DuplicateModel(id: dup.id, text: "\(ids.count) copies of \(dup.title)\(place)", extraCount: ids.count - 1)
        }
        if let soonest = input.pendingCleanup.values.min() {
            let names = hidden.filter { input.pendingCleanup[$0.id] != nil }.map(\.title)
            let minutes = max(1, Int((soonest.timeIntervalSince(input.now) / 60).rounded(.up)))
            cleanup = CleanupModel(
                text: "Auto-cleanup stops \(names.count) leftover\(names.count == 1 ? "" : "s") from ended Claude sessions in \(minutes) min",
                names: names.prefix(4).joined(separator: ", ") + (names.count > 4 ? " and \(names.count - 4) more" : "")
            )
        }
        exposedCount = hidden.filter(\.isExposed).count
        self.machines = machines.map { Self.row($0, input) }
        ignoredCount = ignored.count
        showIgnored = input.showIgnored
        self.ignored = input.showIgnored ? ignored.map { Self.row($0, input) } : []

        sessions = r.claudeSessions.map { s in
            var parts = ["open \(Fmt.duration(input.now.timeIntervalSince(s.started)))", s.isIdle ? "idle" : "working"]
            if !s.backgroundTasks.isEmpty { parts.append("\(s.backgroundTasks.count) background task\(s.backgroundTasks.count == 1 ? "" : "s")") }
            if !s.mcpServers.isEmpty { parts.append("\(s.mcpServers.count) tool server\(s.mcpServers.count == 1 ? "" : "s")") }
            let memory = s.memoryBytes + s.backgroundTasks.reduce(0) { $0 + $1.memoryBytes }
            return SessionModel(
                id: s.id,
                title: s.project ?? s.cwd.map(abbreviateHome) ?? "Claude Code",
                subtitle: parts.joined(separator: " · "),
                cpu: Fmt.cpuCoarse(s.totalCPU) + " CPU",
                secondary: Self.secondary(watts: s.totalWatts, memory: memory),
                idle: s.isIdle,
                tasks: s.backgroundTasks.map { Self.row($0, input) },
                mcp: s.mcpServers.isEmpty ? nil : "Tool servers (MCP): " + s.mcpServers.joined(separator: ", "),
                pid: s.ref.pid,
                childCount: s.members.count - 1,
                stopping: input.stopping.contains(s.id)
            )
        }
        let idle = r.claudeSessions.filter(\.isIdle)
        idleSessionCount = idle.filter { input.now.timeIntervalSince($0.started) >= input.idleAge }.count
        let totalMemory = r.claudeSessions.reduce(UInt64(0)) { $0 + $1.memoryBytes }
        sessionsSummary = r.claudeSessions.isEmpty ? "" : "\(idle.count) idle · \(Fmt.bytes(totalMemory))"

        blockers = r.sleepBlockers.map { b in
            BlockerModel(
                id: b.id,
                process: b.process,
                subtitle: (["Started by \(b.owner)"] + b.reasons.prefix(1).map { "“\($0)”" }).joined(separator: " · "),
                timeLeft: b.timeLeft.flatMap { $0 > 0 ? "ends in " + Fmt.duration($0) : nil },
                canStop: b.canStop,
                stopping: input.stopping.contains(b.id)
            )
        }
    }

    // MARK: Battery

    static func battery(_ input: PanelInputs, strays: [Stray]) -> BatteryModel? {
        guard let b = input.battery else { return nil }
        var now = ["\(b.percent)%"]
        if b.onExternalPower {
            now.append(b.isCharging ? "charging" : "plugged in")
        } else {
            now.append("on battery")
            if let w = b.drawWatts { now.append(String(format: "Mac using %.0f W", w)) }
            if let m = b.minutesRemaining { now.append("~\(Fmt.minutes(m)) left") }
        }
        var model = BatteryModel(now: now.joined(separator: " · "))

        let strayWatts = strays.reduce(0) { $0 + $1.watts }
        if strayWatts >= 0.1 {
            var line = "Hidden processes are using ≈ \(Fmt.watts(strayWatts))"
            if let draw = b.drawWatts, draw > 0.5 {
                // Nearest 5% so the line doesn't flicker every refresh.
                let share = Int((min(100, strayWatts / draw * 100) / 5).rounded()) * 5
                line += ", about \(share)% of that"
            }
            model.strayLine = line
            model.strayHot = strays.contains(where: \.isHot)
        }

        if let story = input.story {
            let end = input.now, span = 24 * 3_600.0
            let x = { (d: Date) in 1 - min(1, max(0, end.timeIntervalSince(d) / span)) }
            model.points = story.points.map { .init(x: x($0.at), y: Double($0.percent) / 100, onAC: $0.onAC) }
            model.deathXs = story.deaths.filter { end.timeIntervalSince($0.at) < span }.map { x($0.at) }
            model.flatCount = story.deathsThisWeek
            if let last = story.deaths.last {
                let times = story.deathsThisWeek == 1 ? "once" : "\(story.deathsThisWeek) times"
                var line = "Ran flat \(times) this week, most recently \(BatteryStory.when(last.at, now: input.now))"
                if let start = last.unpluggedAt, let pct = last.startPercent {
                    line += ": \(pct)% → 1% in \(Fmt.duration(last.at.timeIntervalSince(start))) after unplugging"
                }
                model.flatLine = line
            }
            model.flatDetail = story.lastDeathDetail
            if let sleep = story.lastSleep {
                let t = { (d: Date) in d.formatted(date: .omitted, time: .shortened) }
                var line = "Last sleep \(t(sleep.start))–\(t(sleep.end)) (\(Fmt.duration(sleep.end.timeIntervalSince(sleep.start)))): "
                line += "\(sleep.darkWakes) brief background wake-up\(sleep.darkWakes == 1 ? "" : "s")"
                if let used = sleep.used { line += ", used \(used)%" }
                model.sleepLine = line
            }
        }

        if let ledger = input.ledger, ledger.total >= 0.05 {
            let t = { (d: Date) in d.formatted(date: .omitted, time: .shortened) }
            if b.onExternalPower {
                model.energyTitle = "Energy used last time on battery (\(t(ledger.since))–\(t(ledger.savedAt)))"
            } else if ledger.fromUnplug {
                model.energyTitle = "Energy used since you unplugged \(Fmt.duration(input.now.timeIntervalSince(ledger.since))) ago"
            } else {
                model.energyTitle = "Energy used since \(t(ledger.since)) (when Strays started measuring)"
            }
            let top = ledger.top(5)
            let maxWh = top.first?.wh ?? 1
            model.energyRows = top.map { .init(name: $0.name, wh: Fmt.energy($0.wh), fraction: $0.wh / maxWh) }
            var note = "Measured \(Fmt.energy(ledger.total)) across your apps"
            if !b.onExternalPower, let start = ledger.startPercent, let capacity = b.capacityWh, start > b.percent {
                note += " of ~\(Fmt.energy(Double(start - b.percent) / 100 * capacity)) the battery has supplied"
            }
            model.energyNote = note + ". The rest is the screen, graphics and macOS itself, which can't be measured per app."
        }
        return model
    }

    // MARK: Rows

    /// Plain-English kind for the row: "Server", "Hidden browser", …
    static func kind(_ s: Stray) -> String {
        switch s.kind {
        case .orphan: return s.ports.isEmpty ? "Process" : "Server"
        case .headlessBrowser: return "Hidden browser"
        case .backgroundTask: return s.ports.isEmpty ? "Background task" : "Background server"
        case .vm: return s.title == "Docker Desktop" ? "Container VM" : "Virtual machine"
        case .simulator: return "iOS Simulator"
        case .emulator: return "Android emulator"
        }
    }

    /// How it ended up unattended, in words: "left by a Claude session".
    static func howItGotHere(_ s: Stray) -> String? {
        guard s.kind == .orphan || s.kind == .headlessBrowser else { return nil }
        switch s.origin {
        case .claude(nil, _): return "left by a Claude session"
        case .claude: return "detached from an open Claude session"
        case .terminal(let app): return "left by a closed \(app) window"
        case .unknown: return "its launcher has exited"
        }
    }

    static func startedBy(_ s: Stray) -> String {
        switch s.origin {
        case .claude(nil, let project):
            return "A Claude Code session" + (project.map { " in \($0)" } ?? "") + " that has since ended"
        case .claude(_, let project):
            return "Claude Code" + (project.map { " in \($0)" } ?? "") + " (session still open)"
        case .terminal(let app):
            return s.kind == .orphan || s.kind == .headlessBrowser ? "\(app) (that window or tab has closed)" : app
        case .unknown:
            return s.kind == .orphan || s.kind == .headlessBrowser ? "Unknown: whatever launched it has exited" : "Unknown"
        }
    }

    static func whatItIs(_ s: Stray, pages: [DevToolsPage]) -> String {
        switch s.kind {
        case .headlessBrowser:
            let showing = pages.first.map { ", showing “\($0.title.isEmpty ? $0.url : $0.title)”" } ?? ""
            return "A browser running with no window, usually driven by a script or test tool\(showing)"
        case .orphan:
            return s.ports.isEmpty
                ? "A program running with no terminal or window attached"
                : "A server with no terminal or window attached, listening for connections"
        case .backgroundTask:
            return "A command this Claude session started in the background"
        case .vm:
            return s.title == "Docker Desktop" ? "Docker's Linux virtual machine, which runs your containers" : "A virtual machine"
        case .simulator:
            return "A simulated iPhone/iPad" + (s.detail.map { " running \($0)" } ?? "")
        case .emulator:
            return "An Android emulator" + (s.detail.map { " (\($0))" } ?? "")
        }
    }

    static func row(_ s: Stray, _ input: PanelInputs) -> RowModel {
        let isDocker = s.kind == .vm && s.title == "Docker Desktop"
        let age = Fmt.duration(input.now.timeIntervalSince(s.started))
        let pages = input.pages[s.id] ?? []

        var lead = kind(s)
        if let how = howItGotHere(s) { lead += " " + how }
        if s.kind == .simulator, let runtime = s.detail { lead += " · \(runtime)" }
        if isDocker, !input.containers.isEmpty { lead += " · \(input.containers.count) containers" }
        var parts = [lead, age]
        // Path last, so tail truncation only ever eats the path.
        if let project = s.project { parts.append(project) } else if s.kind == .headlessBrowser, let profile = s.detail { parts.append(profile) }

        var title = s.title
        if let page = pages.first, !page.title.isEmpty { title += " · \(page.title)" }

        var facts = [RowModel.Fact(label: "What it is", value: whatItIs(s, pages: pages))]
        if s.kind != .simulator && s.kind != .vm {
            facts.append(.init(label: "Started by", value: startedBy(s)))
        }
        if let chain = s.launchedBy { facts.append(.init(label: "Launch chain", value: chain)) }
        if !s.ports.isEmpty {
            let exposed = s.isExposed
            facts.append(.init(
                label: "Network",
                value: s.ports.map { ":\($0.port)" }.joined(separator: " ")
                    + (exposed ? " · other devices on your network can connect" : " · this Mac only")
            ))
        }
        facts.append(.init(
            label: "Running for",
            value: "\(Fmt.duration(input.now.timeIntervalSince(s.started))) (since \(s.started.formatted(date: .abbreviated, time: .shortened)))"
        ))
        var used: [String] = []
        if s.cpuSecondsTotal >= 1 { used.append(Fmt.cpuTime(s.cpuSecondsTotal)) }
        if s.energyWhTotal >= 0.05 { used.append(Fmt.energy(s.energyWhTotal) + " of energy") }
        if !used.isEmpty { facts.append(.init(label: "Used so far", value: used.joined(separator: " · "))) }
        let pids = s.members.prefix(5).map { String($0.pid) }.joined(separator: ", ")
        facts.append(.init(
            label: "Processes",
            value: "\(s.members.count) (pid \(pids)\(s.members.count > 5 ? " +\(s.members.count - 5)" : ""))"
        ))

        let icon: String
        switch s.kind {
        case .orphan: icon = s.ports.isEmpty ? "pawprint" : "server.rack"
        case .headlessBrowser: icon = "globe"
        case .backgroundTask: icon = "terminal"
        case .simulator: icon = "iphone"
        case .emulator: icon = "candybarphone"
        case .vm: icon = isDocker ? "shippingbox" : "cpu"
        }

        let stopLabel = s.kind == .simulator ? "Shut down" : isDocker ? "Quit Docker" : "Stop"
        let stopHelp = s.kind == .simulator ? "Shut down this simulator"
            : isDocker ? "Quit Docker Desktop (stops its VM and all containers)"
            : "Stop: asks it to quit, then force-quits after 3 seconds"

        return RowModel(
            id: s.id,
            icon: icon,
            title: title,
            subtitle: parts.joined(separator: " · "),
            cpu: Fmt.cpuCoarse(s.cpuPercent) + " CPU",
            secondary: secondary(watts: s.watts, memory: s.memoryBytes),
            hot: s.isHot,
            ports: s.ports,
            command: s.command,
            cwd: s.cwd == "/" ? nil : s.cwd,
            facts: facts,
            pages: pages,
            containers: isDocker ? input.containers.map { c in
                let usage = [c.cpu.map { "\($0) CPU" }, c.memory].compactMap { $0 }.joined(separator: " · ")
                return ContainerModel(id: c.id, name: c.name,
                                      subtitle: ([usage.isEmpty ? nil : usage, c.image, c.status].compactMap { $0 }).joined(separator: " · "),
                                      stopping: input.stopping.contains(c.id))
            } : [],
            stopping: input.stopping.contains(s.id),
            ignored: input.ignored.contains(s.signature),
            stopLabel: stopLabel,
            stopHelp: stopHelp,
            canForceKill: s.kind != .simulator && s.kind != .vm,
            confirm: isDocker ? dockerConfirm(input.containers) : nil
        )
    }

    /// Quitting Docker stops every container; say which before doing it.
    static func dockerConfirm(_ containers: [DockerContainer]) -> String {
        guard !containers.isEmpty else { return "Quit Docker Desktop? Its VM stops. (Container list not loaded yet.)" }
        let names = containers.map(\.name)
        return "Quit Docker Desktop? This also stops \(containers.count) container\(containers.count == 1 ? "" : "s"): "
            + names.prefix(6).joined(separator: ", ") + (names.count > 6 ? " and \(names.count - 6) more" : "") + "."
    }

    static func secondary(watts: Double, memory: UInt64) -> String {
        watts >= 0.05 ? "\(Fmt.watts(watts)) · \(Fmt.bytes(memory))" : Fmt.bytes(memory)
    }
}

func abbreviateHome(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}
