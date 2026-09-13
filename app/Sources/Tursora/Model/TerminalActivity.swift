import Foundation
import Darwin
import SwiftTerm

struct TerminalActivitySnapshot: Equatable {
    struct Task: Equatable {
        let pid: Int32
        let name: String
        let isStopped: Bool
    }
    let tasks: [Task]
    let informationUnavailable: Bool
    var requiresConfirmation: Bool { informationUnavailable || !tasks.isEmpty }
    static let idle = TerminalActivitySnapshot(tasks: [], informationUnavailable: false)
}

/// Process metadata, never command text, determines which jobs belong to a PTY.
/// PID birth times prevent a later process from inheriting an old session's
/// shutdown signals. Session membership also finds background and orphaned jobs.
enum TerminalActivity {
    struct Identity: Hashable {
        let pid: pid_t
        let startedSeconds: UInt64
        let startedMicroseconds: UInt64
    }
    struct ProcessRecord: Equatable {
        let identity: Identity
        let parentPID: pid_t
        let sessionID: pid_t
        let name: String
        let status: UInt32
        var pid: pid_t { identity.pid }
        var isStopped: Bool { status == UInt32(SSTOP) }
        var isZombie: Bool { status == UInt32(SZOMB) }
    }
    struct ProcessTable {
        let records: [ProcessRecord]
        let unavailablePIDs: [pid_t]
        let isComplete: Bool
    }

    final class Session {
        let shell: Identity
        let shellNames: Set<String>

        init?(process: LocalProcess, expectedShell: String? = nil) {
            guard process.shellPid > 1, let record = readProcess(process.shellPid),
                  record.parentPID == getpid() else { return nil }
            shell = record.identity
            var names = TerminalActivity.standardShellNames
            if let expectedShell { names.insert(URL(fileURLWithPath: expectedShell).lastPathComponent) }
            shellNames = names
        }

        func snapshot() -> TerminalActivitySnapshot {
            let table = readTable()
            let members = Self.members(of: shell, in: table.records)
            let shellReused = table.records.contains { $0.pid == shell.pid && $0.identity != shell }
            let ownedPIDs = Set(members.map(\.pid)).union([shell.pid])
            let unavailableOwned = table.unavailablePIDs.contains {
                $0 == shell.pid || getsid($0) == shell.pid || Self.hasKnownParent($0, parents: ownedPIDs)
            }
            let missingShell = Self.missingShellInformation(shell: shell, table: table, shellIsAlive: TerminalActivity.isAlive(shell.pid))
            let uncertainSession = members.contains { $0.sessionID < 0 && !$0.isZombie }
            return Self.classify(shell: shell, members: members, shellNames: shellNames,
                                 informationUnavailable: !table.isComplete || shellReused || unavailableOwned || missingShell || uncertainSession)
        }

        func ownedProcesses() -> [ProcessRecord] {
            Self.members(of: shell, in: readTable().records)
        }

        static func members(of shell: Identity, in records: [ProcessRecord]) -> [ProcessRecord] {
            // A different process now using the leader PID is never evidence
            // for this terminal's ownership, even if its session ID matches.
            guard !records.contains(where: { $0.pid == shell.pid && $0.identity != shell }) else { return [] }
            var owned = Set(records.filter { $0.identity == shell || $0.sessionID == shell.pid }.map(\.pid))
            var count = -1
            while owned.count != count {
                count = owned.count
                for record in records where owned.contains(record.parentPID) { owned.insert(record.pid) }
            }
            return records.filter { owned.contains($0.pid) && $0.pid > 1 && $0.pid != getpid() }
        }

        static func classify(shell: Identity, members: [ProcessRecord], shellNames: Set<String>,
                             informationUnavailable: Bool) -> TerminalActivitySnapshot {
            let jobs = members.filter { record in
                guard !record.isZombie else { return false }
                // An exec'ed command keeps the shell PID and foreground group.
                // Its executable name distinguishes it from an idle shell.
                return record.identity != shell || record.isStopped || !shellNames.contains(record.name)
            }.sorted { $0.pid < $1.pid }.map {
                TerminalActivitySnapshot.Task(pid: $0.pid, name: $0.name, isStopped: $0.isStopped)
            }
            return TerminalActivitySnapshot(tasks: jobs, informationUnavailable: informationUnavailable)
        }

        static func missingShellInformation(shell: Identity, table: ProcessTable, shellIsAlive: Bool) -> Bool {
            table.unavailablePIDs.contains(shell.pid)
                || (shellIsAlive && !table.records.contains { $0.identity == shell })
        }

        private static func hasKnownParent(_ pid: pid_t, parents: Set<pid_t>) -> Bool {
            // A child whose richer BSD metadata is unavailable must still
            // cause confirmation when libproc identifies its owned parent.
            for parent in parents {
                let count = proc_listchildpids(parent, nil, 0)
                guard count > 0 else { continue }
                var children = [pid_t](repeating: 0, count: Int(count) / MemoryLayout<pid_t>.stride + 16)
                let bytes = children.withUnsafeMutableBytes { proc_listchildpids(parent, $0.baseAddress, Int32($0.count)) }
                if bytes > 0, children.prefix(Int(bytes) / MemoryLayout<pid_t>.stride).contains(pid) { return true }
            }
            return false
        }
    }

    static let standardShellNames: Set<String> = ["sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh", "nu", "xonsh"]

    static func isAlive(_ pid: pid_t) -> Bool {
        guard pid > 1 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    static func ownsShell(_ current: ProcessRecord?, expected: Identity?) -> Bool {
        guard let current, let expected else { return false }
        return current.identity == expected && current.parentPID == getpid()
    }

    static func readProcess(_ pid: pid_t) -> ProcessRecord? {
        guard pid > 1 else { return nil }
        var value = proc_bsdinfo()
        let expected = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &value, expected) == expected else { return readKernelProcess(pid) }
        let name = withUnsafeBytes(of: &value.pbi_name) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        let fallback = withUnsafeBytes(of: &value.pbi_comm) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return ProcessRecord(identity: Identity(pid: pid, startedSeconds: value.pbi_start_tvsec,
                                                startedMicroseconds: value.pbi_start_tvusec),
                             parentPID: pid_t(value.pbi_ppid), sessionID: getsid(pid),
                             name: name.isEmpty ? fallback : name, status: value.pbi_status)
    }

    private static func readKernelProcess(_ pid: pid_t) -> ProcessRecord? {
        // macOS libproc returns ESRCH for an unreaped zombie, and getsid also
        // fails. KERN_PROC_PID retains its original birth time and parent, so
        // we can still prove identity before waitpid without adopting a reused
        // PID. Never substitute only a parent-PID or kill(pid, 0) check here.
        var value = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = mib.withUnsafeMutableBufferPointer { sysctl($0.baseAddress, UInt32($0.count), &value, &size, nil, 0) }
        guard result == 0, size == MemoryLayout<kinfo_proc>.size, value.kp_proc.p_pid == pid else { return nil }
        let started = value.kp_proc.p_un.__p_starttime
        guard started.tv_sec >= 0, started.tv_usec >= 0 else { return nil }
        let name = withUnsafeBytes(of: &value.kp_proc.p_comm) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return ProcessRecord(identity: Identity(pid: pid, startedSeconds: UInt64(started.tv_sec), startedMicroseconds: UInt64(started.tv_usec)),
                             parentPID: value.kp_eproc.e_ppid, sessionID: getsid(pid), name: name,
                             status: UInt32(value.kp_proc.p_stat))
    }

    static func readTable() -> ProcessTable {
        let required = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard required > 0 else { return ProcessTable(records: [], unavailablePIDs: [], isComplete: false) }
        var pids = [pid_t](repeating: 0, count: Int(required) / MemoryLayout<pid_t>.stride + 1024)
        let capacity = pids.count * MemoryLayout<pid_t>.stride
        let used = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress, Int32($0.count)) }
        guard used > 0 else { return ProcessTable(records: [], unavailablePIDs: [], isComplete: false) }
        var records: [ProcessRecord] = []
        var unavailable: [pid_t] = []
        for pid in pids.prefix(min(pids.count, Int(used) / MemoryLayout<pid_t>.stride)) where pid > 1 {
            if let record = readProcess(pid) { records.append(record) }
            else if kill(pid, 0) == 0 || errno != ESRCH { unavailable.append(pid) }
        }
        return ProcessTable(records: records, unavailablePIDs: unavailable, isComplete: Int(used) < capacity)
    }

    @discardableResult static func signal(_ record: ProcessRecord, _ signal: Int32) -> Bool {
        guard record.pid > 1, record.pid != getpid(),
              let current = readProcess(record.pid), current.identity == record.identity else { return false }
        return kill(record.pid, signal) == 0
    }
}

/// SwiftTerm cancels its exit monitor in terminate(). Explicit shutdown owns
/// reaping; repeated callers share the same completion barrier.
enum TerminalProcessLifecycle {
    private final class Stop {
        var completions: [() -> Void] = []
        var finished = false
    }
    private static let stops = NSMapTable<LocalProcess, Stop>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    private static var pendingStops = 0
    private static var allStoppedCompletions: [() -> Void] = []

    static func whenAllStopped(completion: @escaping () -> Void) {
        if pendingStops == 0 { completion() }
        else { allStoppedCompletions.append(completion) }
    }

    static func stop(_ process: LocalProcess, session supplied: TerminalActivity.Session? = nil,
                     completion: (() -> Void)? = nil) {
        if let previous = stops.object(forKey: process) {
            if previous.finished { completion?() }
            else if let completion { previous.completions.append(completion) }
            return
        }
        let stop = Stop()
        if let completion { stop.completions.append(completion) }
        stops.setObject(stop, forKey: process)
        pendingStops += 1
        // Once SwiftTerm has ended, shellPid may already belong to someone
        // else. Only a birth identity captured while live can authorize it.
        let session = supplied ?? (process.running ? TerminalActivity.Session(process: process) : nil)
        let initial = session?.ownedProcesses() ?? []
        let pid = process.shellPid
        var status: Int32 = 0
        var childState: pid_t = -1
        if TerminalActivity.ownsShell(TerminalActivity.readProcess(pid), expected: session?.shell) {
            repeat { childState = waitpid(pid, &status, WNOHANG) } while childState < 0 && errno == EINTR
        }
        for record in initial where record.pid != pid && !record.isZombie {
            TerminalActivity.signal(record, SIGHUP)
            if record.isStopped { TerminalActivity.signal(record, SIGCONT) }
        }
        if childState == 0 {
            // No delayed call to terminate(): it signals shellPid without a
            // birth-time check. Here waitpid still proves direct ownership,
            // and the main-queue SwiftTerm monitor cannot race this call.
            process.terminate()
        }
        let needsReap = childState == 0
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + (initial.isEmpty ? 0 : 0.15)) { [process] in
            let latest = session?.ownedProcesses() ?? []
            let targets = Dictionary((initial + latest).map { ($0.identity, $0) }, uniquingKeysWith: { _, latest in latest }).values
            for record in targets where record.pid != pid && !record.isZombie { TerminalActivity.signal(record, SIGKILL) }
            if needsReap {
                if let shell = TerminalActivity.readProcess(pid), TerminalActivity.ownsShell(shell, expected: session?.shell) {
                    TerminalActivity.signal(shell, SIGKILL)
                }
                var status: Int32 = 0
                while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            }
            _ = process
            DispatchQueue.main.async {
                stop.finished = true
                pendingStops -= 1
                let callbacks = stop.completions
                stop.completions.removeAll()
                callbacks.forEach { $0() }
                if pendingStops == 0 {
                    let barriers = allStoppedCompletions
                    allStoppedCompletions.removeAll()
                    barriers.forEach { $0() }
                }
            }
        }
    }
}
