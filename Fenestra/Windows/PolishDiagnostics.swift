import AppKit
import ApplicationServices

/// Diagnostics for the Windows 11 polish pass (only with `captionDebug`, same distributed notification as the
/// other tests, object "TextEdit polish"). Opens two fresh TextEdit windows and checks, through the real hot key
/// tap where keys are involved:
///   - Control+Option+Z then 1, 2 snaps into layout 1 zone 2; arrows + Return pick layout 2 zone 1; Esc closes
///   - window menu Move (arrows, Return; arrows, Esc puts it back) and Size (edge pick, then steps)
///   - clipboard history Tab / Shift+Tab / Return focus order (adds one test entry, deleted afterward; the text
///     clipboard is put back)
///   - snap groups: snap left, pick the other window in Snap Assist, group of 2, survives minimizing, restoring
///     the group brings both back in place, moving one out of its zone ends the group
///   - per-display taskbar scope: windows counted per display after moving one to the second display
/// Results: app log ("polishtest") and ~/Library/Logs/Fenestra-dragtest/polish.txt. Test windows are closed.
@MainActor
enum PolishDiagnostics {
    private static var lines: [String] = []
    private static func pause(_ ms: UInt64) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }
    private static let src = CGEventSource(stateID: .hidSystemState)

    private static func key(_ code: CGKeyCode, _ flags: CGEventFlags = [], wait: UInt64 = 250) async {
        let d = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
        let u = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
        d?.flags = flags; u?.flags = flags
        d?.post(tap: .cghidEventTap); u?.post(tap: .cghidEventTap)
        await pause(wait)
    }

    private static func ok(_ pass: Bool, _ label: String, _ detail: String = "") {
        lines.append("\(pass ? "PASS" : "FAIL") \(label)\(detail.isEmpty ? "" : ": \(detail)")")
    }

    private static func near(_ a: CGRect, _ b: CGRect, _ tol: CGFloat = 3) -> Bool {
        abs(a.minX - b.minX) <= tol && abs(a.minY - b.minY) <= tol && abs(a.width - b.width) <= tol
            && abs(a.height - b.height) <= tol
    }

    static func run(appName: String) async {
        lines = []
        if NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == appName }) == nil,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: .init())
            await pause(1500)
        }
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == appName }) else {
            Log.write("polishtest: \(appName) not running"); return
        }
        let pid = app.processIdentifier
        let before = Set(AX.windows(pid).compactMap(AX.windowID))
        for _ in 0..<2 { _ = AX.pressNewWindowMenuItem(pid: pid); await pause(600) }
        let fresh = AX.windows(pid).filter { w in AX.windowID(w).map { !before.contains($0) } ?? false }
        guard fresh.count >= 2, let id1 = AX.windowID(fresh[0]), let id2 = AX.windowID(fresh[1]) else {
            Log.write("polishtest: could not open two windows"); return
        }
        let w1 = fresh[0], w2 = fresh[1]
        let main = NSScreen.screens[0]
        let wa = CaptionController.workArea(screen: main)
        let home1 = CGRect(x: wa.minX + 200, y: wa.minY + 120, width: 700, height: 500)
        let home2 = CGRect(x: wa.minX + 500, y: wa.minY + 220, width: 700, height: 500)
        CaptionController.setFrame(pid, w1, home1)
        CaptionController.setFrame(pid, w2, home2)
        AX.focus(pid: pid, window: w1)
        await pause(700)

        await snapLayoutsKeys(pid: pid, w: w1, id: id1, home: home1, wa: wa)
        await mover(pid: pid, w: w1, home: home1)
        await clipboardTab()
        await groups(pid: pid, w1: w1, id1: id1, w2: w2, id2: id2, wa: wa, home1: home1, home2: home2)
        await scope(pid: pid, w2: w2, home2: home2)

        for w in fresh { AX.close(w) }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Fenestra-dragtest")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? lines.joined(separator: "\n").write(to: dir.appendingPathComponent("polish.txt"), atomically: true, encoding: .utf8)
        let passed = lines.filter { $0.hasPrefix("PASS") }.count
        Log.write("polishtest: \(passed)/\(lines.count) PASS | " + lines.joined(separator: " | "))
        lines = []
    }

    // MARK: Control+Option+Z with numbers and arrows

    private static func snapLayoutsKeys(pid: pid_t, w: AXUIElement, id: CGWindowID, home: CGRect, wa: CGRect) async {
        let layouts = SnapLayouts.layouts(for: wa.size)
        let ctrlOpt: CGEventFlags = [.maskControl, .maskAlternate]
        await key(6, ctrlOpt, wait: 500)                                  // Z
        ok(SnapController.shared.keys.stage == .layouts(0), "Win+Z opens with numbered layouts",
           "\(SnapController.shared.keys.stage)")
        await key(18)                                                     // 1
        ok(SnapController.shared.keys.stage == .zones(layout: 0, zone: 0), "1 picks layout 1",
           "\(SnapController.shared.keys.stage)")
        await key(19, wait: 600)                                          // 2
        let z = WindowSnap.rect(layouts[0][1], in: wa)
        ok(near(AX.frame(w) ?? .zero, z), "2 snaps into zone 2", "got \(CaptionController.describe(AX.frame(w) ?? .zero)) expected \(CaptionController.describe(z))")
        SnapAssist.shared.dismiss()
        await pause(200)

        AX.focus(pid: pid, window: w)
        await pause(300)
        await key(6, ctrlOpt, wait: 500)
        await key(124)                                                    // Right
        await key(36)                                                     // Return: layout 2
        await key(36, wait: 600)                                          // Return: zone 1
        let z2 = WindowSnap.rect(layouts[1][0], in: wa)
        ok(near(AX.frame(w) ?? .zero, z2), "Right, Return, Return snaps layout 2 zone 1",
           "got \(CaptionController.describe(AX.frame(w) ?? .zero)) expected \(CaptionController.describe(z2))")
        SnapAssist.shared.dismiss()
        await pause(200)

        let f = AX.frame(w) ?? .zero
        AX.focus(pid: pid, window: w)
        await pause(300)
        await key(6, ctrlOpt, wait: 500)
        await key(53, wait: 300)                                          // Esc
        ok(!(FlyoutManager.shared.currentID?.hasPrefix("snap:") ?? false) && SnapController.shared.keys.stage == .off
           && near(AX.frame(w) ?? .zero, f), "Esc closes without snapping")
        WindowSnap.shared.forget(id)
        CaptionController.setFrame(pid, w, home)
        await pause(300)
    }

    // MARK: Window menu Move and Size

    private static func mover(pid: pid_t, w: AXUIElement, home: CGRect) async {
        AX.focus(pid: pid, window: w)
        await pause(300)
        WindowMover.shared.begin(.move, pid: pid, element: w)
        await pause(200)
        for c: CGKeyCode in [124, 124, 124, 125, 125] { await key(c, wait: 120) }
        await key(36, wait: 300)
        let moved = home.offsetBy(dx: 30, dy: 20)
        ok(near(AX.frame(w) ?? .zero, moved) && !WindowMover.shared.isActive, "Move: arrows then Return",
           "got \(CaptionController.describe(AX.frame(w) ?? .zero)) expected \(CaptionController.describe(moved))")

        WindowMover.shared.begin(.move, pid: pid, element: w)
        await pause(200)
        for c: CGKeyCode in [123, 123, 126] { await key(c, wait: 120) }
        await key(53, wait: 300)
        ok(near(AX.frame(w) ?? .zero, moved), "Move: Esc puts it back",
           "got \(CaptionController.describe(AX.frame(w) ?? .zero))")

        CaptionController.setFrame(pid, w, home)
        await pause(300)
        WindowMover.shared.begin(.size, pid: pid, element: w)
        await pause(200)
        for c: CGKeyCode in [124, 124, 124, 125, 125] { await key(c, wait: 150) }   // right edge +20, bottom edge +10
        await key(36, wait: 300)
        let sized = CGRect(x: home.minX, y: home.minY, width: home.width + 20, height: home.height + 10)
        ok(near(AX.frame(w) ?? .zero, sized), "Size: pick right and bottom edges, then grow",
           "got \(CaptionController.describe(AX.frame(w) ?? .zero)) expected \(CaptionController.describe(sized))")
        CaptionController.setFrame(pid, w, home)
        await pause(300)
    }

    // MARK: Clipboard history Tab order

    private static func clipboardTab() async {
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        let marker = "Fenestra polish test \(Int(Date().timeIntervalSince1970))"
        pb.clearContents()
        pb.setString(marker, forType: .string)
        await pause(900)
        let h = ClipboardHistory.shared
        guard let idx = h.ordered.firstIndex(where: { if case .text(let s) = $0.kind { return s == marker }; return false })
        else { ok(false, "clipboard: test entry recorded"); return }
        let ctrlOpt: CGEventFlags = [.maskControl, .maskAlternate]
        await key(9, ctrlOpt, wait: 600)                                  // V
        h.selected = idx
        var parts: [String] = ["\(h.part)"]
        await key(48); parts.append("\(h.part)")                          // Tab -> more
        await key(36); parts.append(h.expanded == h.ordered[idx].id ? "expanded" : "closed")
        await key(48); parts.append("\(h.part)")                          // -> delete
        await key(48); parts.append("\(h.part)")                          // -> pin
        await key(48, .maskShift); parts.append("\(h.part)")              // Shift+Tab -> delete
        await key(48); await key(48); parts.append("\(h.part)")           // pin -> item
        await key(53, wait: 300)                                          // Esc
        let want = ["item", "more", "expanded", "delete", "pin", "delete", "item"]
        ok(parts == want && !FlyoutManager.shared.isOpen(ClipboardFlyout.id), "clipboard: Tab order",
           parts.joined(separator: ","))
        if let item = h.ordered.first(where: { if case .text(let s) = $0.kind { return s == marker }; return false }) {
            h.delete(item.id)
        }
        pb.clearContents()
        if let saved { pb.setString(saved, forType: .string) }
        await pause(700)
    }

    // MARK: Snap groups

    private static func groups(pid: pid_t, w1: AXUIElement, id1: CGWindowID, w2: AXUIElement, id2: CGWindowID,
                               wa: CGRect, home1: CGRect, home2: CGRect) async {
        // 2/3 + 1/3: a zone your own windows are unlikely to fill already (Snap Assist skips filled zones).
        let layout = SnapLayouts.layouts(for: wa.size)[1]
        AX.focus(pid: pid, window: w1)
        await pause(300)
        WindowSnap.shared.snap(.init(pid: pid, element: w1, id: id1), zone: layout[0], workArea: wa,
                               layout: layout, source: "polishtest")
        await pause(700)
        let picked = SnapAssist.shared.debugPick(id2)
        await pause(800)
        let g = SnapGroups.shared.groups(containing: [id1])
        ok(picked && g.count == 1 && Set(g.first?.members.map(\.id) ?? []) == [id1, id2], "groups: Snap Assist forms a group of 2",
           "picked=\(picked) groups=\(g.map { $0.members.map(\.id) })")

        AX.setMinimized(w1, true); AX.setMinimized(w2, true)
        await pause(1200)
        let g2 = SnapGroups.shared.groups(containing: [id2])
        ok(g2.first?.members.count == 2, "groups: survives minimizing both",
           "frames while minimized \(CaptionController.describe(AX.frame(w1) ?? .zero)), \(CaptionController.describe(AX.frame(w2) ?? .zero))")
        if let grp = g2.first { SnapGroups.shared.restore(grp, focus: id2) }
        await pause(1500)
        let back = !AX.isMinimized(w1) && !AX.isMinimized(w2)
            && near(AX.frame(w1) ?? .zero, WindowSnap.rect(layout[0], in: wa))
            && near(AX.frame(w2) ?? .zero, WindowSnap.rect(layout[1], in: wa))
        let front = AX.focusedWindow(pid).flatMap(AX.windowID)
        ok(back && front == id2, "groups: restore brings both back in their zones, hovered app's window focused",
           "w1 \(CaptionController.describe(AX.frame(w1) ?? .zero)) w2 \(CaptionController.describe(AX.frame(w2) ?? .zero)) focused=\(front.map(String.init) ?? "-")")

        CaptionController.setFrame(pid, w2, home2)
        await pause(400)
        ok(SnapGroups.shared.groups(containing: [id1]).isEmpty, "groups: moving a window out of its zone ends the group")
        WindowSnap.shared.forget(id1)
        WindowSnap.shared.forget(id2)
        CaptionController.setFrame(pid, w1, home1)
        await pause(300)
    }

    // MARK: Per-display taskbar scope

    private static func scope(pid: pid_t, w2: AXUIElement, home2: CGRect) async {
        guard NSScreen.screens.count >= 2, let second = NSScreen.screens.dropFirst().first,
              let item = TaskbarModel.shared.items.first(where: { $0.pids.contains(pid) }) else {
            lines.append("SKIP scope: needs two displays"); return
        }
        let mainID = Displays.id(NSScreen.screens[0]), secondID = Displays.id(second)
        let swa = CaptionController.workArea(screen: second)
        CaptionController.setFrame(pid, w2, CGRect(x: swa.midX - 300, y: swa.midY - 200, width: 600, height: 400))
        await pause(600)
        let all = TaskbarActions.windows(of: item).count
        let onMain = TaskbarActions.windows(of: item, scope: .init(display: mainID, isMain: true)).count
        let onSecond = TaskbarActions.windows(of: item, scope: .init(display: secondID, isMain: false)).count
        let hasSecondBar = TaskbarController.shared.hasTaskbar(display: secondID)
        let pass = hasSecondBar ? (onSecond == 1 && onMain == all - 1) : (onMain == all && onSecond == 1)
        ok(pass, "scope: windows per taskbar", "all=\(all) main=\(onMain) second=\(onSecond) secondHasTaskbar=\(hasSecondBar)")
        CaptionController.setFrame(pid, w2, home2)
        await pause(300)
    }
}
