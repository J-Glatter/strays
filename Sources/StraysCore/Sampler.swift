import Darwin
import Foundation

public struct Snapshot: Sendable {
    public var processes: [Int32: ProcessRecord]
    /// Children by parent pid, oldest first.
    public var children: [Int32: [Int32]]
    /// Every pid the kernel listed, including ones we couldn't inspect.
    public var alive: Set<Int32>
    public var uid: UInt32
    public var takenAt: Date

    public init(processes: [ProcessRecord], uid: UInt32, alive: Set<Int32>? = nil, takenAt: Date = Date()) {
        var byPid: [Int32: ProcessRecord] = [:]
        var children: [Int32: [Int32]] = [:]
        for p in processes {
            byPid[p.pid] = p
            if p.ppid != p.pid { children[p.ppid, default: []].append(p.pid) }
        }
        for key in children.keys {
            children[key]!.sort { (byPid[$0]?.startMicros ?? 0, $0) < (byPid[$1]?.startMicros ?? 0, $1) }
        }
        self.processes = byPid
        self.children = children
        self.alive = alive ?? Set(byPid.keys)
        self.uid = uid
        self.takenAt = takenAt
    }
}

/// Takes process-table snapshots and turns cumulative CPU/energy counters into rates.
/// Not thread-safe; `Engine` confines it to one queue.
public final class Sampler {
    private struct Previous {
        var start: UInt64
        var cpuNs: UInt64
        var energyNj: UInt64
        var smoothed: Double?
    }

    private struct Meta {
        var start: UInt64
        var path: String
        var args: [String]
        var markers: EnvMarkers
        var launch: Launch?
        var isNew = true
    }

    private var previous: [Int32: Previous] = [:]
    private var meta: [Int32: Meta] = [:]
    private var lastTick: UInt64 = 0
    private var argBuffer = [UInt8](repeating: 0, count: LibProc.argMax)
    private let uid = getuid()
    private let tickNumer: UInt64
    private let tickDenom: UInt64

    /// Seconds over which the "sustained CPU" average settles.
    private let smoothingWindow: Double = 30

    /// Launch records that outlive this process (and the app); nil for a throwaway CLI scan.
    public let provenance: ProvenanceStore
    private let projectLabel: (String) -> String?
    private var claudeProjects: [Int32: String?] = [:]

    public init(provenance: ProvenanceStore = ProvenanceStore(url: nil), projectLabel: @escaping (String) -> String? = { _ in nil }) {
        self.provenance = provenance
        self.projectLabel = projectLabel
        var tb = mach_timebase_info()
        mach_timebase_info(&tb)
        tickNumer = UInt64(tb.numer)
        tickDenom = UInt64(max(tb.denom, 1))
    }

    /// True until the first sample; rates need two samples.
    public var isCold: Bool { lastTick == 0 }

    public func sample() -> Snapshot {
        let now = DispatchTime.now().uptimeNanoseconds
        let dtNs = lastTick == 0 ? 0 : Double(now - lastTick)
        lastTick = now

        let pids = LibProc.allPids()
        var records: [ProcessRecord] = []
        records.reserveCapacity(pids.count)
        var nextPrevious: [Int32: Previous] = [:]
        var nextMeta: [Int32: Meta] = [:]

        for pid in pids {
            guard let bsd = LibProc.bsdInfo(pid) else { continue }
            let start = LibProc.start(of: bsd)
            let comm = LibProc.shortName(bsd)
            var rec = ProcessRecord(
                pid: pid, ppid: Int32(bsd.pbi_ppid), pgid: Int32(bsd.pbi_pgid),
                uid: bsd.pbi_uid, name: comm, comm: comm, startMicros: start
            )

            if bsd.pbi_uid == uid {
                rec.sid = getsid(pid)
                let m = metadata(pid: pid, start: start)
                nextMeta[pid] = m
                rec.path = m.path
                rec.args = m.args
                rec.markers = m.markers
                if let base = m.path.split(separator: "/").last, base.first?.isNumber == false {
                    rec.name = String(base)
                }

                if let u = LibProc.usage(pid) {
                    let cpuNs = u.cpuTicks &* tickNumer / tickDenom
                    rec.cpuTimeNs = cpuNs
                    rec.energyNj = u.energyNj
                    rec.footprint = u.footprint

                    var smoothed: Double?
                    if let prev = previous[pid], prev.start == start, dtNs > 0 {
                        rec.cpuPercent = Double(cpuNs >= prev.cpuNs ? cpuNs - prev.cpuNs : 0) / dtNs * 100
                        // nJ per ns is J/s, i.e. watts.
                        rec.watts = Double(u.energyNj >= prev.energyNj ? u.energyNj - prev.energyNj : 0) / dtNs
                        let alpha = min(1, dtNs / 1e9 / smoothingWindow)
                        smoothed = prev.smoothed.map { $0 + (rec.cpuPercent - $0) * alpha } ?? rec.cpuPercent
                    }
                    rec.cpuSmoothed = smoothed ?? 0
                    nextPrevious[pid] = Previous(start: start, cpuNs: cpuNs, energyNj: u.energyNj, smoothed: smoothed)
                }
            }
            records.append(rec)
        }

        rememberLaunches(&records, &nextMeta)
        previous = nextPrevious
        meta = nextMeta
        claudeProjects = claudeProjects.filter { nextMeta[$0.key] != nil }
        return Snapshot(processes: records, uid: uid, alive: Set(pids))
    }

    /// For processes seen for the first time, record what launched them while the launchers
    /// are still alive. Only dev-ish launches (under a shell, a runtime or Claude) are persisted;
    /// app helpers launched by their app aren't interesting later.
    private func rememberLaunches(_ records: inout [ProcessRecord], _ metas: inout [Int32: Meta]) {
        let byPid = Dictionary(records.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        for i in records.indices {
            let rec = records[i]
            guard var m = metas[rec.pid] else { continue }
            if m.isNew {
                m.isNew = false
                if let stored = provenance[rec.pid, rec.startMicros] {
                    m.launch = stored
                } else if let observed = observeLaunch(of: rec, byPid: byPid) {
                    m.launch = observed.launch
                    if observed.devContext { provenance.record(observed.launch, pid: rec.pid, start: rec.startMicros) }
                }
                metas[rec.pid] = m
            }
            records[i].launch = m.launch
        }
    }

    private func observeLaunch(of rec: ProcessRecord, byPid: [Int32: ProcessRecord]) -> (launch: Launch, devContext: Bool)? {
        var chain: [String] = []
        var claudePid: Int32?
        var devContext = false
        var current = rec.ppid
        var hops = 0
        while current > 1, hops < 12, let parent = byPid[current] {
            if Classifier.isClaude(parent) {
                let project = claudeProject(parent.pid)
                chain.append("Claude Code" + (project.map { " (\($0))" } ?? ""))
                claudePid = parent.pid
                devContext = true
                break
            }
            let step = parent.args.isEmpty ? parent.name : CommandNamer.name(args: parent.args, path: parent.path)
            chain.append(step)
            if CommandNamer.known(parent.name) || CommandNamer.known(CommandNamer.basename(parent.path)) { devContext = true }
            current = parent.ppid
            hops += 1
        }
        guard !chain.isEmpty else { return nil }
        let launch = Launch(
            chain: chain, claudePid: claudePid, claudeProject: claudePid.flatMap { claudeProject($0) },
            sessionId: rec.markers.claudeSessionId
        )
        return (launch, devContext)
    }

    private func claudeProject(_ pid: Int32) -> String? {
        if let cached = claudeProjects[pid] { return cached }
        let label = LibProc.cwd(pid).flatMap(projectLabel)
        claudeProjects[pid] = label
        return label
    }

    private func metadata(pid: Int32, start: UInt64) -> Meta {
        if let m = meta[pid], m.start == start { return m }
        let args = LibProc.procArgs(pid, buffer: &argBuffer)
        return Meta(
            start: start,
            path: LibProc.path(pid),
            args: args?.argv ?? [],
            markers: EnvMarkers(env: args?.env ?? [])
        )
    }
}
