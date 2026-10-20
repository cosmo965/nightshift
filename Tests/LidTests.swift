import Foundation

@main struct LidTests {
    static var count = 0
    static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else { fatalError("FAIL: " + label) }; count += 1
    }
    static func main() throws {
        var setting = false
        var disk: LidJournal?
        var order: [String] = []
        let engine = LidEngine(read: { setting }, write: { value in
            order.append("set\(value)"); setting = value
        }, save: { value in order.append(value == nil ? "clear" : "journal"); disk = value })
        try engine.acquire()
        check(setting, "Active work blocks closed-lid sleep")
        check(order == ["journal", "settrue"], "Recovery journal saved before global mutation")
        check(disk?.original == false, "Original sleep state recorded")
        try engine.acquire()
        check(order.count == 2, "Repeated work doesn't spawn redundant pmset writes")
        setting = false // Simulates a reset during a power-source transition.
        try engine.acquire()
        check(setting && order.last == "settrue", "External power-state reset is repaired")
        try engine.restore()
        check(!setting && disk == nil, "Final task completion restores sleep and removes journal")
        check(order.suffix(2) == ["setfalse", "clear"], "Journal cleared only after confirmed restoration")
        setting = true
        try engine.acquire(); try engine.restore()
        check(setting, "Preexisting disabled-sleep state is preserved")
        setting = true; disk = LidJournal(original: false)
        let restarted = LidEngine(journal: disk, read: { setting }, write: { setting = $0 }, save: { disk = $0 })
        try restarted.acquire()
        check(setting && restarted.journal?.original == false, "Daemon restart preserves surviving active work without a sleep gap")
        try restarted.restore()
        check(!setting && disk == nil, "Daemon restart recovers previous crash journal")
        var changed = false
        let noJournal = LidEngine(read: { false }, write: { _ in changed = true }, save: { _ in throw LidError.message("disk full") })
        do { try noJournal.acquire(); fatalError("Should fail") } catch {}
        check(!changed && noJournal.journal == nil, "Journal failure forbids system mutation")
        let denied = LidEngine(read: { false }, write: { _ in throw LidError.message("denied") }, save: { disk = $0 })
        do { try denied.acquire(); fatalError("Should fail") } catch {}
        check(denied.journal != nil && disk != nil, "Rejected mutation retains recovery information")
        setting = true
        let failedRestore = LidEngine(journal: LidJournal(original: false), read: { setting }, write: { _ in
            throw LidError.message("restore failed")
        }, save: { disk = $0 })
        do { try failedRestore.restore(); fatalError("Should fail") } catch {}
        check(failedRestore.journal != nil, "Failed restore keeps journal for retry")
        let unconfirmed = LidEngine(read: { false }, write: { _ in }, save: { _ in })
        do { try unconfirmed.acquire(); fatalError("Should fail") } catch {}
        check(unconfirmed.journal != nil, "Successful command without readback is not protection")
        let owner = Owner(pid: 42, birth: 123)
        var lease = LidLease(token: "token", owner: owner, timestamp: 100, requested: true)
        check(lease.valid(now: 101, alive: { $0 == owner }), "Fresh live process lease accepted")
        check(!lease.valid(now: 146, alive: { _ in true }), "Stale heartbeat releases closed-lid protection")
        check(!lease.valid(now: 101, alive: { _ in false }), "Nightshift crash / PID reuse releases protection")
        check(!lease.valid(now: 90, alive: { _ in true }), "Future timestamp cannot grant indefinite protection")
        lease.requested = false
        check(!lease.valid(now: 101, alive: { _ in true }), "Pause / Quit / waiting publishes release")
        let sameBoot = LidJournal(original: false, bootTime: 123)
        check(sameBoot.belongsToBoot(123), "Same-boot crash journal is eligible for recovery")
        check(!sameBoot.belongsToBoot(456), "A reboot invalidates the prior runtime baseline")
        print("PASS: \(count) closed-lid lifecycle, crash recovery, ownership, and failure checks")
    }
}
