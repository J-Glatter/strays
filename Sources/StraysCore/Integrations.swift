import Foundation

public enum Shell {
    public struct Result: Sendable {
        public var status: Int32
        public var output: String
    }

    private final class Collector: @unchecked Sendable {
        var data = Data()
    }

    /// Runs a tool with a hard timeout. Returns nil if it can't start or times out.
    @discardableResult
    public static func run(_ executable: String, _ args: [String], timeout: TimeInterval = 5) -> Result? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        let collector = Collector()
        let done = DispatchGroup()
        done.enter()
        DispatchQueue.global(qos: .utility).async {
            collector.data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.leave()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        process.waitUntilExit()
        return Result(status: process.terminationStatus, output: String(decoding: collector.data, as: UTF8.self))
    }
}

public struct DevToolsPage: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var url: String
}

public enum DevTools {
    /// Lists the pages an automation browser has open, via its DevTools HTTP endpoint.
    public static func pages(port: UInt16) async -> [DevToolsPage] {
        guard let url = URL(string: "http://127.0.0.1:\(port)/json/list") else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return [] }
        struct Target: Decodable {
            let id: String
            let type: String
            let title: String
            let url: String
        }
        let targets = (try? JSONDecoder().decode([Target].self, from: data)) ?? []
        return targets
            .filter { $0.type == "page" && $0.url != "about:blank" }
            .map { DevToolsPage(id: $0.id, title: $0.title, url: $0.url) }
    }
}

public struct DockerContainer: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var image: String
    public var status: String
    public var ports: String
    /// From `docker stats`, e.g. "0.31%" and "45MiB / 7.6GiB".
    public var cpu: String?
    public var memory: String?
}

public enum Docker {
    static var binary: String? {
        [
            "/usr/local/bin/docker", "/opt/homebrew/bin/docker",
            NSHomeDirectory() + "/.docker/bin/docker",
            "/Applications/Docker.app/Contents/Resources/bin/docker",
        ].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static func containers() -> [DockerContainer]? {
        guard let docker = binary,
              let result = Shell.run(docker, ["ps", "--format", "{{json .}}"], timeout: 6),
              result.status == 0 else { return nil }
        struct Row: Decodable {
            let ID: String
            let Names: String
            let Image: String
            let Status: String
            let Ports: String?
        }
        return result.output.split(separator: "\n").compactMap { line in
            guard let row = try? JSONDecoder().decode(Row.self, from: Data(line.utf8)) else { return nil }
            return DockerContainer(id: row.ID, name: row.Names, image: row.Image, status: row.Status, ports: row.Ports ?? "")
        }
    }

    /// Containers with their current CPU and memory. `docker stats --no-stream` takes a second
    /// or two, so this only runs while the panel is open.
    public static func containersWithStats() -> [DockerContainer]? {
        guard var list = containers(), !list.isEmpty, let docker = binary,
              let result = Shell.run(docker, ["stats", "--no-stream", "--format", "{{json .}}"], timeout: 10),
              result.status == 0 else { return containers() }
        struct Stat: Decodable {
            let ID: String
            let CPUPerc: String
            let MemUsage: String
        }
        var byID: [String: Stat] = [:]
        for line in result.output.split(separator: "\n") {
            if let stat = try? JSONDecoder().decode(Stat.self, from: Data(line.utf8)) { byID[stat.ID] = stat }
        }
        for i in list.indices {
            let stat = byID[list[i].id] ?? byID.first { list[i].id.hasPrefix($0.key) || $0.key.hasPrefix(list[i].id) }?.value
            list[i].cpu = stat?.CPUPerc
            list[i].memory = stat?.MemUsage.split(separator: "/").first.map { $0.trimmingCharacters(in: .whitespaces) }
        }
        return list
    }

    public static func stop(containerID: String) {
        guard let docker = binary else { return }
        Shell.run(docker, ["stop", containerID], timeout: 30)
    }

    /// Docker Desktop is two apps: the engine (`Docker.app`, com.docker.docker) and a separate
    /// window app nested inside it (com.electron.dockerdesktop). Quitting "Docker" by name only
    /// stops the engine and leaves the window app running, so use Docker's own CLI, then let the
    /// caller stop whatever is still alive. Returns whether the CLI reported success.
    @discardableResult
    public static func quitDesktop() -> Bool {
        if let docker = binary, let result = Shell.run(docker, ["desktop", "stop"], timeout: 90), result.status == 0 {
            return true
        }
        // Older Docker Desktop without `docker desktop`: ask both apps to quit.
        for id in ["com.docker.docker", "com.electron.dockerdesktop"] {
            Shell.run("/usr/bin/osascript", ["-e", "quit app id \"\(id)\""], timeout: 10)
        }
        return false
    }
}

public enum Simulators {
    public static func shutdown(udid: String) {
        Shell.run("/usr/bin/xcrun", ["simctl", "shutdown", udid], timeout: 60)
    }
}
