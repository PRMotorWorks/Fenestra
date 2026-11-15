import AppKit
import ApplicationServices

/// Phase 4 snapping core, shared by edge drags (`DragSnap`), Control+Option+arrows (Windows key + arrows),
/// Snap Layouts and Snap Assist. Remembers where each snapped window came from, so dragging it away or
/// un-snapping it with the keyboard gives it its earlier size back, as on Windows.
@MainActor
final class WindowSnap {
    static let shared = WindowSnap()

    struct Target {
        let pid: pid_t
        let element: AXUIElement
        let id: CGWindowID
    }

    /// Unit rects (origin top-left, y down) of the work area.
    enum Zones {
        static let left = CGRect(x: 0, y: 0, width: 0.5, height: 1)
        static let right = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        static let topLeft = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        static let topRight = CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)
        static let bottomLeft = CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)
        static let bottomRight = CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        static let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        static let halves = [left, right]
        static let quarters = [topLeft, topRight, bottomLeft, bottomRight]

        /// The layout a drag or key snap belongs to (for Snap Assist): halves or quarters.
        static func layout(for zone: CGRect) -> [CGRect]? {
            if halves.contains(zone) { return halves }
            if quarters.contains(zone) { return quarters }
            return nil
        }
    }

    private struct Snapped { var frame: CGRect; var zone: CGRect }

    /// Frame from before the window was first snapped or maximized (AX coordinates).
    private var preSnap: [CGWindowID: CGRect] = [:]
    /// Where we last snapped each window, and into which zone.
    private var snapped: [CGWindowID: Snapped] = [:]
    private var started = false

    func start() {
        guard !started, WindowEvents.shared.isRunning else { return }
        started = true
    }

    static func rect(_ unit: CGRect, in wa: CGRect) -> CGRect {
        CGRect(x: wa.minX + unit.minX * wa.width, y: wa.minY + unit.minY * wa.height,
               width: unit.width * wa.width, height: unit.height * wa.height).integral
    }

    // MARK: State

    /// The zone the window is snapped into, if it is still where we put it.
    func snappedZone(_ id: CGWindowID, _ f: CGRect) -> CGRect? {
        guard let s = snapped[id], CaptionController.approx(s.frame, f) else { return nil }
        return s.zone
    }

    /// Snapped by Fenestra or maximized by Fenestra, and still there.
    func isArranged(_ id: CGWindowID, _ f: CGRect) -> Bool {
        snappedZone(id, f) != nil || CaptionController.shared.maximizedByUs(id, f)
    }

    /// For a drag that has already started: the window has moved, so only its size tells whether it is the
    /// window we snapped or maximized.
    func restoreFrameForDrag(_ id: CGWindowID, size: CGSize) -> CGRect? {
        func same(_ r: CGRect) -> Bool { abs(r.width - size.width) <= 2 && abs(r.height - size.height) <= 2 }
        if let s = snapped[id], same(s.frame) { return preSnap[id] }
        if let m = CaptionController.shared.maximizedFrame(id), same(m) {
            return preSnap[id] ?? CaptionController.shared.normalFrame(id)
        }
        return nil
    }

    /// CaptionController is about to maximize the window (button, keys or drag): remember its free frame.
    func willMaximize(_ id: CGWindowID, _ f: CGRect) { rememberPreSnap(id, f) }

    private func rememberPreSnap(_ id: CGWindowID, _ f: CGRect) {
        if !isArranged(id, f) && !CaptionController.shared.isMaximizedFrame(id, f) { preSnap[id] = f }
        if preSnap.count > 200 { prune() }
    }

    private func prune() {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return }
        let alive = Set(list.compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
        preSnap = preSnap.filter { alive.contains($0.key) }
        snapped = snapped.filter { alive.contains($0.key) }
    }

    /// Phase 5 (DisplayMemory): the remembered pre-snap frame, and putting it back.
    func preSnapFrame(_ id: CGWindowID) -> CGRect? { preSnap[id] }
    func setPreSnap(_ id: CGWindowID, _ r: CGRect?) { if let r { preSnap[id] = r } }

    /// Phase 5: put a window back into its zone on a reconnected display. No focus change, no Snap Assist.
    func restoreSnap(_ t: Target, zone: CGRect, workArea wa: CGRect, preSnap pre: CGRect?) {
        let target = Self.rect(zone, in: wa)
        CaptionController.shared.forgetMaximized(t.id)
        CaptionController.setFrame(t.pid, t.element, target)
        snapped[t.id] = Snapped(frame: AX.frame(t.element) ?? target, zone: zone)
        if let pre { preSnap[t.id] = pre }
        CaptionController.shared.markDirty(t.pid, delay: 0.05)
    }

    /// Dragging moved the window out of its snapped place: it is free again.
    func forget(_ id: CGWindowID) {
        snapped[id] = nil
        preSnap[id] = nil
    }

    // MARK: Actions

    /// Puts a window into `zone` of `wa`. With a layout, Snap Assist then offers other windows for the
    /// layout's remaining zones.
    func snap(_ t: Target, zone: CGRect, workArea wa: CGRect, layout: [CGRect]?, source: String, assist: Bool = true) {
        if AX.isMinimized(t.element) { AX.setMinimized(t.element, false) }
        NSRunningApplication(processIdentifier: t.pid)?.unhide()
        guard let f = AX.frame(t.element) else { return }
        if zone == Zones.full {
            maximize(t, workArea: wa)
            return
        }
        rememberPreSnap(t.id, f)
        CaptionController.shared.noteSnapped(t.id, from: f)
        let target = Self.rect(zone, in: wa)
        let t0 = Date()
        CaptionController.setFrame(t.pid, t.element, target)
        let actual = AX.frame(t.element) ?? target
        snapped[t.id] = Snapped(frame: actual, zone: zone)
        AX.focus(pid: t.pid, window: t.element)
        WindowList.touch(t.id)
        CaptionController.shared.markDirty(t.pid, delay: 0.05)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        Log.write("snap (\(source)): \(t.id) -> \(CaptionController.describe(target)) in \(ms) ms" +
                  (actual != target ? " (app made it \(CaptionController.describe(actual)))" : ""))
        if assist, let layout, AppSettings.shared.snapAssist {
            SnapAssist.shared.offer(after: t, layout: layout, filled: zone, workArea: wa)
        }
    }

    func maximize(_ t: Target, workArea wa: CGRect? = nil) {
        CaptionController.shared.maximize(pid: t.pid, element: t.element, id: t.id, workArea: wa)
    }

    /// Back to the frame from before snapping (Windows: Windows key + the opposite arrow).
    func unsnap(_ t: Target) {
        guard let f = AX.frame(t.element) else { return }
        let wa = CaptionController.workArea(for: f)
        let target = preSnap[t.id] ?? CaptionController.defaultRestoreFrame(in: wa)
        forget(t.id)
        Log.write("snap: restore \(t.id) -> \(CaptionController.describe(target))")
        CaptionController.setFrame(t.pid, t.element, target)
        CaptionController.shared.markDirty(t.pid, delay: 0.05)
    }

    // MARK: Keyboard (Control+Option+arrows = Windows key + arrows)

    enum Arrow { case left, right, up, down }

    /// The focused window of the frontmost app.
    private func focusedTarget() -> Target? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let w = AX.focusedWindow(app.processIdentifier),
              (AX.attr(w, kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole,
              AX.attr(w, "AXFullScreen") != true,
              let id = AX.windowID(w) else { return nil }
        return Target(pid: app.processIdentifier, element: w, id: id)
    }

    /// Windows 11:
    ///   Left/Right: snap to that half; from the other half, restore; from the same half, on to the next display
    ///   (wrapping; on a single display column that is the other half). Quarters move sideways.
    ///   Up: normal -> maximize; half -> top quarter; bottom quarter -> top quarter; top quarter -> maximize.
    ///   Down: maximized -> restore; half -> bottom quarter; top quarter -> bottom quarter; otherwise minimize.
    ///   With Shift: Left/Right move the window to the next display, Up stretches it to full height.
    func keyboard(_ a: Arrow, shift: Bool) {
        guard AppSettings.shared.snapWindows, let t = focusedTarget(), let f = AX.frame(t.element) else { return }
        SnapAssist.shared.dismiss()
        let wa = CaptionController.workArea(for: f)
        if shift { shiftMove(t, a, f, wa); return }

        let maximized = CaptionController.shared.isMaximizedFrame(t.id, f)
        let zone = maximized ? Zones.full : (snappedZone(t.id, f) ?? geometricZone(f, wa))
        let Z = Zones.self
        func put(_ z: CGRect, _ area: CGRect = wa) {
            snap(t, zone: z, workArea: area, layout: Z.layout(for: z), source: "keys")
        }
        switch a {
        case .left, .right:
            let toLeft = a == .left
            let same = toLeft ? Z.left : Z.right, other = toLeft ? Z.right : Z.left
            switch zone {
            case other: unsnap(t)
            case same:
                // Windows walks on to the neighboring display (wrapping around).
                let next = neighborScreen(of: f, toLeft: toLeft)
                put(other, next.map(CaptionController.workArea(screen:)) ?? wa)
            case Z.topLeft where !toLeft: put(Z.topRight)
            case Z.topRight where toLeft: put(Z.topLeft)
            case Z.bottomLeft where !toLeft: put(Z.bottomRight)
            case Z.bottomRight where toLeft: put(Z.bottomLeft)
            case Z.topLeft, Z.topRight, Z.bottomLeft, Z.bottomRight: put(same)
            default: put(same)
            }
        case .up:
            switch zone {
            case Z.full: break
            case Z.left, Z.bottomLeft: put(Z.topLeft)
            case Z.right, Z.bottomRight: put(Z.topRight)
            case Z.topLeft, Z.topRight: maximize(t)
            case nil: maximize(t)
            default: maximize(t)
            }
        case .down:
            switch zone {
            case Z.full: CaptionController.shared.restore(pid: t.pid, element: t.element, id: t.id)
            case Z.left, Z.topLeft: put(Z.bottomLeft)
            case Z.right, Z.topRight: put(Z.bottomRight)
            default:
                Log.write("snap (keys): minimize \(t.id)")
                AX.setMinimized(t.element, true)
            }
        }
    }

    /// A zone the window fills exactly (an app or the user may have put it there without us).
    private func geometricZone(_ f: CGRect, _ wa: CGRect) -> CGRect? {
        for z in Zones.halves + Zones.quarters {
            let r = Self.rect(z, in: wa)
            if abs(r.minX - f.minX) <= 4 && abs(r.minY - f.minY) <= 4 && abs(r.width - f.width) <= 4 && abs(r.height - f.height) <= 4 {
                return z
            }
        }
        return nil
    }

    private func screen(containing f: CGRect) -> NSScreen? {
        let c = NSPoint(x: f.midX, y: CaptionController.primaryHeight - f.midY)
        return NSScreen.screens.first { $0.frame.contains(c) } ?? NSScreen.main
    }

    /// The display to the left or right (by center), wrapping around to the farthest one on the other side.
    /// Displays stacked in one column (yours) have no left/right neighbor, so the window stays on its display.
    private func neighborScreen(of f: CGRect, toLeft: Bool) -> NSScreen? {
        guard let cur = screen(containing: f) else { return nil }
        let others = NSScreen.screens.filter { $0 != cur }
        let x = cur.frame.midX
        let side = others.filter { toLeft ? $0.frame.maxX <= cur.frame.minX + 1 : $0.frame.minX >= cur.frame.maxX - 1 }
        if let n = side.min(by: { abs($0.frame.midX - x) < abs($1.frame.midX - x) }) { return n }
        let wrap = others.filter { toLeft ? $0.frame.minX >= cur.frame.maxX - 1 : $0.frame.maxX <= cur.frame.minX + 1 }
        return wrap.max(by: { abs($0.frame.midX - x) < abs($1.frame.midX - x) }) ?? cur
    }

    /// Windows key + Shift + arrows: Left/Right move to the next display (keeping the window's place there,
    /// or its snap zone), Up stretches it to the full work-area height.
    private func shiftMove(_ t: Target, _ a: Arrow, _ f: CGRect, _ wa: CGRect) {
        switch a {
        case .up:
            rememberPreSnap(t.id, f)
            let r = CGRect(x: f.minX, y: wa.minY, width: f.width, height: wa.height)
            Log.write("snap (keys): stretch \(t.id) -> \(CaptionController.describe(r))")
            CaptionController.setFrame(t.pid, t.element, r)
            CaptionController.shared.markDirty(t.pid, delay: 0.05)
        case .down:
            if let r = preSnap[t.id], abs(f.height - wa.height) <= 2 {
                CaptionController.setFrame(t.pid, t.element, CGRect(x: f.minX, y: r.minY, width: f.width, height: r.height))
                CaptionController.shared.markDirty(t.pid, delay: 0.05)
            }
        case .left, .right:
            let screens = NSScreen.screens
            guard screens.count > 1, let cur = screen(containing: f), let i = screens.firstIndex(of: cur) else { return }
            // Ordered left to right, then top to bottom (Windows cycles through all displays).
            let ordered = screens.sorted { ($0.frame.minX, -$0.frame.maxY) < ($1.frame.minX, -$1.frame.maxY) }
            let k = ordered.firstIndex(of: screens[i]) ?? 0
            let next = ordered[(k + (a == .left ? -1 : 1) + ordered.count) % ordered.count]
            let wa2 = CaptionController.workArea(screen: next)
            if CaptionController.shared.isMaximizedFrame(t.id, f) {
                maximize(t, workArea: wa2)
            } else if let z = snappedZone(t.id, f) ?? geometricZone(f, wa) {
                snap(t, zone: z, workArea: wa2, layout: nil, source: "keys")
            } else {
                let unit = CGRect(x: (f.minX - wa.minX) / wa.width, y: (f.minY - wa.minY) / wa.height,
                                  width: f.width / wa.width, height: f.height / wa.height)
                var r = Self.rect(unit, in: wa2)
                r.size.width = min(r.width, wa2.width); r.size.height = min(r.height, wa2.height)
                r.origin.x = min(max(r.minX, wa2.minX), wa2.maxX - r.width)
                r.origin.y = min(max(r.minY, wa2.minY), wa2.maxY - r.height)
                Log.write("snap (keys): move \(t.id) to display \(CaptionController.describe(wa2))")
                CaptionController.setFrame(t.pid, t.element, r)
                AX.focus(pid: t.pid, window: t.element)
                CaptionController.shared.markDirty(t.pid, delay: 0.05)
            }
        }
    }

    /// Control+Option+Z (Windows key + Z): Snap Layouts for the focused window.
    func showLayoutsForFocusedWindow() {
        guard let t = focusedTarget() else { return }
        SnapController.shared.showFromKeyboard(t.id)
    }
}
