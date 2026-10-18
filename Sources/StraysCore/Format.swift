import Foundation

public enum Fmt {
    /// `20d 3h`, `4h 12m`, `35m`, `40s`
    public static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        let d = s / 86_400, h = (s % 86_400) / 3_600, m = (s % 3_600) / 60
        if d > 0 { return h > 0 && d < 10 ? "\(d)d \(h)h" : "\(d)d" }
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        if m > 0 { return "\(m)m" }
        return "\(s)s"
    }

    public static func bytes(_ b: UInt64) -> String {
        let v = Double(b), gb = 1_073_741_824.0, mb = 1_048_576.0
        if v >= gb { return String(format: "%.1f GB", v / gb) }
        if v >= mb { return String(format: "%.0f MB", v / mb) }
        return String(format: "%.0f KB", v / 1024)
    }

    public static func watts(_ w: Double) -> String {
        if w < 0.05 { return "<0.1 W" }
        return w < 10 ? String(format: "%.1f W", w) : String(format: "%.0f W", w)
    }

    /// 100% = one full core, like Activity Monitor and top.
    public static func cpu(_ percent: Double) -> String {
        if percent < 0.5 { return "0%" }
        return percent < 10 ? String(format: "%.1f%%", percent) : String(format: "%.0f%%", percent)
    }

    /// Panel variant: whole percents (and "<1%") so idle jitter like 0.6% ↔ 1.2% doesn't
    /// redraw a row every refresh.
    public static func cpuCoarse(_ percent: Double) -> String {
        if percent < 0.05 { return "0%" }
        if percent < 1 { return "<1%" }
        return String(format: "%.0f%%", percent)
    }

    public static func cpuTime(_ seconds: Double) -> String {
        if seconds >= 3_600 { return String(format: "%.0f CPU-hours", seconds / 3_600) }
        if seconds >= 60 { return String(format: "%.0f CPU-min", seconds / 60) }
        return String(format: "%.0f CPU-s", seconds)
    }

    public static func energy(_ wh: Double) -> String {
        if wh >= 1_000 { return String(format: "%.1f kWh", wh / 1_000) }
        if wh >= 10 { return String(format: "%.0f Wh", wh) }
        return String(format: "%.1f Wh", wh)
    }

    public static func minutes(_ m: Int) -> String {
        m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }

    public static func batteryLine(_ b: BatteryState) -> String {
        var parts = ["\(b.percent)%"]
        if b.onExternalPower {
            parts.append(b.isCharging ? "charging" : "on power")
        } else {
            parts.append("on battery")
            // Whole watts: battery draw jitters by tenths every few seconds.
            if let w = b.drawWatts { parts.append(String(format: "drawing %.0f W", w)) }
            if let m = b.minutesRemaining { parts.append("~\(minutes(m)) left") }
        }
        return parts.joined(separator: " · ")
    }
}
