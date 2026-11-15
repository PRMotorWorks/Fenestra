import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Phase 4 diagnostics (only with `captionDebug`, through the same distributed notification as the drag tests):
///   "App snapdrag"  drags the app's biggest window by its title bar to the left edge, then a corner, then the
///                   top edge, releasing each time, and checks the frame against the expected zone
///   "App snapkeys"  focuses the window and presses Control+Option+arrows (through the real hot key tap)
///   "App alttab"    holds Option, presses Tab, checks the switcher, releases Option, checks the front window
/// Results go to the app log and ~/Library/Logs/Fenestra-dragtest/snap.txt; the window is put back afterward.
/// These move your real windows, mouse and keyboard focus.
@MainActor
enum SnapDiagnostics {
    private static var lines: [String] = []

    private static func target(_ appName: String) -> (pid_t, AXUIElement, CGWindowID, CGRect)? {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == appName }) else { return nil }
        let best = AX.windows(app.processIdentifier).compactMap { w -> (AXUIElement, CGWindowID, CGRect)? in
            guard let id = AX.windowID(w), let f = AX.frame(w), !AX.isMinimized(w) else { return nil }
            return (w, id, f)
        }.max { $0.2.width * $0.2.height < $1.2.width * $1.2.height }
        guard let b = best else { return nil }
        return (app.processIdentifier, b.0, b.1, b.2)
    }

    private static func pause(_ ms: UInt64) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }

    private static func check(_ label: String, _ id: CGWindowID, expect: CGRect) {
        let got = CaptionController.bounds(of: id) ?? .zero
        let ok = abs(got.minX - expect.minX) <= 3 && abs(got.minY - expect.minY) <= 3
            && abs(got.width - expect.width) <= 3 && abs(got.height - expect.height) <= 3
        lines.append("\(ok ? "PASS" : "FAIL") \(label): got \(CaptionController.describe(got)) expected \(CaptionController.describe(expect))")
    }

    private static func finish(_ name: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Fenestra-dragtest")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? lines.joined(separator: "\n").write(to: dir.appendingPathComponent("snap.txt"), atomically: true, encoding: .utf8)
        Log.write("snaptest \(name): " + lines.joined(separator: " | "))
        lines = []
    }

    static func dragTest(appName: String) async {
        guard let (pid, w, id, f0) = target(appName) else { Log.write("snaptest: no window for \(appName)"); return }
        AX.focus(pid: pid, window: w)
        await pause(300)
        let wa = CaptionController.workArea(for: f0)
        let screen = NSScreen.screens.first { CaptionController.axRect($0.frame).contains(CGPoint(x: f0.midX, y: f0.midY)) }
            ?? NSScreen.screens[0]
        let sf = CaptionController.axRect(screen.frame)
        let src = CGEventSource(stateID: .hidSystemState)
        func post(_ type: CGEventType, _ p: CGPoint) {
            CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        /// Title bar drag from the window's current position to `to`, in small steps, then release.
        func drag(to: CGPoint) async {
            guard let f = AX.frame(w) else { return }
            // Same grab point as the caption drag tests: 60% across, at the traffic lights' height.
            let lightsY = CaptionController.shared.entry(id)?.lights.midY ?? 14
            var p = CGPoint(x: (f.minX + f.width * 0.6).rounded(), y: (f.minY + lightsY).rounded())
            post(.mouseMoved, p); await pause(80)
            post(.leftMouseDown, p); await pause(120)
            let steps = 50
            let dx = (to.x - p.x) / CGFloat(steps), dy = (to.y - p.y) / CGFloat(steps)
            for _ in 0..<steps {
                p.x += dx; p.y += dy
                post(.leftMouseDragged, p)
                await pause(10)
            }
            for _ in 0..<15 { post(.leftMouseDragged, to); await pause(20) }     // rest at the edge
            post(.leftMouseUp, to)
            await pause(600)
            SnapAssist.shared.dismiss()
        }
        lines = ["snapdrag \(appName) window=\(id) start=\(CaptionController.describe(f0)) workArea=\(CaptionController.describe(wa))"]
        await drag(to: CGPoint(x: sf.minX, y: sf.midY))
        check("left edge -> left half", id, expect: WindowSnap.rect(WindowSnap.Zones.left, in: wa))
        await drag(to: CGPoint(x: sf.maxX - 1, y: sf.minY + 20))
        check("top-right corner -> top-right quarter", id, expect: WindowSnap.rect(WindowSnap.Zones.topRight, in: wa))
        await drag(to: CGPoint(x: sf.midX + 300, y: sf.minY))
        check("top edge -> maximize", id, expect: wa)
        // Dragging the maximized window away gives back its size from before it was first snapped.
        await drag(to: CGPoint(x: sf.midX, y: sf.midY - 100))
        let after = CaptionController.bounds(of: id) ?? .zero
        let sizeBack = abs(after.width - f0.width) <= 3 && abs(after.height - f0.height) <= 3
        lines.append("\(sizeBack ? "PASS" : "FAIL") drag away restores size: got \(CaptionController.describe(after)) original \(CaptionController.describe(f0))")
        CaptionController.setFrame(pid, w, f0)
        finish("snapdrag")
    }

    static func keysTest(appName: String) async {
        guard let (pid, w, id, f0) = target(appName) else { Log.write("snaptest: no window for \(appName)"); return }
        AX.focus(pid: pid, window: w)
        await pause(400)
        let wa = CaptionController.workArea(for: f0)
        let src = CGEventSource(stateID: .hidSystemState)
        func press(_ code: CGKeyCode, shift: Bool = false) async {
            var flags: CGEventFlags = [.maskControl, .maskAlternate]
            if shift { flags.insert(.maskShift) }
            let d = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
            let u = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
            d?.flags = flags; u?.flags = flags
            d?.post(tap: .cghidEventTap); u?.post(tap: .cghidEventTap)
            await pause(500)
            SnapAssist.shared.dismiss()
            await pause(100)
        }
        let Z = WindowSnap.Zones.self
        lines = ["snapkeys \(appName) window=\(id) start=\(CaptionController.describe(f0))"]
        await press(123); check("Left -> left half", id, expect: WindowSnap.rect(Z.left, in: wa))
        await press(126); check("Up -> top-left quarter", id, expect: WindowSnap.rect(Z.topLeft, in: wa))
        await press(125); check("Down -> bottom-left quarter", id, expect: WindowSnap.rect(Z.bottomLeft, in: wa))
        await press(124); check("Right -> bottom-right quarter", id, expect: WindowSnap.rect(Z.bottomRight, in: wa))
        await press(126); check("Up -> top-right quarter", id, expect: WindowSnap.rect(Z.topRight, in: wa))
        await press(126); check("Up -> maximize", id, expect: wa)
        await press(125); check("Down -> back to the top-right quarter", id, expect: WindowSnap.rect(Z.topRight, in: wa))
        await press(123); check("Left -> top-left quarter", id, expect: WindowSnap.rect(Z.topLeft, in: wa))
        await press(123); check("Left -> left half", id, expect: WindowSnap.rect(Z.left, in: wa))
        await press(124)
        let after = CaptionController.bounds(of: id) ?? .zero
        let back = abs(after.width - f0.width) <= 3 && abs(after.height - f0.height) <= 3
        lines.append("\(back ? "PASS" : "FAIL") Right -> restored to the size before snapping: got \(CaptionController.describe(after)) original \(CaptionController.describe(f0))")
        CaptionController.setFrame(pid, w, f0)
        finish("snapkeys")
    }

    static func altTabTest() async {
        let src = CGEventSource(stateID: .hidSystemState)
        let before = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        let expected = WindowList.all()
        func key(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) {
            let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
        lines = ["alttab front=\(before) windows=\(expected.count): " + expected.prefix(4).map { "\($0.appName)/\($0.id)" }.joined(separator: ", ")]
        key(58, down: true, flags: .maskAlternate)            // Option down
        await pause(50)
        key(48, down: true, flags: .maskAlternate); key(48, down: false, flags: .maskAlternate)
        await pause(400)
        lines.append("\(AltTab.shared.active ? "PASS" : "FAIL") switcher open while Option is held")
        key(58, down: false, flags: [])                        // Option up
        await pause(500)
        let after = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        lines.append("\(!AltTab.shared.active ? "PASS" : "FAIL") switcher closed after release; front app now \(after)")
        finish("alttab")
    }
}

/// "App looks": screenshots of each Phase 4 surface into ~/Library/Logs/Fenestra-dragtest/look-*.png
/// "App clicks": one synthetic click on a Snap Layouts zone and one on a Snap Assist card, checking each snaps.
@MainActor
enum SnapLookDiagnostics {
    private static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Fenestra-dragtest")
    private static let src = CGEventSource(stateID: .hidSystemState)
    private static func pause(_ ms: UInt64) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }

    private static func mouse(_ type: CGEventType, _ p: CGPoint) {
        CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
    private static func key(_ code: CGKeyCode, down: Bool, _ flags: CGEventFlags) {
        let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
        e?.flags = flags
        e?.post(tap: .cghidEventTap)
    }
    private static func click(_ p: CGPoint) async {
        mouse(.mouseMoved, p); await pause(120)
        mouse(.leftMouseDown, p); await pause(60)
        mouse(.leftMouseUp, p)
    }

    static func capture(_ name: String, screen: NSScreen = NSScreen.screens[0]) async {
        guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == n }) else { return }
        let cfg = SCStreamConfiguration()
        cfg.width = Int(screen.frame.width)
        cfg.height = Int(screen.frame.height)
        cfg.showsCursor = true
        let filter = SCContentFilter(display: display, excludingWindows: [])
        guard let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg),
              let dest = CGImageDestinationCreateWithURL(dir.appendingPathComponent("look-\(name).png") as CFURL,
                                                         UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
    }

    private static func target(_ appName: String) -> (pid_t, AXUIElement, CGWindowID, CGRect)? {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == appName }),
              let w = AX.focusedWindow(app.processIdentifier) ?? AX.windows(app.processIdentifier).first,
              let id = AX.windowID(w), let f = AX.frame(w) else { return nil }
        return (app.processIdentifier, w, id, f)
    }

    /// Title bar drag through waypoints; rests 350 ms at each and takes the named screenshot there.
    private static func drag(_ w: AXUIElement, _ id: CGWindowID, _ points: [(CGPoint, String?)]) async {
        guard let f = AX.frame(w) else { return }
        let lightsY = CaptionController.shared.entry(id)?.lights.midY ?? 14
        var p = CGPoint(x: (f.minX + f.width * 0.6).rounded(), y: (f.minY + lightsY).rounded())
        mouse(.mouseMoved, p); await pause(80)
        mouse(.leftMouseDown, p); await pause(120)
        for (to, shot) in points {
            let steps = 40
            let dx = (to.x - p.x) / CGFloat(steps), dy = (to.y - p.y) / CGFloat(steps)
            for _ in 0..<steps { p.x += dx; p.y += dy; mouse(.leftMouseDragged, p); await pause(10) }
            p = to
            for _ in 0..<12 { mouse(.leftMouseDragged, to); await pause(30) }
            if let shot { await capture(shot) }
        }
        mouse(.leftMouseUp, p)
        await pause(700)
    }

    /// Whether the window's caption panel is shown directly above it (else its traffic lights show).
    private static func captions(_ id: CGWindowID, _ step: String) {
        guard let e = CaptionController.shared.entry(id) else { Log.write("looktest \(step): no caption entry"); return }
        let o = CaptionController.onscreenOrder()
        let above = (o[CGWindowID(e.panel.windowNumber)] ?? -9) == (o[id] ?? -1) - 1
        Log.write("looktest \(step): captions shown=\(e.shown) hiddenForDrag=\(e.hiddenForDrag) aboveWindow=\(above)")
    }

    static func looks(appName: String) async {
        guard let (pid, w, id, f0) = target(appName) else { Log.write("looktest: no window for \(appName)"); return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        AX.focus(pid: pid, window: w)
        await pause(400)
        let screen = NSScreen.screens[0]
        let sf = CaptionController.axRect(screen.frame)
        let wa = CaptionController.workArea(screen: screen)
        // 1. Edge preview, then Snap Assist.
        await drag(w, id, [(CGPoint(x: sf.minX, y: sf.midY), "preview")])
        await capture("assist")
        captions(id, "after edge snap")
        SnapAssist.shared.dismiss()
        await pause(300)
        // 2. Snap layouts bar: handle, open, over a zone.
        let (bar, tile) = DragSnap.shared.debugBar
        _ = bar
        await drag(w, id, [(CGPoint(x: wa.midX, y: wa.minY + 110), "bar-handle"),
                           (CGPoint(x: wa.midX, y: wa.minY + 30), "bar-open")])
        SnapAssist.shared.dismiss()
        await pause(300)
        captions(id, "after bar drag 1")
        let (bar2, _) = DragSnap.shared.debugBar
        await drag(w, id, [(CGPoint(x: wa.midX, y: wa.minY + 30), nil),
                           (CGPoint(x: bar2.minX + 10 + tile.width * 0.25, y: bar2.minY + 10 + tile.height / 2), "bar-zone")])
        SnapAssist.shared.dismiss()
        await pause(300)
        captions(id, "after bar drag 2")
        // 3. Snap Layouts flyout (Control+Option+Z).
        AX.focus(pid: pid, window: w)
        await pause(300)
        key(6, down: true, [.maskControl, .maskAlternate]); key(6, down: false, [.maskControl, .maskAlternate])
        await pause(700)
        await capture("layouts")
        captions(id, "flyout open")
        FlyoutManager.shared.close(animated: false)
        // 4. Alt+Tab held open, then cancelled with Esc.
        key(58, down: true, .maskAlternate); await pause(50)
        key(48, down: true, .maskAlternate); key(48, down: false, .maskAlternate)
        await pause(700)
        await capture("alttab")
        key(53, down: true, .maskAlternate); key(53, down: false, .maskAlternate)
        await pause(100)
        key(58, down: false, [])
        await pause(300)
        // 5. Task View on every display.
        TaskView.shared.open()
        await pause(800)
        for (i, s) in NSScreen.screens.enumerated() { await capture("taskview-\(i)", screen: s) }
        TaskView.shared.close()
        await pause(300)
        CaptionController.setFrame(pid, w, f0)
        AX.focus(pid: pid, window: w)
        Log.write("looktest: done, see \(dir.path)/look-*.png")
    }

    static func clicks(appName: String) async {
        guard let (pid, w, id, f0) = target(appName) else { Log.write("clicktest: no window for \(appName)"); return }
        var lines: [String] = []
        AX.focus(pid: pid, window: w)
        await pause(400)
        let wa = CaptionController.workArea(for: f0)
        // Snap Layouts: open with Control+Option+Z, one click on the left zone of the first layout.
        key(6, down: true, [.maskControl, .maskAlternate]); key(6, down: false, [.maskControl, .maskAlternate])
        await pause(700)
        if let pf = FlyoutManager.shared.panelFrame {
            let tile = SnapLayouts.tileSize(for: wa.size)
            let p = CGPoint(x: pf.minX + 14 + tile.width * 0.25, y: CaptionController.primaryHeight - pf.maxY + 14 + tile.height / 2)
            await click(p)
            await pause(500)
            let got = CaptionController.bounds(of: id) ?? .zero
            let want = WindowSnap.rect(WindowSnap.Zones.left, in: wa)
            lines.append("\(CaptionController.approx(got, want) ? "PASS" : "FAIL") one click on a Snap Layouts zone: got \(CaptionController.describe(got))")
        } else {
            lines.append("FAIL Snap Layouts flyout didn't open")
        }
        // Snap Assist (opened by that snap): one click on the first card.
        await pause(300)
        if let (p, cand) = SnapAssist.shared.debugFirstCard {
            let before = AX.frame(cand.element)
            await click(p)
            await pause(600)
            let got = CaptionController.bounds(of: cand.id) ?? .zero
            let want = WindowSnap.rect(WindowSnap.Zones.right, in: wa)
            lines.append("\(CaptionController.approx(got, want) ? "PASS" : "FAIL") one click on a Snap Assist card (\(cand.appName)): got \(CaptionController.describe(got))")
            if let before { CaptionController.setFrame(cand.pid, cand.element, before) }
        } else {
            lines.append("FAIL Snap Assist didn't open")
        }
        SnapAssist.shared.dismiss()
        CaptionController.setFrame(pid, w, f0)
        AX.focus(pid: pid, window: w)
        Log.write("clicktest: " + lines.joined(separator: " | "))
    }
}
