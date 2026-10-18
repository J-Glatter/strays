import Foundation
import StraysCore

/// The Claude Code SessionEnd hook that runs `strays --session-end`. Installing it is done by
/// the bundled claude-hook.py, which merges it into ~/.claude/settings.json without disturbing
/// anything else.
enum ClaudeHook {
    static var settings: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    static var isInstalled: Bool {
        // The command is `"$HOME/.local/bin/strays" --session-end`, so match the two parts separately.
        guard let text = try? String(contentsOf: settings, encoding: .utf8) else { return false }
        return text.contains("--session-end") && text.contains("strays")
    }

    /// Returns a one-line result for the footer.
    static func install() -> String {
        guard let script = Bundle.main.url(forResource: "claude-hook", withExtension: "py") else {
            return "Hook script missing; run ./install.sh"
        }
        guard let result = Shell.run("/usr/bin/python3", [script.path, "install"], timeout: 20), result.status == 0 else {
            return "Couldn't install the hook"
        }
        return "Hook installed. Applies to new Claude sessions."
    }
}
