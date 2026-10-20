import AppKit
import IOKit.pwr_mgt
import Darwin

final class PowerAssertion {
    private(set) var id: IOPMAssertionID = 0
    private(set) var held = false
    private(set) var error: String?
    func set(_ needed: Bool) {
        guard needed != held else { return }
        if needed {
            let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn), "Nightshift: agents are working" as CFString, &id)
            if result == kIOReturnSuccess { held = true; error = nil }
            else { error = "Cannot prevent sleep (IOKit \(result))" }
        } else {
            let result = IOPMAssertionRelease(id)
            if result == kIOReturnSuccess { held = false; id = 0; error = nil }
            else { error = "Could not release assertion (IOKit \(result))" }
        }
    }
    deinit { if held { IOPMAssertionRelease(id) } }
}

final class NightshiftApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let power = PowerAssertion()
    private let lid = ClosedLid()
    private var registry = Registry()
    private var policy = WakePolicy()
    private let root = Paths.data
    private let io = DispatchQueue(label: "Nightshift.io", qos: .utility)
    private var watchers: [DirectoryWatcher] = []
    private var timer: Timer?
    private var transcriptTimer: Timer?
    private let detector = AgentDetection()
    private var recovering = false
    private var installingDetection = false
    private var setupPresented = false
    private var release: DispatchWorkItem?
    private var paused = false
    private var manualUntil: Date?
    private var bridgeMessage = "Optional ClaudeBar feed: off"
    private var bridgeLive = false
    private var feedIsFresh = false
    private var bridgeGeneration = 0
    private var fetching = false
    private var feedStamp: Date?
    private var lastStatus = Data()
    private var lastState = Data()
    private var lockFD: Int32 = -1
    private var dismissals: [String: Double] = [:]
    private var bridgeEnabled = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try Paths.prepare(root)
            lockFD = open(root.appendingPathComponent("app.lock").path, O_CREAT | O_RDWR, 0o600)
            guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { NSApp.terminate(nil); return }
        } catch { show("Cannot start Nightshift", error.localizedDescription); NSApp.terminate(nil); return }
        if let d = try? Data(contentsOf: root.appendingPathComponent("registry.json")),
           let saved = try? JSONDecoder().decode(Registry.self, from: d) { registry = saved }
        registry.sweep(now: Date().timeIntervalSince1970)
        // Restored records lacking a process identity are uncertain, never silently assumed finished.
        for k in Array(registry.tasks.keys) where registry.tasks[k]?.owner == nil && registry.tasks[k]?.state == .working {
            registry.tasks[k]?.state = .unknown
            registry.tasks[k]?.reason = "Restored; waiting for a fresh event"
        }
        if let d = try? Data(contentsOf: root.appendingPathComponent("settings.json")),
           let settings = try? JSONSerialization.jsonObject(with: d) as? [String: Bool] {
            bridgeEnabled = settings["bridgeEnabled"] ?? false
            lid.enabled = settings["closedLidEnabled"] ?? true
            setupPresented = settings["setupPresented"] ?? false
        }
        if !bridgeEnabled { registry.tasks = registry.tasks.filter { $0.value.source != "ClaudeBar bridge" } }
        menu.delegate = self; item.menu = menu
        drainInbox(); readFeed(force: true); fetchLive()
        watch(root.appendingPathComponent("inbox").path) { [weak self] in self?.drainInbox() }
        watch(Paths.feed.deletingLastPathComponent().path) { [weak self] in
            self?.readFeed(); self?.fetchLive()
        }
        // Low-frequency reconciliation handles dead owners and missed filesystem notifications.
        let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in self?.reconcile() }
        t.tolerance = 3; RunLoop.main.add(t, forMode: .common); timer = t
        let transcripts = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.recoverTranscripts() }
        transcripts.tolerance = 0.5
        RunLoop.main.add(transcripts, forMode: .common); transcriptTimer = transcripts
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
        update()
        recoverTranscripts()
        if !setupPresented {
            DispatchQueue.main.async { [weak self] in self?.installDetection() }
        }
    }

    private func watch(_ path: String, action: @escaping () -> Void) {
        if let w = DirectoryWatcher(path: path, queue: .main, changed: action) { watchers.append(w) }
    }

    private func drainInbox() {
        let inbox = root.appendingPathComponent("inbox")
        io.async {
            let files = (try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? []
            let entries: [(URL, HookEvent?)] = files.filter { $0.pathExtension == "json" }.map { url in
                let e = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(HookEvent.self, from: $0) }
                return (url, e)
            }
            DispatchQueue.main.async {
                for (_, e) in entries.sorted(by: { ($0.1?.timestamp ?? 0) < ($1.1?.timestamp ?? 0) }) {
                    if let e { self.registry.apply(e) }
                    else { self.registry.warning = "An unreadable hook event was skipped" }
                }
                self.update()
                // Save before acknowledging events. Replay after a crash is idempotent.
                if self.encodedRegistry() == self.lastState {
                    for (url, _) in entries { try? FileManager.default.removeItem(at: url) }
                }
            }
        }
    }

    private func readFeed(force: Bool = false) {
        guard bridgeEnabled else { return }
        let path = Paths.feed
        let stamp = (try? FileManager.default.attributesOfItem(atPath: path.path)[.modificationDate]) as? Date
        let fresh = stamp.map { (0...30).contains(Date().timeIntervalSince($0)) } ?? false
        guard force || stamp != feedStamp || (feedIsFresh && !fresh) else { return }
        feedStamp = stamp
        let generation = bridgeGeneration
        io.async {
            let result: Result<[FeedSession], Error> = Result {
                try JSONDecoder().decode([FeedSession].self, from: Data(contentsOf: path))
            }
            DispatchQueue.main.async {
                guard self.bridgeEnabled, generation == self.bridgeGeneration else { return }
                switch result {
                case .success(let rows):
                    self.feedIsFresh = stamp.map { (0...30).contains(Date().timeIntervalSince($0)) } ?? false
                    if self.feedIsFresh && !self.bridgeLive {
                        self.registry.ingestFeed(rows, now: Date().timeIntervalSince1970, live: false)
                    }
                case .failure:
                    self.feedIsFresh = false
                }
                self.updateBridgeMessage()
                self.update()
            }
        }
    }

    private func fetchLive() {
        guard bridgeEnabled, !fetching else { return }
        fetching = true
        let generation = bridgeGeneration
        let port = UInt16(ProcessInfo.processInfo.environment["CLAUDEBAR_PORT"] ?? "47823") ?? 47823
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/state")!)
        request.timeoutInterval = 2
        // No cloud endpoints, cookies, credentials, or prompt storage.
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config)
        session.dataTask(with: request) { data, response, _ in
            session.finishTasksAndInvalidate()
            let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let rows = (object?["sessions"] as? [[String: Any]]).flatMap {
                try? JSONDecoder().decode([FeedSession].self, from: JSONSerialization.data(withJSONObject: $0))
            }
            DispatchQueue.main.async {
                guard self.bridgeEnabled, generation == self.bridgeGeneration else { return }
                self.fetching = false
                if let rows, (response as? HTTPURLResponse)?.statusCode == 200 {
                    self.registry.ingestFeed(rows, now: Date().timeIntervalSince1970, live: true)
                    self.bridgeLive = true
                } else { self.bridgeLive = false }
                self.updateBridgeMessage()
                self.update()
            }
        }.resume()
    }

    private func updateBridgeMessage() {
        if !bridgeEnabled { bridgeMessage = "ClaudeBar detection: off — using built-in detection" }
        else if bridgeLive { bridgeMessage = "ClaudeBar detection: connected alongside built-in detection" }
        else if feedIsFresh { bridgeMessage = "ClaudeBar detection: fresh saved feed; built-in detection remains active" }
        else {
            bridgeMessage = "ClaudeBar unavailable — using built-in detection. Enable it with Set up agent detection… if needed."
            if registry.tasks.values.contains(where: { $0.source == "ClaudeBar bridge" && ($0.state == .working || $0.state == .unknown) }) {
                bridgeMessage += " Previously reported work is retained until confirmed finished or dismissed."
            }
        }
    }

    private func reconcile() {
        registry.sweep(now: Date().timeIntervalSince1970)
        drainInbox(); recoverTranscripts(); readFeed(); fetchLive(); update()
    }

    private func recoverTranscripts() {
        guard !recovering else { return }
        recovering = true
        let snapshot = Array(registry.tasks.values)
        io.async {
            let completions = self.detector.recoveries(for: snapshot)
            DispatchQueue.main.async {
                self.recovering = false
                for (task, result) in completions { self.registry.recover(result, for: task) }
                if !completions.isEmpty { self.update() }
            }
        }
    }

    private var detectionMessage: String {
        if installingDetection { return "Agent detection: setting up…" }
        let events = registry.tasks.values.filter { $0.source == "direct hook" }
        guard let last = events.map(\.updated).max() else { return "Agent detection: no events yet — set up below" }
        let date = DateFormatter.localizedString(from: Date(timeIntervalSince1970: last), dateStyle: .short, timeStyle: .short)
        return "Built-in detection · last event \(date)"
    }
    @objc private func woke() { reconcile() }

    private var visibleTasks: [TaskRecord] {
        registry.tasks.values.filter { t in
            guard t.state != .idle else { return false }
            return (dismissals[t.key] ?? -.infinity) < t.updated
        }.sorted { $0.key < $1.key }
    }
    private var active: [TaskRecord] { visibleTasks.filter { $0.state == .working || $0.state == .unknown } }
    private var waiting: [TaskRecord] { visibleTasks.filter { $0.state == .waiting } }
    private var overrideOn: Bool { manualUntil.map { $0 > Date() } ?? false }

    private func update() {
        let want = !paused && (!active.isEmpty || overrideOn)
        let now = Date().timeIntervalSince1970
        if paused { policy.deadline = nil; power.set(false) }
        else { power.set(policy.wantsWake(active: want, held: power.held, now: now)) }
        lid.sync(awake: power.held)
        release?.cancel(); release = nil
        if let deadline = policy.deadline {
            let w = DispatchWorkItem { [weak self] in self?.update() }
            release = w; DispatchQueue.main.asyncAfter(deadline: .now() + max(0.01, deadline - now), execute: w)
        }
        let headline: String
        let color: NSColor
        if power.error != nil { headline = "Sleep prevention error"; color = .systemYellow }
        else if paused { headline = "Paused — normal sleep allowed"; color = .systemRed }
        else if power.held && lid.enabled && !lid.confirmed { headline = "Keeping watch — closed-lid protection unconfirmed"; color = .systemYellow }
        else if !power.held && lid.restoring { headline = "Restoring closed-lid sleep settings"; color = .systemYellow }
        else if power.held { headline = active.isEmpty && !overrideOn ? "Finishing — releasing wakefulness" : "Keeping watch"; color = .systemGreen }
        else if !waiting.isEmpty { headline = "Awaiting your answer — normal sleep allowed"; color = .systemYellow }
        else { headline = "Idle — normal sleep allowed"; color = .systemRed }
        item.button?.image = Self.owl(color)
        item.button?.toolTip = "Nightshift: \(headline)\n\(active.count) working · \(waiting.count) waiting\n\(lid.message)\n\(detectionMessage)"
        item.button?.setAccessibilityLabel("Nightshift: \(headline)")
        save(headline)
    }

    private func save(_ headline: String) {
        if let d = encodedRegistry(), d != lastState {
            do { try d.write(to: root.appendingPathComponent("registry.json"), options: .atomic); lastState = d }
            catch { registry.warning = "Cannot save task state: \(error.localizedDescription)" }
        }
        let rows = visibleTasks.map { t -> [String: Any] in
            ["key": t.key, "label": t.label, "state": t.state.rawValue, "source": t.source,
             "host": t.host, "reason": t.reason, "ownerPID": t.owner?.pid ?? 0]
        }
        let object: [String: Any] = ["status": headline, "assertionHeld": power.held,
            "working": active.count, "waiting": waiting.count, "paused": paused,
            "detection": detectionMessage, "detectionMode": "built-in hooks + transcript recovery",
            "bridge": bridgeMessage, "closedLidEnabled": lid.enabled, "closedLidConfirmed": lid.confirmed,
            "closedLid": lid.message, "warning": registry.warning, "tasks": rows]
        if let d = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]), d != lastStatus {
            try? d.write(to: root.appendingPathComponent("status.json"), options: .atomic); lastStatus = d
        }
    }

    private func encodedRegistry() -> Data? {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(registry)
    }

    static func owl(_ color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 23, height: 20), flipped: false) { _ in
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: 3, y: 1, width: 17, height: 16), xRadius: 7, yRadius: 7).fill()
            for (outer, inner) in [(3.0, 9.0), (20.0, 14.0)] {
                let ear = NSBezierPath()
                ear.move(to: NSPoint(x: outer, y: 19))
                ear.line(to: NSPoint(x: outer, y: 12))
                ear.line(to: NSPoint(x: inner, y: 15))
                ear.close(); ear.fill()
            }
            NSColor.white.setFill()
            for x in [4.5, 11.5] {
                NSBezierPath(ovalIn: NSRect(x: x, y: 7, width: 7, height: 8)).fill()
            }
            NSColor(white: 0.12, alpha: 1).setFill()
            for x in [7.0, 14.0] {
                NSBezierPath(ovalIn: NSRect(x: x, y: 9.5, width: 2.5, height: 3.5)).fill()
            }
            let beak = NSBezierPath()
            beak.move(to: NSPoint(x: 10, y: 7))
            beak.line(to: NSPoint(x: 13, y: 7))
            beak.line(to: NSPoint(x: 11.5, y: 4.5))
            beak.close(); beak.fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    func menuWillOpen(_ menu: NSMenu) {
        lid.refresh(requested: power.held && lid.enabled)
        menu.removeAllItems()
        func action(_ text: String, _ selector: Selector, in parent: NSMenu, checked: Bool? = nil) {
            let i = NSMenuItem(title: text, action: selector, keyEquivalent: "")
            i.target = self
            if let checked { i.state = checked ? .on : .off }
            parent.addItem(i)
        }
        func group(_ title: String) -> NSMenu {
            let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let sub = NSMenu(title: title)
            i.submenu = sub; menu.addItem(i)
            return sub
        }
        action("Status & details…", #selector(showStatus), in: menu)
        menu.addItem(.separator())

        let tasks = visibleTasks.isEmpty ? nil : group("Tasks (\(visibleTasks.count))")
        for t in visibleTasks {
            let state = t.state == .working ? "Working" : t.state == .waiting ? "Waiting" : "Uncertain (kept awake)"
            let title = "\(state) · \(t.provider) · \(t.label.isEmpty ? String(t.session.prefix(8)) : t.label)"
            let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let sub = NSMenu()
            let details = NSMenuItem(title: "View task details…", action: #selector(showTaskDetails(_:)), keyEquivalent: "")
            details.target = self; details.representedObject = t.key; sub.addItem(details)
            let dismiss = NSMenuItem(title: "Ignore this task until its next event", action: #selector(dismissTask(_:)), keyEquivalent: "")
            dismiss.target = self; dismiss.representedObject = t.key; sub.addItem(dismiss)
            i.submenu = sub; tasks?.addItem(i)
        }

        let wake = group("Wakefulness")
        action(paused ? "Resume automatic wakefulness" : "Pause automatic wakefulness", #selector(togglePause), in: wake)
        action(overrideOn ? "End manual keep-awake" : "Keep awake for 1 hour", #selector(toggleManual), in: wake)
        wake.addItem(.separator())
        action("Closed-lid protection", #selector(toggleLid), in: wake, checked: lid.enabled)
        action("Closed-lid helper setup…", #selector(setup), in: wake)

        let integrations = group("Agent Detection")
        action("Set up agent detection…", #selector(installDetection), in: integrations)
        action("Refresh sources", #selector(refresh), in: integrations)
        action("Detection setup guide…", #selector(setup), in: integrations)
        integrations.addItem(.separator())
        action("Use ClaudeBar detection (optional)", #selector(toggleBridge), in: integrations, checked: bridgeEnabled)

        let help = group("Help & Diagnostics")
        action("Open diagnostics folder", #selector(diagnostics), in: help)
        action("Open Login Items settings…", #selector(loginSettings), in: help)
        action("About & limitations…", #selector(about), in: help)
        menu.addItem(.separator())
        action("Quit Nightshift", #selector(quit), in: menu)
    }

    @objc private func showStatus() {
        let snapshot = (try? JSONSerialization.jsonObject(with: lastStatus)) as? [String: Any]
        var lines = [snapshot?["status"] as? String ?? "Normal sleep allowed",
            "\(active.count) working · \(waiting.count) waiting",
            power.held ? "Idle-sleep prevention: active" : "Idle-sleep prevention: inactive",
            lid.message, detectionMessage]
        if overrideOn, let until = manualUntil {
            lines.append("Manual keep-awake until " + DateFormatter.localizedString(from: until, dateStyle: .none, timeStyle: .short))
        }
        if let error = power.error { lines.append(error) }
        if !registry.warning.isEmpty { lines.append(registry.warning) }
        if bridgeEnabled { lines.append(bridgeMessage) }
        show("Nightshift status", lines.joined(separator: "\n\n"))
    }

    @objc private func showTaskDetails(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String, let task = registry.tasks[key] else { return }
        show(task.label.isEmpty ? task.provider : task.label,
            "State: \(task.state.rawValue)\n\n\(task.reason)\n\nSource: \(task.source)\nHost: \(task.host.isEmpty ? "not reported" : task.host)\nSession: \(task.session)")
    }

    @objc private func dismissTask(_ sender: NSMenuItem) {
        if let key = sender.representedObject as? String { dismissals[key] = registry.tasks[key]?.updated; update() }
    }
    @objc private func refresh() { readFeed(force: true); reconcile() }
    @objc private func togglePause() { paused.toggle(); update() }
    @objc private func toggleManual() {
        manualUntil = overrideOn ? nil : Date().addingTimeInterval(3600)
        if manualUntil != nil { paused = false }
        update()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3600) { [weak self] in self?.update() }
    }
    @objc private func toggleBridge() {
        bridgeEnabled.toggle()
        bridgeGeneration += 1
        bridgeLive = false; feedIsFresh = false; fetching = false
        if !bridgeEnabled {
            registry.tasks = registry.tasks.filter { $0.value.source != "ClaudeBar bridge" }
            updateBridgeMessage()
        } else {
            bridgeMessage = "Checking optional ClaudeBar detection; built-in detection remains active"
            readFeed(force: true); fetchLive()
        }
        saveSettings()
        update()
    }
    private func saveSettings() {
        if let d = try? JSONSerialization.data(withJSONObject: ["bridgeEnabled": bridgeEnabled, "closedLidEnabled": lid.enabled, "setupPresented": setupPresented]) {
            try? d.write(to: root.appendingPathComponent("settings.json"), options: .atomic)
        }
    }
    @objc private func toggleLid() { lid.enabled.toggle(); saveSettings(); update() }
    @objc private func diagnostics() { NSWorkspace.shared.open(root) }
    @objc private func loginSettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!) }
    @objc private func setup() {
        if let url = Bundle.main.url(forResource: "SETUP", withExtension: "html") { NSWorkspace.shared.open(url) }
    }
    @objc private func installDetection() {
        guard !installingDetection else { return }
        setupPresented = true; saveSettings()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Keep your Mac awake while agents work"
        alert.informativeText = "Enable Nightshift's built-in detection for Claude Code and Codex across compatible terminal, editor, and desktop hosts. ClaudeBar is not required. Setup backs up configuration and preserves existing hooks. Restart agent sessions afterwards; review new Codex hooks with /hooks."
        alert.addButton(withTitle: "Enable Detection")
        alert.addButton(withTitle: "Later")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let script = Bundle.main.url(forResource: "configure-hooks", withExtension: "py") else {
            show("Detection setup unavailable", "Rebuild Nightshift or run scripts/configure-hooks.py from the project folder.")
            return
        }
        installingDetection = true; update()
        let appPath = Bundle.main.bundleURL.path
        let dataPath = root.path
        io.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", script.path, "--app", appPath, "--data", dataPath]
            let output = Pipe(); process.standardOutput = output; process.standardError = output
            var message: String
            var success = false
            do {
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                success = process.terminationStatus == 0
                message = String(data: data, encoding: .utf8) ?? "Open the setup guide for command-line instructions."
            } catch { message = error.localizedDescription }
            DispatchQueue.main.async {
                self.installingDetection = false; self.update()
                self.show(success ? "Agent detection configured" : "Agent detection needs setup", message)
            }
        }
    }
    @objc private func about() {
        show("Nightshift 1.2", "Keeps your Mac awake while agents work. Built-in lifecycle hooks, process checks, and transcript recovery track Claude Code and Codex across compatible hosts without ClaudeBar. Other agents can use the local event adapter.\n\nGreen means wakefulness is active and requested lid protection is confirmed. Yellow reports waiting tasks or power/lid issues. Red allows normal sleep. The display may sleep.\n\nThe optional closed-lid helper restores the prior global power setting when work ends, Nightshift quits, its process dies, or its heartbeat expires. It releases protection at 15% battery. While held it also blocks explicit Sleep; test lid behavior on your Mac.\n\nSetup and Codex hook review are required. Hosts without compatible events need an adapter; an open app alone does not count as work. Conversation text is not retained.")
    }
    private func show(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message; alert.runModal()
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        release?.cancel(); power.set(false)
        lid.release()
        if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD) }
    }
}
