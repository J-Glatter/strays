import Foundation

public struct SimulatorInfo: Codable, Hashable, Sendable {
    public var name: String
    public var runtime: String?
}

/// The filesystem- and socket-touching lookups the classifier needs, behind a protocol
/// so tests can feed a synthetic process table.
public protocol ProcessInspector: AnyObject {
    func cwd(_ pid: Int32) -> String?
    func listeningPorts(_ pid: Int32) -> [ListeningPort]
    func projectLabel(forDirectory dir: String) -> String?
    func simulatorInfo(udid: String) -> SimulatorInfo?
}

public final class LiveInspector: ProcessInspector {
    private let home = NSHomeDirectory()
    private var gitRoots: [String: String?] = [:]
    private var simulators: [String: SimulatorInfo?] = [:]
    private var ports: [Int32: (at: UInt64, ports: [ListeningPort])] = [:]
    /// Socket enumeration walks every fd of a process (hundreds for Docker), and listeners rarely change.
    private let portsTTL: UInt64 = 10_000_000_000

    public init() {}

    public func cwd(_ pid: Int32) -> String? { LibProc.cwd(pid) }

    public func listeningPorts(_ pid: Int32) -> [ListeningPort] {
        let now = DispatchTime.now().uptimeNanoseconds
        if let cached = ports[pid], now - cached.at < portsTTL { return cached.ports }
        let fresh = LibProc.listeningPorts(pid)
        if ports.count > 2_000 { ports.removeAll() }
        ports[pid] = (now, fresh)
        return fresh
    }

    public func projectLabel(forDirectory dir: String) -> String? {
        ProjectLabel.make(directory: dir, projectRoot: gitRoot(of: dir), home: home)
    }

    public func simulatorInfo(udid: String) -> SimulatorInfo? {
        if let cached = simulators[udid] { return cached }
        let plist = "\(home)/Library/Developer/CoreSimulator/Devices/\(udid)/device.plist"
        var info: SimulatorInfo?
        if let data = FileManager.default.contents(atPath: plist),
           let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let name = dict["name"] as? String {
            info = SimulatorInfo(name: name, runtime: (dict["runtime"] as? String).map(Self.prettyRuntime))
        }
        simulators[udid] = info
        return info
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-26-2` → `iOS 26.2`
    static func prettyRuntime(_ id: String) -> String {
        guard let last = id.split(separator: ".").last else { return id }
        let parts = last.split(separator: "-")
        guard let os = parts.first else { return id }
        return parts.count > 1 ? "\(os) \(parts.dropFirst().joined(separator: "."))" : String(os)
    }

    private func gitRoot(of dir: String) -> String? {
        if let cached = gitRoots[dir] { return cached }
        var current = dir
        var found: String?
        let fm = FileManager.default
        while current.count > 1, current != home {
            if fm.fileExists(atPath: current + "/.git") { found = current; break }
            current = (current as NSString).deletingLastPathComponent
        }
        gitRoots[dir] = found
        return found
    }
}

public enum ProjectLabel {
    static let devFolders = ["Development", "Developer", "dev", "code", "Code", "src", "Projects", "projects", "repos", "workspace", "git"]

    /// `~/Development/games/gambit` → `games/gambit`; a subfolder of a repo gets ` › sub`.
    public static func make(directory: String, projectRoot: String?, home: String) -> String? {
        guard directory != "/", !directory.isEmpty else { return nil }
        var label = shorten(projectRoot ?? directory, home: home)
        if let root = projectRoot, directory.hasPrefix(root + "/") {
            let sub = directory.dropFirst(root.count + 1).split(separator: "/")
            label += " › " + sub.suffix(2).joined(separator: "/")
        }
        return label
    }

    static func shorten(_ path: String, home: String) -> String {
        if path == home { return "~" }
        guard path.hasPrefix(home + "/") else { return path }
        let rel = String(path.dropFirst(home.count + 1))
        for folder in devFolders where rel.hasPrefix(folder + "/") {
            return String(rel.dropFirst(folder.count + 1))
        }
        return "~/" + rel
    }
}
