import Foundation
import IOKit
import IOKit.pwr_mgt

public struct PowerAssertion: Codable, Hashable, Sendable {
    public var type: String
    public var name: String
    public var timeLeft: Double?

    public init(type: String, name: String, timeLeft: Double? = nil) {
        self.type = type
        self.name = name
        self.timeLeft = timeLeft
    }
}

public enum PowerAssertions {
    /// Assertion types that keep the Mac (or its display) awake. "UserIsActive" and the
    /// short-lived system ones are noise.
    public static let sleepPreventing: Set<String> = [
        "PreventUserIdleSystemSleep", "PreventSystemSleep", "PreventUserIdleDisplaySleep",
        "NoIdleSleepAssertion", "NoDisplaySleepAssertion", "DenySystemSleep", "PreventDiskIdle",
    ]

    public static func byProcess() -> [Int32: [PowerAssertion]] {
        var ref: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&ref) == kIOReturnSuccess,
              let dict = ref?.takeRetainedValue() as NSDictionary? else { return [:] }
        var out: [Int32: [PowerAssertion]] = [:]
        for (key, value) in dict {
            guard let pid = (key as? NSNumber)?.int32Value, let list = value as? [[String: Any]] else { continue }
            out[pid] = list.compactMap { a in
                guard let type = a["AssertType"] as? String else { return nil }
                return PowerAssertion(
                    type: type,
                    name: a["AssertName"] as? String ?? "",
                    timeLeft: (a["AssertTimeoutTimeLeft"] as? NSNumber)?.doubleValue
                )
            }
        }
        return out
    }
}

public struct BatteryState: Codable, Hashable, Sendable {
    public var percent: Int
    public var isCharging: Bool
    public var onExternalPower: Bool
    /// Whole-machine draw from the battery; only known while discharging.
    public var drawWatts: Double?
    public var minutesRemaining: Int?
    /// Full-charge energy at today's battery health, roughly mAh × volts.
    public var capacityWh: Double?
}

public enum Battery {
    /// Reads the smart battery's registry entry directly; no root and no `pmset` needed.
    /// Returns nil on Macs without a battery.
    public static func read() -> BatteryState? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = props?.takeRetainedValue() as? [String: Any] else { return nil }

        func int(_ key: String) -> Int64? { (d[key] as? NSNumber)?.int64Value }
        func bool(_ key: String) -> Bool { (d[key] as? NSNumber)?.boolValue ?? false }

        let current = int("CurrentCapacity") ?? 0
        let max = int("MaxCapacity") ?? 100
        let external = bool("ExternalConnected")
        var draw: Double?
        if !external, let amps = int("InstantAmperage") ?? int("Amperage"), amps < 0, let mv = int("Voltage") {
            draw = Double(-amps) * Double(mv) / 1_000_000
        }
        var remaining: Int?
        if !external, let minutes = int("TimeRemaining"), minutes > 0, minutes < 65_535 {
            remaining = Int(minutes)
        }
        var capacity: Double?
        if let mAh = int("AppleRawMaxCapacity") ?? int("NominalChargeCapacity"), let mv = int("Voltage"), mAh > 0 {
            capacity = Double(mAh) * Double(mv) / 1_000_000
        }
        return BatteryState(
            percent: max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : Int(current),
            isCharging: bool("IsCharging"),
            onExternalPower: external,
            drawWatts: draw,
            minutesRemaining: remaining,
            capacityWh: capacity
        )
    }
}

public struct SystemInfo: Codable, Hashable, Sendable {
    public var uptime: TimeInterval
    public var swapUsed: UInt64
    /// `pmset` displaysleep for battery power; 0 means never.
    public var displaySleepOnBattery: Int?
}

public enum SystemProbe {
    public static func read(includePmset: Bool = true) -> SystemInfo {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &boot, &size, nil, 0)
        let bootTime = Double(boot.tv_sec) + Double(boot.tv_usec) / 1e6

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)

        var displaySleep: Int?
        if includePmset, let result = Shell.run("/usr/bin/pmset", ["-g", "custom"]), result.status == 0 {
            displaySleep = parseBatteryDisplaySleep(result.output)
        }
        return SystemInfo(uptime: Date().timeIntervalSince1970 - bootTime, swapUsed: swap.xsu_used, displaySleepOnBattery: displaySleep)
    }

    /// Pulls `displaysleep` out of the "Battery Power:" block of `pmset -g custom`.
    public static func parseBatteryDisplaySleep(_ output: String) -> Int? {
        var inBattery = false
        for line in output.split(separator: "\n") {
            if !line.hasPrefix(" ") {
                inBattery = line.hasPrefix("Battery Power")
                continue
            }
            guard inBattery else { continue }
            let parts = line.split(whereSeparator: \.isWhitespace)
            if parts.first == "displaysleep", parts.count > 1 { return Int(parts[1]) }
        }
        return nil
    }
}

public struct SystemWarning: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var detail: String
    /// A command the user can paste to fix it.
    public var fix: String?
}

public enum SystemWarnings {
    public static func evaluate(_ system: SystemInfo?) -> [SystemWarning] {
        guard let system else { return [] }
        var out: [SystemWarning] = []
        if system.displaySleepOnBattery == 0 {
            out.append(SystemWarning(
                id: "displaysleep",
                title: "Display never sleeps on battery",
                detail: "While the screen is on the Mac can't idle-sleep, so a laptop left open drains to zero.",
                fix: "sudo pmset -b displaysleep 5"
            ))
        }
        if system.uptime > 21 * 86_400 {
            let swap = system.swapUsed > 2 << 30 ? " · \(Fmt.bytes(system.swapUsed)) swap" : ""
            out.append(SystemWarning(
                id: "uptime",
                title: "Up \(Fmt.duration(system.uptime))\(swap)",
                detail: "A restart clears leftover processes and swap.",
                fix: nil
            ))
        }
        return out
    }
}
