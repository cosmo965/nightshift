import Foundation
import Darwin

/// User-side client. No sudo, authentication prompts, or privileged commands in
/// the agent event path. The separately installed daemon owns the global setting.
final class ClosedLid {
    var enabled = true
    private let token = UUID().uuidString
    private let directory = URL(fileURLWithPath: "/var/run/nightshift-lid-\(getuid())", isDirectory: true)
    private var lastWrite = Date.distantPast
    private var lastRequest = false
    private(set) var confirmed = false
    private(set) var restoring = false
    private(set) var message = "Closed lid: administrator setup required"

    func sync(awake: Bool) {
        let requested = awake && enabled
        var info = stat()
        guard lstat(directory.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            confirmed = false; message = "Closed lid: administrator setup required"; return
        }
        if requested != lastRequest || Date().timeIntervalSince(lastWrite) >= 10 {
            guard let owner = Owner.capture(getpid()) else {
                confirmed = false; message = "Closed lid: cannot verify Nightshift process"; return
            }
            let lease = LidLease(token: token, owner: owner, timestamp: Date().timeIntervalSince1970, requested: requested)
            do {
                try JSONEncoder().encode(lease).write(to: directory.appendingPathComponent("lease.json"), options: .atomic)
                lastRequest = requested; lastWrite = Date()
            } catch {
                confirmed = false; message = "Closed lid: cannot contact helper"; return
            }
        }
        refresh(requested: requested)
    }

    func refresh(requested: Bool) {
        restoring = false
        let path = directory.appendingPathComponent("status.json").path
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { confirmed = false; message = "Closed lid: waiting for installed helper"; return }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_uid == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size <= 4096 else {
            confirmed = false; message = "Closed lid: helper status is untrusted"; return
        }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &buffer, buffer.count)
        guard n > 0, let status = try? JSONDecoder().decode(LidStatus.self, from: Data(buffer.prefix(n))),
              status.token == token, abs(Date().timeIntervalSince1970 - status.timestamp) < 20 else {
            confirmed = false; message = "Closed lid: awaiting fresh confirmation"; return
        }
        confirmed = requested && status.confirmed
        restoring = !requested && (status.confirmed || status.recoveryPending)
        message = "Closed lid: " + status.message
    }

    func release() {
        enabled = false; lastWrite = .distantPast
        sync(awake: false)
    }
}
