import Foundation

/// Sorts a process snapshot into the things worth showing. Each process lands in at most
/// one group; groups are claimed in priority order (browsers, machines, Claude sessions,
/// orphans), and every group is a root process plus its descendants.
public enum Classifier {
    public static func classify(
        _ snapshot: Snapshot,
        inspector: ProcessInspector,
        assertions: [Int32: [PowerAssertion]] = [:],
        now: Date = Date()
    ) -> Report {
        let ctx = Context(snapshot: snapshot, inspector: inspector, now: now)
        let browsers = ctx.automationBrowsers()
        let machines = ctx.machines()
        let sessions = ctx.claudeSessions()
        let orphans = ctx.orphans()
        let blockers = ctx.sleepBlockers(assertions)
        let hidden = (browsers + orphans).sorted(by: Stray.byImpact)
        return Report(
            hidden: hidden,
            claudeSessions: sessions.sorted { ($0.totalWatts, $1.started) > ($1.totalWatts, $0.started) },
            sleepBlockers: blockers,
            machines: machines.sorted(by: Stray.byImpact),
            duplicates: duplicates(in: hidden),
            generatedAt: now
        )
    }

    /// Same kind, same folder, same command (ignoring port numbers) = copies of one thing.
    static func duplicates(in hidden: [Stray]) -> [DuplicateGroup] {
        let groups = Dictionary(grouping: hidden) { s in
            "\(s.kind.rawValue)|\(s.cwd ?? s.project ?? "")|\(withoutPorts(s.title))"
        }
        return groups.compactMap { key, members -> DuplicateGroup? in
            guard members.count > 1 else { return nil }
            let sorted = members.sorted { $0.started < $1.started }
            let newest = sorted[sorted.count - 1]
            return DuplicateGroup(id: key, title: withoutPorts(newest.title), place: newest.project,
                                  strayIds: sorted.map(\.id), keepId: newest.id)
        }
        .sorted { ($0.strayIds.count, $1.id) > ($1.strayIds.count, $0.id) }
    }

    /// "http.server 8733" → "http.server"
    static func withoutPorts(_ title: String) -> String {
        title.split(separator: " ").filter { !($0.count >= 2 && $0.allSatisfy(\.isNumber)) }.joined(separator: " ")
    }

    static let shellLeaders: Set<String> = ["zsh", "bash", "sh", "fish", "dash", "ksh", "login", "tmux", "screen", "claude"]
    static let browserExecutables: Set<String> = [
        "Google Chrome", "Google Chrome for Testing", "Google Chrome Canary", "Google Chrome Beta",
        "Google Chrome Dev", "Chromium", "Microsoft Edge", "Brave Browser", "chrome", "chromium",
        "chrome-headless-shell", "headless_shell", "msedge", "firefox", "Firefox",
    ]

    /// macOS's own daemons (Handoff, audio, powerd). Their sleep assertions aren't actionable.
    /// `caffeinate` lives in /usr/bin, so it stays visible.
    static func isSystemDaemon(_ p: ProcessRecord) -> Bool {
        if p.uid == 0 || p.name == "powerd" { return true }
        return ["/System/", "/usr/libexec/", "/usr/sbin/"].contains { p.path.hasPrefix($0) }
    }

    static func isClaude(_ p: ProcessRecord) -> Bool {
        p.comm == "claude" || p.name == "claude" || p.path.contains("/claude/versions/")
            || p.path.contains("/claude-code") || p.commandLine.contains("@anthropic-ai/claude-code/cli")
    }

    static func isAutomationBrowser(_ p: ProcessRecord) -> Bool {
        let exe = CommandNamer.basename(p.path.isEmpty ? p.name : p.path)
        guard browserExecutables.contains(exe), !exe.contains("Helper") else { return false }
        if exe.contains("headless") { return true }
        return p.args.contains { arg in
            arg.hasPrefix("--headless") || arg.hasPrefix("--remote-debugging-port") || arg == "--remote-debugging-pipe"
                || arg == "--enable-automation" || arg == "-headless" || arg == "--marionette" || arg == "-marionette"
        }
    }

    static func browserTitle(_ p: ProcessRecord) -> String {
        let exe = CommandNamer.basename(p.path.isEmpty ? p.name : p.path)
        var product: String
        switch exe {
        case "Google Chrome", "chrome": product = "Chrome"
        case "chrome-headless-shell", "headless_shell": product = "Chrome headless shell"
        case "msedge", "Microsoft Edge": product = "Edge"
        case "firefox": product = "Firefox"
        case "chromium": product = "Chromium"
        default: product = exe.replacingOccurrences(of: "Google ", with: "")
        }
        if p.path.contains("ms-playwright") { product = "Playwright \(product)" }
        else if p.path.contains("puppeteer") { product = "Puppeteer \(product)" }
        let headless = exe.contains("headless") || p.args.contains { $0.hasPrefix("--headless") || $0 == "-headless" }
        if product.contains("headless") { return product }
        return headless ? "Headless \(product)" : "\(product) (automation)"
    }

    static func simulatorUDID(in commandLine: String) -> String? {
        let pattern = "/Devices/([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})"
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: commandLine, range: NSRange(commandLine.startIndex..., in: commandLine)),
              let r = Range(m.range(at: 1), in: commandLine) else { return nil }
        return String(commandLine[r])
    }

    static func prettyTerminal(_ termProgram: String) -> String {
        switch termProgram {
        case "Apple_Terminal": return "Terminal"
        case "iTerm.app": return "iTerm"
        case "vscode": return "VS Code"
        case "WarpTerminal": return "Warp"
        case "ghostty": return "Ghostty"
        case "WezTerm": return "WezTerm"
        case "tmux": return "tmux"
        default: return termProgram.contains("JetBrains") ? "JetBrains terminal" : termProgram
        }
    }
}

private final class Context {
    let snap: Snapshot
    let inspector: ProcessInspector
    let now: Date
    var claimed = Set<Int32>()
    lazy var claudePids: Set<Int32> = Set(mine.filter(Classifier.isClaude).map(\.pid))
    lazy var mine: [ProcessRecord] = snap.processes.values
        .filter { $0.uid == snap.uid }
        .sorted { ($0.startMicros, $0.pid) < ($1.startMicros, $1.pid) }

    init(snapshot: Snapshot, inspector: ProcessInspector, now: Date) {
        self.snap = snapshot
        self.inspector = inspector
        self.now = now
    }

    // MARK: Groups

    func automationBrowsers() -> [Stray] {
        mine.filter { p in
            Classifier.isAutomationBrowser(p)
                && !(snap.processes[p.ppid].map(Classifier.isAutomationBrowser) ?? false)
        }.compactMap { p in
            let members = take(p.pid)
            guard !members.isEmpty else { return nil }
            let profile = p.args.first { $0.hasPrefix("--user-data-dir=") }
                .map { CommandNamer.basename(String($0.dropFirst("--user-data-dir=".count))) }
            let explicitPort = p.args.first { $0.hasPrefix("--remote-debugging-port=") }
                .flatMap { UInt16($0.dropFirst("--remote-debugging-port=".count)) }
                .flatMap { $0 == 0 ? nil : $0 }
            var stray = makeStray(.headlessBrowser, members, title: Classifier.browserTitle(p), detail: profile)
            stray.devtoolsPort = explicitPort ?? stray.ports.first?.port
            return stray
        }
    }

    func machines() -> [Stray] {
        var out: [Stray] = []

        for p in mine where p.name == "launchd_sim" && !claimed.contains(p.pid) {
            let members = take(p.pid)
            let udid = Classifier.simulatorUDID(in: p.commandLine)
            let info = udid.flatMap(inspector.simulatorInfo)
            var stray = makeStray(.simulator, members, title: info?.name ?? "iOS Simulator", detail: info?.runtime)
            stray.simulatorUDID = udid
            out.append(stray)
        }

        let vmXPC = "com.apple.Virtualization.VirtualMachine"
        let products: [(title: String, matches: (ProcessRecord) -> Bool, ownsVirtualizationVM: Bool)] = [
            ("Docker Desktop", { $0.path.contains("/Docker.app/") || $0.name.hasPrefix("com.docker.") }, true),
            ("OrbStack", { $0.path.contains("/OrbStack.app/") }, true),
            ("Colima / Lima", { $0.name == "limactl" || $0.name == "colima" }, true),
            ("UTM", { $0.path.contains("/UTM.app/") }, true),
            ("Parallels VM", { $0.name == "prl_vm_app" }, false),
            ("VirtualBox VM", { $0.name == "VBoxHeadless" || $0.name == "VirtualBoxVM" }, false),
            ("Tart VM", { $0.name == "tart" }, true),
        ]
        for product in products {
            let roots = mine.filter { !claimed.contains($0.pid) && product.matches($0) }
            guard !roots.isEmpty else { continue }
            var members: [ProcessRecord] = []
            // Lead with the longest-lived process so the row's age reads as the product's uptime.
            for root in roots { members += take(root.pid) }
            if product.ownsVirtualizationVM {
                for vm in mine where vm.name.hasPrefix(vmXPC) && !claimed.contains(vm.pid) { members += take(vm.pid) }
            }
            guard !members.isEmpty else { continue }
            out.append(makeStray(.vm, members, title: product.title))
        }

        for p in mine where p.name.hasPrefix("qemu-system") && !claimed.contains(p.pid) {
            let avd = p.args.firstIndex(of: "-avd").flatMap { $0 + 1 < p.args.count ? p.args[$0 + 1] : nil }
            let members = take(p.pid)
            out.append(makeStray(avd == nil ? .vm : .emulator, members, title: avd == nil ? "QEMU VM" : "Android emulator", detail: avd))
        }

        for p in mine where p.name.hasPrefix(vmXPC) && !claimed.contains(p.pid) {
            out.append(makeStray(.vm, take(p.pid), title: "Virtual machine", detail: "Virtualization.framework"))
        }
        return out
    }

    func claudeSessions() -> [ClaudeSession] {
        var sessions: [ClaudeSession] = []
        for claude in mine where claudePids.contains(claude.pid) && !claimed.contains(claude.pid) {
            claimed.insert(claude.pid)
            let cwd = inspector.cwd(claude.pid)
            let project = cwd.flatMap(inspector.projectLabel)
            var members = [claude.ref]
            var cpu = claude.cpuPercent
            var watts = claude.watts
            var memory = claude.footprint
            var tasks: [Stray] = []
            var mcps: [String] = []

            for childPid in snap.children[claude.pid] ?? [] {
                guard let child = snap.processes[childPid], !claimed.contains(childPid),
                      !claudePids.contains(childPid) else { continue }
                let age = now.timeIntervalSince(child.startDate)
                let isMCP = subtree(childPid).contains { $0.commandLine.lowercased().contains("mcp") }
                // A Bash tool call under 30s old is Claude working, not a background job.
                guard child.name == "caffeinate" || isMCP || age >= 30 else { continue }

                let group = take(childPid)
                members += group.map(\.ref)
                if child.name == "caffeinate" { continue }
                if isMCP {
                    mcps.append(CommandNamer.name(args: child.args, path: child.path))
                    cpu += group.reduce(0) { $0 + $1.cpuPercent }
                    watts += group.reduce(0) { $0 + $1.watts }
                    memory += group.reduce(0) { $0 + $1.footprint }
                } else {
                    var task = makeStray(.backgroundTask, group)
                    task.origin = .claude(livePid: claude.pid, project: project)
                    tasks.append(task)
                }
            }

            sessions.append(ClaudeSession(
                id: "claude-\(claude.pid)-\(claude.startMicros)", ref: claude.ref, project: project, cwd: cwd,
                started: claude.startDate, cpuPercent: cpu, watts: watts, memoryBytes: memory,
                backgroundTasks: tasks.sorted(by: Stray.byImpact), mcpServers: mcps, members: members
            ))
        }
        return sessions
    }

    /// Processes whose launcher is gone: reparented to launchd, and either their session's
    /// shell has exited or Claude Code's environment says Claude started them. Real launchd
    /// jobs and apps lead their own session, so they don't match.
    func orphans() -> [Stray] {
        mine.filter { p in
            guard p.ppid == 1, !claimed.contains(p.pid), p.pid != getpid(),
                  !p.name.lowercased().contains("crashpad") else { return false }
            // Anything launchd started (LaunchServices apps, e.g. Claude ran `open -a …`; brew services)
            // sits in launchd's session 1 and is meant to be running, even if it inherited Claude's env.
            // A dev-run app binary (Python.app, Electron) stays in its shell's session.
            if p.sid == 1 || (p.sid == p.pid && p.path.contains(".app/Contents/MacOS/")) { return false }
            if p.markers.claudeCode || p.launch?.claudePid != nil { return true }
            // Agents and apps live in launchd's own session (sid 1).
            guard p.sid > 1, p.sid != p.pid else { return false }
            guard snap.alive.contains(p.sid) else { return true }
            guard let leader = snap.processes[p.sid] else { return false }
            return Classifier.shellLeaders.contains(leader.name) || Classifier.isClaude(leader)
        }.compactMap { p in
            let members = take(p.pid)
            return members.isEmpty ? nil : makeStray(.orphan, members)
        }
    }

    func sleepBlockers(_ assertions: [Int32: [PowerAssertion]]) -> [SleepBlocker] {
        assertions.compactMap { pid, list -> SleepBlocker? in
            let relevant = list.filter { PowerAssertions.sleepPreventing.contains($0.type) }
            guard !relevant.isEmpty, let p = snap.processes[pid], !Classifier.isSystemDaemon(p) else { return nil }
            let owner: String
            if let claude = claudePids.contains(pid) ? pid : claudeAncestor(of: pid) {
                owner = ["Claude Code", inspector.cwd(claude).flatMap(inspector.projectLabel)].compactMap { $0 }.joined(separator: " · ")
            } else if p.markers.claudeCode {
                owner = "Claude Code (session ended)"
            } else {
                owner = topAncestor(of: pid)?.name ?? p.name
            }
            return SleepBlocker(
                id: "sleep-\(pid)-\(p.startMicros)", ref: p.ref, process: p.name, owner: owner,
                reasons: Array(Set(relevant.map(\.name).filter { !$0.isEmpty })).sorted(),
                types: Array(Set(relevant.map(\.type))).sorted(),
                timeLeft: relevant.compactMap(\.timeLeft).max(),
                canStop: p.uid == snap.uid && !p.path.contains(".app/Contents/MacOS/")
            )
        }.sorted { $0.process < $1.process }
    }

    // MARK: Building blocks

    /// Root plus unclaimed descendants, breadth-first; claims them.
    func take(_ root: Int32) -> [ProcessRecord] {
        let group = subtree(root)
        claimed.formUnion(group.map(\.pid))
        return group
    }

    func subtree(_ root: Int32) -> [ProcessRecord] {
        var out: [ProcessRecord] = []
        var queue = [root]
        var seen = Set<Int32>()
        while !queue.isEmpty {
            let pid = queue.removeFirst()
            guard seen.insert(pid).inserted, !claimed.contains(pid), let p = snap.processes[pid] else { continue }
            // A Claude session started from inside another one is its own session, not a child task.
            if pid != root, claudePids.contains(pid) { continue }
            out.append(p)
            queue += snap.children[pid] ?? []
        }
        return out
    }

    func claudeAncestor(of pid: Int32) -> Int32? {
        var current = snap.processes[pid]?.ppid
        var hops = 0
        while let c = current, c > 1, hops < 64 {
            if claudePids.contains(c) { return c }
            current = snap.processes[c]?.ppid
            hops += 1
        }
        return nil
    }

    /// The process just below launchd in this one's ancestry (e.g. Terminal, Chrome).
    func topAncestor(of pid: Int32) -> ProcessRecord? {
        var current = snap.processes[pid]
        var hops = 0
        while let c = current, c.ppid > 1, hops < 64, let parent = snap.processes[c.ppid] {
            current = parent
            hops += 1
        }
        return current?.pid == pid ? nil : current
    }

    func origin(for members: [ProcessRecord]) -> Origin {
        guard let root = members.first else { return .unknown }
        if let live = claudeAncestor(of: root.pid) {
            return .claude(livePid: live, project: inspector.cwd(live).flatMap(inspector.projectLabel))
        }
        // npm & co. overwrite their env with the process title, so ask the children too.
        let markers = members.first { $0.markers.readable }?.markers
        let launch = members.lazy.compactMap(\.launch).first { $0.claudePid != nil }
        // What Strays saw launch it beats an inherited CLAUDE_PID in the environment.
        let launcher = launch?.claudePid ?? markers?.claudePid
        if markers?.claudeCode == true || launcher != nil {
            if let cp = launcher, claudePids.contains(cp), let claude = snap.processes[cp], claude.startMicros <= root.startMicros {
                return .claude(livePid: cp, project: inspector.cwd(cp).flatMap(inspector.projectLabel))
            }
            return .claude(livePid: nil, project: launch?.claudeProject)
        }
        if let term = markers?.termProgram { return .terminal(Classifier.prettyTerminal(term)) }
        return .unknown
    }

    func makeStray(_ kind: Stray.Kind, _ members: [ProcessRecord], title: String? = nil, detail: String? = nil) -> Stray {
        let root = members[0]
        let cwd = inspector.cwd(root.pid) ?? root.markers.pwd
        var ports: [UInt16: Bool] = [:]
        for p in members where !p.name.contains("Helper") {
            for lp in inspector.listeningPorts(p.pid) { ports[lp.port] = (ports[lp.port] ?? false) || lp.exposed }
        }
        return Stray(
            id: "\(kind.rawValue)-\(root.pid)-\(root.startMicros)",
            kind: kind,
            title: title ?? CommandNamer.name(args: root.args, path: root.path.isEmpty ? root.name : root.path),
            detail: detail,
            project: cwd.flatMap(inspector.projectLabel),
            cwd: cwd,
            command: root.commandLine.isEmpty ? root.name : root.commandLine,
            root: root.ref,
            members: members.map(\.ref),
            started: root.startDate,
            cpuPercent: members.reduce(0) { $0 + $1.cpuPercent },
            cpuSmoothed: members.reduce(0) { $0 + $1.cpuSmoothed },
            watts: members.reduce(0) { $0 + $1.watts },
            memoryBytes: members.reduce(0) { $0 + $1.footprint },
            cpuSecondsTotal: members.reduce(0) { $0 + Double($1.cpuTimeNs) / 1e9 },
            energyWhTotal: members.reduce(0) { $0 + Double($1.energyNj) / 3.6e12 },
            ports: ports.map { ListeningPort(port: $0.key, exposed: $0.value) }.sorted { $0.port < $1.port },
            origin: origin(for: members),
            devtoolsPort: nil,
            simulatorUDID: nil,
            launchedBy: root.launch?.summary,
            claudeSessionId: members.first { $0.markers.readable }?.markers.claudeSessionId ?? root.launch?.sessionId
        )
    }
}
