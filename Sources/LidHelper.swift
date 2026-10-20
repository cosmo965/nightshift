import Foundation
import IOKit
import IOKit.ps
import Darwin

private func sleepDisabled() throws -> Bool {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard service != 0 else { throw LidError.message("Cannot read macOS power-management state") }
    defer { IOObjectRelease(service) }
    // An absent SleepDisabled property means the default (sleep enabled).
    guard let value = IORegistryEntryCreateCFProperty(service, "SleepDisabled" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else { return false }
    guard let number = value as? NSNumber else { throw LidError.message("Unexpected SleepDisabled property type") }
    return number.boolValue
}

private func setSleepDisabled(_ disabled: Bool) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    process.arguments = ["-a", "disablesleep", disabled ? "1" : "0"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    // pmset has a fixed command/arguments: no user-controlled command execution.
    let deadline = Date().addingTimeInterval(3)
    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    if process.isRunning { process.terminate(); throw LidError.message("pmset timed out") }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw LidError.message("macOS rejected the closed-lid setting") }
}

private func batteryAllowsProtection() -> Bool {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return true }
    for source in sources {
        guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
              d[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue,
              let current = d[kIOPSCurrentCapacityKey] as? Int,
              let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
        if Double(current) / Double(max) <= 0.15 { return false }
    }
    return true
}

private final class PowerCallback {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
}

@main struct LidHelper {
    static func main() throws {
        if CommandLine.arguments.contains("--inspect") {
            let value = try? sleepDisabled()
            let report: [String: Any] = ["sleepDisabled": value.map { $0 as Any } ?? NSNull(),
                "batteryAllowsProtection": batteryAllowsProtection(), "readOnly": true]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            FileHandle.standardOutput.write(data); print(""); return
        }
        guard geteuid() == 0 else { fputs("Nightshift lid helper requires administrator installation.\n", stderr); exit(1) }
        let args = CommandLine.arguments
        guard args.count >= 2, let uid = UInt32(args[1]), uid >= 501 else { exit(2) }
        let runtime = URL(fileURLWithPath: "/var/run/nightshift-lid-\(uid)", isDirectory: true)
        let journalRoot = URL(fileURLWithPath: "/var/db/local.nightshift-lid", isDirectory: true)
        let journalURL = journalRoot.appendingPathComponent("restore.json")
        let fm = FileManager.default
        var boot = timeval()
        var bootSize = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &bootSize, nil, 0) == 0 else { exit(7) }
        let bootTime = Int64(boot.tv_sec)
        try fm.createDirectory(at: journalRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var rootInfo = stat()
        guard lstat(journalRoot.path, &rootInfo) == 0, rootInfo.st_uid == 0,
              rootInfo.st_mode & S_IFMT == S_IFDIR, rootInfo.st_mode & 0o077 == 0 else { exit(3) }
        let journal: LidJournal?
        if fm.fileExists(atPath: journalURL.path) {
            let stored = try JSONDecoder().decode(LidJournal.self, from: Data(contentsOf: journalURL))
            if stored.belongsToBoot(bootTime) { journal = stored }
            else {
                // disablesleep is runtime state. A prior boot's baseline must not
                // re-enable a stale setting after the kernel has reset it.
                try fm.removeItem(at: journalURL); journal = nil
            }
        } else { journal = nil }
        let engine = LidEngine(journal: journal, read: sleepDisabled, write: setSleepDisabled, save: { record in
            if var record {
                record.bootTime = bootTime
                try JSONEncoder().encode(record).write(to: journalURL, options: .atomic)
            }
            else if fm.fileExists(atPath: journalURL.path) { try fm.removeItem(at: journalURL) }
        })
        let lockFile = open(journalRoot.appendingPathComponent("helper.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lockFile >= 0, flock(lockFile, LOCK_EX | LOCK_NB) == 0 else { exit(4) }
        defer { close(lockFile) }
        // An explicit uninstall restores immediately. On daemon restart, tick()
        // first validates the lease: preserve protection for surviving work,
        // otherwise restore. Avoid briefly enabling clamshell sleep mid-task.
        if args.contains("--restore") { try engine.restore(); return }
        try fm.createDirectory(at: runtime, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var dirInfo = stat()
        guard lstat(runtime.path, &dirInfo) == 0, dirInfo.st_mode & S_IFMT == S_IFDIR,
              dirInfo.st_uid == uid || dirInfo.st_uid == 0 else { exit(5) }
        guard chown(runtime.path, uid, gid_t.max) == 0, chmod(runtime.path, 0o700) == 0 else { exit(6) }

        func getLease() -> LidLease? {
            let fd = open(runtime.appendingPathComponent("lease.json").path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == uid, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 4096 else { return nil }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { return nil }
            return try? JSONDecoder().decode(LidLease.self, from: Data(buffer.prefix(n)))
        }
        func ownerAlive(_ owner: Owner) -> Bool {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            return proc_pidinfo(owner.pid, PROC_PIDTBSDINFO, 0, &info, size) == size && info.pbi_uid == uid && Owner.capture(owner.pid) == owner
        }
        func publish(_ status: LidStatus) {
            // Atomic replacement doesn't follow a caller-created destination symlink.
            if let data = try? JSONEncoder().encode(status) {
                try? data.write(to: runtime.appendingPathComponent("status.json"), options: .atomic)
            }
        }
        func tick() {
            let now = Date().timeIntervalSince1970
            let lease = getLease()
            let batteryOK = batteryAllowsProtection()
            let valid = batteryOK && (lease?.valid(now: now, alive: ownerAlive) ?? false)
            do {
                if valid { try engine.acquire() } else { try engine.restore() }
                publish(LidStatus(token: lease?.token ?? "", timestamp: now, confirmed: valid,
                    message: valid ? "protected — verified by macOS" : !batteryOK ? "suspended — battery at or below 15%" : "released — previous sleep setting restored"))
            } catch {
                // Retain the journal on failure and retry; never claim success.
                publish(LidStatus(token: lease?.token ?? "", timestamp: now, confirmed: false,
                    message: error.localizedDescription, recoveryPending: engine.journal != nil))
            }
        }
        tick()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .milliseconds(500))
        timer.setEventHandler { tick() }; timer.resume()
        var lastLease: Date?
        // A separate watcher makes releases prompt, without a status/write feedback loop.
        let events = DirectoryWatcher(path: runtime.path, queue: .main) {
            let stamp = (try? fm.attributesOfItem(atPath: runtime.appendingPathComponent("lease.json").path)[.modificationDate]) as? Date
            if stamp != lastLease { lastLease = stamp; tick() }
        }
        signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
        let stop = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        let shutdown: () -> Void = {
            do { try engine.restore(); exit(0) }
            catch { NSLog("Nightshift helper restoration failed: %@", error.localizedDescription); exit(1) }
        }
        stop.setEventHandler(handler: shutdown); interrupt.setEventHandler(handler: shutdown)
        stop.resume(); interrupt.resume()
        let callback = PowerCallback { tick() }
        let powerChanges = IOPSNotificationCreateRunLoopSource({ pointer in
            if let pointer { Unmanaged<PowerCallback>.fromOpaque(pointer).takeUnretainedValue().run() }
        }, Unmanaged.passUnretained(callback).toOpaque())?.takeRetainedValue()
        if let powerChanges { CFRunLoopAddSource(CFRunLoopGetMain(), powerChanges, .defaultMode) }
        withExtendedLifetime((events, timer, stop, interrupt, callback, powerChanges)) { CFRunLoopRun() }
    }
}
