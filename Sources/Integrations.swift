import Foundation
import Darwin

struct FeedSession: Decodable {
    var id: String
    var agent: String?
    var cwd: String?
    var project: String?
    var hostBundleID: String?
    var host: String?
    var agentPID: Int32?
    var pid: Int32?
    var phase: String
    var lastEventAt: Double?
    var subagents: Int?
}

extension Registry {
    mutating func ingestFeed(_ list: [FeedSession], now: Double, live: Bool) {
        var keys = Set<String>()
        for s in list {
            let provider = s.agent ?? "claude"
            let key = provider + ":" + s.id + ":main"
            keys.insert(key)
            let updated = s.lastEventAt.map { $0 + Date.timeIntervalBetween1970AndReferenceDate } ?? now
            // Direct hooks take ownership for this session; do not let a delayed bridge overwrite them.
            if let old = tasks[key], old.source == "direct hook" { continue }
            let phase: WorkState
            switch s.phase {
            case "thinking", "tool", "compacting", "working": phase = .working
            case "waiting": phase = .waiting
            case "idle", "done", "failed", "interrupted": phase = .idle
            default: phase = .unknown
            }
            let previous = tasks[key]
            let pid = s.agentPID ?? s.pid
            var owner = previous?.owner
            if owner?.pid != pid { owner = pid.flatMap(Owner.capture) }
            // Don't capture a reused PID as a new owner for the same stale session.
            if let owner, !owner.alive { tasks.removeValue(forKey: key); continue }
            let label = s.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? s.project ?? provider
            tasks[key] = TaskRecord(key: key, session: s.id, actor: "main", provider: provider,
                label: label, host: s.hostBundleID ?? s.host ?? "", state: phase,
                source: "ClaudeBar bridge", updated: updated, owner: owner,
                reason: phase == .waiting ? "Awaiting your input" : s.phase)
            let childKey = provider + ":" + s.id + ":bridge-children"
            if let count = s.subagents {
                keys.insert(childKey)
                if count > 0 {
                    tasks[childKey] = TaskRecord(key: childKey, session: s.id, actor: "bridge-children",
                        provider: provider, label: label + " (\(count) subagents)", host: s.host ?? "",
                        state: .working, source: "ClaudeBar bridge", updated: now, owner: owner,
                        reason: "Reported by live ClaudeBar")
                } else { tasks.removeValue(forKey: childKey) }
            }
        }
        // A live /state is authoritative about removed sessions; persisted files can lag.
        if live {
            tasks = tasks.filter { $0.value.source != "ClaudeBar bridge" || keys.contains($0.key) }
        }
    }
}

final class DirectoryWatcher {
    private var source: DispatchSourceFileSystemObject?
    init?(path: String, queue: DispatchQueue, changed: @escaping () -> Void) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
            eventMask: [.write, .rename, .delete], queue: queue)
        s.setEventHandler(handler: changed)
        s.setCancelHandler { close(fd) }
        s.resume(); source = s
    }
    deinit { source?.cancel() }
}

enum HookInput {
    static func automaticReviewer() -> Bool {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex"
        guard let text = try? String(contentsOfFile: home + "/config.toml", encoding: .utf8) else { return false }
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { break }
            if line.hasPrefix("approvals_reviewer"), let eq = line.firstIndex(of: "=") {
                let value = line[line.index(after: eq)...].split(separator: "#", maxSplits: 1).first?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                return value == "guardian_subagent"
            }
        }
        return false
    }

    static func normalize(_ d: [String: Any], provider: String) -> HookEvent? {
        guard let session = d["session_id"] as? String, !session.isEmpty,
              let name = d["hook_event_name"] as? String else { return nil }
        let actor = (d["agent_id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "main"
        // Subagent start/stop hooks can carry the parent's transcript_path.
        // Only a dedicated child transcript may recover a child independently.
        let transcript = actor == "main" ? d["transcript_path"] : d["agent_transcript_path"]
        let background = (d["background_tasks"] as? [[String: Any]] ?? []).compactMap { task -> String? in
            guard ["running", "pending"].contains(task["status"] as? String ?? "") else { return nil }
            return task["id"] as? String ?? task["task_id"] as? String
        }
        let cwd = d["cwd"] as? String ?? ""
        let env = ProcessInfo.processInfo.environment
        return HookEvent(provider: provider, session: session, actor: actor, name: name,
            turn: d["turn_id"] as? String, tool: d["tool_name"] as? String ?? "",
            toolID: d["tool_use_id"] as? String ?? "", notification: d["notification_type"] as? String ?? "",
            label: URL(fileURLWithPath: cwd).lastPathComponent,
            host: env["__CFBundleIdentifier"] ?? env["TERM_PROGRAM"] ?? "",
            owner: Owner.agentAncestor(provider: provider), background: background,
            autoReview: (d["auto_review"] as? Bool) ?? (provider == "codex" && name == "PermissionRequest" && automaticReviewer()),
            transcriptPath: (transcript as? String).flatMap {
                $0.hasPrefix("/") && $0.hasSuffix(".jsonl") ? $0 : nil
            })
    }
}

enum Paths {
    static var data: URL {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--data"), args.count > i + 1 {
            return URL(fileURLWithPath: args[i + 1], isDirectory: true)
        }
        let env = ProcessInfo.processInfo.environment
        if let p = env["NIGHTSHIFT_DATA"] ?? env["CAFFEINE_DATA"] {
            return URL(fileURLWithPath: p, isDirectory: true)
        }
        // Portable by default: no hidden changes to global agent configuration.
        let parent = Bundle.main.bundleURL.deletingLastPathComponent()
        let current = parent.appendingPathComponent("Nightshift Data", isDirectory: true)
        let legacy = parent.appendingPathComponent("Caffeine Data", isDirectory: true)
        if !FileManager.default.fileExists(atPath: current.path),
           FileManager.default.fileExists(atPath: legacy.path) {
            do { try FileManager.default.moveItem(at: legacy, to: current) }
            catch { return legacy } // Keep existing state accessible if migration fails.
        }
        return current
    }
    static var feed: URL {
        let env = ProcessInfo.processInfo.environment
        return URL(fileURLWithPath: env["NIGHTSHIFT_FEED"] ?? env["CAFFEINE_FEED"] ??
            NSHomeDirectory() + "/Library/Application Support/Claudebar/sessions.json")
    }
    static func prepare(_ root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: root.appendingPathComponent("inbox"),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
}
