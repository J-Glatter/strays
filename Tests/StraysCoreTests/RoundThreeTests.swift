import XCTest
@testable import StraysCore

private func makeStray(
    _ id: String, title: String, kind: Stray.Kind = .orphan, cwd: String? = "/Users/me/Development/games/panel-skirmish",
    origin: Origin = .claude(livePid: nil, project: nil), ageHours: Double = 48, cpu: Double = 0,
    ports: [ListeningPort] = [], pid: Int32 = 100, now: Date = Date()
) -> Stray {
    Stray(
        id: id, kind: kind, title: title, detail: nil, project: "games/panel-skirmish", cwd: cwd, command: title,
        root: PidRef(pid: pid, start: 1), members: [PidRef(pid: pid, start: 1)],
        started: now.addingTimeInterval(-ageHours * 3_600), cpuPercent: cpu, cpuSmoothed: cpu, watts: 0,
        memoryBytes: 0, cpuSecondsTotal: 0, energyWhTotal: 0, ports: ports, origin: origin,
        devtoolsPort: nil, simulatorUDID: nil, launchedBy: nil, claudeSessionId: nil
    )
}

final class DuplicateTests: XCTestCase {
    func testCopiesInTheSameFolderGroupAndKeepTheNewest() {
        let hidden = [
            makeStray("a", title: "server/index.js", ageHours: 70),
            makeStray("b", title: "server/index.js", ageHours: 60),
            makeStray("c", title: "server/index.js", ageHours: 50),
            makeStray("d", title: "http.server 8733", cwd: "/x/public"),
            makeStray("e", title: "http.server 8734", cwd: "/x/public", ageHours: 1),
            makeStray("f", title: "http.server 8732", cwd: "/x"),
        ]
        let dups = Classifier.duplicates(in: hidden)
        XCTAssertEqual(dups.count, 2)
        XCTAssertEqual(dups[0].strayIds, ["a", "b", "c"])
        XCTAssertEqual(dups[0].keepId, "c")
        XCTAssertEqual(dups[0].extraIds, ["a", "b"])
        XCTAssertEqual(dups[1].title, "http.server")
        XCTAssertEqual(dups[1].keepId, "e", "port numbers don't make copies different; newest is kept")
    }

    func testWithoutPorts() {
        XCTAssertEqual(Classifier.withoutPorts("http.server 8790"), "http.server")
        XCTAssertEqual(Classifier.withoutPorts("python -c import x"), "python -c import x")
    }
}

final class SessionStartTests: XCTestCase {
    func testListsWhatsRunningInTheProjectOnly() {
        let now = Date()
        let inProject = makeStray("a", title: "vite", cwd: "/Users/me/Development/games/gambit/web",
                                  ports: [ListeningPort(port: 5180, exposed: true)], pid: 11825, now: now)
        let elsewhere = makeStray("b", title: "server.js", cwd: "/Users/me/Development/games/mtg", now: now)
        let report = Report(hidden: [inProject, elsewhere], claudeSessions: [], sleepBlockers: [], machines: [], generatedAt: now)

        let items = SessionStart.running(in: report, cwd: "/Users/me/Development/games/gambit/web",
                                         projectRoot: "/Users/me/Development/games/gambit")
        XCTAssertEqual(items.map(\.id), ["a"])

        let text = SessionStart.context(for: items, duplicates: [], home: "/Users/me", now: now)!
        XCTAssertTrue(text.contains("- vite on :5180 (reachable from the network) (pid 11825, running 2d"), text)
        XCTAssertTrue(text.contains("in ~/Development/games/gambit/web"), text)
        XCTAssertTrue(text.contains("--stop <pid>"))
        XCTAssertNil(SessionStart.context(for: [], duplicates: []))
    }

    func testHookOutputIsTheDocumentedShape() throws {
        let json = SessionStart.hookOutput(context: "hello")
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: [String: String]]
        XCTAssertEqual(obj?["hookSpecificOutput"]?["hookEventName"], "SessionStart")
        XCTAssertEqual(obj?["hookSpecificOutput"]?["additionalContext"], "hello")
    }
}

final class EnergyLedgerTests: XCTestCase {
    func testAccumulatesDeltasByAppAndGroup() {
        let since = Date(timeIntervalSince1970: 1_000)
        func p(_ pid: Int32, _ name: String, path: String, energyWh: Double, startedAt: Double = 0) -> ProcessRecord {
            ProcessRecord(pid: pid, ppid: 1, name: name, path: path, startMicros: UInt64(startedAt * 1_000_000),
                          energyNj: UInt64(energyWh * 3.6e12))
        }
        let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        let helper = "/Applications/Google Chrome.app/Contents/Frameworks/X.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
        let orphan = makeStray("o", title: "node", pid: 30)
        let report = Report(hidden: [orphan], claudeSessions: [], sleepBlockers: [], machines: [], generatedAt: since)

        var ledger = EnergyLedger(since: since, startPercent: 100)
        ledger.update(snapshot: Snapshot(processes: [
            p(10, "Google Chrome", path: chrome, energyWh: 5),
            p(11, "Google Chrome Helper", path: helper, energyWh: 1),
            p(30, "node", path: "/usr/local/bin/node", energyWh: 2),
        ], uid: 501), report: report)
        XCTAssertEqual(ledger.total, 0, "first sight of processes started before `since` is only a baseline")

        ledger.update(snapshot: Snapshot(processes: [
            p(10, "Google Chrome", path: chrome, energyWh: 7),
            p(11, "Google Chrome Helper", path: helper, energyWh: 2),
            p(30, "node", path: "/usr/local/bin/node", energyWh: 2.5),
            p(40, "yes", path: "/usr/bin/yes", energyWh: 0.25, startedAt: 2_000),
        ], uid: 501), report: report)
        XCTAssertEqual(ledger.wh["Google Chrome"] ?? 0, 3, accuracy: 0.001, "helpers count towards their app")
        XCTAssertEqual(ledger.wh[EnergyLedger.hiddenGroup] ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(ledger.wh["yes"] ?? 0, 0.25, accuracy: 0.001, "started during the period: all of it counts")
        XCTAssertEqual(ledger.top(1).first?.name, "Google Chrome")
    }
}

final class AutoCleanupTests: XCTestCase {
    func testOnlyOldIdleLeftoversFromEndedClaudeSessions() {
        let now = Date()
        let candidates = [
            makeStray("old-idle", title: "a", ageHours: 30, now: now),
            makeStray("young", title: "b", ageHours: 2, now: now),
            makeStray("busy", title: "c", ageHours: 30, cpu: 40, now: now),
            makeStray("live-session", title: "d", origin: .claude(livePid: 5, project: nil), ageHours: 30, now: now),
            makeStray("terminal", title: "e", origin: .terminal("Terminal"), ageHours: 30, now: now),
            makeStray("ignored", title: "f", ageHours: 30, now: now),
        ]
        let ignored: Set<String> = [candidates[5].signature]
        let picked = AutoCleanup.eligible(candidates, ignored: ignored, olderThan: 24 * 3_600, now: now)
        XCTAssertEqual(picked.map(\.id), ["old-idle"])
    }
}

final class SleepSessionTests: XCTestCase {
    func testOvernightSleepCountsDarkWakesAndCharge() throws {
        let log = """
        2026-10-16 23:00:00 +0100 Sleep               \tEntering Sleep state due to 'Idle Sleep':TCPKeepAlive=active Using Batt (Charge:100%) 131 secs
        2026-10-16 23:04:12 +0100 DarkWake            \tDarkWake from Deep Idle [CDNP] : due to rtc/SleepService Using BATT (Charge:100%) 2 secs
        2026-10-16 23:04:14 +0100 Sleep               \tEntering Sleep state due to 'Sleep Service Back to Sleep':TCPKeepAlive=active Using Batt (Charge:100%) 131 secs
        2026-10-16 23:04:17 +0100 Wake Requests       \t[process=mDNSResponder request=Maintenance deltaSecs=7200]
        2026-10-17 03:06:25 +0100 DarkWake            \tDarkWake from Deep Idle [CDNP] : due to wifibt Using BATT (Charge:99%) 2 secs
        2026-10-17 08:49:09 +0100 Wake                \tWake from Deep Idle [CDNVA] : due to lid UserActivity Assertion Using BATT (Charge:98%)
        """
        let now = PowerLog.timestamp.date(from: "2026-10-17 12:00:00 +0100")!
        let summary = PowerLog.parse(log, now: now)
        let sleep = try XCTUnwrap(summary.sleeps.last)
        XCTAssertEqual(sleep.darkWakes, 2)
        XCTAssertEqual(sleep.startPercent, 100)
        XCTAssertEqual(sleep.endPercent, 98)
        XCTAssertEqual(sleep.used, 2)
        XCTAssertEqual(BatteryStory(log: summary, samples: [], now: now).lastSleep, sleep)
    }
}
