import Foundation
import AppKit

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--render-icons"), args.count > i + 1 {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 552, pixelsHigh: 160,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor(white: 0.96, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: 552, height: 160)).fill()
    for (index, color) in [NSColor.systemRed, .systemGreen, .systemYellow].enumerated() {
        NightshiftApp.owl(color).draw(in: NSRect(x: index * 184, y: 0, width: 184, height: 160))
    }
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[i + 1]))
    exit(0)
}
if args.contains("--status") {
    if let bytes = try? Data(contentsOf: Paths.data.appendingPathComponent("status.json")) {
        FileHandle.standardOutput.write(bytes); print("")
    } else { print("Nightshift has not written a status snapshot in \(Paths.data.path)"); exit(1) }
    exit(0)
}
if let i = args.firstIndex(of: "--hook"), args.count > i + 1 {
    // Hooks never block or change the agent's decision, even if writing fails.
    do {
        var bytes = Data()
        while let chunk = try FileHandle.standardInput.read(upToCount: 65536), !chunk.isEmpty {
            bytes.append(chunk)
            if bytes.count > 4 * 1024 * 1024 { print("{}"); exit(0) }
        }
        if let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
           let event = HookInput.normalize(object, provider: args[i + 1]) {
            let root = Paths.data
            try Paths.prepare(root)
            let destination = root.appendingPathComponent("inbox").appendingPathComponent(event.id + ".json")
            try JSONEncoder().encode(event).write(to: destination, options: .atomic)
            chmod(destination.path, 0o600)
        }
    } catch { /* Monitoring failure must never prevent agent work. */ }
    print("{}")
    exit(0)
}
if args.contains("--power-test") {
    let assertion = PowerAssertion(); assertion.set(true)
    guard assertion.held else { fputs("Power assertion failed\n", stderr); exit(1) }
    print("Assertion created; holding for 5 seconds")
    Thread.sleep(forTimeInterval: 5)
    assertion.set(false)
    guard !assertion.held else { exit(1) }
    print("Assertion released")
    exit(0)
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = NightshiftApp()
app.delegate = delegate
app.run()
