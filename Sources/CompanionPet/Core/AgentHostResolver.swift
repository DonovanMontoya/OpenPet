import AppKit
import Foundation
import Darwin

// MARK: - Protocols

/// Abstraction over AgentHostResolver for injection in tests and adapters.
protocol HostResolving: Sendable {
    func resolveHost(forAgentPID agentPID: Int32) -> HostBinding
    func currentDirectory(forPID pid: Int32) -> String?
}

protocol ProcessTreeProvider: Sendable {
    func parentPID(of pid: Int32) -> Int32?
}

protocol RunningAppLookup: Sendable {
    func bundleID(for pid: Int32) -> String?
    func isGUIApp(pid: Int32) -> Bool
}

// MARK: - Default implementations

struct SysctlProcessTreeProvider: ProcessTreeProvider {
    func parentPID(of pid: Int32) -> Int32? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        let result = sysctl(&mib, 4, &info, &size, nil, 0)
        guard result == 0, size > 0 else { return nil }
        let ppid = info.kp_eproc.e_ppid
        guard ppid > 0 else { return nil }
        return ppid
    }
}

struct NSRunningAppLookup: RunningAppLookup {
    func bundleID(for pid: Int32) -> String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    func isGUIApp(pid: Int32) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return app.activationPolicy != .prohibited
    }
}

// MARK: - AgentHostResolver

final class AgentHostResolver: HostResolving, @unchecked Sendable {
    private let processTree: ProcessTreeProvider
    private let appLookup: RunningAppLookup
    private let lock = NSLock()
    private var cache: [Int32: CacheEntry] = [:]
    private let cacheTTL: TimeInterval = 10

    private struct CacheEntry {
        var binding: HostBinding
        var expiresAt: Date
    }

    init(
        processTree: ProcessTreeProvider = SysctlProcessTreeProvider(),
        appLookup: RunningAppLookup = NSRunningAppLookup()
    ) {
        self.processTree = processTree
        self.appLookup = appLookup
    }

    func resolveHost(forAgentPID agentPID: Int32) -> HostBinding {
        if let cached = cachedBinding(for: agentPID) {
            return cached
        }

        var binding = HostBinding(agentPID: agentPID)
        var current = agentPID
        var hops = 0
        let maxHops = 16

        while hops < maxHops {
            guard let ppid = processTree.parentPID(of: current), ppid > 1 else { break }
            current = ppid
            hops += 1

            if appLookup.isGUIApp(pid: current) {
                binding.hostPID = current
                binding.hostBundleID = appLookup.bundleID(for: current)
                break
            }
        }

        storeCache(agentPID: agentPID, binding: binding)
        return binding
    }

    func ttyPath(forPID pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let devNum = info.kp_eproc.e_tdev
        // -1 (or 0xffffffff as Int32) means no tty
        guard devNum != -1 else { return nil }
        // Construct /dev/ttysXXX from dev number
        var ttyBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard devname_r(dev_t(bitPattern: UInt32(bitPattern: devNum)), S_IFCHR, &ttyBuf, Int32(MAXPATHLEN)) != nil else {
            return nil
        }
        let name = ttyBuf.withUnsafeBufferPointer { buf in
            String(decoding: buf.prefix(while: { $0 != 0 }).map(UInt8.init), as: UTF8.self)
        }
        guard !name.isEmpty, name != "??" else { return nil }
        return "/dev/" + name
    }

    func currentDirectory(forPID pid: Int32) -> String? {
        var pathInfo = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let ret = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &pathInfo, size)
        guard ret > 0 else { return nil }
        let cwd = withUnsafeBytes(of: pathInfo.pvi_cdir.vip_path) { buf -> String? in
            guard let base = buf.baseAddress?.assumingMemoryBound(to: CChar.self) else { return nil }
            return String(cString: base)
        }
        return cwd.flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: - Cache

    private func cachedBinding(for agentPID: Int32) -> HostBinding? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = cache[agentPID], entry.expiresAt > .now else {
            return nil
        }
        return entry.binding
    }

    private func storeCache(agentPID: Int32, binding: HostBinding) {
        lock.lock()
        defer { lock.unlock() }
        cache[agentPID] = CacheEntry(binding: binding, expiresAt: Date().addingTimeInterval(cacheTTL))
    }
}
