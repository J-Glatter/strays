import XCTest
@testable import StraysCore

final class PowerLogTests: XCTestCase {
    private let log = """
    2026-10-17 09:35:47 +0100 Assertions          \tSummary- [System: PrevIdle] Using AC(Charge: 71)
    2026-10-17 12:10:00 +0100 Assertions          \tSummary- [System: PrevIdle] Using AC(Charge: 100)
    2026-10-17 12:15:49 +0100 Assertions          \tSummary- [System: PrevIdle] Using Batt(Charge: 100)
    2026-10-17 14:00:00 +0100 Wake                \tWake from Deep Idle [CDNVA] : due to lid Using BATT (Charge:45%)
    some unrelated line without a date
    2026-10-17 15:31:36 +0100 Sleep               \tEntering Sleep state due to 'Low Power Sleep':TCPKeepAlive=inactive Using Batt (Charge:1%) 2 secs
    2026-10-17 16:11:02 +0100 Wake                \tWake from Hibernate due to acattach Using AC (Charge:1%)
    """

    func testFindsTheDeathAndTheUnplugBeforeIt() throws {
        let now = PowerLog.timestamp.date(from: "2026-10-17 17:00:00 +0100")!
        let summary = PowerLog.parse(log, now: now)
        XCTAssertEqual(summary.deaths.count, 1)
        let death = try XCTUnwrap(summary.deaths.first)
        XCTAssertEqual(death.startPercent, 100)
        XCTAssertEqual(death.unpluggedAt, PowerLog.timestamp.date(from: "2026-10-17 12:15:49 +0100"))
        XCTAssertEqual(death.drainPerHour ?? 0, 99 / (3 * 3600.0 + 15 * 60 + 47) * 3600, accuracy: 0.1)
        XCTAssertEqual(summary.points.map(\.percent), [71, 100, 100, 45, 1, 1])
        XCTAssertEqual(summary.points.map(\.onAC), [true, true, false, false, false, true])
    }

    func testDeathWithNoUnplugInTheLogHasNoWindow() {
        let summary = PowerLog.parse("2026-10-12 12:05:00 +0100 Sleep  \tEntering Sleep state due to 'Low Power Sleep': Using Batt (Charge:1%)")
        XCTAssertEqual(summary.deaths.count, 1)
        XCTAssertNil(summary.deaths[0].unpluggedAt)
    }

    func testReadingFormats() {
        XCTAssertEqual(PowerLog.reading(in: "x Using BATT (Charge:49%) y")?.percent, 49)
        XCTAssertEqual(PowerLog.reading(in: "x Using Batt(Charge: 7)")?.percent, 7)
        XCTAssertEqual(PowerLog.reading(in: "x Using AC (Charge:100%)")?.onAC, true)
        XCTAssertNil(PowerLog.reading(in: "Using nothing"))
    }

    func testStoryUsesOwnSamplesForTheDeathDetail() {
        let now = PowerLog.timestamp.date(from: "2026-10-17 17:00:00 +0100")!
        let summary = PowerLog.parse(log, now: now)
        let unplug = summary.deaths[0].unpluggedAt!
        let samples = (1...3).map { i in
            HistorySample(at: unplug.addingTimeInterval(Double(i) * 1_800), percent: 100 - i * 10, onAC: false,
                          drawWatts: 18, strayWatts: 7, top: [])
        }
        let story = BatteryStory(log: summary, samples: samples, now: now)
        XCTAssertEqual(story.deathsThisWeek, 1)
        XCTAssertEqual(story.lastDeathLine?.hasPrefix("Last ran flat today"), true)
        XCTAssertTrue(story.lastDeathLine?.contains("100% → 1% in 3h 15m") == true, story.lastDeathLine ?? "")
        XCTAssertEqual(story.lastDeathDetail, "Averaged 18 W; hidden processes were 7.0 W of that")
    }
}

final class ProvenanceTests: XCTestCase {
    func testSummarySkipsBareShellsAndDuplicates() {
        let launch = Launch(chain: ["node scripts/screenshot.mjs", "zsh", "node scripts/screenshot.mjs", "Claude Code (personal/home-assistant)", "Terminal"])
        XCTAssertEqual(launch.summary, "node scripts/screenshot.mjs ← Claude Code (personal/home-assistant) ← Terminal")
        XCTAssertNil(Launch(chain: ["zsh", "-zsh"]).summary)
    }

    func testStoreRoundTripsAndPrunesDeadProcesses() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("strays-prov-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ProvenanceStore(url: url, load: false)
        store.record(Launch(chain: ["a"]), pid: 10, start: 1)
        store.record(Launch(chain: ["b"]), pid: 11, start: 2)
        store.record(Launch(chain: ["ignored"]), pid: 10, start: 1)
        store.saveIfNeeded(alive: ["10:1"], force: true)

        let reloaded = ProvenanceStore(url: url)
        XCTAssertEqual(reloaded[10, 1]?.chain, ["a"], "first record wins")
        XCTAssertNil(reloaded[11, 2], "dead processes are pruned on save")
    }

    func testLedgerRecordsBecomeProvenance() throws {
        let ledger = FileManager.default.temporaryDirectory.appendingPathComponent("strays-ledger-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: ledger) }
        let record = SessionEndRecord(
            sessionId: "abc", claudePid: 500, claudeStart: 9, project: "games/gambit", reason: "prompt_input_exit",
            endedAt: Date(), groups: [[PidRef(pid: 600, start: 7)]],
            processes: [.init(pid: 600, start: 7, title: "vite", ports: [5180], chain: ["Claude Code (games/gambit)"])]
        )
        try SessionLedger.append(record, to: ledger)
        try SessionLedger.append(record, to: ledger)
        XCTAssertEqual(SessionLedger.read(ledger).count, 2)

        let store = ProvenanceStore(url: nil)
        store.mergeLedger(ledger)
        let launch = try XCTUnwrap(store[600, 7])
        XCTAssertEqual(launch.source, .sessionEnd)
        XCTAssertEqual(launch.claudeProject, "games/gambit")
        XCTAssertEqual(launch.sessionId, "abc")
    }
}

final class SessionEndTests: XCTestCase {
    private func stray(_ id: Int32, origin: Origin, sessionId: String? = nil, kind: Stray.Kind = .orphan) -> Stray {
        Stray(
            id: "s\(id)", kind: kind, title: "t\(id)", detail: nil, project: nil, cwd: nil, command: "c",
            root: PidRef(pid: id, start: 1), members: [PidRef(pid: id, start: 1), PidRef(pid: id + 1, start: 1)],
            started: Date(), cpuPercent: 0, cpuSmoothed: 0, watts: 0, memoryBytes: 0, cpuSecondsTotal: 0,
            energyWhTotal: 0, ports: [ListeningPort(port: 5180, exposed: true)], origin: origin,
            devtoolsPort: nil, simulatorUDID: nil, launchedBy: nil, claudeSessionId: sessionId
        )
    }

    func testLeftoversAreTheSessionsTasksAndItsDetachedProcesses() {
        let task = stray(10, origin: .claude(livePid: 500, project: nil), kind: .backgroundTask)
        let session = ClaudeSession(
            id: "c500", ref: PidRef(pid: 500, start: 1), project: "games/gambit", cwd: nil, started: Date(),
            cpuPercent: 0, watts: 0, memoryBytes: 0, backgroundTasks: [task], mcpServers: [], members: []
        )
        let report = Report(
            hidden: [
                stray(20, origin: .claude(livePid: 500, project: nil)),       // detached from this session
                stray(30, origin: .claude(livePid: nil, project: nil), sessionId: "abc"), // same session id
                stray(40, origin: .claude(livePid: 999, project: nil)),       // another session
                stray(50, origin: .terminal("Terminal")),
            ],
            claudeSessions: [session], sleepBlockers: [], machines: [], generatedAt: Date()
        )
        let left = SessionEnd.leftovers(report: report, claudePid: 500, sessionId: "abc")
        XCTAssertEqual(left.map(\.id), ["s10", "s20", "s30"])

        let claude = ProcessRecord(pid: 500, ppid: 1, name: "claude", startMicros: 1)
        let record = SessionEnd.record(claude: claude, project: "games/gambit", input: .init(session_id: "abc"), leftovers: left)
        XCTAssertEqual(record.groups.count, 3)
        XCTAssertEqual(record.processes.count, 6)
        XCTAssertEqual(record.processes.first?.chain, ["Claude Code (games/gambit)"])
        XCTAssertEqual(record.processes[1].chain, ["t10", "Claude Code (games/gambit)"])
    }

    func testFindsTheClaudeAboveTheHook() {
        let snap = Snapshot(processes: [
            ProcessRecord(pid: 500, ppid: 1, name: "claude"),
            ProcessRecord(pid: 501, ppid: 500, name: "bash"),
            ProcessRecord(pid: 502, ppid: 501, name: "strays"),
        ], uid: 501)
        XCTAssertEqual(SessionEnd.claudeAncestor(of: 502, in: snap)?.pid, 500)
        XCTAssertNil(SessionEnd.claudeAncestor(of: 500, in: snap))
    }
}
