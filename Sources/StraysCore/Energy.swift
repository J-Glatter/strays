import Foundation

/// Energy used per app since the charger came out, from the kernel's per-process energy
/// counters. Covers your own processes (apps, Claude, dev tools); the display, the GPU
/// compositor (WindowServer) and macOS itself can't be measured per process.
public struct EnergyLedger: Codable, Sendable, Equatable {
    public var since: Date
    public var startPercent: Int?
    /// True when `since` is the moment the charger came out (not just when Strays started measuring).
    public var fromUnplug = false
    public var savedAt: Date
    /// Group name → watt-hours.
    public var wh: [String: Double]
    /// "pid:start" → energy counter (nJ) at the last update.
    var last: [String: UInt64]

    public init(since: Date, startPercent: Int?) {
        self.since = since
        self.startPercent = startPercent
        savedAt = since
        wh = [:]
        last = [:]
    }

    public static let hiddenGroup = "Hidden & orphaned"
    public static let claudeGroup = "Claude Code"

    public mutating func update(snapshot: Snapshot, report: Report, now: Date = Date()) {
        let groups = Self.groups(report)
        var next: [String: UInt64] = [:]
        next.reserveCapacity(last.count)
        for p in snapshot.processes.values where p.uid == snapshot.uid && p.energyNj > 0 {
            let key = ProvenanceStore.key(pid: p.pid, start: p.startMicros)
            next[key] = p.energyNj
            let delta: UInt64
            if let prev = last[key] {
                delta = p.energyNj >= prev ? p.energyNj - prev : 0
            } else if p.startDate >= since {
                delta = p.energyNj // started during this period: all of it counts
            } else {
                continue // first sight of an older process: this is the baseline
            }
            guard delta > 0 else { continue }
            wh[groups[p.pid] ?? Self.appName(p), default: 0] += Double(delta) / 3.6e12
        }
        last = next
        savedAt = now
    }

    public var total: Double { wh.values.reduce(0, +) }

    public func top(_ n: Int) -> [(name: String, wh: Double)] {
        wh.sorted { $0.value > $1.value }.prefix(n).map { (name: $0.key, wh: $0.value) }
    }

    /// Hidden strays, Claude sessions and VMs are grouped by what Strays calls them; everything
    /// else by its app bundle (helpers count towards their app) or executable name.
    static func groups(_ r: Report) -> [Int32: String] {
        var out: [Int32: String] = [:]
        for s in r.hidden { for m in s.members { out[m.pid] = hiddenGroup } }
        for session in r.claudeSessions {
            for m in session.members { out[m.pid] = claudeGroup }
            out[session.ref.pid] = claudeGroup
        }
        for s in r.machines { for m in s.members { out[m.pid] = s.title } }
        return out
    }

    /// "/Applications/Google Chrome.app/…/Google Chrome Helper.app/…" → "Google Chrome"
    public static func appName(_ p: ProcessRecord) -> String {
        if Classifier.isClaude(p) { return claudeGroup }
        if let bundle = p.path.split(separator: "/").first(where: { $0.hasSuffix(".app") }) {
            return String(bundle.dropLast(4))
        }
        return p.name
    }

    // MARK: Persistence (the app restarts; the discharge it was measuring doesn't)

    public static func load(_ url: URL = StraysPaths.support.appendingPathComponent("energy.json")) -> EnergyLedger? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? ProvenanceStore.decoder.decode(EnergyLedger.self, from: data)
    }

    public func save(_ url: URL = StraysPaths.support.appendingPathComponent("energy.json")) {
        if let data = try? ProvenanceStore.encoder.encode(self) { try? data.write(to: url, options: .atomic) }
    }
}

/// Opt-in: stop things Claude sessions left behind once they're old and idle.
public enum AutoCleanup {
    /// Only orphans and hidden browsers from Claude sessions that have ended, that are idle
    /// now and older than `olderThan`. Never anything ignored.
    public static func eligible(_ hidden: [Stray], ignored: Set<String>, olderThan: TimeInterval, now: Date = Date()) -> [Stray] {
        hidden.filter { s in
            guard !ignored.contains(s.signature), s.kind == .orphan || s.kind == .headlessBrowser,
                  case .claude(nil, _) = s.origin else { return false }
            return now.timeIntervalSince(s.started) >= olderThan && s.cpuSmoothed < 1
        }
    }
}
