import Darwin
import Foundation

public enum Stopper {
    /// SIGTERM the whole group, then SIGKILL whatever is still alive after `grace`.
    /// A process stuck in a synchronous loop never runs its SIGTERM handler, so the
    /// follow-up kill is what actually stops it. Start times guard against pid reuse.
    /// Returns whatever is still alive at the end.
    @discardableResult
    public static func stop(_ members: [PidRef], force: Bool = false, grace: TimeInterval = 3) -> [PidRef] {
        let targets = alive(members)
        guard !targets.isEmpty else { return [] }

        for m in targets { kill(m.pid, force ? SIGKILL : SIGTERM) }
        if !force, waitForExit(targets, timeout: grace).isEmpty { return [] }

        let survivors = alive(targets)
        for m in survivors { kill(m.pid, SIGKILL) }
        return waitForExit(survivors, timeout: 1)
    }

    /// Members still running (zombies count as gone).
    public static func alive(_ members: [PidRef]) -> [PidRef] {
        members.filter { LibProc.startMicros($0.pid) == $0.start }
    }

    private static func waitForExit(_ members: [PidRef], timeout: TimeInterval) -> [PidRef] {
        let deadline = Date().addingTimeInterval(timeout)
        var remaining = alive(members)
        while !remaining.isEmpty, Date() < deadline {
            usleep(100_000)
            remaining = alive(remaining)
        }
        return remaining
    }
}
