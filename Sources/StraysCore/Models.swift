import Foundation

/// A pid plus its start time, so a stop never hits a recycled pid.
public struct PidRef: Codable, Hashable, Sendable {
    public var pid: Int32
    public var start: UInt64

    public init(pid: Int32, start: UInt64) {
        self.pid = pid
        self.start = start
    }
}

/// The handful of environment variables that tell us who launched a process.
public struct EnvMarkers: Codable, Hashable, Sendable {
    public var readable = false
    public var claudeCode = false
    public var claudePid: Int32?
    public var claudeSessionId: String?
    public var termProgram: String?
    public var pwd: String?

    public init() {}

    public init(env: [String]) {
        readable = !env.isEmpty
        for entry in env {
            guard let eq = entry.firstIndex(of: "=") else { continue }
            let value = String(entry[entry.index(after: eq)...])
            switch entry[..<eq] {
            case "CLAUDECODE": claudeCode = claudeCode || value == "1"
            case "CLAUDE_PID": claudePid = Int32(value)
            case "CLAUDE_CODE_SESSION_ID": claudeSessionId = value
            case "TERM_PROGRAM": termProgram = value
            case "PWD": pwd = value
            default: break
            }
        }
        if claudePid != nil || claudeSessionId != nil { claudeCode = true }
    }
}

public struct ProcessRecord: Codable, Hashable, Sendable {
    public var pid: Int32
    public var ppid: Int32
    public var pgid: Int32
    /// Session id, or -1 when not looked up (other users' processes).
    public var sid: Int32
    public var uid: UInt32
    /// Display name: executable basename, falling back to the kernel's short name.
    public var name: String
    /// Kernel short name (p_comm), the name the process was exec'd under.
    public var comm: String
    public var path: String
    public var args: [String]
    public var markers: EnvMarkers
    public var startMicros: UInt64
    /// Lifetime CPU time across all cores.
    public var cpuTimeNs: UInt64
    /// Lifetime energy as accounted by the kernel (rusage v6).
    public var energyNj: UInt64
    public var footprint: UInt64
    /// CPU over the last sample interval; 100 = one full core.
    public var cpuPercent: Double
    /// Exponentially smoothed CPU, used for "hot" so one spike doesn't flag a process.
    public var cpuSmoothed: Double
    /// Average power over the last sample interval.
    public var watts: Double
    /// What launched it, captured while the launcher was alive (or from the SessionEnd hook).
    /// Survives the process being orphaned, and covers binaries whose environment macOS hides
    /// (platform binaries like /bin/sh, hardened apps like Chrome).
    public var launch: Launch?

    public init(
        pid: Int32, ppid: Int32, pgid: Int32 = 0, sid: Int32 = -1, uid: UInt32 = 501,
        name: String, comm: String? = nil, path: String = "", args: [String] = [],
        markers: EnvMarkers = EnvMarkers(), startMicros: UInt64 = 0,
        cpuTimeNs: UInt64 = 0, energyNj: UInt64 = 0, footprint: UInt64 = 0,
        cpuPercent: Double = 0, cpuSmoothed: Double = 0, watts: Double = 0,
        launch: Launch? = nil
    ) {
        self.launch = launch
        self.pid = pid
        self.ppid = ppid
        self.pgid = pgid
        self.sid = sid
        self.uid = uid
        self.name = name
        self.comm = comm ?? name
        self.path = path
        self.args = args
        self.markers = markers
        self.startMicros = startMicros
        self.cpuTimeNs = cpuTimeNs
        self.energyNj = energyNj
        self.footprint = footprint
        self.cpuPercent = cpuPercent
        self.cpuSmoothed = cpuSmoothed
        self.watts = watts
    }

    public var ref: PidRef { PidRef(pid: pid, start: startMicros) }
    public var startDate: Date { Date(timeIntervalSince1970: Double(startMicros) / 1_000_000) }
    public var commandLine: String { args.filter { !$0.isEmpty }.joined(separator: " ") }
}

public struct ListeningPort: Codable, Hashable, Sendable, Identifiable {
    public var port: UInt16
    /// Bound to a wildcard address, so reachable from the local network, not just this Mac.
    public var exposed: Bool

    public init(port: UInt16, exposed: Bool) {
        self.port = port
        self.exposed = exposed
    }

    public var id: UInt16 { port }
}

public enum Origin: Codable, Hashable, Sendable {
    /// Launched from Claude Code. `livePid` is set while that session is still running.
    case claude(livePid: Int32?, project: String?)
    case terminal(String)
    case unknown

    public var label: String? {
        switch self {
        case .claude(nil, _): return "Claude (session ended)"
        case .claude: return "Claude (session live)"
        case .terminal(let app): return app
        case .unknown: return nil
        }
    }

    public var isClaude: Bool {
        if case .claude = self { return true }
        return false
    }
}

public struct Stray: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case orphan, headlessBrowser, backgroundTask, vm, simulator, emulator
    }

    public var id: String
    public var kind: Kind
    public var title: String
    /// Secondary identifier: browser profile dir, simulator runtime, VM flavour.
    public var detail: String?
    public var project: String?
    public var cwd: String?
    public var command: String
    public var root: PidRef
    /// Root first, then descendants breadth-first.
    public var members: [PidRef]
    public var started: Date
    public var cpuPercent: Double
    public var cpuSmoothed: Double
    public var watts: Double
    public var memoryBytes: UInt64
    public var cpuSecondsTotal: Double
    public var energyWhTotal: Double
    public var ports: [ListeningPort]
    public var origin: Origin
    public var devtoolsPort: UInt16?
    public var simulatorUDID: String?
    /// "node scripts/screenshot.mjs ← Claude Code (personal/home-assistant)"
    public var launchedBy: String?
    public var claudeSessionId: String?

    /// Listening on a wildcard address, so other devices on the network can connect.
    public var isExposed: Bool { ports.contains(where: \.exposed) }

    /// Stable across restarts of the same thing; used for the ignore list.
    public var signature: String { "\(kind.rawValue)|\(project ?? "")|\(title)" }
    public var isHot: Bool { cpuSmoothed >= 15 || watts >= 1 }

    public static func byImpact(_ a: Stray, _ b: Stray) -> Bool {
        if abs(a.watts - b.watts) > 0.05 { return a.watts > b.watts }
        if abs(a.cpuSmoothed - b.cpuSmoothed) > 0.5 { return a.cpuSmoothed > b.cpuSmoothed }
        return a.started < b.started
    }
}

public struct ClaudeSession: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var ref: PidRef
    public var project: String?
    public var cwd: String?
    public var started: Date
    /// The claude process plus its MCP servers (background tasks are counted separately).
    public var cpuPercent: Double
    public var watts: Double
    public var memoryBytes: UInt64
    public var backgroundTasks: [Stray]
    public var mcpServers: [String]
    /// Every pid in the session tree, for "end session".
    public var members: [PidRef]

    /// An idle Claude Code session still ticks along at 1–4% CPU; real work is well above that.
    public var isIdle: Bool { cpuPercent < 5 && backgroundTasks.allSatisfy { $0.cpuPercent < 2 } }
    public var totalCPU: Double { cpuPercent + backgroundTasks.reduce(0) { $0 + $1.cpuPercent } }
    public var totalWatts: Double { watts + backgroundTasks.reduce(0) { $0 + $1.watts } }
}

public struct SleepBlocker: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var ref: PidRef
    public var process: String
    public var owner: String
    public var reasons: [String]
    public var types: [String]
    public var timeLeft: Double?
    public var canStop: Bool
}

/// Several copies of the same thing left running in the same folder, e.g. five
/// `server/index.js` in games/panel-skirmish, usually from sessions that didn't know one was up.
public struct DuplicateGroup: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var place: String?
    /// Oldest first.
    public var strayIds: [String]
    /// The newest copy, which "keep newest" leaves running.
    public var keepId: String

    public var extraIds: [String] { strayIds.filter { $0 != keepId } }
}

public struct Report: Codable, Sendable {
    /// Orphans and automation browsers: the things nobody is looking at.
    public var hidden: [Stray]
    public var claudeSessions: [ClaudeSession]
    public var sleepBlockers: [SleepBlocker]
    /// VMs, simulators, emulators.
    public var machines: [Stray]
    public var duplicates: [DuplicateGroup]
    public var generatedAt: Date

    public init(hidden: [Stray], claudeSessions: [ClaudeSession], sleepBlockers: [SleepBlocker], machines: [Stray],
                duplicates: [DuplicateGroup] = [], generatedAt: Date) {
        self.hidden = hidden
        self.claudeSessions = claudeSessions
        self.sleepBlockers = sleepBlockers
        self.machines = machines
        self.duplicates = duplicates
        self.generatedAt = generatedAt
    }

    public static let empty = Report(hidden: [], claudeSessions: [], sleepBlockers: [], machines: [], generatedAt: .distantPast)
}
