import XCTest
@testable import StraysCore

final class CommandNamerTests: XCTestCase {
    private func name(_ args: [String], path: String = "") -> String {
        CommandNamer.name(args: args, path: path)
    }

    func testTsNodeDevSkipsRequireHook() {
        let args = [
            "/Users/joe/.nvm/versions/node/v22.13.0/bin/node", "-r", "/var/folders/T/ts-node-dev-hook-1.js",
            "/Users/joe/p/node_modules/ts-node-dev/lib/wrap.js", "src/index.ts",
        ]
        XCTAssertEqual(name(args, path: args[0]), "ts-node-dev src/index.ts")
    }

    func testBinShimUsesToolNameAndIgnoresFlagValues() {
        let args = ["node", "/p/node_modules/.bin/vite", "--host", "0.0.0.0", "--port", "5180"]
        XCTAssertEqual(name(args, path: "/usr/local/bin/node"), "vite")
    }

    func testScopedPackage() {
        XCTAssertEqual(name(["node", "/p/node_modules/@scope/tool/dist/cli.js"], path: "/bin/node"), "@scope/tool")
    }

    func testIndexFileGetsParentDirectory() {
        XCTAssertEqual(name(["node", "/Users/joe/panel-skirmish/server/index.js"], path: "/bin/node"), "server/index.js")
    }

    func testPythonModule() {
        let args = ["/opt/homebrew/.../Python", "-m", "http.server", "8790", "--bind", "127.0.0.1"]
        XCTAssertEqual(name(args, path: "/opt/homebrew/Frameworks/Python.framework/Resources/Python.app/Contents/MacOS/Python"), "http.server 8790")
    }

    func testPythonInlineCodeIsOneShortLine() {
        let code = "\nimport http.server\nimport socketserver\n\nPORT = 8888\nwith socketserver.TCPServer(('0.0.0.0', PORT), Handler) as httpd:\n    httpd.serve_forever()\n"
        let result = name(["python3", "-c", code], path: "/usr/bin/python3")
        XCTAssertTrue(result.hasPrefix("python -c import http.server import socketserver"), result)
        XCTAssertFalse(result.contains("\n"))
        XCTAssertLessThanOrEqual(result.count, 60)
    }

    func testProcessTitleDropsFlags() {
        XCTAssertEqual(name(["npm run dev"]), "npm run dev")
        XCTAssertEqual(name(["npm exec vite --host 0.0.0.0 --port 5180 --strictPort", "", ""]), "npm exec vite")
    }

    func testPackageRunnerShowsThePackage() {
        XCTAssertEqual(name(["/opt/homebrew/bin/uv", "tool", "uvx", "mcp-for-blender"], path: "/opt/homebrew/bin/uv"), "mcp-for-blender")
        XCTAssertEqual(name(["npx", "-y", "@playwright/mcp"], path: "/usr/local/bin/npx"), "@playwright/mcp")
    }

    func testNpmViaNodeScript() {
        let args = ["node", "/Users/joe/.nvm/versions/node/v22/bin/npm", "run", "dev"]
        XCTAssertEqual(name(args, path: "/Users/joe/.nvm/versions/node/v22/bin/node"), "npm run dev")
    }

    func testClaudeShellWrapperShowsTheRealCommand() {
        let script = "source /Users/joe/.claude/shell-snapshots/snapshot-zsh-1.sh 2>/dev/null || true && setopt NO_EXTENDED_GLOB 2>/dev/null || true && eval 'python3 -m http.server 8790 --bind 127.0.0.1' < /dev/null && pwd -P >| /tmp/claude-3915-cwd"
        XCTAssertEqual(name(["/bin/zsh", "-c", script], path: "/bin/zsh"), "python3 -m http.server 8790 --bind 127.0.0.1")
    }

    func testEvalUnescapesQuotes() {
        XCTAssertEqual(CommandNamer.extractEval("eval 'echo '\\''hi'\\''' < /dev/null"), "echo 'hi'")
    }

    func testPlainShellScript() {
        XCTAssertEqual(name(["sh", "-c", "node scripts/build.mjs && node scripts/serve.mjs"], path: "/bin/sh"), "node scripts/build.mjs && node scripts/serve.mjs")
    }

    func testUnknownBinaryIsItsName() {
        XCTAssertEqual(name(["esbuild", "--service=0.21.5", "--ping"], path: "/p/node_modules/@esbuild/darwin-arm64/bin/esbuild"), "esbuild")
    }
}
