import Foundation

/// Turns a raw argv into the short name a person would recognise:
/// `node -r hook.js …/node_modules/ts-node-dev/lib/wrap.js src/index.ts` → `ts-node-dev src/index.ts`.
public enum CommandNamer {
    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "ksh"]
    static let jsRuntimes: Set<String> = ["node", "bun", "deno", "tsx", "ts-node"]
    static let otherRuntimes: Set<String> = ["ruby", "java", "php", "perl"]
    /// Tools whose subcommand is the interesting part (`npm run dev`).
    static let packageManagers: Set<String> = ["npm", "pnpm", "yarn", "bun"]
    /// Tools that just run another package (`uvx mcp-for-blender` → `mcp-for-blender`).
    static let packageRunners: Set<String> = ["npx", "pnpx", "bunx", "uv", "uvx", "pipx"]
    static let runnerFiller: Set<String> = ["tool", "run", "uvx", "x", "exec", "dlx", "--yes", "-y", "--quiet", "-q"]
    /// node/python flags that take a separate value argument.
    static let flagsWithValue: Set<String> = [
        "-r", "--require", "--import", "--loader", "--experimental-loader", "--env-file",
        "--inspect-port", "--title", "-W", "-X",
    ]

    public static func name(args rawArgs: [String], path: String) -> String {
        let args = rawArgs.filter { !$0.isEmpty }
        let exe = basename(path.isEmpty ? (args.first ?? "") : path)
        guard let first = args.first else { return exe }

        // process.title rewrites leave one string with spaces: "npm run dev".
        // Drop the flags: "npm exec vite --host 0.0.0.0 --port 5180" → "npm exec vite".
        if args.count == 1, first.contains(" ") {
            let words = first.split(separator: " ")
            return joined(words.prefix { !$0.hasPrefix("-") }.map(String.init)).nonEmpty ?? clean(first)
        }

        let argv0 = basename(first)
        let tool = [exe, argv0].first { !$0.isEmpty && known($0) } ?? (exe.isEmpty ? argv0 : exe)
        let rest = Array(args.dropFirst())

        if shells.contains(tool), let i = rest.firstIndex(of: "-c"), i + 1 < rest.count {
            let script = rest[i + 1]
            return clean(extractEval(script) ?? script)
        }

        if isPython(tool) {
            if let i = rest.firstIndex(of: "-m"), i + 1 < rest.count {
                return joined([rest[i + 1]] + firstPositional(rest[(i + 2)...]))
            }
            if let i = rest.firstIndex(of: "-c"), i + 1 < rest.count {
                let code = clean(rest[i + 1])
                return "python -c " + (code.count > 48 ? String(code.prefix(47)) + "…" : code)
            }
            if let (script, after) = script(in: rest) { return describe(script: script, following: after) }
            return "python"
        }

        if packageManagers.contains(tool) {
            return joined([tool] + rest.prefix(2))
        }

        if packageRunners.contains(tool) {
            let meaningful = rest.drop { runnerFiller.contains($0) }
            return joined(Array(meaningful.prefix(1))).nonEmpty ?? tool
        }

        if jsRuntimes.contains(tool) || otherRuntimes.contains(tool) {
            if let (script, after) = script(in: rest) { return describe(script: script, following: after) }
            return tool
        }

        return tool
    }

    /// Human name for a background shell Claude started: pulls the command out of
    /// `zsh -c source …snapshot.sh && … eval 'python3 -m http.server 8790' < /dev/null …`.
    public static func extractEval(_ script: String) -> String? {
        guard let open = script.range(of: "eval '") else { return nil }
        var out = ""
        var i = open.upperBound
        while i < script.endIndex {
            let ch = script[i]
            if ch == "'" {
                // Shell-escaped quote inside single quotes: '\''
                if script[script.index(after: i)...].hasPrefix("\\''") {
                    out.append("'")
                    i = script.index(i, offsetBy: 4)
                    continue
                }
                break
            }
            out.append(ch)
            i = script.index(after: i)
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - Helpers

    static func known(_ name: String) -> Bool {
        shells.contains(name) || jsRuntimes.contains(name) || otherRuntimes.contains(name)
            || packageManagers.contains(name) || packageRunners.contains(name) || isPython(name)
    }

    static func isPython(_ name: String) -> Bool {
        name.lowercased().hasPrefix("python")
    }

    /// First positional argument (the script) and everything after it.
    static func script(in rest: [String]) -> (String, [String])? {
        var i = 0
        while i < rest.count {
            let arg = rest[i]
            if arg == "--" { i += 1; continue }
            if arg.hasPrefix("-") {
                i += flagsWithValue.contains(arg) ? 2 : 1
                continue
            }
            return (arg, Array(rest[(i + 1)...]))
        }
        return nil
    }

    static func describe(script: String, following: [String]) -> String {
        let next = following.first.flatMap { $0.hasPrefix("-") ? nil : $0 }
        if let pkg = packageName(inNodeModulesPath: script) {
            if packageManagers.contains(pkg) { return joined([pkg] + following.prefix(2)) }
            if let next, looksLikeFile(next) { return "\(pkg) \(next)" }
            return pkg
        }
        let base = basename(script)
        if packageManagers.contains(base) || packageRunners.contains(base) {
            return joined([base] + following.prefix(2))
        }
        let stem = base.split(separator: ".").first.map(String.init) ?? base
        let parent = basename((script as NSString).deletingLastPathComponent)
        if ["index", "main", "server", "app", "cli"].contains(stem), !parent.isEmpty, parent != "." {
            return clean("\(parent)/\(base)")
        }
        return clean(base)
    }

    static func packageName(inNodeModulesPath path: String) -> String? {
        guard let r = path.range(of: "node_modules/", options: .backwards) else { return nil }
        let parts = path[r.upperBound...].split(separator: "/").map(String.init)
        guard let first = parts.first else { return nil }
        if first == ".bin" { return parts.count > 1 ? parts[1] : nil }
        if first.hasPrefix("@"), parts.count > 1 { return "\(first)/\(parts[1])" }
        return first
    }

    static func looksLikeFile(_ s: String) -> Bool {
        if s.contains("/") { return true }
        guard let dot = s.lastIndex(of: "."), dot != s.startIndex else { return false }
        let ext = s[s.index(after: dot)...]
        return (1...5).contains(ext.count) && ext.allSatisfy(\.isLetter)
    }

    static func firstPositional(_ args: ArraySlice<String>) -> [String] {
        guard let first = args.first, !first.hasPrefix("-") else { return [] }
        return [first]
    }

    static func basename(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    static func joined(_ parts: [String]) -> String {
        clean(parts.joined(separator: " "))
    }

    static func clean(_ s: String) -> String {
        let collapsed = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count > 140 ? String(collapsed.prefix(139)) + "…" : collapsed
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
