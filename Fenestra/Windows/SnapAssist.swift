import AppKit
import SwiftUI

/// Snap Assist (Windows 11): after a window is snapped, the empty part of the layout shows the other open
/// windows; pick one and it fills that zone, then the next empty zone asks the same. Escape, a click
/// elsewhere, or pressing a key in another app ends it. Zones another window already fills are skipped.
@MainActor
final class SnapAssist {
    static let shared = SnapAssist()

    private var panel: OverlayPanel?
    private var model: WindowGridModel?
    private var zones: [CGRect] = []          // unit rects still to fill
    private var workArea: CGRect = .zero
    private var placed: Set<CGWindowID> = []
    private var monitors: [Any] = []
    private var openedAt = Date.distantPast

    var isOpen: Bool { panel?.isVisible == true }

    /// Diagnostics: the first card's center (AX coordinates) and its window.
    var debugFirstCard: (CGPoint, SwitchWindow)? {
        guard let m = model, let p = panel, let row = m.rows.first, let i = row.first else { return nil }
        let rowW = row.map(m.cardWidth).reduce(0, +) + CGFloat(max(row.count - 1, 0)) * WindowGridModel.spacing
        let viewH = min(m.contentSize.height + 48, p.frame.height)
        let x = p.frame.midX - rowW / 2 + m.cardWidth(i) / 2
        let top = p.frame.midY + viewH / 2 - 24
        let y = top - m.cardHeight / 2
        return (CGPoint(x: x, y: CaptionController.primaryHeight - y), m.items[i])
    }

    func offer(after t: WindowSnap.Target, layout: [CGRect], filled: CGRect, workArea wa: CGRect) {
        dismiss()
        workArea = wa
        placed = [t.id]
        // Zones some other window already fills (a snap group on Windows) don't need assistance.
        let others = Self.onscreenBounds(excluding: t.id)
        zones = layout.filter { z in
            guard z != filled else { return false }
            let r = WindowSnap.rect(z, in: wa)
            return !others.contains { abs($0.minX - r.minX) <= 6 && abs($0.minY - r.minY) <= 6
                && abs($0.width - r.width) <= 6 && abs($0.height - r.height) <= 6 }
        }
        SnapGroups.shared.assistStarted(first: t, zone: filled, workArea: wa)
        // Let the snapped window settle first (and the drag's mouse-up finish).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            MainActor.assumeIsolated { SnapAssist.shared.showNext() }
        }
    }

    private func showNext() {
        guard let z = zones.first else { dismiss(); return }
        let candidates = WindowList.all().filter { !placed.contains($0.id) }
        guard !candidates.isEmpty else { dismiss(); return }
        let frame = WindowSnap.rect(z, in: workArea)
        let cocoa = CaptionController.shared.cocoaRect(frame).insetBy(dx: 6, dy: 6)

        let m = WindowGridModel(items: candidates)
        m.selected = 0
        // Windows fills the zone with fairly large thumbnails (about two per row in a half).
        m.layout(in: CGSize(width: cocoa.width - 48, height: cocoa.height - 48),
                 maxH: min(max(cocoa.height * 0.28, 120), 260), minH: 70)
        m.onPick = { w in SnapAssist.shared.pick(w) }
        m.onClose = { w in WindowList.close(w) }
        m.loadThumbnails(maxSize: CGSize(width: 520, height: 300))
        model = m

        let p = panel ?? OverlayPanel(level: .floating, keyable: true)
        p.contentView = FirstClickHostingView(rootView: SnapAssistView(model: m))
        p.contentView?.roundCorners(8)
        p.setFrame(cocoa, display: false)
        p.hasShadow = true
        if panel == nil {
            p.alphaValue = 0
            p.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                p.animator().alphaValue = 1
            }
        } else {
            p.makeKeyAndOrderFront(nil)
        }
        p.invalidateShadow()
        panel = p
        openedAt = Date()
        installMonitors()
    }

    /// Diagnostics: picks the card of window `id`, as a click on it would.
    func debugPick(_ id: CGWindowID) -> Bool {
        guard let w = model?.items.first(where: { $0.id == id }) else { return false }
        pick(w)
        return true
    }

    private func pick(_ w: SwitchWindow) {
        guard let z = zones.first else { return }
        zones.removeFirst()
        placed.insert(w.id)
        let target = WindowSnap.Target(pid: w.pid, element: w.element, id: w.id)
        WindowSnap.shared.snap(target, zone: z, workArea: workArea, layout: nil, source: "assist", assist: false)
        SnapGroups.shared.assistPicked(target, zone: z)
        if zones.isEmpty { dismiss(); return }
        // After the picked window's app has come forward, so the panel keeps the keyboard.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            MainActor.assumeIsolated { if !SnapAssist.shared.zones.isEmpty { SnapAssist.shared.showNext() } }
        }
    }

    func dismiss() {
        SnapGroups.shared.assistEnded()
        zones = []
        model = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        guard let p = panel else { return }
        panel = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            p.animator().alphaValue = 0
        }, completionHandler: { p.orderOut(nil) })
    }

    private func installMonitors() {
        guard monitors.isEmpty else { return }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown], handler: { _ in
            MainActor.assumeIsolated {
                // The mouse-up of the drag that snapped the window can arrive right after we open.
                if Date().timeIntervalSince(SnapAssist.shared.openedAt) > 0.25 { SnapAssist.shared.dismiss() }
            }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown], handler: { e in
            let swallow = MainActor.assumeIsolated { SnapAssist.shared.local(e) }
            return swallow ? nil : e
        }) { monitors.append(l) }
    }

    /// Returns true to swallow the event.
    private func local(_ e: NSEvent) -> Bool {
        guard let m = model, let p = panel else { return false }
        if e.type != .keyDown {
            if e.window !== p { dismiss() }
            return false
        }
        switch e.keyCode {
        case 53: dismiss(); return true                                   // Esc
        case 123: m.move(.left); return true
        case 124: m.move(.right); return true
        case 125: m.move(.down); return true
        case 126: m.move(.up); return true
        case 36, 76, 49: if let s = m.selected { m.pick(s) }; return true  // Return, Enter, Space
        case 48: m.move(e.modifierFlags.contains(.shift) ? .left : .right); return true   // Tab
        default: return false
        }
    }

    static func onscreenBounds(excluding id: CGWindowID) -> [CGRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let own = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0, (w[kCGWindowOwnerPID as String] as? pid_t) != own,
                  (w[kCGWindowNumber as String] as? CGWindowID) != id,
                  let bd = w[kCGWindowBounds as String] as? NSDictionary else { return nil }
            return CGRect(dictionaryRepresentation: bd)
        }
    }
}

/// Acrylic area over the empty zone with the window cards centered in it.
struct SnapAssistView: View {
    @ObservedObject var model: WindowGridModel
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack {
            Color.clear
            ScrollView(.vertical) {
                WindowGridView(model: model).padding(24)
                    .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
            .frame(maxHeight: model.contentSize.height + 48)
        }
        .background(Theme.flyoutTint(scheme).opacity(0.7))
        .background(VisualEffect(material: .hudWindow, cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border(scheme), lineWidth: 1))
        .foregroundStyle(Theme.text(scheme))
        .font(Theme.font(13))
    }
}
