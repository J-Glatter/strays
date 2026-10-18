import Foundation

public enum StraysPaths {
    /// ~/Library/Application Support/Strays, created on demand.
    public static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Strays", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static var provenance: URL { support.appendingPathComponent("provenance.json") }
    public static var sessionLedger: URL { support.appendingPathComponent("sessions.jsonl") }
    public static var history: URL { support.appendingPathComponent("history.jsonl") }
    public static var activityLog: URL { support.appendingPathComponent("activity.log") }

    /// Posted (cross-process) by the SessionEnd hook so the menu bar app can follow up.
    public static let sessionEndedNotification = Notification.Name("com.glatter.strays.sessionEnded")
}

/// What launched a process, captured while its launcher was still alive.
public struct Launch: Codable, Hashable, Sendable {
    public enum Source: String, Codable, Sendable {
        /// Strays saw the process while its parents were still running.
        case observed
        /// The Claude Code SessionEnd hook listed it as the session closed.
        case sessionEnd
    }

    /// Nearest launcher first, e.g. ["node scripts/screenshot.mjs", "Claude Code (personal/home-assistant)"].
    public var chain: [String]
    public var claudePid: Int32?
    public var claudeProject: String?
    public var sessionId: String?
    public var source: Source
    public var recordedAt: Date

    public init(chain: [String], claudePid: Int32? = nil, claudeProject: String? = nil,
                sessionId: String? = nil, source: Source = .observed, recordedAt: Date = Date()) {
        self.chain = chain
        self.claudePid = claudePid
        self.claudeProject = claudeProject
        self.sessionId = sessionId
        self.source = source
        self.recordedAt = recordedAt
    }

    /// "node scripts/screenshot.mjs ← Claude Code (personal/home-assistant)"
    public var summary: String? {
        var out: [String] = []
        for step in chain where !Self.bareShells.contains(step) && out.last != step {
            out.append(step)
            if out.count == 3 { break }
        }
        return out.isEmpty ? nil : out.joined(separator: " ← ")
    }

    static let bareShells: Set<String> = ["zsh", "bash", "sh", "fish", "dash", "login", "-zsh", "-bash"]
}

/// Launch records keyed by "pid:start", persisted so they survive app restarts
/// (the processes usually outlive the app). Not thread-safe; owned by `Engine`'s queue.
public final class ProvenanceStore {
    private var entries: [String: Launch] = [:]
    private var dirty = false
    private var lastSave = Date.distantPast
    private let url: URL?
    private var ledgerOffset: UInt64 = 0

    /// `url: nil` keeps it in memory only (tests, read-only CLI use).
    public init(url: URL?, load: Bool = true) {
        self.url = url
        if load, let url, let data = try? Data(contentsOf: url) {
            entries = (try? Self.decoder.decode([String: Launch].self, from: data)) ?? [:]
        }
    }

    public static func key(pid: Int32, start: UInt64) -> String { "\(pid):\(start)" }

    public subscript(pid: Int32, start: UInt64) -> Launch? {
        entries[Self.key(pid: pid, start: start)]
    }

    public func record(_ launch: Launch, pid: Int32, start: UInt64, overwrite: Bool = false) {
        let key = Self.key(pid: pid, start: start)
        guard overwrite || entries[key] == nil else { return }
        entries[key] = launch
        dirty = true
    }

    public var count: Int { entries.count }

    /// Folds SessionEnd hook records in, so processes Strays never saw attached still get an origin.
    public func mergeLedger(_ ledger: URL = StraysPaths.sessionLedger) {
        guard let handle = try? FileHandle(forReadingFrom: ledger) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < ledgerOffset { ledgerOffset = 0 }
        try? handle.seek(toOffset: ledgerOffset)
        let data = handle.readDataToEndOfFile()
        ledgerOffset = size
        for record in SessionLedger.decode(data) {
            for p in record.processes {
                let launch = Launch(
                    chain: p.chain.isEmpty ? ["Claude Code" + (record.project.map { " (\($0))" } ?? "")] : p.chain,
                    claudePid: record.claudePid, claudeProject: record.project, sessionId: record.sessionId,
                    source: .sessionEnd, recordedAt: record.endedAt
                )
                self.record(launch, pid: p.pid, start: p.start, overwrite: false)
            }
        }
    }

    /// Writes at most once a minute, dropping entries for processes that have exited.
    public func saveIfNeeded(alive: Set<String>, force: Bool = false) {
        guard let url, dirty, force || Date().timeIntervalSince(lastSave) > 60 else { return }
        entries = entries.filter { alive.contains($0.key) }
        if entries.count > 4_000 {
            let keep = entries.sorted { $0.value.recordedAt > $1.value.recordedAt }.prefix(4_000)
            entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        if let data = try? Self.encoder.encode(entries) { try? data.write(to: url, options: .atomic) }
        dirty = false
        lastSave = Date()
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
}

/// One line of sessions.jsonl, written by `strays --session-end` from Claude Code's SessionEnd hook.
public struct SessionEndRecord: Codable, Hashable, Sendable {
    public struct Process: Codable, Hashable, Sendable {
        public var pid: Int32
        public var start: UInt64
        public var title: String
        public var ports: [UInt16]
        public var chain: [String]

        public init(pid: Int32, start: UInt64, title: String, ports: [UInt16], chain: [String]) {
            self.pid = pid
            self.start = start
            self.title = title
            self.ports = ports
            self.chain = chain
        }
    }

    public var sessionId: String?
    public var claudePid: Int32
    public var claudeStart: UInt64
    public var project: String?
    public var reason: String?
    public var endedAt: Date
    /// Each group's pids, root first, so a notification can stop exactly these.
    public var groups: [[PidRef]]
    public var processes: [Process]

    public init(sessionId: String?, claudePid: Int32, claudeStart: UInt64, project: String?, reason: String?,
                endedAt: Date, groups: [[PidRef]], processes: [Process]) {
        self.sessionId = sessionId
        self.claudePid = claudePid
        self.claudeStart = claudeStart
        self.project = project
        self.reason = reason
        self.endedAt = endedAt
        self.groups = groups
        self.processes = processes
    }
}

public enum SessionLedger {
    public static func append(_ record: SessionEndRecord, to url: URL = StraysPaths.sessionLedger) throws {
        var line = try ProvenanceStore.encoder.encode(record)
        line.append(0x0A)
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: url)
        }
    }

    public static func read(_ url: URL = StraysPaths.sessionLedger) -> [SessionEndRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return decode(data)
    }

    static func decode(_ data: Data) -> [SessionEndRecord] {
        data.split(separator: 0x0A).compactMap { try? ProvenanceStore.decoder.decode(SessionEndRecord.self, from: Data($0)) }
    }
}

/// A short human-readable log of what the app did on its own (notifications, session-end
/// follow-ups), for "why didn't I get told about X?". Trimmed when it passes 256 KB.
public enum ActivityLog {
    public static func write(_ message: String, to url: URL = StraysPaths.activityLog) {
        let line = Data("\(ISO8601DateFormatter().string(from: Date())) \(message)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            if let size = try? handle.seekToEnd(), size > 256_000 {
                try? handle.truncate(atOffset: 0)
            }
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url)
        }
    }
}
