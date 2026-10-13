import Darwin
import Foundation
import DeskmanPorts

/// `TerminalActivity` over libproc (ADR-2610101549). For each tty, the foreground
/// process group's leader is the job; its parents lead to the terminal app. It reads
/// the program's name and folder only, never its arguments, and only this user's processes.
@MainActor public final class ProcessTerminalActivity: TerminalActivity {
    /// Executable path fragments of terminal apps, and the name their windows carry.
    /// iTerm2's tabs hang off `iTermServer`, which outlives the app.
    static let terminals: [(fragment: String, app: String)] = [
        ("/Warp.app/", "Warp"), ("/iTerm.app/", "iTerm2"), ("/iTerm2/iTermServer", "iTerm2"),
        ("/Terminal.app/", "Terminal"), ("/Ghostty.app/", "Ghostty"), ("/kitty.app/", "kitty"),
        ("/WezTerm.app/", "WezTerm"), ("/Alacritty.app/", "Alacritty"),
    ]

    public init() {}

    public func jobs() -> [TerminalJob] {
        let me = getuid()
        var info: [pid_t: proc_bsdinfo] = [:]
        for pid in Self.allPids() {
            if let i = Self.bsdInfo(pid), i.pbi_uid == me { info[pid] = i }
        }
        var appOf: [pid_t: String?] = [:]
        // Jobs are this user's; the way up to the terminal may pass a root process
        // (iTerm2 starts each shell through /usr/bin/login), so ancestors are read on demand.
        // proc_pidinfo refuses another user's process; sysctl gives its parent, as ps does.
        func parentOf(_ pid: pid_t) -> pid_t? { info[pid].map { pid_t($0.pbi_ppid) } ?? Self.sysctlParent(pid) }
        func terminalApp(_ pid: pid_t) -> String? {
            var p = pid
            for _ in 0..<16 {
                if let known = appOf[p] { return known }
                guard let parent = parentOf(p) else { return nil }
                guard parent > 1 else { return nil }
                if let path = Self.path(parent), let t = Self.terminals.first(where: { path.contains($0.fragment) }) {
                    appOf[pid] = t.app
                    return t.app
                }
                p = parent
            }
            return nil
        }
        var jobs: [TerminalJob] = []
        for (pid, i) in info {
            // The leader of its tty's foreground group: the program in front in that tab.
            let noTTY = UInt32.max
            guard i.e_tdev != noTTY, i.e_tdev != 0, pid_t(i.pbi_pgid) == pid, i.e_tpgid == i.pbi_pgid,
                  let app = terminalApp(pid) else { continue }
            let tty = devname(dev_t(bitPattern: i.e_tdev), S_IFCHR).map { String(cString: $0) } ?? "?"
            jobs.append(TerminalJob(app: app, tty: tty, program: Self.program(pid, i), folder: Self.cwd(pid)))
        }
        return jobs.sorted { $0.tty < $1.tty }
    }

    private static func allPids() -> [pid_t] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return Array(pids.prefix(Int(max(0, got))))
    }

    private static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var i = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &i, size) == size ? i : nil
    }

    private static func sysctlParent(_ pid: pid_t) -> pid_t? {
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var kp = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, 4, &kp, &size, nil, 0) == 0, size > 0 else { return nil }
        return kp.kp_eproc.e_ppid
    }

    private static func cwd(_ pid: pid_t) -> String? {
        var v = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &v, size) == size else { return nil }
        let path = withUnsafeBytes(of: &v.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        return path.isEmpty ? nil : path
    }

    private static func path(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
    }

    /// The program's name. Some install one file per version (Claude Code runs
    /// ".../claude/versions/2.1.296"): a version-like name gives way to the folder that
    /// names the program. Arguments are never read, so argv[0] is not an option.
    static func program(_ pid: pid_t, _ i: proc_bsdinfo) -> String {
        let n = name(i)
        guard looksLikeVersion(n), let path = path(pid) else { return n }
        let parts = path.split(separator: "/").map(String.init).dropLast()
        return parts.reversed().first { !looksLikeVersion($0) && !["versions", "bin", "libexec"].contains($0) } ?? n
    }

    static func looksLikeVersion(_ s: String) -> Bool {
        !s.isEmpty && s.first!.isNumber && s.allSatisfy { $0.isNumber || $0 == "." || $0 == "-" }
    }

    /// The process's own name (up to 32 characters), else its short command name.
    private static func name(_ i: proc_bsdinfo) -> String {
        var i = i
        let long = withUnsafeBytes(of: &i.pbi_name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        if !long.isEmpty { return long }
        return withUnsafeBytes(of: &i.pbi_comm) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    }
}
