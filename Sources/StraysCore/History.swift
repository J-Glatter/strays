import Foundation

/// A point-in-time battery reading recorded by the app every few minutes.
public struct HistorySample: Codable, Hashable, Sendable {
    public struct Top: Codable, Hashable, Sendable {
        public var title: String
        public var watts: Double

        public init(title: String, watts: Double) {
            self.title = title
            self.watts = watts
        }
    }

    public var at: Date
    public var percent: Int
    public var onAC: Bool
    /// Whole-machine draw from the battery, when discharging.
    public var drawWatts: Double?
    /// Hidden processes + VMs at that moment.
    public var strayWatts: Double
    public var top: [Top]

    public init(at: Date, percent: Int, onAC: Bool, drawWatts: Double?, strayWatts: Double, top: [Top]) {
        self.at = at
        self.percent = percent
        self.onAC = onAC
        self.drawWatts = drawWatts
        self.strayWatts = strayWatts
        self.top = top
    }
}

public enum HistoryStore {
    static let keep: TimeInterval = 14 * 86_400

    public static func append(_ sample: HistorySample, to url: URL = StraysPaths.history) {
        guard var line = try? ProvenanceStore.encoder.encode(sample) else { return }
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url)
        }
    }

    public static func load(since: Date, from url: URL = StraysPaths.history) -> [HistorySample] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A)
            .compactMap { try? ProvenanceStore.decoder.decode(HistorySample.self, from: Data($0)) }
            .filter { $0.at >= since }
    }

    /// Drops samples older than two weeks once the file gets big.
    public static func prune(_ url: URL = StraysPaths.history) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attrs[.size] as? Int ?? 0) > 1_500_000 else { return }
        let kept = load(since: Date().addingTimeInterval(-keep), from: url)
        let data = kept.compactMap { try? ProvenanceStore.encoder.encode($0) }
            .reduce(into: Data()) { $0.append($1); $0.append(0x0A) }
        try? data.write(to: url, options: .atomic)
    }
}

/// Reads macOS's own power log (`pmset -g log`): charge readings every few minutes plus
/// "Low Power Sleep" events, which is the Mac shutting down on an empty battery.
public enum PowerLog {
    public struct Point: Codable, Hashable, Sendable {
        public var at: Date
        public var percent: Int
        public var onAC: Bool
    }

    public struct Death: Codable, Hashable, Sendable {
        public var at: Date
        /// When it was last unplugged before dying, and the charge then.
        public var unpluggedAt: Date?
        public var startPercent: Int?

        public init(at: Date, unpluggedAt: Date? = nil, startPercent: Int? = nil) {
            self.at = at
            self.unpluggedAt = unpluggedAt
            self.startPercent = startPercent
        }

        public var drainPerHour: Double? {
            guard let start = unpluggedAt, let pct = startPercent else { return nil }
            let hours = at.timeIntervalSince(start) / 3_600
            return hours > 0.1 ? Double(pct - 1) / hours : nil
        }
    }

    /// One stretch of sleep: from going to sleep to the next wake with the display on.
    public struct SleepSession: Codable, Hashable, Sendable {
        public var start: Date
        public var end: Date
        public var startPercent: Int?
        public var endPercent: Int?
        /// Brief background wake-ups (network upkeep, scheduled tasks) during it.
        public var darkWakes: Int

        public var used: Int? {
            guard let a = startPercent, let b = endPercent, a >= b else { return nil }
            return a - b
        }
    }

    public struct Summary: Codable, Hashable, Sendable {
        public var points: [Point]
        public var deaths: [Death]
        public var sleeps: [SleepSession] = []
        public var readAt: Date
    }

    public static func read() -> Summary? {
        // ~7 MB and ~2 s of CPU, so callers run this rarely and off the main thread.
        guard let result = Shell.run("/usr/bin/pmset", ["-g", "log"], timeout: 30), result.status == 0 else { return nil }
        return parse(result.output)
    }

    public static func parse(_ log: String, now: Date = Date()) -> Summary {
        var points: [Point] = []
        var deathTimes: [Date] = []
        var sleeps: [SleepSession] = []
        var asleep: (start: Date, percent: Int?, dark: Int)?
        for line in log.split(separator: "\n", omittingEmptySubsequences: true) {
            // Cheap checks first: date parsing is the slow part and most lines don't need it.
            let reading = reading(in: line)
            let isDeath = line.contains("'Low Power Sleep'")
            let event = sleepEvent(line)
            guard reading != nil || isDeath || event != nil, line.first?.isNumber == true, line.count > 25,
                  let date = timestamp.date(from: String(line.prefix(25))) else { continue }
            if let reading { points.append(Point(at: date, percent: reading.percent, onAC: reading.onAC)) }
            if isDeath { deathTimes.append(date) }
            switch event {
            case .sleep?: if asleep == nil { asleep = (date, reading?.percent, 0) }
            case .darkWake?: asleep?.dark += 1
            case .fullWake?:
                if let a = asleep {
                    sleeps.append(SleepSession(start: a.start, end: date, startPercent: a.percent, endPercent: reading?.percent, darkWakes: a.dark))
                }
                asleep = nil
            case nil: break
            }
        }

        let deaths = deathTimes.map { death -> Death in
            // Walk back from the death to the last reading on AC; the one after it is the unplug.
            let before = points.filter { $0.at <= death }
            // No unplug in the log (it only goes back about a week): say nothing rather than guess.
            guard let lastAC = before.lastIndex(where: \.onAC) else { return Death(at: death) }
            let unplug = before.indices.contains(lastAC + 1) ? before[lastAC + 1] : nil
            return Death(at: death, unpluggedAt: unplug?.at, startPercent: unplug?.percent)
        }

        // Keep two days of readings at most one per 5 minutes; that's plenty for a sparkline.
        let cutoff = now.addingTimeInterval(-48 * 3_600)
        var thinned: [Point] = []
        for p in points where p.at >= cutoff {
            if let last = thinned.last, p.at.timeIntervalSince(last.at) < 300, p.onAC == last.onAC { continue }
            thinned.append(p)
        }
        let recentSleeps = sleeps.filter { $0.end >= now.addingTimeInterval(-48 * 3_600) }
        return Summary(points: thinned, deaths: deaths, sleeps: recentSleeps, readAt: now)
    }

    enum SleepEvent { case sleep, darkWake, fullWake }

    /// The event kind sits right after the 25-character timestamp. A full wake turns the
    /// display on ("V" in flags like [CDNVA]); dark wakes have their own kind.
    static func sleepEvent(_ line: Substring) -> SleepEvent? {
        guard line.count > 30 else { return nil }
        let rest = line.dropFirst(26)
        if rest.hasPrefix("Sleep ") { return rest.contains("Entering Sleep state") ? .sleep : nil }
        if rest.hasPrefix("DarkWake ") { return .darkWake }
        if rest.hasPrefix("Wake "), rest.contains("Wake from"),
           let open = rest.firstIndex(of: "["), let close = rest[open...].firstIndex(of: "]"),
           rest[open..<close].contains("V") {
            return .fullWake
        }
        return nil
    }

    /// "Using BATT (Charge:49%)", "Using Batt(Charge: 49)", "Using AC (Charge:100%)"
    static func reading(in line: Substring) -> (percent: Int, onAC: Bool)? {
        guard let using = line.range(of: "Using ") else { return nil }
        let rest = line[using.upperBound...]
        let onAC = rest.hasPrefix("AC")
        guard onAC || rest.hasPrefix("BATT") || rest.hasPrefix("Batt"),
              let charge = rest.range(of: "Charge:") else { return nil }
        let digits = rest[charge.upperBound...].drop { $0 == " " }.prefix { $0.isNumber }
        guard let pct = Int(digits) else { return nil }
        return (pct, onAC)
    }

    static let timestamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return f
    }()
}

/// What the battery section says, combining the power log with Strays' own samples.
public struct BatteryStory: Sendable, Equatable {
    public var points: [PowerLog.Point]
    public var deaths: [PowerLog.Death]
    public var lastDeathLine: String?
    public var lastDeathDetail: String?
    public var deathsThisWeek: Int
    /// The most recent sleep of an hour or more in the last day.
    public var lastSleep: PowerLog.SleepSession?

    public init(log: PowerLog.Summary?, samples: [HistorySample], now: Date = Date()) {
        lastSleep = log?.sleeps.last { $0.end.timeIntervalSince($0.start) >= 3_600 && $0.end >= now.addingTimeInterval(-24 * 3_600) }
        var points = log?.points ?? []
        points += samples.map { PowerLog.Point(at: $0.at, percent: $0.percent, onAC: $0.onAC) }
        let dayAgo = now.addingTimeInterval(-24 * 3_600)
        self.points = points.filter { $0.at >= dayAgo }.sorted { $0.at < $1.at }

        let week = now.addingTimeInterval(-7 * 86_400)
        deaths = (log?.deaths ?? []).filter { $0.at >= week }
        deathsThisWeek = deaths.count

        guard let last = deaths.last else { return }
        var line = "Last ran flat \(Self.when(last.at, now: now))"
        if let start = last.unpluggedAt, let pct = last.startPercent {
            line += ": \(pct)% → 1% in \(Fmt.duration(last.at.timeIntervalSince(start)))"
        }
        lastDeathLine = line

        // If Strays was recording during that discharge, say what the hidden stuff cost.
        if let start = last.unpluggedAt {
            let during = samples.filter { $0.at >= start && $0.at <= last.at && !$0.onAC }
            let draws = during.compactMap(\.drawWatts)
            if !draws.isEmpty {
                let avgDraw = draws.reduce(0, +) / Double(draws.count)
                let avgStray = during.map(\.strayWatts).reduce(0, +) / Double(during.count)
                lastDeathDetail = "Averaged \(Fmt.watts(avgDraw)); hidden processes were \(Fmt.watts(avgStray)) of that"
            }
        }
    }

    public static func when(_ date: Date, now: Date) -> String {
        let cal = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if cal.isDate(date, inSameDayAs: now) { return "today \(time)" }
        if let yesterday = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date, inSameDayAs: yesterday) {
            return "yesterday \(time)"
        }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}
