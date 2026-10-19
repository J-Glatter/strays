import Foundation
import StraysCore

/// `strays` in a terminal: same scan as the menu bar, printed. Handy for Claude
/// sessions to check what they've left running.
enum CLI {
    static let flags: Set<String> = [
        "--list", "--json", "--stop", "--port", "--battery", "--session-end", "--session-start", "--update", "--bench",
        "--help", "-h", "--unregister-login-item",
    ]

    static func handles(arguments: [String], invokedAs: String) -> Bool {
        invokedAs == "strays" || arguments.contains(where: flags.contains)
    }

    static func run(_ args: [String]) -> Int32 {
        if args.contains("--help") || args.contains("-h") {
            print("""
            strays: find the hidden processes draining your battery

              strays               list orphans, hidden browsers, Claude sessions, sleep blockers, VMs
              strays --json        the same as JSON
              strays --stop <pid>  stop the whole group that pid belongs to (SIGTERM, then SIGKILL after 3 s)
              strays --port <n>    what's listening on port n, and what started it
              strays --battery     when the battery last ran flat, and how fast it drained
              strays --update      pull the latest source (if it has a git remote) and reinstall
              strays --session-start / --session-end
                                   for Claude Code's hooks (read the hook JSON on stdin)
              Strays.app           the menu bar app (this binary with no flags)
            """)
            return 0
        }
        if args.contains("--unregister-login-item") {
            LoginItem.set(false)
            return 0
        }
        if args.contains("--session-end") { return sessionEnd() }
        if args.contains("--session-start") { return sessionStart() }
        if args.contains("--update") { return update() }
        if args.contains("--battery") { return battery() }
        if let i = args.firstIndex(of: "--port") { return port(i + 1 < args.count ? UInt16(args[i + 1]) : nil) }

        if args.contains("--bench") {
            let engine = Engine()
            _ = engine.scanSync()
            for _ in 0..<5 {
                let t0 = DispatchTime.now().uptimeNanoseconds
                _ = engine.scanSync()
                print(String(format: "scan: %.1f ms", Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6))
            }
            return 0
        }

        let result = Engine().scanSync()

        if let i = args.firstIndex(of: "--stop") {
            guard i + 1 < args.count, let pid = Int32(args[i + 1]) else {
                print("usage: strays --stop <pid>")
                return 2
            }
            guard let stray = group(containing: pid, in: result.report) else {
                print("pid \(pid) isn't part of anything strays tracks; use kill directly if you're sure")
                return 1
            }
            print("stopping \(stray.title) (\(stray.members.count) process\(stray.members.count == 1 ? "" : "es"))…")
            let survivors = Stopper.stop(stray.members)
            print(survivors.isEmpty ? "stopped" : "still running: \(survivors.map { String($0.pid) }.joined(separator: " "))")
            return survivors.isEmpty ? 0 : 1
        }
        let system = SystemProbe.read()
        let warnings = SystemWarnings.evaluate(system)

        if args.contains("--json") {
            struct Output: Encodable {
                let report: Report
                let battery: BatteryState?
                let system: SystemInfo
                let warnings: [SystemWarning]
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = (try? encoder.encode(Output(report: result.report, battery: result.battery, system: system, warnings: warnings))) ?? Data()
            print(String(decoding: data, as: UTF8.self))
            return 0
        }

        printText(result, warnings: warnings)
        return 0
    }

    private static func group(containing pid: Int32, in r: Report) -> Stray? {
        (r.hidden + r.machines + r.claudeSessions.flatMap(\.backgroundTasks))
            .first { $0.members.contains { $0.pid == pid } }
    }

    // MARK: --session-end

    /// Called by Claude Code's SessionEnd hook. Records what the session leaves running and
    /// pings the menu bar app, which checks a few seconds later what actually survived.
    /// Never fails loudly: a hook error would just be noise at the end of a session.
    private static func sessionEnd() -> Int32 {
        let stdin = FileHandle.standardInput.readDataToEndOfFile()
        let input = (try? JSONDecoder().decode(SessionEnd.HookInput.self, from: stdin)) ?? SessionEnd.HookInput()

        let engine = Engine()
        let result = engine.scanSync(warm: false)
        guard let snap = result.snapshot, let claude = SessionEnd.claudeAncestor(of: getpid(), in: snap) else { return 0 }

        let leftovers = SessionEnd.leftovers(report: result.report, claudePid: claude.pid, sessionId: input.session_id)
        let project = result.report.claudeSessions.first { $0.ref.pid == claude.pid }?.project
        let record = SessionEnd.record(claude: claude, project: project, input: input, leftovers: leftovers)
        guard !leftovers.isEmpty else { return 0 }

        try? SessionLedger.append(record)
        DistributedNotificationCenter.default().postNotificationName(
            StraysPaths.sessionEndedNotification, object: nil, userInfo: nil, deliverImmediately: true
        )
        print("strays: session left \(leftovers.count) running: " + leftovers.map(\.title).joined(separator: ", "))
        return 0
    }

    // MARK: --session-start

    /// Called by Claude Code's SessionStart hook. Prints context for the new session listing what's
    /// already running in its project, or nothing. Never fails loudly.
    private static func sessionStart() -> Int32 {
        let stdin = FileHandle.standardInput.readDataToEndOfFile()
        let input = (try? JSONDecoder().decode(SessionEnd.HookInput.self, from: stdin)) ?? SessionEnd.HookInput()
        let cwd = input.cwd ?? FileManager.default.currentDirectoryPath
        let result = Engine().scanSync(warm: false)
        let items = SessionStart.running(in: result.report, cwd: cwd, projectRoot: LiveInspector().projectRoot(of: cwd))
        if let context = SessionStart.context(for: items, duplicates: result.report.duplicates) {
            print(SessionStart.hookOutput(context: context))
        }
        return 0
    }

    // MARK: --update

    /// Pulls the source `install.sh` was run from (when it has a remote) and reinstalls.
    private static func update() -> Int32 {
        guard let source = UserDefaults(suiteName: "com.glatter.strays")?.string(forKey: "sourcePath"),
              FileManager.default.fileExists(atPath: source + "/install.sh") else {
            print("don't know where the source is; run ./install.sh from the strays folder once")
            return 1
        }
        print("source: \(source)")
        if run("/usr/bin/git", ["-C", source, "rev-parse", "--abbrev-ref", "@{u}"], quiet: true) == 0 {
            guard run("/usr/bin/git", ["-C", source, "pull", "--ff-only"]) == 0 else {
                print("git pull failed; not reinstalling")
                return 1
            }
        } else {
            print("no git remote configured; rebuilding the local source as-is")
        }
        return run("/bin/bash", [source + "/install.sh", "--yes"])
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String], quiet: Bool = false) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        if quiet {
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
        }
        do { try p.run() } catch { return 127 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    // MARK: --port

    private static func port(_ port: UInt16?) -> Int32 {
        guard let port else {
            print("usage: strays --port <number>")
            return 2
        }
        let engine = Engine()
        let result = engine.scanSync(warm: false)
        let listeners = engine.listeners(port: port)
        guard !listeners.isEmpty else {
            print("nothing of yours is listening on :\(port)")
            return 1
        }
        for l in listeners {
            let p = l.process
            let name = CommandNamer.name(args: p.args, path: p.path.isEmpty ? p.name : p.path)
            print(":\(port)  \(name)  (pid \(p.pid), running \(Fmt.duration(Date().timeIntervalSince(p.startDate))))")
            print("   " + (l.port.exposed ? "reachable from other devices on your network" : "this Mac only (localhost)"))
            if let project = l.project { print("   folder: \(project)") }
            if let stray = group(containing: p.pid, in: result.report) {
                let what = stray.kind == .backgroundTask ? "background task of a running Claude session" : "hidden: nothing is attached to it"
                print("   \(what)" + (stray.origin.label.map { " · \($0)" } ?? ""))
                if let launched = stray.launchedBy { print("   started by: \(launched)") }
                print("   stop it: strays --stop \(stray.root.pid)")
            } else if let launched = p.launch?.summary {
                print("   started by: \(launched)")
            }
            print("   command: \(p.commandLine)")
        }
        return 0
    }

    // MARK: --battery

    private static func battery() -> Int32 {
        if let b = Battery.read() { print("Now: \(Fmt.batteryLine(b))") }
        let story = BatteryStory(log: PowerLog.read(), samples: HistoryStore.load(since: Date().addingTimeInterval(-7 * 86_400)))
        print("Ran flat \(story.deathsThisWeek) time\(story.deathsThisWeek == 1 ? "" : "s") in the last 7 days")
        for d in story.deaths {
            var line = "  \(d.at.formatted(date: .abbreviated, time: .shortened))"
            if let start = d.unpluggedAt, let pct = d.startPercent {
                line += "  \(pct)% → 1% in \(Fmt.duration(d.at.timeIntervalSince(start)))"
                if let rate = d.drainPerHour { line += String(format: " (%.0f%%/hour)", rate) }
            }
            print(line)
        }
        if let detail = story.lastDeathDetail { print(detail) }
        if let sleep = story.lastSleep {
            var line = "Last sleep: \(sleep.start.formatted(date: .omitted, time: .shortened))–\(sleep.end.formatted(date: .omitted, time: .shortened))"
            line += " (\(Fmt.duration(sleep.end.timeIntervalSince(sleep.start)))), \(sleep.darkWakes) background wake-ups"
            if let used = sleep.used { line += ", used \(used)%" }
            print(line)
        }
        if let ledger = EnergyLedger.load(), ledger.total > 0.05 {
            print("Energy by app since \(ledger.since.formatted(date: .abbreviated, time: .shortened)) (measured by the menu bar app):")
            for (name, wh) in ledger.top(8) { print("  \(Fmt.energy(wh))  \(name)") }
        }
        return 0
    }

    // MARK: Text listing

    private static func printText(_ result: ScanResult, warnings: [SystemWarning]) {
        let r = result.report
        let strays = r.hidden + r.machines
        let strayWatts = strays.reduce(0) { $0 + $1.watts }
        var header = "Strays"
        if let b = result.battery { header += " · battery \(Fmt.batteryLine(b))" }
        print(header)
        if strayWatts >= 0.05 { print("Hidden processes and machines are drawing ≈ \(Fmt.watts(strayWatts))") }
        let exposed = r.hidden.filter(\.isExposed).count
        if exposed > 0 { print("\(exposed) hidden server\(exposed == 1 ? " is" : "s are") reachable from your network") }

        for w in warnings {
            print("\n! \(w.title): \(w.detail)" + (w.fix.map { "\n  fix: \($0)" } ?? ""))
        }

        section("Hidden & orphaned", r.hidden.map(lines))
        section("Duplicates", r.duplicates.map { d in
            ["  \(d.strayIds.count) copies of \(d.title)" + (d.place.map { " in \($0)" } ?? "") + " (newest kept by 'keep newest')"]
        })
        section("Claude sessions", r.claudeSessions.map { s in
            let state = s.isIdle ? "idle" : "working"
            var extra: [String] = []
            if !s.backgroundTasks.isEmpty { extra.append("\(s.backgroundTasks.count) background") }
            if !s.mcpServers.isEmpty { extra.append("MCP: " + s.mcpServers.joined(separator: ", ")) }
            var out = [row(s.totalCPU, s.totalWatts, s.memoryBytes, s.started, s.project ?? s.cwd ?? "?"),
                       indent(([state, "pid \(s.ref.pid)"] + extra).joined(separator: " · "))]
            for t in s.backgroundTasks { out += lines(t).map { "  " + $0 } }
            return out
        })
        section("Keeping the Mac awake", r.sleepBlockers.map { b in
            ["  \(b.process) · \(b.owner)" + (b.reasons.isEmpty ? "" : " · " + b.reasons.joined(separator: ", ")) + " · pid \(b.ref.pid)"]
        })
        section("VMs & simulators", r.machines.map(lines))
    }

    private static func section(_ title: String, _ items: [[String]]) {
        guard !items.isEmpty else { return }
        print("\n\(title.uppercased()) (\(items.count))")
        items.flatMap { $0 }.forEach { print($0) }
    }

    private static func lines(_ s: Stray) -> [String] {
        let ports = s.ports.map { ":\($0.port)" + ($0.exposed ? "(lan)" : "") }.joined(separator: " ")
        let title = [s.title, s.detail, ports.isEmpty ? nil : ports].compactMap { $0 }.joined(separator: " ")
        let pids = s.members.count > 1 ? "pid \(s.root.pid) +\(s.members.count - 1)" : "pid \(s.root.pid)"
        let meta = [s.project, s.origin.label, pids].compactMap { $0 }.joined(separator: " · ")
        var out = [row(s.cpuPercent, s.watts, s.memoryBytes, s.started, title), indent(meta)]
        if let launched = s.launchedBy { out.append(indent("started by: \(launched)")) }
        return out
    }

    private static func row(_ cpu: Double, _ watts: Double, _ mem: UInt64, _ started: Date, _ title: String) -> String {
        func pad(_ s: String, _ n: Int) -> String { String(repeating: " ", count: max(0, n - s.count)) + s }
        let age = Fmt.duration(Date().timeIntervalSince(started))
        return "  \(pad(Fmt.cpu(cpu), 5)) \(pad(Fmt.watts(watts), 7)) \(pad(Fmt.bytes(mem), 8)) \(pad(age, 6))  \(title)"
    }

    private static func indent(_ s: String) -> String {
        String(repeating: " ", count: 33) + s
    }
}
