import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Diagnostics only (active when `captionDebug` is set): drags a window with synthetic mouse events and,
/// while it moves, records window vs. caption panel positions and screenshots of the window's top-left
/// corner into ~/Library/Logs/Fenestra-dragtest/. Triggered by the distributed notification
/// "local.fenestra.debug.dragtest" with the app name as the object.
@MainActor
enum DragDiagnostics {
    static func install() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("local.fenestra.debug.dragtest"), object: nil, queue: .main
        ) { n in
            // "App" = even drag; "App real" = uneven drag across displays; "App click" = title bar click.
            let parts = (n.object as? String ?? "Terminal").split(separator: " ").map(String.init)
            let name = parts[0], mode = parts.count > 1 ? parts[1] : "even"
            MainActor.assumeIsolated {
                Task { @MainActor in
                    switch mode {
                    case "click": await clickTest(appName: name)
                    case "control": await controlTest(appName: name)
                    case "real": await run(appName: name, realistic: true)
                    case "fast": await run(appName: name, realistic: true, hz1000: true)
                    case "edge": await edgeTest(appName: name)
                    case "snapdrag": await SnapDiagnostics.dragTest(appName: name)
                    case "snapkeys": await SnapDiagnostics.keysTest(appName: name)
                    case "alttab": await SnapDiagnostics.altTabTest()
                    case "looks": await SnapLookDiagnostics.looks(appName: name)
                    case "clicks": await SnapLookDiagnostics.clicks(appName: name)
                    case "displays": await DisplayDiagnostics.run(appName: name)
                    case "polish": await PolishDiagnostics.run(appName: name)
                    default: await run(appName: name, realistic: false)
                    }
                }
            }
        }
        // "App x y": puts that app's captioned window at x,y (AX), to undo test drags exactly.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("local.fenestra.debug.move"), object: nil, queue: .main
        ) { n in
            let parts = (n.object as? String ?? "").split(separator: " ")
            MainActor.assumeIsolated {
                guard parts.count == 3, let x = Double(parts[1]), let y = Double(parts[2]),
                      let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == String(parts[0]) }),
                      let w = AX.windows(app.processIdentifier).max(by: {
                          (AX.frame($0)?.width ?? 0) * (AX.frame($0)?.height ?? 0) < (AX.frame($1)?.width ?? 0) * (AX.frame($1)?.height ?? 0)
                      }) else { return }
                AX.setPosition(w, CGPoint(x: x, y: y))
                Log.write("dragtest: moved \(parts[0]) to \(x),\(y)")
            }
        }
    }

    private static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Fenestra-dragtest")

    static func run(appName: String, realistic: Bool, hz1000: Bool = false) async {
        clearTestFiles()
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == appName }),
              let e = CaptionController.shared.entries.values
                .filter({ $0.pid == app.processIdentifier && $0.shown })
                .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
            Log.write("dragtest: no captioned window for \(appName)")
            return
        }
        let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let f = e.frame
        let start = CGPoint(x: (f.minX + f.width * 0.6).rounded(), y: (f.minY + e.lights.midY).rounded())
        let src = CGEventSource(stateID: .hidSystemState)
        func post(_ type: CGEventType, _ p: CGPoint) {
            CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
        func pause(_ ms: UInt64) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }
        let panelID = CGWindowID(e.panel.windowNumber)
        var lines = ["app=\(appName) window=\(e.id) panel=\(panelID) frame=\(CaptionController.describe(f)) start=\(start)",
                     "step  t(ms)  mouse  window  panel-1  dx dy"]
        let t0 = Date()
        func sample(_ label: String, _ p: CGPoint) {
            let w = CaptionController.bounds(of: e.id) ?? .zero
            let pn = CaptionController.bounds(of: panelID) ?? .zero
            let dx = Int(pn.minX - 1 - w.minX), dy = Int(pn.minY - 1 - w.minY)
            lines.append("\(label) \(Int(Date().timeIntervalSince(t0) * 1000)) \(Int(p.x)),\(Int(p.y)) " +
                         "\(Int(w.minX)),\(Int(w.minY)) \(Int(pn.minX - 1)),\(Int(pn.minY - 1)) \(dx) \(dy)")
        }

        post(.mouseMoved, start); await pause(60)
        post(.leftMouseDown, start); await pause(100)
        var p = start
        if realistic {
            // Like a hand on a real mouse: uneven 1 to 9 ms gaps, speed varying, upward across the boundary
            // between the portable display and the main one (y 1080), with a short stop on the way.
            var rng = SystemRandomNumberGenerator()
            let total = hz1000 ? 1100 : 220             // 1000 Hz mouse: 1 ms apart, 1/5 of the step
            for i in 1...total {
                let phase = Double(i) / Double(total)
                let speed = 0.5 + 1.5 * sin(phase * .pi)          // slow, fast, slow
                let k: Double = hz1000 ? 0.2 : 1
                p.x += CGFloat(Double.random(in: -0.5...2.0, using: &rng) * speed * k)
                p.y -= CGFloat(Double.random(in: 1.0...4.0, using: &rng) * speed * k)
                post(.leftMouseDragged, p)
                if hz1000 { try? await Task.sleep(nanoseconds: 1_000_000) }
                else { await pause(UInt64.random(in: 1...9, using: &rng)) }
                if i == total * 6 / 11 { await pause(120) }      // hesitate
                if i % (hz1000 ? 20 : 4) == 0 { sample("\(i)", p) }
                if i % (hz1000 ? 50 : 10) == 0, let content {
                    let name = "step\(i)"
                    Task { @MainActor in await shot(content, around: e.id, lights: e.lights, name: name) }
                }
            }
        } else {
            for i in 1...60 {                   // ~750 pt/s, like a brisk drag
                p.x += 6; p.y += 2
                post(.leftMouseDragged, p)
                await pause(8)
                sample("\(i)", p)
                if i % 10 == 0, let content {    // not awaited: the drag keeps going while it captures
                    let name = "step\(i)"
                    Task { @MainActor in await shot(content, around: e.id, lights: e.lights, name: name) }
                }
            }
        }
        post(.leftMouseUp, p)
        await pause(200)
        sample("up+200", p)
        if let content { await shot(content, around: e.id, lights: e.lights, name: "after") }
        // Put the window back where it was.
        await pause(300)
        if let w = AX.windows(e.pid).first(where: { AX.windowID($0) == e.id }) { AX.setPosition(w, f.origin) }
        lines += lightLog
        lightLog = []
        try? lines.joined(separator: "\n").write(to: dir.appendingPathComponent("positions.txt"), atomically: true, encoding: .utf8)
        Log.write("dragtest: \(appName) done, see \(dir.path)")
    }

    /// Drags down against the bottom of the screen for 150 pt, then back up 150 pt, sampling the real window
    /// position: shows whether macOS moves the window back at once on reversal (relative) or only once the
    /// mouse returns to where it stopped (grab point under the cursor).
    static func edgeTest(appName: String) async {
        clearTestFiles()
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == appName }),
              let e = CaptionController.shared.entries.values
                .filter({ $0.pid == app.processIdentifier && $0.shown })
                .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { return }
        let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let f = e.frame
        var p = CGPoint(x: (f.minX + f.width * 0.6).rounded(), y: (f.minY + e.lights.midY).rounded())
        let src = CGEventSource(stateID: .hidSystemState)
        func post(_ type: CGEventType) {
            CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        let panelID = CGWindowID(e.panel.windowNumber)
        var lines = ["edge \(appName) frame=\(CaptionController.describe(f))", "i mouseY windowY panelY"]
        post(.mouseMoved); try? await Task.sleep(nanoseconds: 60_000_000)
        post(.leftMouseDown); try? await Task.sleep(nanoseconds: 100_000_000)
        for i in 1...100 {
            p.y += i <= 50 ? 3 : -3
            post(.leftMouseDragged)
            try? await Task.sleep(nanoseconds: 8_000_000)
            let w = CaptionController.bounds(of: e.id) ?? .zero, pn = CaptionController.bounds(of: panelID) ?? .zero
            lines.append("\(i) \(Int(p.y)) \(Int(w.minY)) \(Int(pn.minY - 1))")
            if i % 5 == 0, let content {
                let name = "edge\(i)"
                Task { @MainActor in await shot(content, around: e.id, lights: e.lights, name: name) }
            }
        }
        post(.leftMouseUp)
        try? await Task.sleep(nanoseconds: 300_000_000)
        if let w = AX.windows(e.pid).first(where: { AX.windowID($0) == e.id }) { AX.setPosition(w, f.origin) }
        lines += lightLog
        lightLog = []
        try? lines.joined(separator: "\n").write(to: dir.appendingPathComponent("edge.txt"), atomically: true, encoding: .utf8)
        Log.write("dragtest: edge on \(appName) done")
    }

    /// Clicks (no drag) on the window's title bar and samples, every 4 ms for 200 ms, whether our panel is
    /// directly above the window in the window list (if not, the traffic lights can show).
    static func clickTest(appName: String) async {
        clearTestFiles()
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == appName }),
              let e = CaptionController.shared.entries.values
                .filter({ $0.pid == app.processIdentifier && $0.shown })
                .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { return }
        let f = e.frame
        let p = CGPoint(x: (f.minX + f.width * 0.6).rounded(), y: (f.minY + e.lights.midY).rounded())
        let src = CGEventSource(stateID: .hidSystemState)
        let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let panelID = CGWindowID(e.panel.windowNumber)
        var lines = ["click \(appName) window=\(e.id) panel=\(panelID) at \(p)", "t(ms) panelAboveWindow"]
        let t0 = Date()
        for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
            if type == .leftMouseDown {
                for k in 0..<12 {
                    if k % 2 == 0, let content {
                        let name = "click\(k)"
                        Task { @MainActor in await shot(content, around: e.id, lights: e.lights, name: name) }
                    }
                    let o = CaptionController.onscreenOrder()
                    lines.append("\(Int(Date().timeIntervalSince(t0) * 1000)) down \((o[panelID] ?? -9) == (o[e.id] ?? -1) - 1)")
                    try? await Task.sleep(nanoseconds: 4_000_000)
                }
            }
        }
        for _ in 0..<40 {
            let o = CaptionController.onscreenOrder()
            lines.append("\(Int(Date().timeIntervalSince(t0) * 1000)) up \((o[panelID] ?? -9) == (o[e.id] ?? -1) - 1)")
            try? await Task.sleep(nanoseconds: 4_000_000)
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        lines += lightLog
        lightLog = []
        try? lines.joined(separator: "\n").write(to: dir.appendingPathComponent("click.txt"), atomically: true, encoding: .utf8)
        Log.write("dragtest: click on \(appName) done")
    }

    static var lightLog: [String] = []

    /// Removes results of earlier synthetic tests, keeping recordings of real drags (real-*.txt).
    static func clearTestFiles() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where !(f.hasPrefix("real-") && f.hasSuffix(".txt")) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
        }
    }

    /// Positive control for the metric: hides the buttons for a moment and counts the traffic lights.
    static func controlTest(appName: String) async {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == appName }),
              let e = CaptionController.shared.entries.values.first(where: { $0.pid == app.processIdentifier && $0.shown }),
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        else { return }
        e.panel.orderOut(nil)
        try? await Task.sleep(nanoseconds: 60_000_000)
        await shot(content, around: e.id, lights: e.lights, name: "control-hidden")
        e.panel.order(.above, relativeTo: Int(e.id))
        try? await Task.sleep(nanoseconds: 60_000_000)
        await shot(content, around: e.id, lights: e.lights, name: "control-shown")
        Log.write("dragtest: \(lightLog.joined(separator: ", "))")
        lightLog = []
    }

    /// Pixels with the traffic lights' saturated red / yellow / green: > 0 means they are visible.
    static func trafficLightPixels(_ img: CGImage) -> Int {
        let w = img.width, h = img.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return -1 }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        var n = 0
        for i in stride(from: 0, to: px.count, by: 4) {
            let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
            if (r > 200 && g < 120 && b < 110) || (r > 210 && g > 160 && b < 90) || (g > 170 && r < 130 && b < 120) { n += 1 }
        }
        return n
    }

    /// Screenshot of the composited screen (window plus our panel) around the window's top-left corner.
    private static func shot(_ content: SCShareableContent, around id: CGWindowID, lights: CGRect, name: String) async {
        guard let b = CaptionController.bounds(of: id) else { return }
        let region = CGRect(x: b.minX - 40, y: b.minY - 30, width: 220, height: 100)
        guard let display = content.displays.first(where: { $0.frame.contains(CGPoint(x: b.minX + 5, y: b.minY + 5)) })
        else { return }
        let cfg = SCStreamConfiguration()
        cfg.sourceRect = region.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        cfg.width = Int(region.width)
        cfg.height = Int(region.height)
        cfg.showsCursor = true
        let filter = SCContentFilter(display: display, excludingWindows: [])
        guard let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) else { return }
        // Count only where the traffic lights are (the window may have moved a few points meanwhile).
        let area = CGRect(x: 40 + lights.minX - 8, y: 30 + lights.minY - 8, width: lights.width + 16, height: lights.height + 16)
        let lit = img.cropping(to: area).map(trafficLightPixels) ?? -1
        lightLog.append("\(name) trafficLightPixels=\(lit)")
        guard let dest = CGImageDestinationCreateWithURL(dir.appendingPathComponent("\(name).png") as CFURL,
                                                         UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
    }
}
