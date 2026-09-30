import Darwin
import Foundation

// tf-watchdog <parent-pid> <throttle-state.json> [<llama-server.pid>]
//
// Started by TimeFocus at launch. Waits for TimeFocus to exit for ANY reason (quit, crash, kill -9, killall), then:
//  • resumes every process TimeFocus may have left paused by its slowdown (only processes it recorded, matched by
//    pid + start time, and only if they are actually stopped), and restores their CPU priority;
//  • stops a llama-server TimeFocus may have left running (verified by its executable name).
// Deliberately tiny and dependency-free, with a process name that does not contain "TimeFocus".

func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
}

func recover(stateFile: String) {
    guard let data = FileManager.default.contents(atPath: stateFile),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
    func entries(_ key: String) -> [(pid_t, UInt64?)] {
        if let procs = obj[key] as? [[String: Any]] {
            return procs.compactMap { p in (p["pid"] as? Int).map { (pid_t($0), (p["start"] as? NSNumber)?.uint64Value) } }
        }
        if key == "procs", let pids = obj["pids"] as? [Int] { return pids.map { (pid_t($0), nil) } } // old format
        return []
    }
    func alive(_ pid: pid_t, _ start: UInt64?) -> proc_bsdinfo? {
        guard pid > 1, let info = bsdInfo(pid) else { return nil }
        if let start, UInt64(info.pbi_start_tvsec) != start { return nil } // pid recycled by an unrelated process
        return info
    }
    // processes TimeFocus pauses every duty cycle: resume them if they are stopped
    for (pid, start) in entries("procs") {
        if let info = alive(pid, start), info.pbi_status == UInt32(SSTOP) { kill(pid, SIGCONT) }
    }
    // processes TimeFocus demoted to background priority: restore normal priority
    for (pid, start) in entries("demoted") where alive(pid, start) != nil {
        setpriority(PRIO_DARWIN_PROCESS, UInt32(pid), 0)
    }
}

func stopLlama(pidFile: String) {
    guard let s = try? String(contentsOfFile: pidFile, encoding: .utf8),
          let pid = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return }
    var buf = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0, String(cString: buf).hasSuffix("llama-server") else { return }
    kill(pid, SIGTERM)
    usleep(1_500_000)
    if bsdInfo(pid) != nil { kill(pid, SIGKILL) }
    try? FileManager.default.removeItem(atPath: pidFile)
}

let args = CommandLine.arguments
guard args.count >= 3, let parent = pid_t(args[1]) else {
    FileHandle.standardError.write("usage: tf-watchdog <parent-pid> <state-file> [<llama-pid-file>]\n".data(using: .utf8)!)
    exit(2)
}
signal(SIGHUP, SIG_IGN)
signal(SIGINT, SIG_IGN)

let kq = kqueue()
var ev = kevent(ident: UInt(parent), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
                fflags: NOTE_EXIT, data: 0, udata: nil)
if kevent(kq, &ev, 1, nil, 0, nil) != -1 {
    var out = kevent()
    while true {
        let n = kevent(kq, nil, 0, &out, 1, nil)
        if n > 0 { break }
        if n < 0 && errno != EINTR { break }
    }
}
// twice, more than one duty period apart, in case the app died in the middle of a pause
recover(stateFile: args[2])
usleep(300_000)
recover(stateFile: args[2])
if args.count >= 4 { stopLlama(pidFile: args[3]) }
exit(0)
