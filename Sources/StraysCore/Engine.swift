import Foundation

public struct ScanResult: Sendable {
    public var report: Report
    public var battery: BatteryState?
    public var snapshot: Snapshot?

    public init(report: Report, battery: BatteryState?, snapshot: Snapshot? = nil) {
        self.report = report
        self.battery = battery
        self.snapshot = snapshot
    }
}

/// A process listening on a TCP port, for `strays --port`.
public struct Listener: Sendable {
    public var process: ProcessRecord
    public var port: ListeningPort
    public var cwd: String?
    public var project: String?
}

/// Owns the sampler and inspector and confines them to one serial queue,
/// so the UI and the CLI can both scan without sharing mutable state.
public final class Engine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "strays.engine", qos: .utility)
    private let sampler: Sampler
    private let inspector: LiveInspector
    private let persists: Bool
    private var lastSnapshot: Snapshot?

    /// `persistProvenance`: the menu bar app records launch chains to disk; CLI runs only read them.
    public init(persistProvenance: Bool = false) {
        persists = persistProvenance
        let inspector = LiveInspector()
        let store = ProvenanceStore(url: StraysPaths.provenance)
        store.mergeLedger()
        self.inspector = inspector
        sampler = Sampler(provenance: store, projectLabel: { inspector.projectLabel(forDirectory: $0) })
    }

    public func scan() async -> ScanResult {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.scanOnQueue(warm: true)) }
        }
    }

    /// `warm: false` skips the one-second baseline (CPU rates read as zero) for quick one-shot uses.
    public func scanSync(warm: Bool = true) -> ScanResult {
        queue.sync { scanOnQueue(warm: warm) }
    }

    /// Picks up SessionEnd hook records written since the last call.
    public func mergeSessionLedger() {
        queue.async { self.sampler.provenance.mergeLedger() }
    }

    public func flush() {
        queue.sync { self.save(force: true) }
    }

    /// Every one of your processes listening on `port`, from the last scan.
    public func listeners(port: UInt16) -> [Listener] {
        queue.sync {
            let snap = lastSnapshot ?? sampler.sample()
            return snap.processes.values
                .filter { $0.uid == snap.uid }
                .sorted { $0.pid < $1.pid }
                .compactMap { p -> Listener? in
                    guard let lp = LibProc.listeningPorts(p.pid).first(where: { $0.port == port }) else { return nil }
                    let cwd = inspector.cwd(p.pid)
                    return Listener(process: p, port: lp, cwd: cwd, project: cwd.flatMap(inspector.projectLabel))
                }
        }
    }

    private func scanOnQueue(warm: Bool) -> ScanResult {
        if warm, sampler.isCold {
            // Rates need two samples; take a short baseline first.
            _ = sampler.sample()
            Thread.sleep(forTimeInterval: 1)
        }
        let snapshot = sampler.sample()
        lastSnapshot = snapshot
        let report = Classifier.classify(snapshot, inspector: inspector, assertions: PowerAssertions.byProcess())
        save(force: false)
        return ScanResult(report: report, battery: Battery.read(), snapshot: snapshot)
    }

    private func save(force: Bool) {
        guard persists, let snap = lastSnapshot else { return }
        let alive = Set(snap.processes.values.map { ProvenanceStore.key(pid: $0.pid, start: $0.startMicros) })
        sampler.provenance.saveIfNeeded(alive: alive, force: force)
    }
}
