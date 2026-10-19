import Foundation

/// Logic behind `strays --session-start`, run from Claude Code's SessionStart hook: tell the new
/// session what's already running for its project, so it reuses a server instead of starting
/// another copy on a new port (how five panel-skirmish servers ended up running at once).
public enum SessionStart {
    /// What's running in `projectRoot` (or `cwd` outside a repo) that this session didn't start.
    public static func running(in report: Report, cwd: String, projectRoot: String?) -> [Stray] {
        let root = projectRoot ?? cwd
        func inside(_ path: String?) -> Bool {
            guard let path else { return false }
            return path == root || path.hasPrefix(root + "/")
        }
        let hidden = report.hidden.filter { inside($0.cwd) }
        let otherSessions = report.claudeSessions.flatMap(\.backgroundTasks).filter { inside($0.cwd) }
        return hidden + otherSessions
    }

    /// The text injected into the new session's context, or nil when there's nothing to say.
    public static func context(for items: [Stray], duplicates: [DuplicateGroup], cli: String = "~/.local/bin/strays",
                               home: String = NSHomeDirectory(), now: Date = Date()) -> String? {
        guard !items.isEmpty else { return nil }
        var lines = ["Strays (a process monitor on this Mac) found these already running in this project, started before this session:"]
        for s in items.prefix(8) {
            let ports = s.ports.map { ":\($0.port)" + ($0.exposed ? " (reachable from the network)" : "") }
            var line = "- \(s.title)"
            if !ports.isEmpty { line += " on " + ports.joined(separator: ", ") }
            line += " (pid \(s.root.pid), running \(Fmt.duration(now.timeIntervalSince(s.started)))"
            switch (s.kind, s.origin) {
            case (.backgroundTask, _): line += ", background task of another open Claude session"
            case (_, .claude(nil, _)): line += ", left behind by an earlier Claude session"
            case (_, .claude): line += ", detached from another open Claude session"
            case (_, .terminal(let app)): line += ", left running from a closed \(app) window"
            case (_, .unknown): line += ", orphaned"
            }
            if let cwd = s.cwd { line += ", in \(cwd.hasPrefix(home) ? "~" + cwd.dropFirst(home.count) : cwd)" }
            lines.append(line + ")")
        }
        if items.count > 8 { lines.append("- and \(items.count - 8) more (run `\(cli)` to list them)") }
        let ids = Set(items.map(\.id))
        for dup in duplicates where dup.strayIds.contains(where: ids.contains) {
            lines.append("Note: \(dup.strayIds.count) copies of \(dup.title) are running; probably only one is needed.")
        }
        lines.append("Prefer reusing a running server over starting another copy on a new port. If one is stale, `\(cli) --stop <pid>` stops it and its child processes.")
        return lines.joined(separator: "\n")
    }

    /// The hook's stdout: Claude Code adds `additionalContext` to the session.
    public static func hookOutput(context: String) -> String {
        let payload: [String: Any] = [
            "hookSpecificOutput": ["hookEventName": "SessionStart", "additionalContext": context],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
