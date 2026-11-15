import AppKit
import ApplicationServices
import SwiftUI

/// Windows 11 drag snapping: drag a window until the pointer touches a display edge and a translucent
/// preview shows where it will go (left/right edge: half, corner: quarter, top edge: maximize); let go and it
/// snaps there, then Snap Assist offers the other windows. Dragging toward the top center shows the snap
/// layouts bar; drop on one of its zones. Dragging a window Fenestra snapped or maximized gives it its earlier
/// size back.
///
/// A drag is recognized the same way the caption buttons hide (`CaptionController.windowMoved`): a window
/// moves (shared `WindowEvents` hub) while the left button is down. Only during such a drag a listen-only
/// event tap follows the pointer. Nothing runs otherwise.
@MainActor
final class DragSnap {
    static let shared = DragSnap()

    private struct Session {
        let target: WindowSnap.Target
        var size: CGSize
        var resized = false
        var ignoreResizeUntil = Date.distantPast
    }

    struct Zone: Equatable {
        let unit: CGRect
        let workArea: CGRect
        let layout: [CGRect]?
        /// Picked in the snap bar at the top: the dragged window covers most of the screen there, so the preview
        /// goes in front of it (user, 2026-11-15). Edge and corner drags keep it behind, as on Windows 11.
        var fromBar = false
    }

    private var session: Session?
    private var zone: Zone?
    private var pending: Zone?
    private var pendingTimer: Timer?
    private var tap: CFMachPort?
    private var upTimer: Timer?
    private let preview = SnapPreview()
    private let bar = SnapBar()
    /// Diagnostics: the snap layouts bar's expanded frame (AX) and tile size.
    var debugBar: (CGRect, CGSize) { bar.debugGeometry }
    private var started = false
    private let ownPid = ProcessInfo.processInfo.processIdentifier

    /// Pointer distance from an edge that counts as touching it (the pointer stops at an outer edge).
    private let edge: CGFloat = 3
    /// At an edge shared with another display the pointer passes straight through, so there it has to rest
    /// within 6 pt for a moment.
    private let sharedEdge: CGFloat = 6
    private let sharedDwell: TimeInterval = 0.3
    /// How close to a corner (along the edge) gives a quarter instead of a half.
    private let corner: CGFloat = 64

    func start() {
        guard !started, WindowEvents.shared.isRunning else { return }
        started = true
        WindowEvents.shared.subscribe { kind, pid, el in
            switch kind {
            case .moved: DragSnap.shared.moved(pid, el)
            case .resized: DragSnap.shared.resized(el)
            default: break
            }
        }
    }

    // MARK: Drag recognition

    private func moved(_ pid: pid_t, _ el: AXUIElement) {
        guard session == nil, pid != ownPid, AppSettings.shared.snapWindows,
              NSEvent.pressedMouseButtons & 1 != 0,
              (AX.attr(el, kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole,
              AX.isSettable(el, kAXSizeAttribute),
              let id = AX.windowID(el), let f = AX.frame(el) else { return }
        // Windows snaps windows dragged by the title bar. The grab point stays put relative to the window
        // during a drag, so it must be in the top band and not on an edge (that would be a resize).
        let m = Self.mouse()
        let dy = m.y - f.minY
        guard dy >= 4, dy <= 100, m.x - f.minX >= 6, f.maxX - m.x >= 6 else { return }
        SnapAssist.shared.dismiss()
        var s = Session(target: .init(pid: pid, element: el, id: id), size: f.size)
        restoreSizeForDrag(&s, f)
        session = s
        enableTap()
    }

    /// A size change during the drag means it's a resize from the top or left edge, not a move.
    private func resized(_ el: AXUIElement) {
        guard var s = session, !s.resized, CFEqual(s.target.element, el), Date() > s.ignoreResizeUntil,
              let f = AX.frame(el), abs(f.width - s.size.width) > 2 || abs(f.height - s.size.height) > 2 else { return }
        s.resized = true
        session = s
        setZone(nil)
        bar.hide()
    }

    /// Windows: dragging a snapped or maximized window gives it back its size from before, under the pointer
    /// at the same relative position along the title bar.
    private func restoreSizeForDrag(_ s: inout Session, _ f: CGRect) {
        guard let r = WindowSnap.shared.restoreFrameForDrag(s.target.id, size: f.size), r.width > 50, r.height > 50,
              abs(r.width - f.width) > 2 || abs(r.height - f.height) > 2 else { return }
        let m = Self.mouse()
        var x = m.x - (m.x - f.minX) * (r.width / max(f.width, 1))
        x = min(max(x, m.x - r.width + 40), m.x - 40)
        let target = CGRect(x: x.rounded(), y: f.minY, width: r.width, height: r.height)
        s.ignoreResizeUntil = Date().addingTimeInterval(0.6)
        s.size = r.size
        WindowSnap.shared.forget(s.target.id)
        Log.write("snap (drag): restore size of \(s.target.id) -> \(CaptionController.describe(target))")
        AX.setSize(s.target.element, target.size)
        AX.setPosition(s.target.element, target.origin)
        if let now = AX.frame(s.target.element) { s.size = now.size }      // apps may keep a minimum size
    }

    private static func mouse() -> CGPoint {
        let m = NSEvent.mouseLocation
        return CGPoint(x: m.x, y: CaptionController.primaryHeight - m.y)
    }

    // MARK: Pointer tracking (event tap on only while dragging)

    private func enableTap() {
        if tap == nil {
            let mask = CGEventMask(1 << CGEventType.leftMouseDragged.rawValue) | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
            let cb: CGEventTapCallBack = { _, type, event, _ in
                let loc = event.location
                MainActor.assumeIsolated {
                    let d = DragSnap.shared
                    switch type {
                    case .leftMouseDragged: d.dragged(to: loc)
                    case .leftMouseUp: DispatchQueue.main.async { MainActor.assumeIsolated { d.mouseUp() } }
                    case .tapDisabledByTimeout, .tapDisabledByUserInput:
                        if d.session != nil, let t = d.tap { CGEvent.tapEnable(tap: t, enable: true) }
                    default: break
                    }
                }
                return Unmanaged.passUnretained(event)
            }
            guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                            eventsOfInterest: mask, callback: cb, userInfo: nil) else {
                Log.write("snap: drag event tap unavailable")
                session = nil
                return
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
            tap = t
        }
        CGEvent.tapEnable(tap: tap!, enable: true)
        upTimer?.invalidate()
        // Backstop in case the release never reaches the tap.
        upTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { if NSEvent.pressedMouseButtons & 1 == 0 { DragSnap.shared.mouseUp() } }
        }
        dragged(to: Self.mouse())
    }

    private func stopTap() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        upTimer?.invalidate()
        upTimer = nil
    }

    private func dragged(to p: CGPoint) {
        guard let s = session else { stopTap(); return }
        guard !s.resized else { return }
        evaluate(p)
    }

    private func mouseUp() {
        stopTap()
        guard let s = session else { return }
        session = nil
        let z = zone
        zone = nil
        pending = nil
        pendingTimer?.invalidate()
        preview.hide()
        bar.hide()
        guard let z, !s.resized else { return }
        // Let the window server finish the drag before moving the window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            MainActor.assumeIsolated {
                WindowSnap.shared.snap(s.target, zone: z.unit, workArea: z.workArea, layout: z.layout, source: "drag")
            }
        }
    }

    // MARK: Zones

    private enum Edge { case left, right, top }

    private func evaluate(_ p: CGPoint) {
        guard let screen = NSScreen.screens.first(where: { CaptionController.axRect($0.frame).contains(p) }) else {
            setZone(nil); bar.hide(); return
        }
        let sf = CaptionController.axRect(screen.frame)
        let wa = CaptionController.workArea(screen: screen)

        // Snap layouts bar at the top center.
        if AppSettings.shared.snapBarOnDrag, let hit = bar.track(p, screenTop: sf.minY + edge, workArea: wa) {
            if case .zone(let layout, let unit) = hit {
                setZone(Zone(unit: unit, workArea: wa, layout: layout, fromBar: true))
            }
            else { setZone(nil) }
            return
        }
        bar.hide()

        let Z = WindowSnap.Zones.self
        let shared: (Edge) -> Bool = { self.edgeShared(screen, $0, at: p) }
        func near(_ d: CGFloat, _ e: Edge) -> Bool { d <= (shared(e) ? sharedEdge : edge) }
        var hit: (CGRect, Edge)?
        if near(p.x - sf.minX, .left) || near(sf.maxX - 1 - p.x, .right) {
            let left = p.x - sf.minX < sf.maxX - p.x
            let e: Edge = left ? .left : .right
            if p.y - sf.minY < corner { hit = (left ? Z.topLeft : Z.topRight, e) }
            else if sf.maxY - p.y < corner { hit = (left ? Z.bottomLeft : Z.bottomRight, e) }
            else { hit = (left ? Z.left : Z.right, e) }
        } else if near(p.y - sf.minY, .top) {
            if p.x - sf.minX < corner { hit = (Z.topLeft, .top) }
            else if sf.maxX - p.x < corner { hit = (Z.topRight, .top) }
            else { hit = (Z.full, .top) }
        }
        guard let h = hit else { setZone(nil); return }
        let (unit, e) = h
        let z = Zone(unit: unit, workArea: wa, layout: Z.layout(for: unit))
        if shared(e) { setPending(z) } else { setZone(z) }
    }

    /// Another display continues past this edge where the pointer is.
    private func edgeShared(_ screen: NSScreen, _ e: Edge, at p: CGPoint) -> Bool {
        let sf = CaptionController.axRect(screen.frame)
        return NSScreen.screens.contains { s in
            guard s != screen else { return false }
            let o = CaptionController.axRect(s.frame)
            switch e {
            case .left: return abs(o.maxX - sf.minX) <= 1 && p.y >= o.minY && p.y < o.maxY
            case .right: return abs(o.minX - sf.maxX) <= 1 && p.y >= o.minY && p.y < o.maxY
            case .top: return abs(o.maxY - sf.minY) <= 1 && p.x >= o.minX && p.x < o.maxX
            }
        }
    }

    private func setPending(_ z: Zone) {
        if zone == z || pending == z { return }
        if zone != nil { setZone(nil) }
        pending = z
        pendingTimer?.invalidate()
        pendingTimer = Timer.scheduledTimer(withTimeInterval: sharedDwell, repeats: false) { _ in
            MainActor.assumeIsolated {
                let d = DragSnap.shared
                guard d.session != nil, let p = d.pending, p == z else { return }
                // Still resting at that edge?
                d.pending = nil
                d.evaluateDwell(z)
            }
        }
    }

    private func evaluateDwell(_ z: Zone) {
        let p = Self.mouse()
        guard let screen = NSScreen.screens.first(where: { CaptionController.axRect($0.frame).contains(p) }),
              CaptionController.workArea(screen: screen) == z.workArea else { return }
        let sf = CaptionController.axRect(screen.frame)
        let atEdge = p.x - sf.minX <= sharedEdge || sf.maxX - 1 - p.x <= sharedEdge || p.y - sf.minY <= sharedEdge
        if atEdge { applyZone(z) }
    }

    private func setZone(_ z: Zone?) {
        pending = nil
        pendingTimer?.invalidate()
        applyZone(z)
    }

    private func applyZone(_ z: Zone?) {
        guard z != zone else { return }
        zone = z
        guard let z, let s = session else { preview.hide(); return }
        let target = WindowSnap.rect(z.unit, in: z.workArea)
        // Edge drags: behind the dragged window, above every other window (Windows 11; user's choice 2026-11-15).
        // Snap bar: in front, where the window would otherwise hide it.
        let from = AX.frame(s.target.element), icon = WindowList.icon(s.target.pid)
        if z.fromBar { preview.show(target, from: from, icon: icon, above: s.target.id) }
        else { preview.show(target, from: from, icon: icon, below: s.target.id) }
    }
}

/// The translucent rounded rectangle that shows where a window will snap (acrylic with the app's icon in the
/// middle). It glides between zones. While dragging it sits just below the dragged window, as on Windows 11; the
/// Snap Layouts flyout puts it above the window, which isn't moving then.
@MainActor
final class SnapPreview {
    private var panel: OverlayPanel?
    private var tint: NSView?
    private var iconView: NSImageView?
    private var visible = false

    func show(_ frame: CGRect, from start: CGRect?, icon: NSImage, below id: CGWindowID) {
        show(frame, from: start, icon: icon, relativeTo: id, place: .below)
    }

    func show(_ frame: CGRect, from start: CGRect?, icon: NSImage, above id: CGWindowID) {
        show(frame, from: start, icon: icon, relativeTo: id, place: .above)
    }

    private func show(_ frame: CGRect, from start: CGRect?, icon: NSImage, relativeTo id: CGWindowID,
                      place: NSWindow.OrderingMode) {
        let p = panel ?? make()
        let target = CaptionController.shared.cocoaRect(frame).insetBy(dx: 6, dy: 6)
        iconView?.image = icon
        styleTint()
        if !visible {
            visible = true
            let from = start.map { CaptionController.shared.cocoaRect($0) } ?? target
            p.setFrame(from, display: false)
            p.alphaValue = 0
        }
        // Every time: an app may raise its window after the preview appeared.
        p.order(place, relativeTo: Int(id))
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.1, 0.9, 0.2, 1)
            p.animator().setFrame(target, display: true)
            p.animator().alphaValue = 1
        }
    }

    func hide() {
        guard visible, let p = panel else { return }
        visible = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            p.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // Unless it was shown again meanwhile (a new zone right after leaving the old one).
            MainActor.assumeIsolated { if self?.visible != true { p.orderOut(nil) } }
        })
    }

    private func make() -> OverlayPanel {
        let p = OverlayPanel(level: .normal)
        p.ignoresMouseEvents = true
        let root = NSView()
        root.wantsLayer = true
        let fx = NSVisualEffectView()
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.maskImage = VisualEffect.mask(8)
        fx.autoresizingMask = [.width, .height]
        root.addSubview(fx)
        let t = NSView()
        t.wantsLayer = true
        t.layer?.cornerRadius = 8
        t.layer?.cornerCurve = .continuous
        t.layer?.borderWidth = 1
        t.autoresizingMask = [.width, .height]
        root.addSubview(t)
        let iv = NSImageView()
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.frame = NSRect(x: 0, y: 0, width: 56, height: 56)
        iv.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        root.addSubview(iv)
        p.contentView = root
        p.setFrame(NSRect(x: 0, y: 0, width: 200, height: 200), display: false)
        fx.frame = root.bounds
        t.frame = root.bounds
        iv.frame.origin = NSPoint(x: 72, y: 72)
        panel = p
        tint = t
        iconView = iv
        return p
    }

    private func styleTint() {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        tint?.layer?.backgroundColor = (dark ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 1, alpha: 0.35)).cgColor
        tint?.layer?.borderColor = (dark ? NSColor(white: 1, alpha: 0.18) : NSColor(white: 0, alpha: 0.12)).cgColor
    }
}

/// Snap layouts bar shown while dragging a window toward the top center of a display (Windows 11 22H2+):
/// a small handle first, the layouts once the pointer reaches it. The pointer is tracked by DragSnap (the
/// bar never takes the mouse; the drag belongs to the window server).
@MainActor
final class SnapBar {
    enum Hit { case bar, zone([CGRect], CGRect) }

    private var panel: OverlayPanel?
    private let model = SnapBarModel()
    private var workArea: CGRect = .zero
    private var expandedFrame: CGRect = .zero        // AX
    private static let pad: CGFloat = 10, spacing: CGFloat = 10
    var debugGeometry: (CGRect, CGSize) { (expandedFrame, model.tile) }

    func track(_ p: CGPoint, screenTop: CGFloat, workArea wa: CGRect) -> Hit? {
        if wa != workArea { configure(wa) }
        // The very top edge is "maximize", left to DragSnap.
        guard p.y > screenTop else { if model.expanded { model.expanded = false; model.highlight = nil }; return nil }
        let e = expandedFrame
        let inExpanded = p.x >= e.minX - 16 && p.x <= e.maxX + 16 && p.y <= e.maxY + 16
        let reveal = p.y <= wa.minY + 48 && abs(p.x - wa.midX) <= 100
        let nearTop = p.y <= wa.minY + 140 && abs(p.x - wa.midX) <= max(e.width / 2 + 40, wa.width * 0.15)
        if (model.expanded && inExpanded) || reveal {
            show(expanded: true)
            for (i, layout) in model.layouts.enumerated() {
                let tile = CGRect(x: e.minX + Self.pad + CGFloat(i) * (model.tile.width + Self.spacing), y: e.minY + Self.pad,
                                  width: model.tile.width, height: model.tile.height)
                for (z, unit) in layout.enumerated() {
                    let r = CGRect(x: tile.minX + unit.minX * tile.width, y: tile.minY + unit.minY * tile.height,
                                   width: unit.width * tile.width, height: unit.height * tile.height).insetBy(dx: 1.5, dy: 1.5)
                    if r.contains(p) {
                        model.highlight = SnapBarModel.Key(layout: i, zone: z)
                        return .zone(layout, unit)
                    }
                }
            }
            model.highlight = nil
            return .bar
        }
        if nearTop {
            show(expanded: false)
            model.highlight = nil
            return .bar
        }
        hide()
        return nil
    }

    private func configure(_ wa: CGRect) {
        workArea = wa
        model.layouts = SnapLayouts.layouts(for: wa.size)
        let t = SnapLayouts.tileSize(for: wa.size)
        model.tile = CGSize(width: (t.width * 0.8).rounded(), height: (t.height * 0.8).rounded())
        let n = CGFloat(model.layouts.count)
        let w = Self.pad * 2 + n * model.tile.width + (n - 1) * Self.spacing
        let h = Self.pad * 2 + model.tile.height
        expandedFrame = CGRect(x: (wa.midX - w / 2).rounded(), y: wa.minY + 8, width: w, height: h)
        if let p = panel { p.setFrame(CaptionController.shared.cocoaRect(expandedFrame), display: false) }
    }

    private func show(expanded: Bool) {
        if model.expanded != expanded { model.expanded = expanded }
        let p = panel ?? make()
        if !p.isVisible {
            p.setFrame(CaptionController.shared.cocoaRect(expandedFrame), display: false)
            p.alphaValue = 1
            p.orderFrontRegardless()
        }
    }

    func hide() {
        guard let p = panel, p.isVisible else { return }
        model.expanded = false
        model.highlight = nil
        p.orderOut(nil)
    }

    private func make() -> OverlayPanel {
        let p = OverlayPanel(level: .floating)
        p.ignoresMouseEvents = true
        let host = NSHostingView(rootView: SnapBarView(model: model, pad: Self.pad, spacing: Self.spacing))
        host.sizingOptions = []
        p.contentView = host
        p.setFrame(CaptionController.shared.cocoaRect(expandedFrame), display: false)
        panel = p
        return p
    }
}

@MainActor
final class SnapBarModel: ObservableObject {
    struct Key: Equatable { let layout: Int; let zone: Int }
    @Published var expanded = false
    @Published var highlight: Key?
    @Published var layouts: [[CGRect]] = []
    @Published var tile = CGSize(width: 66, height: 37)
}

struct SnapBarView: View {
    @ObservedObject var model: SnapBarModel
    let pad: CGFloat
    let spacing: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack(alignment: .top) {
            if model.expanded {
                HStack(spacing: spacing) {
                    ForEach(model.layouts.indices, id: \.self) { i in tile(i) }
                }
                .padding(pad)
                .background(chrome(RoundedRectangle(cornerRadius: 8, style: .continuous)))
                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
            } else {
                Capsule().fill(Theme.text(scheme).opacity(0.45)).frame(width: 36, height: 4)
                    .padding(.horizontal, 22).padding(.vertical, 6)
                    .background(chrome(Capsule()))
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeOut(duration: 0.15), value: model.expanded)
    }

    private func chrome<S: InsettableShape>(_ shape: S) -> some View {
        shape.fill(Theme.flyoutTint(scheme))
            .background(VisualEffect(material: .hudWindow, cornerRadius: 8).clipShape(shape))
            .overlay(shape.strokeBorder(Theme.border(scheme), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
    }

    private func tile(_ i: Int) -> some View {
        let t = model.tile
        return ZStack(alignment: .topLeading) {
            ForEach(model.layouts[i].indices, id: \.self) { z in
                let unit = model.layouts[i][z]
                let r = CGRect(x: unit.minX * t.width, y: unit.minY * t.height,
                               width: unit.width * t.width, height: unit.height * t.height).insetBy(dx: 1.5, dy: 1.5)
                let on = model.highlight == SnapBarModel.Key(layout: i, zone: z)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(on ? Theme.accent : (scheme == .dark ? Color.white.opacity(0.09) : Color.white.opacity(0.85)))
                    .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(on ? Theme.accent : Theme.border(scheme).opacity(2), lineWidth: 1))
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
            }
        }
        .frame(width: t.width, height: t.height, alignment: .topLeading)
    }
}
