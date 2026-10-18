import XCTest
@testable import StraysCore

final class ParsingTests: XCTestCase {
    private func procargs(argc: Int32, exec: String, argv: [String], env: [String]) -> [UInt8] {
        var bytes = withUnsafeBytes(of: argc.littleEndian) { Array($0) }
        bytes += Array(exec.utf8) + [0, 0, 0, 0]
        for a in argv { bytes += Array(a.utf8) + [0] }
        for e in env { bytes += Array(e.utf8) + [0] }
        return bytes + [0, 0]
    }

    func testProcArgsSplitsArgvAndEnv() throws {
        let buf = procargs(argc: 3, exec: "/usr/local/bin/node", argv: ["node", "server.js", "--port"],
                           env: ["CLAUDECODE=1", "CLAUDE_PID=123", "PWD=/x", "TERM_PROGRAM=Apple_Terminal"])
        let parsed = try XCTUnwrap(ProcArgs.parse(buf))
        XCTAssertEqual(parsed.execPath, "/usr/local/bin/node")
        XCTAssertEqual(parsed.argv, ["node", "server.js", "--port"])
        let markers = EnvMarkers(env: parsed.env)
        XCTAssertTrue(markers.claudeCode)
        XCTAssertEqual(markers.claudePid, 123)
        XCTAssertEqual(markers.pwd, "/x")
        XCTAssertEqual(markers.termProgram, "Apple_Terminal")
    }

    func testProcessTitleRewriteLeavesNoEnv() throws {
        // npm overwrites the args area: one title string, then NULs where env was.
        var buf = withUnsafeBytes(of: Int32(3).littleEndian) { Array($0) }
        buf += Array("/bin/node".utf8) + [0, 0]
        buf += Array("npm run dev".utf8) + [UInt8](repeating: 0, count: 40)
        let parsed = try XCTUnwrap(ProcArgs.parse(buf))
        XCTAssertEqual(parsed.argv.filter { !$0.isEmpty }, ["npm run dev"])
        XCTAssertTrue(parsed.env.isEmpty)
        XCTAssertFalse(EnvMarkers(env: parsed.env).readable)
    }

    func testProcArgsRejectsGarbage() {
        XCTAssertNil(ProcArgs.parse([1, 2]))
        XCTAssertNil(ProcArgs.parse(withUnsafeBytes(of: Int32(-5)) { Array($0) }))
    }

    func testProjectLabels() {
        let home = "/Users/me"
        XCTAssertEqual(ProjectLabel.make(directory: "/Users/me/Development/games/gambit", projectRoot: "/Users/me/Development/games/gambit", home: home), "games/gambit")
        XCTAssertEqual(ProjectLabel.make(directory: "/Users/me/Development/p/apps/web/src", projectRoot: "/Users/me/Development/p", home: home), "p › web/src")
        XCTAssertEqual(ProjectLabel.make(directory: "/Users/me/Music/x", projectRoot: nil, home: home), "~/Music/x")
        XCTAssertEqual(ProjectLabel.make(directory: "/private/tmp", projectRoot: nil, home: home), "/private/tmp")
        XCTAssertNil(ProjectLabel.make(directory: "/", projectRoot: nil, home: home))
    }

    func testPmsetDisplaySleepIsReadFromBatterySection() {
        let output = """
        Battery Power:
         Sleep On Power Button 1
         displaysleep         0
         sleep                1
        AC Power:
         displaysleep         10
        """
        XCTAssertEqual(SystemProbe.parseBatteryDisplaySleep(output), 0)
        XCTAssertNil(SystemProbe.parseBatteryDisplaySleep("AC Power:\n displaysleep 10\n"))
    }

    func testRuntimeNames() {
        XCTAssertEqual(LiveInspector.prettyRuntime("com.apple.CoreSimulator.SimRuntime.iOS-26-2"), "iOS 26.2")
        XCTAssertEqual(LiveInspector.prettyRuntime("com.apple.CoreSimulator.SimRuntime.watchOS-11-0"), "watchOS 11.0")
    }

    func testFormatting() {
        XCTAssertEqual(Fmt.duration(20 * 86_400 + 3 * 3_600), "20d")
        XCTAssertEqual(Fmt.duration(2 * 86_400 + 5 * 3_600), "2d 5h")
        XCTAssertEqual(Fmt.duration(4 * 3_600 + 12 * 60), "4h 12m")
        XCTAssertEqual(Fmt.duration(40), "40s")
        XCTAssertEqual(Fmt.watts(3.44), "3.4 W")
        XCTAssertEqual(Fmt.watts(0.01), "<0.1 W")
        XCTAssertEqual(Fmt.bytes(8_111 * 1_048_576), "7.9 GB")
        XCTAssertEqual(Fmt.cpu(87.3), "87%")
        XCTAssertEqual(Fmt.cpu(2.24), "2.2%")
        XCTAssertEqual(Fmt.cpuCoarse(0), "0%")
        XCTAssertEqual(Fmt.cpuCoarse(0.6), "<1%")
        XCTAssertEqual(Fmt.cpuCoarse(1.2), "1%")
        XCTAssertEqual(Fmt.cpuCoarse(87.3), "87%")
    }

    func testDisplaySleepWarning() {
        let warnings = SystemWarnings.evaluate(SystemInfo(uptime: 232 * 86_400, swapUsed: 12 << 30, displaySleepOnBattery: 0))
        XCTAssertEqual(warnings.map(\.id), ["displaysleep", "uptime"])
        XCTAssertEqual(warnings.first?.fix, "sudo pmset -b displaysleep 5")
        XCTAssertTrue(SystemWarnings.evaluate(SystemInfo(uptime: 3_600, swapUsed: 0, displaySleepOnBattery: 5)).isEmpty)
    }
}
