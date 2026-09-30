import AppKit
import CoreGraphics
import Darwin
import IOKit.ps
import IOKit.pwr_mgt

/// Cumulative input-event counters maintained by the window server. Only COUNTS are read — never key contents.
/// No extra permission is required.
public struct InputCounters: Equatable {
    public var keys: UInt32
    public var clicks: UInt32
    public var scrolls: UInt32
    public var moves: UInt32

    public static func read() -> InputCounters {
        func c(_ t: CGEventType) -> UInt32 { CGEventSource.counterForEventType(.combinedSessionState, eventType: t) }
        return InputCounters(keys: c(.keyDown), clicks: c(.leftMouseDown) &+ c(.rightMouseDown) &+ c(.otherMouseDown),
                             scrolls: c(.scrollWheel), moves: c(.mouseMoved) &+ c(.leftMouseDragged))
    }

    /// Wrap-safe difference.
    public func delta(since old: InputCounters) -> InputDelta {
        InputDelta(keys: Double(keys &- old.keys), clicks: Double(clicks &- old.clicks),
                   scrolls: Double(scrolls &- old.scrolls), moves: Double(moves &- old.moves))
    }
}

public struct InputDelta: Equatable {
    public var keys: Double = 0, clicks: Double = 0, scrolls: Double = 0, moves: Double = 0
    public init(keys: Double = 0, clicks: Double = 0, scrolls: Double = 0, moves: Double = 0) {
        self.keys = keys; self.clicks = clicks; self.scrolls = scrolls; self.moves = moves
    }
    public var total: Double { keys + clicks + scrolls + moves }
}

public enum SystemSignals {
    /// Seconds since the last keyboard/mouse/trackpad event from the user.
    public static func secondsSinceLastInput() -> Double {
        guard let any = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }

    /// PIDs currently preventing display sleep (video players, browsers playing video, presentations…).
    public static func pidsPreventingDisplaySleep() -> Set<pid_t> {
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess, let dict = raw?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else {
            return []
        }
        var out = Set<pid_t>()
        for (pid, assertions) in dict {
            for a in assertions {
                let type = a["AssertType"] as? String ?? ""
                if type == "PreventUserIdleDisplaySleep" || type == "NoDisplaySleepAssertion" {
                    out.insert(pid.int32Value)
                }
            }
        }
        return out
    }

    public struct PowerState: Equatable {
        public var onAC: Bool
        public var batteryFraction: Double?
    }

    public static func power() -> PowerState {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return PowerState(onAC: true, batteryFraction: nil) }
        let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        var fraction: Double? = nil
        if let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for ps in list {
                if let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                   let cur = d[kIOPSCurrentCapacityKey] as? Double, let mx = d[kIOPSMaxCapacityKey] as? Double, mx > 0 {
                    fraction = cur / mx
                }
            }
        }
        return PowerState(onAC: source == kIOPMACPowerKey, batteryFraction: fraction)
    }

    /// Resident memory of this process (for the UI's "RAM used" indicator).
    public static func residentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? info.resident_size : 0
    }

    public static var physicalMemoryBytes: UInt64 { ProcessInfo.processInfo.physicalMemory }
}

/// Process-tree helpers based on libproc (no special permission needed for the user's own processes).
public enum ProcessTree {
    public struct Info {
        public var pid: pid_t
        public var ppid: pid_t
        public var uid: uid_t
        public var name: String
    }

    public static func allProcesses() -> [Info] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = pids.withUnsafeMutableBufferPointer { buf in
            proc_listallpids(buf.baseAddress, Int32(buf.count * MemoryLayout<pid_t>.size))
        }
        guard n > 0 else { return [] }
        var out: [Info] = []
        out.reserveCapacity(Int(n))
        for pid in pids.prefix(Int(n)) where pid > 0 {
            var bsd = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size else { continue }
            let name = withUnsafePointer(to: &bsd.pbi_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN * 2)) { String(cString: $0) }
            }
            let comm = withUnsafePointer(to: &bsd.pbi_comm) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) { String(cString: $0) }
            }
            out.append(Info(pid: pid, ppid: pid_t(bsd.pbi_ppid), uid: bsd.pbi_uid, name: name.isEmpty ? comm : name))
        }
        return out
    }

    /// `root` plus all of its descendants.
    public static func descendants(of root: pid_t, in procs: [Info]? = nil) -> [pid_t] {
        let all = procs ?? allProcesses()
        var children: [pid_t: [pid_t]] = [:]
        for p in all { children[p.ppid, default: []].append(p.pid) }
        var out: [pid_t] = [root]
        var queue = [root]
        var seen: Set<pid_t> = [root]
        while let p = queue.popLast() {
            for c in children[p] ?? [] where seen.insert(c).inserted {
                out.append(c)
                queue.append(c)
            }
        }
        return out
    }

    /// Start time (seconds since epoch — together with the pid it identifies a process uniquely) and stopped state.
    public static func bsd(_ pid: pid_t) -> (start: UInt64, stopped: Bool, uid: uid_t)? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return (UInt64(info.pbi_start_tvsec), info.pbi_status == UInt32(SSTOP), info.pbi_uid)
    }

    public static func executablePath(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }
}
