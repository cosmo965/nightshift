import Foundation

struct LidLease: Codable {
    var token: String
    var owner: Owner
    var timestamp: Double
    var requested: Bool
    func valid(now: Double, alive: (Owner) -> Bool) -> Bool {
        requested && !token.isEmpty && now - timestamp >= -5 && now - timestamp <= 45 && alive(owner)
    }
}

struct LidStatus: Codable {
    var token: String
    var timestamp: Double
    var confirmed: Bool
    var message: String
    var recoveryPending: Bool = false
}

struct LidJournal: Codable {
    var original: Bool
    var bootTime: Int64? = nil
    func belongsToBoot(_ current: Int64) -> Bool { bootTime == current }
}

/// The helper journals BEFORE changing the global setting. A restarted helper
/// resumes a verified surviving lease or restores that baseline. The journal survives
/// failed restoration so a retry never loses the original setting.
final class LidEngine {
    var journal: LidJournal?
    var read: () throws -> Bool
    var write: (Bool) throws -> Void
    var save: (LidJournal?) throws -> Void
    init(journal: LidJournal? = nil, read: @escaping () throws -> Bool,
         write: @escaping (Bool) throws -> Void, save: @escaping (LidJournal?) throws -> Void) {
        self.journal = journal; self.read = read; self.write = write; self.save = save
    }
    func acquire() throws {
        if journal == nil {
            let baseline = try read()
            let record = LidJournal(original: baseline)
            try save(record)
            journal = record
        }
        if try !read() { try write(true) }
        guard try read() else { throw LidError.message("macOS did not confirm closed-lid protection") }
    }
    func restore() throws {
        guard let record = journal else { return }
        if try read() != record.original { try write(record.original) }
        guard try read() == record.original else { throw LidError.message("Sleep setting restoration is unconfirmed; retrying") }
        try save(nil)
        journal = nil
    }
}

enum LidError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}
