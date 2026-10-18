import XCTest
@testable import StraysCore

private final class FakeInspector: ProcessInspector {
    var cwds: [Int32: String] = [:]
    var ports: [Int32: [ListeningPort]] = [:]

    func cwd(_ pid: Int32) -> String? { cwds[pid] }
    func listeningPorts(_ pid: Int32) -> [ListeningPort] { ports[pid] ?? [] }
    func projectLabel(forDirectory dir: String) -> String? { ProjectLabel.make(directory: dir, projectRoot: nil, home: "/Users/me") }
    func simulatorInfo(udid: String) -> SimulatorInfo? { SimulatorInfo(name: "iPhone 17 Pro", runtime: "iOS 26.2") }
}

final class ClassifierTests: XCTestCase {
    private let me: UInt32 = 501
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func proc(
        _ pid: Int32, ppid: Int32, sid: Int32? = nil, name: String, path: String? = nil, args: [String]? = nil,
        env: [String] = [], uid: UInt32 = 501, ageSeconds: Double = 3_600, cpu: Double = 0, claudeAncestor: Int32? = nil
    ) -> ProcessRecord {
        ProcessRecord(
            pid: pid, ppid: ppid, sid: sid ?? pid, uid: uid, name: name,
            path: path ?? "/usr/bin/\(name)", args: args ?? [name], markers: EnvMarkers(env: env),
            startMicros: UInt64((now.timeIntervalSince1970 - ageSeconds) * 1_000_000),
            cpuPercent: cpu, cpuSmoothed: cpu,
            launch: claudeAncestor.map { Launch(chain: ["sh -c yes", "Claude Code (games/gambit)"], claudePid: $0, claudeProject: "games/gambit") }
        )
    }

    private func classify(_ procs: [ProcessRecord], inspector: FakeInspector = FakeInspector(),
                          assertions: [Int32: [PowerAssertion]] = [:]) -> Report {
        let all = [proc(1, ppid: 0, name: "launchd", uid: 0)] + procs
        return Classifier.classify(Snapshot(processes: all, uid: me), inspector: inspector, assertions: assertions, now: now)
    }

    func testOrphanWhoseShellDiedIsHidden() {
        let r = classify([proc(100, ppid: 1, sid: 99, name: "node", args: ["node", "server.js"], env: ["TERM_PROGRAM=iTerm.app"])])
        XCTAssertEqual(r.hidden.map(\.title), ["server.js"])
        XCTAssertEqual(r.hidden.first?.origin, .terminal("iTerm"))
    }

    func testLaunchdJobsAndAppsAreNotOrphans() {
        let r = classify([
            proc(200, ppid: 1, sid: 1, name: "WindowManager"),
            proc(201, ppid: 1, sid: 201, name: "Terminal", path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
            proc(202, ppid: 1, sid: 150, name: "chrome_crashpad_handler"),
        ])
        XCTAssertTrue(r.hidden.isEmpty, "\(r.hidden.map(\.title))")
    }

    func testAppOpenedFromClaudeIsNotAStrayButDevRunAppBinaryIs() {
        let r = classify([
            // `open -a Foo` from a Claude shell: LaunchServices puts it in launchd's session.
            proc(250, ppid: 1, sid: 1, name: "Foo", path: "/Applications/Foo.app/Contents/MacOS/Foo", env: ["CLAUDECODE=1"]),
            proc(252, ppid: 1, sid: 252, name: "Bar", path: "/Applications/Bar.app/Contents/MacOS/Bar", env: ["CLAUDECODE=1"]),
            // `python3 -m http.server &` from a Claude shell: runs Python.app's binary in the shell's session.
            proc(251, ppid: 1, sid: 240, name: "Python", path: "/opt/homebrew/Python.app/Contents/MacOS/Python",
                 args: ["Python", "-m", "http.server", "8777"], env: ["CLAUDECODE=1"]),
        ])
        XCTAssertEqual(r.hidden.map(\.title), ["http.server 8777"])
    }

    func testDetachedFromLiveShellCounts() {
        let r = classify([
            proc(300, ppid: 1, sid: 300, name: "zsh"),
            proc(301, ppid: 1, sid: 300, name: "python3", args: ["python3", "-m", "http.server"]),
        ])
        XCTAssertEqual(r.hidden.map(\.title), ["http.server"])
    }

    func testClaudeEnvMarksOrphanEvenWithOwnSession() {
        let r = classify([proc(400, ppid: 1, sid: 400, name: "node", args: ["node", "a.js"], env: ["CLAUDECODE=1", "CLAUDE_PID=9999"])])
        XCTAssertEqual(r.hidden.first?.origin, .claude(livePid: nil, project: nil))
    }

    func testRememberedClaudeAncestorPointsAtLiveSession() {
        let inspector = FakeInspector()
        inspector.cwds[500] = "/Users/me/Development/games/gambit"
        let r = classify([
            proc(500, ppid: 1, sid: 500, name: "claude", ageSeconds: 7_200),
            proc(510, ppid: 1, sid: 509, name: "sh", args: ["sh", "-c", "yes"], claudeAncestor: 500),
        ], inspector: inspector)
        XCTAssertEqual(r.hidden.first?.origin, .claude(livePid: 500, project: "games/gambit"))
    }

    func testOrphanGroupIncludesDescendantsAndSumsCPU() {
        let r = classify([
            proc(600, ppid: 1, sid: 599, name: "npm run dev", args: ["npm run dev"]),
            proc(601, ppid: 600, sid: 599, name: "node", args: ["node", "/p/node_modules/.bin/vite"], env: ["CLAUDECODE=1"], cpu: 20),
            proc(602, ppid: 601, sid: 599, name: "esbuild", cpu: 5),
        ])
        XCTAssertEqual(r.hidden.count, 1)
        let s = try! XCTUnwrap(r.hidden.first)
        XCTAssertEqual(s.title, "npm run dev")
        XCTAssertEqual(s.members.map(\.pid), [600, 601, 602])
        XCTAssertEqual(s.cpuPercent, 25)
        XCTAssertTrue(s.isHot)
        XCTAssertTrue(s.origin.isClaude, "env found on a child should still mark the group")
    }

    func testHeadlessChromeIsOneGroupWithHelpers() {
        let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        let helper = "/Applications/Google Chrome.app/Contents/Frameworks/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
        let inspector = FakeInspector()
        inspector.ports[700] = [ListeningPort(port: 52_674, exposed: false)]
        let r = classify([
            proc(700, ppid: 1, sid: 650, name: "Google Chrome", path: chrome,
                 args: [chrome, "--headless=new", "--remote-debugging-port=0", "--user-data-dir=/tmp/tvc-YtTFSE"]),
            proc(701, ppid: 700, sid: 650, name: "Google Chrome Helper (Renderer)", path: helper,
                 args: [helper, "--type=renderer", "--remote-debugging-port=0"], cpu: 25),
            // The user's own Chrome is not automation.
            proc(800, ppid: 1, sid: 1, name: "Google Chrome", path: chrome, args: [chrome, "--no-startup-window"]),
        ], inspector: inspector)
        XCTAssertEqual(r.hidden.count, 1)
        let s = try! XCTUnwrap(r.hidden.first)
        XCTAssertEqual(s.kind, .headlessBrowser)
        XCTAssertEqual(s.title, "Headless Chrome")
        XCTAssertEqual(s.detail, "tvc-YtTFSE")
        XCTAssertEqual(s.devtoolsPort, 52_674)
        XCTAssertEqual(s.members.count, 2)
    }

    func testClaudeSessionSplitsMCPFromBackgroundTasks() {
        let inspector = FakeInspector()
        inspector.cwds[900] = "/Users/me/Development/personal/home-assistant"
        let wrapper = "source /Users/me/.claude/shell-snapshots/s.sh && eval 'python3 -m http.server 8790' < /dev/null"
        let r = classify([
            proc(900, ppid: 1, sid: 900, name: "claude", ageSeconds: 86_400),
            proc(901, ppid: 900, name: "uv", path: "/opt/homebrew/bin/uv", args: ["uv", "tool", "uvx", "mcp-for-blender"]),
            proc(902, ppid: 900, name: "zsh", path: "/bin/zsh", args: ["/bin/zsh", "-c", wrapper], ageSeconds: 600),
            proc(903, ppid: 902, name: "Python", args: ["Python", "-m", "http.server", "8790"]),
            proc(904, ppid: 900, name: "zsh", path: "/bin/zsh", args: ["/bin/zsh", "-c", "eval 'ls' < /dev/null"], ageSeconds: 2),
            proc(905, ppid: 900, name: "caffeinate", args: ["caffeinate", "-i", "-t", "300"]),
        ], inspector: inspector, assertions: [905: [PowerAssertion(type: "PreventUserIdleSystemSleep", name: "caffeinate command-line tool")]])

        let session = try! XCTUnwrap(r.claudeSessions.first)
        XCTAssertEqual(session.project, "personal/home-assistant")
        XCTAssertEqual(session.mcpServers, ["mcp-for-blender"])
        XCTAssertEqual(session.backgroundTasks.map(\.title), ["python3 -m http.server 8790"])
        XCTAssertEqual(session.backgroundTasks.first?.members.map(\.pid), [902, 903])
        XCTAssertTrue(r.hidden.isEmpty)
        XCTAssertEqual(r.sleepBlockers.first?.owner, "Claude Code · personal/home-assistant")
        XCTAssertTrue(r.sleepBlockers.first?.canStop == true)
    }

    func testSystemDaemonsAreNotSleepBlockers() {
        let r = classify([proc(950, ppid: 1, sid: 1, name: "sharingd", path: "/usr/libexec/sharingd")],
                         assertions: [950: [PowerAssertion(type: "PreventUserIdleSystemSleep", name: "Handoff")]])
        XCTAssertTrue(r.sleepBlockers.isEmpty)
    }

    func testSimulatorAndDockerAreMachines() {
        let udid = "005E12F2-368B-44EE-9106-B6240CA066E6"
        let r = classify([
            proc(1000, ppid: 1, name: "launchd_sim",
                 args: ["launchd_sim", "/Users/me/Library/Developer/CoreSimulator/Devices/\(udid)/data/var/run/launchd_bootstrap.plist"]),
            proc(1001, ppid: 1000, name: "SpringBoard", cpu: 3),
            proc(1100, ppid: 1, name: "com.docker.backend", path: "/Applications/Docker.app/Contents/MacOS/com.docker.backend"),
            proc(1101, ppid: 1, name: "com.apple.Virtualization.VirtualMachine"),
        ])
        XCTAssertEqual(Set(r.machines.map(\.title)), ["iPhone 17 Pro", "Docker Desktop"])
        XCTAssertEqual(r.machines.first { $0.kind == .simulator }?.simulatorUDID, udid)
        XCTAssertEqual(r.machines.first { $0.title == "Docker Desktop" }?.members.count, 2)
        XCTAssertTrue(r.hidden.isEmpty)
    }
}

final class NestedSessionTests: XCTestCase {
    func testClaudeStartedInsideAnotherSessionIsItsOwnSession() {
        let now = Date()
        func p(_ pid: Int32, _ ppid: Int32, _ name: String, age: Double = 3_600) -> ProcessRecord {
            ProcessRecord(pid: pid, ppid: ppid, sid: pid, name: name, args: [name],
                          startMicros: UInt64((now.timeIntervalSince1970 - age) * 1_000_000))
        }
        let snap = Snapshot(processes: [
            p(1, 0, "launchd"), p(100, 1, "claude", age: 7_200), p(101, 100, "zsh"),
            p(200, 101, "claude"), p(201, 200, "python3"),
        ], uid: 501)
        final class Nothing: ProcessInspector {
            func cwd(_ pid: Int32) -> String? { nil }
            func listeningPorts(_ pid: Int32) -> [ListeningPort] { [] }
            func projectLabel(forDirectory dir: String) -> String? { nil }
            func simulatorInfo(udid: String) -> SimulatorInfo? { nil }
        }
        let r = Classifier.classify(snap, inspector: Nothing(), now: now)
        let outer = r.claudeSessions.first { $0.ref.pid == 100 }
        let inner = r.claudeSessions.first { $0.ref.pid == 200 }
        XCTAssertEqual(outer?.backgroundTasks.flatMap(\.members).map(\.pid), [101])
        XCTAssertEqual(inner?.backgroundTasks.flatMap(\.members).map(\.pid), [201])
    }
}
