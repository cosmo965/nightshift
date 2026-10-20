import Foundation

@main struct DetectionTests {
    static var count = 0
    static func check(_ value: @autoclosure () -> Bool, _ name: String) {
        guard value() else { fatalError("FAIL: " + name) }
        count += 1
    }
    static func line(_ entry: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
    }
    static func codex(_ kind: String, at time: Int = 102, turn: String = "turn-1") -> Data {
        line(["type": "event_msg", "timestamp": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(time))),
              "payload": ["type": kind, "turn_id": turn]])
    }
    static func claude(_ reason: String, sidechain: Bool = false) -> Data {
        line(["type": "assistant", "timestamp": "1970-01-01T00:01:42.000Z", "isSidechain": sidechain,
              "message": ["stop_reason": reason, "content": "PRIVATE TRANSCRIPT TEXT"]])
    }
    static func main() throws {
        let done = codex("task_complete")
        check(TranscriptActivity.completion(in: [done], provider: "codex")?.timestamp == 102, "Codex completion timestamp")
        check(TranscriptActivity.completion(in: [done, codex("task_started", at: 103)], provider: "codex") == nil, "New turn fences old completion")
        check(TranscriptActivity.completion(in: [codex("turn_aborted")], provider: "codex")?.interrupted == true, "Codex interrupt")
        check(TranscriptActivity.completion(in: [claude("end_turn")], provider: "claude") != nil, "Claude completion")
        check(TranscriptActivity.completion(in: [claude("tool_use")], provider: "claude") == nil, "Tool call is ongoing work")
        check(TranscriptActivity.completion(in: [claude("pause_turn")], provider: "claude") == nil, "Pause-turn is not completion")
        check(TranscriptActivity.completion(in: [claude("end_turn", sidechain: true)], provider: "claude") == nil, "Sidechain cannot end parent")
        let user = line(["type": "user", "timestamp": "1970-01-01T00:01:43Z", "message": ["content": "A new prompt"]])
        check(TranscriptActivity.completion(in: [claude("end_turn"), user], provider: "claude") == nil, "Claude user input fences old completion")
        let interrupt = line(["type": "user", "timestamp": "1970-01-01T00:01:43Z", "message": ["content": [["type": "text", "text": "[Request interrupted by user]"]]]])
        check(TranscriptActivity.completion(in: [interrupt], provider: "claude")?.interrupted == true, "Claude interruption marker")
        check(TranscriptActivity.completion(in: [line(["type": "event_msg", "payload": ["type": "task_complete"]])], provider: "codex") == nil, "Undated events cannot release work")
        check(TranscriptActivity.completion(in: [done], provider: "custom") == nil, "Unsupported transcripts don't guess")

        var registry = Registry()
        var start = HookEvent(timestamp: 100, provider: "codex", session: "s", name: "UserPromptSubmit", turn: "turn-1")
        start.transcriptPath = "/fixture/session.jsonl"
        registry.apply(start)
        let snapshot = registry.tasks["codex:s:main"]!
        registry.apply(HookEvent(timestamp: 101, provider: "codex", session: "s", actor: "child", name: "SubagentStart"))
        registry.recover(TranscriptCompletion(timestamp: 99, turn: "turn-1", interrupted: false), for: snapshot)
        check(registry.working.count == 2, "Older terminal record cannot end current work")
        registry.recover(TranscriptCompletion(timestamp: 102, turn: "other-turn", interrupted: false), for: snapshot)
        check(registry.working.count == 2, "Wrong turn cannot release work")
        registry.recover(TranscriptCompletion(timestamp: 102, turn: "turn-1", interrupted: false), for: snapshot)
        check(registry.working.count == 1 && registry.working.first?.actor == "child", "Recovered parent preserves active subagent")
        var newer = start; newer.id = UUID().uuidString; newer.timestamp = 103; newer.turn = "turn-2"
        registry.apply(newer)
        registry.recover(TranscriptCompletion(timestamp: 104, turn: nil, interrupted: false), for: snapshot)
        check(registry.tasks[snapshot.key]?.state == .working, "Concurrent hooks invalidate recovery snapshot")
        let restored = try JSONDecoder().decode(Registry.self, from: JSONEncoder().encode(registry))
        check(restored.tasks[snapshot.key]?.transcriptPath == start.transcriptPath, "Transcript attachment survives app restart")
        let event = HookInput.normalize(["session_id": "private", "hook_event_name": "UserPromptSubmit",
            "transcript_path": "/fixture/session.jsonl", "prompt": "PRIVATE"], provider: "claude")!
        let encoded = String(data: try JSONEncoder().encode(event), encoding: .utf8)!
        check(event.transcriptPath == "/fixture/session.jsonl" && !encoded.contains("PRIVATE"), "Hooks keep transcript path without conversation text")
        let child = HookInput.normalize(["session_id": "parent", "hook_event_name": "SubagentStart", "agent_id": "child",
            "transcript_path": "/fixture/parent.jsonl"], provider: "claude")!
        check(child.transcriptPath == nil, "A child never recovers from its parent's transcript")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("session.jsonl")
        let tail = ActivityTranscript()
        try done.write(to: file)
        check(tail.read(file.path).isEmpty, "Partial final JSON line waits for newline")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: Data([0x0A])); try handle.close()
        check(tail.read(file.path) == [done], "Appending newline completes buffered record")
        check(tail.read(file.path).isEmpty, "Unchanged transcripts aren't reread")
        let abort = codex("turn_aborted") + Data([0x0A])
        try abort.write(to: file, options: .atomic)
        check(tail.read(file.path) == [Data(abort.dropLast())], "Atomic file replacement restarts tail")
        let link = folder.appendingPathComponent("link.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        check(ActivityTranscript().read(link.path).isEmpty, "Transcript reader rejects symlinks")
        let huge = Data(repeating: 65, count: 2 * 1024 * 1024) + Data([0x0A]) + done + Data([0x0A])
        try huge.write(to: file, options: .atomic)
        check(ActivityTranscript().read(file.path) == [done], "Initial window skips oversized partial line")
        var fixture = snapshot; fixture.transcriptPath = file.path
        let detection = AgentDetection()
        check(detection.recoveries(for: [fixture]).count == 1, "Built-in engine recovers without ClaudeBar")
        print("PASS: \(count) built-in detection and transcript recovery checks")
    }
}
