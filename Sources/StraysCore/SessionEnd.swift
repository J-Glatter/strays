import Foundation

/// Logic behind `strays --session-end`, run from Claude Code's SessionEnd hook while the
/// ending session's `claude` process is still alive.
public enum SessionEnd {
    /// The fields of the hook's stdin JSON that we use.
    public struct HookInput: Decodable, Sendable {
        public var session_id: String?
        public var cwd: String?
        public var reason: String?

        public init(session_id: String? = nil, cwd: String? = nil, reason: String? = nil) {
            self.session_id = session_id
            self.cwd = cwd
            self.reason = reason
        }
    }

    /// The `claude` process this hook runs under (hook → shell → claude).
    public static func claudeAncestor(of pid: Int32, in snap: Snapshot) -> ProcessRecord? {
        var current = snap.processes[pid]?.ppid
        var hops = 0
        while let c = current, c > 1, hops < 32, let p = snap.processes[c] {
            if Classifier.isClaude(p) { return p }
            current = p.ppid
            hops += 1
        }
        return nil
    }

    /// What the ending session would leave running: its background tasks, plus anything it
    /// started that has already detached from it.
    public static func leftovers(report: Report, claudePid: Int32, sessionId: String?) -> [Stray] {
        let tasks = report.claudeSessions.first { $0.ref.pid == claudePid }?.backgroundTasks ?? []
        let detached = report.hidden.filter { s in
            if case .claude(let live, _) = s.origin, live == claudePid { return true }
            if let sessionId, s.claudeSessionId == sessionId { return true }
            return false
        }
        return tasks + detached
    }

    public static func record(
        claude: ProcessRecord, project: String?, input: HookInput, leftovers: [Stray], now: Date = Date()
    ) -> SessionEndRecord {
        let launcher = "Claude Code" + (project.map { " (\($0))" } ?? "")
        let processes = leftovers.flatMap { stray in
            stray.members.map {
                SessionEndRecord.Process(
                    pid: $0.pid, start: $0.start, title: stray.title,
                    ports: stray.ports.map(\.port),
                    chain: $0 == stray.root ? [launcher] : [stray.title, launcher]
                )
            }
        }
        return SessionEndRecord(
            sessionId: input.session_id, claudePid: claude.pid, claudeStart: claude.startMicros,
            project: project, reason: input.reason, endedAt: now,
            groups: leftovers.map(\.members), processes: processes
        )
    }

    /// Which of a record's groups are still running once the session has actually gone.
    /// Empty if the `claude` process is still alive (e.g. `/clear` ends a session but keeps the process).
    public static func survivors(of record: SessionEndRecord) -> [[PidRef]] {
        let claude = PidRef(pid: record.claudePid, start: record.claudeStart)
        guard Stopper.alive([claude]).isEmpty else { return [] }
        return record.groups.map(Stopper.alive).filter { !$0.isEmpty }
    }
}
