import Darwin
import Foundation

/// Thin wrappers over libproc and sysctl. Everything here is a direct kernel call,
/// with no subprocesses, so a full scan of ~900 processes takes a few milliseconds.
enum LibProc {
    static let argMax: Int = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        return sysctl(&mib, 2, &value, &size, nil, 0) == 0 ? Int(value) : 1 << 20
    }()

    static func allPids() -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 128)
        let got = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard got > 0 else { return [] }
        return pids.prefix(Int(got)).filter { $0 > 0 }
    }

    static func bsdInfo(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    /// Start time of a live (non-zombie) process, or nil if it's gone.
    static func startMicros(_ pid: Int32) -> UInt64? {
        guard let info = bsdInfo(pid), info.pbi_status != UInt32(SZOMB) else { return nil }
        return start(of: info)
    }

    static func start(of info: proc_bsdinfo) -> UInt64 {
        UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec)
    }

    static func shortName(_ info: proc_bsdinfo) -> String {
        let name = string(fromTuple: info.pbi_name)
        return name.isEmpty ? string(fromTuple: info.pbi_comm) : name
    }

    static func path(_ pid: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : ""
    }

    struct Usage {
        var cpuTicks: UInt64
        var energyNj: UInt64
        var footprint: UInt64
    }

    static func usage(_ pid: Int32) -> Usage? {
        var v6 = rusage_info_v6()
        let ok6 = withUnsafeMutablePointer(to: &v6) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
        }
        if ok6 == 0 {
            return Usage(cpuTicks: v6.ri_user_time + v6.ri_system_time, energyNj: v6.ri_energy_nj, footprint: v6.ri_phys_footprint)
        }
        // macOS 13 has no v6 (and so no energy figure); v4 still gives CPU and memory.
        var v4 = rusage_info_v4()
        let ok4 = withUnsafeMutablePointer(to: &v4) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard ok4 == 0 else { return nil }
        return Usage(cpuTicks: v4.ri_user_time + v4.ri_system_time, energyNj: 0, footprint: v4.ri_phys_footprint)
    }

    static func procArgs(_ pid: Int32, buffer: inout [UInt8]) -> ProcArgs? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = buffer.count
        let rc = buffer.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) }
        guard rc == 0, size > 0 else { return nil }
        return buffer.withUnsafeBytes { ProcArgs.parse(UnsafeRawBufferPointer(rebasing: $0[0..<size])) }
    }

    static func cwd(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = string(fromTuple: info.pvi_cdir.vip_path)
        return path.isEmpty ? nil : path
    }

    static func listeningPorts(_ pid: Int32) -> [ListeningPort] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 16)
        let got = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard got > 0 else { return [] }

        var ports: [UInt16: Bool] = [:]
        for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  Int(info.psi.soi_kind) == Int(SOCKINFO_TCP) else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let ini = tcp.tcpsi_ini
            let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport))
            let exposed: Bool
            if ini.insi_vflag & UInt8(INI_IPV4) != 0 {
                exposed = ini.insi_laddr.ina_46.i46a_addr4.s_addr == 0
            } else {
                exposed = withUnsafeBytes(of: ini.insi_laddr.ina_6) { $0.allSatisfy { $0 == 0 } }
            }
            ports[port] = (ports[port] ?? false) || exposed
        }
        return ports.map { ListeningPort(port: $0.key, exposed: $0.value) }.sorted { $0.port < $1.port }
    }

    static func string<T>(fromTuple tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
