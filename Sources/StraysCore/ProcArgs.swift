import Foundation

/// Parsed `KERN_PROCARGS2` buffer: argc, exec path, argv, then the environment.
///
/// Layout: `[argc: Int32][exec_path\0][\0 padding][argv[0]\0 … argv[argc-1]\0][env\0 …]`.
/// Processes that rewrite their title (npm, node's `process.title`) overwrite this area,
/// so argv can collapse to a single string and env can come back empty.
public struct ProcArgs: Hashable, Sendable {
    public var execPath: String
    public var argv: [String]
    public var env: [String]

    public static func parse(_ bytes: [UInt8]) -> ProcArgs? {
        bytes.withUnsafeBytes { parse($0) }
    }

    public static func parse(_ buf: UnsafeRawBufferPointer) -> ProcArgs? {
        guard buf.count >= MemoryLayout<Int32>.size else { return nil }
        let argc = Int(buf.loadUnaligned(as: Int32.self))
        guard argc >= 0, argc < 65_536 else { return nil }
        var i = MemoryLayout<Int32>.size

        func cString() -> String {
            let start = i
            while i < buf.count, buf[i] != 0 { i += 1 }
            let s = String(decoding: UnsafeRawBufferPointer(rebasing: buf[start..<i]), as: UTF8.self)
            if i < buf.count { i += 1 }
            return s
        }

        let exec = cString()
        while i < buf.count, buf[i] == 0 { i += 1 }

        var argv: [String] = []
        argv.reserveCapacity(argc)
        for _ in 0..<argc where i < buf.count {
            argv.append(cString())
        }

        var env: [String] = []
        while i < buf.count, buf[i] != 0 {
            env.append(cString())
        }
        return ProcArgs(execPath: exec, argv: argv, env: env)
    }
}
