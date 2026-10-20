import Foundation
import Darwin

enum WorkState: String, Codable { case working, waiting, idle, unknown }

struct TranscriptCompletion {
    var timestamp: Double
    var turn: String?
    var interrupted: Bool
}

struct Owner: Codable, Equatable {
    var pid: Int32
    var birth: UInt64
    static func capture(_ pid: Int32) -> Owner? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 1, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Owner(pid: pid, birth: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec)
    }
    var alive: Bool {
        if let current = Self.capture(pid) { return current == self }
        // A permission failure is not proof the owner died.
        return kill(pid, 0) == 0 || errno != ESRCH
    }
    static func agentAncestor(provider: String) -> Owner? {
        var pid = getppid()
        for _ in 0..<12 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard pid > 1, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { break }
            var bytes = [CChar](repeating: 0, count: 4096)
            if proc_pidpath(pid, &bytes, UInt32(bytes.count)) > 0 {
                let name = URL(fileURLWithPath: String(cString: bytes)).lastPathComponent.lowercased()
                if name == provider || name.hasPrefix(provider + "-") { return capture(pid) }
            }
            pid = Int32(info.pbi_ppid)
        }
        return nil
    }
}

struct TaskRecord: Codable, Equatable {
    var key: String
    var session: String
    var actor: String
    var provider: String
    var label: String
    var host: String
    var state: WorkState
    var source: String
    var updated: Double
    var turn: String?
    var owner: Owner?
    var pending: Set<String> = []
    var tools: Set<String> = []
    var finishedTools: Set<String> = []
    var reason: String = ""
    var transcriptPath: String?
}

struct HookEvent: Codable {
    var id: String = UUID().uuidString
    var timestamp: Double = Date().timeIntervalSince1970
    var provider: String
    var session: String
    var actor: String = "main"
    var name: String
    var turn: String?
    var tool: String = ""
    var toolID: String = ""
    var notification: String = ""
    var label: String = ""
    var host: String = ""
    var owner: Owner?
    var background: [String] = []
    var autoReview: Bool = false
    var transcriptPath: String?
}

/// All mutations are serialized by the application on its main queue.
/// Task keys, rather than a +/- counter, make repeated events idempotent.
struct Registry: Codable {
    var tasks: [String: TaskRecord] = [:]
    var seen: [String] = []
    var endedSessions: [String: Double] = [:]
    var warning: String = ""
    var working: [TaskRecord] { tasks.values.filter { $0.state == .working || $0.state == .unknown } }
    var waiting: [TaskRecord] { tasks.values.filter { $0.state == .waiting } }

    mutating func apply(_ e: HookEvent) {
        guard !e.session.isEmpty, !seen.contains(e.id) else { return }
        seen.append(e.id)
        if seen.count > 2048 { seen.removeFirst(seen.count - 2048) }
        let prefix = e.provider + ":" + e.session + ":"
        if let end = endedSessions[prefix], e.timestamp <= end { return }
        let key = prefix + e.actor
        if e.name == "SessionEnd" {
            endedSessions[prefix] = e.timestamp
            tasks = tasks.filter { !$0.key.hasPrefix(prefix) || $0.value.updated > e.timestamp }
            return
        }
        var t = tasks[key] ?? TaskRecord(key: key, session: e.session, actor: e.actor,
            provider: e.provider, label: e.label, host: e.host, state: .idle,
            source: "direct hook", updated: 0)
        guard e.timestamp >= t.updated else { return }
        // A delayed tool event must not revive a turn that already stopped.
        let sameTurn = e.turn != nil && t.turn == e.turn
        if t.state == .idle && sameTurn && !["UserPromptSubmit", "SubagentStart", "SessionStart"].contains(e.name) { return }
        if let turn = e.turn, t.turn != turn {
            t.pending = []; t.tools = []; t.finishedTools = []
            t.turn = turn
        }
        t.updated = e.timestamp
        t.source = "direct hook"
        if !e.label.isEmpty { t.label = e.label }
        if !e.host.isEmpty { t.host = e.host }
        if let owner = e.owner { t.owner = owner }
        if let path = e.transcriptPath { t.transcriptPath = path }
        let token = e.toolID.isEmpty ? e.tool : e.toolID
        switch e.name {
        case "SessionStart": break // An open session is not active work.
        case "UserPromptSubmit", "SubagentStart":
            t.state = .working; t.pending = []; t.tools = []; t.finishedTools = []; t.reason = "Running"
        case "PreToolUse":
            if !token.isEmpty && t.finishedTools.contains(token) { return }
            if !token.isEmpty { t.tools.insert(token) }
            if Self.isQuestion(e.tool) {
                t.pending.insert(token); t.reason = "Awaiting your answer"
            }
            t.state = t.pending.isEmpty || !t.tools.subtracting(t.pending).isEmpty ? .working : .waiting
        case "PermissionRequest", "Elicitation":
            if !e.autoReview { t.pending.insert(token.isEmpty ? "approval" : token) }
            t.state = t.pending.isEmpty || !t.tools.subtracting(t.pending).isEmpty ? .working : .waiting
            t.reason = e.autoReview ? "Automatic approval review" : "Awaiting approval or input"
        case "PostToolUse", "PostToolUseFailure", "PermissionDenied", "ElicitationResult":
            if !token.isEmpty {
                t.tools.remove(token); t.finishedTools.insert(token); t.pending.remove(token)
            }
            if t.tools.isEmpty || e.name == "ElicitationResult" { t.pending.remove("approval") }
            t.state = t.pending.isEmpty || !t.tools.subtracting(t.pending).isEmpty ? .working : .waiting
            t.reason = t.pending.isEmpty ? "Running" : "Awaiting your answer"
        case "Notification":
            if ["permission_prompt", "elicitation_dialog", "idle_prompt"].contains(e.notification) {
                t.pending.insert("approval"); t.state = .waiting; t.reason = "Awaiting your input"
            }
        case "PreCompact", "PostCompact": t.state = .working; t.reason = "Compacting / continuing"
        case "Stop", "SubagentStop", "StopFailure", "Interrupt":
            t.state = .idle; t.pending = []; t.tools = []; t.reason = e.name
            // Children are independent and deliberately survive parent Stop.
        default: return
        }
        tasks[key] = t
        if e.name == "Stop", e.actor == "main" {
            // A host that supplies background_tasks can keep pending work awake.
            for id in e.background {
                let childKey = prefix + "background/" + id
                tasks[childKey] = TaskRecord(key: childKey, session: e.session, actor: "background/" + id,
                    provider: e.provider, label: t.label, host: t.host, state: .working,
                    source: "direct hook", updated: e.timestamp, owner: t.owner, reason: "Background task")
            }
            let active = Set(e.background.map { prefix + "background/" + $0 })
            for k in Array(tasks.keys) where k.hasPrefix(prefix + "background/") && !active.contains(k) {
                tasks[k]?.state = .idle
            }
        }
    }

    static func isQuestion(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.contains("request_user_input") || n.contains("requestuserinput") || n.contains("askuserquestion") || n == "exitplanmode"
    }

    mutating func recover(_ result: TranscriptCompletion, for snapshot: TaskRecord) {
        guard var current = tasks[snapshot.key], current.updated == snapshot.updated,
              current.transcriptPath == snapshot.transcriptPath,
              current.state == .working || current.state == .unknown,
              result.timestamp >= current.updated,
              result.turn == nil || current.turn == nil || result.turn == current.turn else { return }
        current.state = .idle
        current.pending = []; current.tools = []
        current.updated = result.timestamp
        current.reason = result.interrupted ? "Interrupted (recovered from transcript)" : "Completed (recovered from transcript)"
        // A parent completion must not discard independently running subagents.
        tasks[snapshot.key] = current
    }

    mutating func sweep(now: Double, alive: (Owner) -> Bool = { $0.alive }) {
        for k in Array(tasks.keys) {
            guard var t = tasks[k] else { continue }
            if let owner = t.owner, !alive(owner) { tasks.removeValue(forKey: k); continue }
            if t.state == .idle && now - t.updated > 3600 { tasks.removeValue(forKey: k); continue }
            if t.state == .working && now - t.updated > 3600 {
                // Silence does not prove completion. Preserve wakefulness and expose uncertainty.
                t.state = .unknown; t.reason = "No event for an hour; verify or dismiss"
                tasks[k] = t
            }
        }
    }
}

struct WakePolicy {
    var grace: Double = 3
    var deadline: Double?
    mutating func wantsWake(active: Bool, held: Bool, now: Double) -> Bool {
        if active { deadline = nil; return true }
        guard held else { deadline = nil; return false }
        if deadline == nil { deadline = now + grace }
        if now < deadline! { return true }
        deadline = nil
        return false
    }
}
