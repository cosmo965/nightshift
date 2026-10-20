import Foundation
import Darwin

/// Nightshift's own bounded reader. Transcript text is never persisted or displayed.
final class ActivityTranscript {
    private var offset: UInt64?
    private var identity: String?
    private var carry = Data()
    private var droppingLine = false
    private let maxBytes = 1024 * 1024

    func read(_ path: String) -> [Data] {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return [] }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_size >= 0 else { return [] }
        let size = UInt64(info.st_size)
        let id = "\(info.st_dev):\(info.st_ino)"
        if identity != id || size < (offset ?? 0) {
            identity = id; offset = nil; carry.removeAll(); droppingLine = false
        }
        if offset == nil {
            offset = size > 256 * 1024 ? size - 256 * 1024 : 0
            droppingLine = offset! > 0
        }
        guard let start = offset, size > start,
              (try? handle.seek(toOffset: start)) != nil,
              let chunk = try? handle.read(upToCount: Int(min(size - start, UInt64(maxBytes)))),
              !chunk.isEmpty else { return [] }
        offset = start + UInt64(chunk.count)
        carry.append(chunk)
        var lines: [Data] = []
        var begin = carry.startIndex
        while let end = carry[begin...].firstIndex(of: 0x0A) {
            if droppingLine { droppingLine = false }
            else if end - begin <= maxBytes { lines.append(carry.subdata(in: begin..<end)) }
            begin = end + 1
        }
        carry = carry.subdata(in: begin..<carry.endIndex)
        if carry.count > maxBytes { carry.removeAll(); droppingLine = true }
        return lines
    }
}

enum TranscriptActivity {
    static func completion(in lines: [Data], provider: String) -> TranscriptCompletion? {
        for line in lines.reversed() {
            guard let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  entry["isSidechain"] as? Bool != true else { continue }
            let kind = entry["type"] as? String ?? ""
            let payload = entry["payload"] as? [String: Any] ?? [:]
            var interrupted = false
            if provider == "codex" {
                guard kind == "event_msg" else { continue }
                let event = payload["type"] as? String ?? ""
                if ["task_started", "turn_started"].contains(event) { return nil }
                guard ["task_complete", "task_completed", "turn_complete", "turn_completed", "turn_aborted"].contains(event) else { continue }
                interrupted = event == "turn_aborted"
            } else if provider == "claude" {
                let message = entry["message"] as? [String: Any] ?? [:]
                if kind == "user" {
                    let content = message["content"]
                    let text = content as? String
                    let blocks = content as? [[String: Any]] ?? []
                    interrupted = text?.hasPrefix("[Request interrupted by user") == true || blocks.contains {
                        ($0["text"] as? String)?.hasPrefix("[Request interrupted by user") == true
                    }
                    // New user input after a completion fences that older turn.
                    if !interrupted { return nil }
                } else if kind == "assistant" {
                    guard let reason = message["stop_reason"] as? String else { return nil }
                    // Only explicit terminal reasons can release a wake assertion.
                    guard ["end_turn", "stop_sequence", "max_tokens", "refusal"].contains(reason) else { return nil }
                } else { continue }
            } else { return nil }
            guard let timestamp = timestamp(entry["timestamp"]), timestamp.isFinite else { return nil }
            return TranscriptCompletion(timestamp: timestamp,
                turn: payload["turn_id"] as? String ?? entry["turn_id"] as? String,
                interrupted: interrupted)
        }
        return nil
    }

    private static func timestamp(_ raw: Any?) -> Double? {
        guard let text = raw as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date.timeIntervalSince1970 }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)?.timeIntervalSince1970
    }
}

/// Access from the app's serial I/O queue only.
final class AgentDetection {
    private var readers: [String: (String, ActivityTranscript)] = [:]

    func recoveries(for tasks: [TaskRecord]) -> [(TaskRecord, TranscriptCompletion)] {
        let eligible = tasks.filter { $0.source == "direct hook" && ($0.state == .working || $0.state == .unknown) && $0.transcriptPath != nil }
        let keys = Set(eligible.map(\.key))
        readers = readers.filter { keys.contains($0.key) }
        return eligible.compactMap { task in
            let path = task.transcriptPath!
            if readers[task.key]?.0 != path { readers[task.key] = (path, ActivityTranscript()) }
            let lines = readers[task.key]!.1.read(path)
            guard let result = TranscriptActivity.completion(in: lines, provider: task.provider) else { return nil }
            return (task, result)
        }
    }
}
