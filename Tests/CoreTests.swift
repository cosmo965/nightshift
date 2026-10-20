import Foundation

@main struct CoreTests {
    static var count = 0
    static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else { fatalError("FAIL: " + name) }
        count += 1
    }
    static func event(_ name: String, _ stamp: Double, session: String = "s", actor: String = "main", turn: String? = "t1", tool: String = "", id: String = "") -> HookEvent {
        HookEvent(timestamp: stamp, provider: "codex", session: session, actor: actor, name: name,
                  turn: turn, tool: tool, toolID: id)
    }
    static func main() throws {
        var r = Registry()
        r.apply(event("SessionStart", 1))
        check(r.working.isEmpty, "Opening an app/session doesn't keep awake")
        let start = event("UserPromptSubmit", 2)
        r.apply(start); r.apply(start)
        check(r.working.count == 1, "Repeated event is idempotent")
        r.apply(event("UserPromptSubmit", 3, session: "second"))
        r.apply(event("SubagentStart", 4, actor: "child"))
        r.apply(event("Stop", 5))
        check(r.working.count == 2, "Parent stop preserves independent child and other session")
        r.apply(event("Stop", 6, session: "second"))
        check(r.working.count == 1, "Last child holds wakefulness")
        r.apply(event("SubagentStop", 7, actor: "child"))
        check(r.working.isEmpty, "Last task finishing releases eligibility")
        r.apply(event("PreToolUse", 4, actor: "child", tool: "Bash", id: "late"))
        r.apply(event("PostToolUse", 8, actor: "child", tool: "Bash", id: "late"))
        check(r.working.isEmpty, "Late tool callbacks don't resurrect completed turn")
        r.apply(event("UserPromptSubmit", 9, turn: "t2"))
        r.apply(event("PreToolUse", 10, turn: "t2", tool: "functions.request_user_input", id: "q"))
        check(r.waiting.count == 1 && r.working.isEmpty, "Explicit question releases eligibility")
        r.apply(event("PostToolUse", 11, turn: "t2", tool: "functions.request_user_input", id: "q"))
        check(r.working.count == 1, "Answer resumes work")
        r.apply(event("PreToolUse", 12, turn: "t2", tool: "Bash", id: "one"))
        r.apply(event("PermissionRequest", 13, turn: "t2", tool: "Bash", id: "one"))
        check(r.waiting.count == 1, "Approval wait is detected")
        r.apply(event("PreToolUse", 14, turn: "t2", tool: "Bash", id: "two"))
        check(r.working.count == 1, "Parallel unblocked tool keeps awake during another approval")
        r.apply(event("PostToolUse", 15, turn: "t2", tool: "Bash", id: "two"))
        check(r.waiting.count == 1, "Unrelated tool completion doesn't answer approval")
        r.apply(event("PostToolUse", 16, turn: "t2", tool: "Bash", id: "one"))
        check(r.working.count == 1, "Matching tool completion clears approval")
        r.sweep(now: 8000, alive: { _ in true })
        check(r.working.first?.state == .unknown, "Long silent work stays awake with uncertainty")
        var owned = event("UserPromptSubmit", 8001, session: "owned")
        owned.owner = Owner(pid: 42, birth: 123)
        r.apply(owned); r.sweep(now: 8002, alive: { _ in false })
        check(!r.tasks.values.contains { $0.session == "owned" }, "Dead or reused owner is removed")
        r.apply(event("SessionEnd", 9000))
        r.apply(event("UserPromptSubmit", 8999))
        check(!r.tasks.values.contains { $0.session == "s" }, "Late event cannot revive ended session")
        r.apply(event("UserPromptSubmit", 9001, turn: "t3"))
        check(r.working.count == 1, "New prompt after session boundary can run")
        var background = event("Stop", 9002, turn: "t3")
        background.background = ["worker1", "worker2"]
        r.apply(background)
        check(r.working.count == 2, "Reported queued background tasks keep awake")
        r.apply(event("SessionEnd", 9003))
        check(r.working.isEmpty, "Session end clears owned background tasks")
        var p = WakePolicy()
        check(p.wantsWake(active: true, held: false, now: 1), "First work acquires assertion")
        check(p.wantsWake(active: false, held: true, now: 2), "Last stop starts grace period")
        check(p.wantsWake(active: true, held: true, now: 3), "New queued work cancels release")
        check(p.deadline == nil, "Cancelled grace has no deadline")
        check(p.wantsWake(active: false, held: true, now: 4), "Second stop starts fresh grace")
        check(!p.wantsWake(active: false, held: true, now: 7), "Grace expires")
        let encoded = try JSONEncoder().encode(r)
        let restored = try JSONDecoder().decode(Registry.self, from: encoded)
        check(restored.tasks.count == r.tasks.count, "Restart preserves registry")
        let raw: [String: Any] = ["session_id": "s", "hook_event_name": "PreToolUse", "tool_name": "Bash",
            "prompt": "secret prompt", "tool_input": ["command": "secret command"]]
        let normalized = HookInput.normalize(raw, provider: "codex")!
        let text = String(data: try JSONEncoder().encode(normalized), encoding: .utf8)!
        check(!text.contains("secret"), "No prompt or tool arguments stored")
        check(Registry.isQuestion("functions.request_user_input_async"), "Namespaced input tool recognized")
        let feed = FeedSession(id: "bridge", agent: "codex", cwd: "/a/project", phase: "thinking", lastEventAt: 100)
        r.ingestFeed([feed], now: 9004, live: false)
        check(r.working.count == 1, "Bridge active session is detected")
        r.ingestFeed([], now: 9005, live: true)
        check(r.working.isEmpty, "Live bridge removal reconciles exited sessions")
        r.apply(event("UserPromptSubmit", 9006, session: "bridge", turn: "direct"))
        let idleFeed = FeedSession(id: "bridge", agent: "codex", phase: "done")
        r.ingestFeed([idleFeed], now: 9007, live: true)
        check(r.working.count == 1, "Stale bridge never overwrites direct hooks")
        var load = Registry()
        for i in 0..<1000 {
            load.apply(event("UserPromptSubmit", Double(i), session: "load\(i)"))
        }
        check(load.working.count == 1000, "1000 concurrent task identities remain independent")
        for i in 0..<999 { load.apply(event("Stop", 2000 + Double(i), session: "load\(i)")) }
        check(load.working.count == 1, "999 completions preserve the last task")
        load.apply(event("Stop", 4000, session: "load999"))
        check(load.working.isEmpty, "Final completion removes last wakefulness claim")
        let guardian = HookEvent(timestamp: 10000, provider: "codex", session: "g", name: "PermissionRequest", autoReview: true)
        load.apply(guardian)
        check(load.working.count == 1 && load.waiting.isEmpty, "Automatic review is work, not user input")
        var fallback = Registry()
        fallback.apply(event("UserPromptSubmit", 11000, session: "native"))
        fallback.ingestFeed([FeedSession(id: "supplemental", agent: "claude", phase: "thinking")], now: 11001, live: true)
        check(fallback.working.count == 2, "Optional feed supplements built-in detection")
        fallback.ingestFeed([], now: 11002, live: true)
        check(fallback.working.count == 1 && fallback.working.first?.session == "native", "Missing optional sessions do not clear built-in work")
        fallback.apply(event("Stop", 11003, session: "native"))
        fallback.ingestFeed([FeedSession(id: "native", agent: "codex", phase: "thinking")], now: 11004, live: true)
        check(fallback.working.isEmpty, "Returning optional feed cannot revive completed native work")
        fallback.apply(event("UserPromptSubmit", 11005, session: "native", turn: "new"))
        check(fallback.working.count == 1, "Built-in detection runs without any supplemental feed")
        print("PASS: \(count) lifecycle, concurrency, recovery, privacy, and integration checks")
    }
}
