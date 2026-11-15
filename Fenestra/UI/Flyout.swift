import AppKit
import SwiftUI

/// Borderless panel used for every Windows-style flyout (Quick Settings, calendar, thumbnails, ...).
final class FlyoutPanel: NSPanel {
    /// Lets the Wi-Fi password field take typing. Off for clipboard history: the app you type in keeps focus.
    var keyable = true
    override var canBecomeKey: Bool { keyable }
    override var canBecomeMain: Bool { false }
}

/// Opens one flyout at a time above the taskbar, with the Windows 11 slide-up (200 ms, ease-out),
/// and closes it on a click anywhere else or on Escape.
@MainActor
final class FlyoutManager {
    static let shared = FlyoutManager()

    private(set) var currentID: String?
    private var panel: FlyoutPanel?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var keyMonitor: Any?
    private var ignoreRect: NSRect = .zero
    private var onClose: (() -> Void)?

    /// Where a flyout opens: above the taskbar (tray, thumbnails) or just below its anchor
    /// (Snap Layouts under a window's maximize button), on the anchor's display.
    enum Placement { case aboveTaskbar, below }
    private var placement: Placement = .aboveTaskbar
    private(set) var placementScreen: NSScreen?

    func isOpen(_ id: String) -> Bool { currentID == id }
    /// Screen frame of the open flyout, if any.
    var panelFrame: NSRect? { panel?.frame }

    /// - Parameters:
    ///   - anchor: screen rect of the button that opened it (clicks on it toggle instead of reopening).
    ///   - align: .center places the panel centered over the anchor, .trailing aligns right edges.
    func toggle<V: View>(id: String, anchor: NSRect, align: HorizontalAlignment = .trailing,
                         gap: CGFloat = 12, @ViewBuilder content: () -> V) {
        if currentID == id { close(); return }
        show(id: id, anchor: anchor, align: align, gap: gap, content: content)
    }

    func show<V: View>(id: String, anchor: NSRect, align: HorizontalAlignment = .trailing,
                       gap: CGFloat = 12, placement: Placement = .aboveTaskbar, keyable: Bool = true,
                       onClose: (() -> Void)? = nil, @ViewBuilder content: () -> V) {
        let t0 = CACurrentMediaTime()
        close(animated: false)
        currentID = id
        self.onClose = onClose
        ignoreRect = anchor
        self.placement = placement
        currentAlign = align

        // A flyout built ahead of time (Quick Settings, calendar) skips SwiftUI's first layout: 40 to 120 ms
        // between the click and the first frame (measured 2026-11-15). Yesterday's calendar is built again.
        let built: Built
        var warm = false
        if let pre = prepared.removeValue(forKey: id), pre.day == FlyoutManager.today() {
            built = pre.built
            warm = true
        } else {
            built = build(content())
        }
        let p = built.panel
        let size = built.token.size
        token = built.token

        let screen: NSScreen
        if placement == .below {
            screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) }
                ?? NSScreen.screens[0]
        } else {
            // Phase 5: above the taskbar the anchor belongs to (main or a secondary display's).
            screen = TaskbarController.shared.screen(for: NSPoint(x: anchor.midX, y: anchor.midY))
        }
        placementScreen = screen
        var x: CGFloat
        switch align {
        case .center: x = anchor.midX - size.width / 2
        case .leading: x = anchor.minX
        default: x = anchor.maxX - size.width
        }
        let margin: CGFloat = placement == .below ? 4 : 12
        x = min(max(x, screen.frame.minX + margin), screen.frame.maxX - size.width - margin)
        let y: CGFloat
        if placement == .below {
            // Under the anchor; flipped above it only when the window sits at the very bottom of the screen.
            let below = anchor.minY - gap - size.height
            y = below >= screen.visibleFrame.minY ? below : anchor.maxY + gap
        } else {
            y = screen.frame.minY + Theme.taskbarHeight + gap
        }
        let finalFrame = NSRect(x: x, y: y, width: size.width, height: size.height)
        let slide: CGFloat = placement == .below ? 8 : -24

        p.keyable = keyable
        p.ignoresMouseEvents = false
        p.alphaValue = 0
        p.setFrame(finalFrame.offsetBy(dx: 0, dy: slide), display: false)
        p.orderFrontRegardless()
        panel = p
        installMonitors()
        NotificationCenter.default.post(name: FlyoutManager.didShow, object: id)

        // Draw the first frame before the animation clock starts. Started at once, the slide's first visible
        // frame landed 60% of the way up (the Windows curve does most of its move early) and looked like a jump.
        p.displayIfNeeded()
        CATransaction.flush()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard FlyoutManager.shared.panel === p else { return }
                p.invalidateShadow()
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.2
                    ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.1, 0.9, 0.2, 1)   // Windows "decelerate"
                    p.animator().alphaValue = 1
                    p.animator().setFrame(finalFrame, display: true)
                }
                let m = FlyoutManager.shared
                m.openedAt = CACurrentMediaTime()
                m.lastShowMs = (m.openedAt - t0) * 1000
                Log.write(String(format: "flyout: %@ %@, animation starts %.0f ms after the click", id,
                                 warm ? "prepared" : "built now", m.lastShowMs))
            }
        }
    }
    /// Main-thread time from show() to the start of its animation (FlyoutDiagnostics).
    private(set) var lastShowMs: Double = 0

    /// Posted with the flyout's id as the object when it opens (a prepared view refreshes its state then).
    static let didShow = Notification.Name("FlyoutManager.didShow")
    /// Posted with the flyout's id however it closes (its button, a click elsewhere, Escape, another flyout).
    static let didClose = Notification.Name("FlyoutManager.didClose")

    // MARK: Building panels, and flyouts prepared ahead of time

    private struct Built { let panel: FlyoutPanel; let token: FlyoutToken }
    private struct Prepared { let built: Built; let day: Int }
    private var prepared: [String: Prepared] = [:]
    private var builders: [String: () -> AnyView] = [:]
    private var token: FlyoutToken?

    private static func today() -> Int { Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0 }

    private func build<V: View>(_ content: V) -> Built {
        let token = FlyoutToken()
        let host = FirstClickHostingView(rootView: FlyoutChrome(content: content, token: token))
        // Measure with the default sizing options (fittingSize is 0 x 0 without them), then stop SwiftUI
        // from resizing the window itself: AppKit would keep the top edge fixed and grow it downward behind
        // the taskbar. contentSizeChanged() resizes it from the bottom instead.
        host.layoutSubtreeIfNeeded()
        var size = host.fittingSize
        if size.width < 1 || size.height < 1 { size = host.intrinsicContentSize }
        token.size = size
        host.sizingOptions = []
        host.roundCorners(8)
        let p = FlyoutPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        p.contentView = host
        ArrowCursor.install(on: host)
        return Built(panel: p, token: token)
    }

    /// Keeps one copy of this flyout built and drawn, hidden, so opening it doesn't wait for SwiftUI.
    /// A fresh copy is made after each close, so every opening starts from a new view as before.
    func prepare<V: View>(id: String, @ViewBuilder content: @escaping () -> V) {
        builders[id] = { AnyView(content()) }
        schedulePrepare(id, after: 1.5)
    }

    private func schedulePrepare(_ id: String, after delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated { FlyoutManager.shared.prepareNow(id) }
        }
    }

    private func prepareNow(_ id: String) {
        guard let make = builders[id], currentID != id else { return }
        if let pre = prepared[id], pre.day == FlyoutManager.today() { return }
        let t0 = CACurrentMediaTime()
        let built = build(make())
        // Draw it once, invisible and click-through, so the first frame on opening is ready too.
        let p = built.panel
        let screen = NSScreen.screens[0].frame
        p.ignoresMouseEvents = true
        p.alphaValue = 0
        p.setFrameOrigin(NSPoint(x: screen.maxX - p.frame.width - 12, y: screen.minY + Theme.taskbarHeight + 12))
        p.orderFrontRegardless()
        p.displayIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            MainActor.assumeIsolated {
                if FlyoutManager.shared.panel !== p { p.orderOut(nil) }
            }
        }
        prepared[id] = Prepared(built: built, day: FlyoutManager.today())
        Log.write(String(format: "flyout: %@ prepared in %.0f ms", id, (CACurrentMediaTime() - t0) * 1000))
    }

    private var currentAlign: HorizontalAlignment = .trailing

    /// Called by FlyoutChrome whenever its content's natural size changes (e.g. opening the Wi-Fi list).
    /// The bottom edge stays just above the taskbar and the panel grows upward, as on Windows.
    func contentSizeChanged(_ size: CGSize, token: FlyoutToken) {
        guard size.width > 0, size.height > 0 else { return }
        token.size = size
        guard let p = panel, token === self.token else { return }   // a prepared, hidden flyout: just remember it
        let old = p.frame
        guard abs(old.width - size.width) > 0.5 || abs(old.height - size.height) > 0.5 else { return }
        var x: CGFloat
        switch currentAlign {
        case .center: x = old.midX - size.width / 2
        case .leading: x = old.minX
        default: x = old.maxX - size.width
        }
        let screen = placementScreen ?? TaskbarController.shared.screen ?? NSScreen.screens[0]
        x = min(max(x, screen.frame.minX + 12), screen.frame.maxX - size.width - 12)
        let maxH = screen.frame.height - Theme.taskbarHeight - 24
        let h = min(size.height, maxH)
        let y = placement == .below ? old.maxY - h : old.minY      // below: the top edge stays put
        let frame = NSRect(x: x, y: y, width: size.width, height: h)
        // Opening a sub-page (Wi-Fi list, Bluetooth) resizes in 0.2 s like Windows instead of jumping;
        // during the open animation the size just follows.
        guard CACurrentMediaTime() - openedAt > 0.25 else { p.setFrame(frame, display: true); p.invalidateShadow(); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.1, 0.9, 0.2, 1)
            p.animator().setFrame(frame, display: true)
        }, completionHandler: { p.invalidateShadow() })
    }
    fileprivate var openedAt: CFTimeInterval = 0

    func makeKey() { panel?.makeKey() }

    func close(animated: Bool = true) {
        removeMonitors()
        if let id = currentID, builders[id] != nil { schedulePrepare(id, after: 0.5) }
        if let id = currentID { NotificationCenter.default.post(name: FlyoutManager.didClose, object: id) }
        currentID = nil
        token = nil
        if let done = onClose { onClose = nil; done() }
        guard let p = panel else { return }
        panel = nil
        guard animated else { p.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            p.animator().alphaValue = 0
            p.animator().setFrame(p.frame.offsetBy(dx: 0, dy: placement == .below ? 6 : -12), display: true)
        }, completionHandler: { p.orderOut(nil) })
    }

    private func installMonitors() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            MainActor.assumeIsolated { FlyoutManager.shared.close() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { e in
            MainActor.assumeIsolated {
                let m = FlyoutManager.shared
                let loc = NSEvent.mouseLocation
                if let p = m.panel, p.frame.contains(loc) { return }
                if m.ignoreRect.contains(loc) { return }       // the opening button toggles it itself
                m.close()
            }
            return e
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { MainActor.assumeIsolated { FlyoutManager.shared.close() }; return nil }
            return e
        }
    }

    private func removeMonitors() {
        [globalMonitor, localMonitor, keyMonitor].compactMap { $0 }.forEach(NSEvent.removeMonitor)
        globalMonitor = nil; localMonitor = nil; keyMonitor = nil
    }
}

/// Acrylic background, 8 px corners and hairline border shared by all flyouts.
/// Ties a FlyoutChrome to its panel, so a prepared (hidden) flyout's size changes don't resize the open one.
final class FlyoutToken {
    var size: CGSize = .zero
}

struct FlyoutChrome<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    let content: Content
    let token: FlyoutToken
    var body: some View {
        content
            .background(Theme.flyoutTint(scheme))
            .background(VisualEffect(material: .hudWindow, cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border(scheme), lineWidth: 1))
            .foregroundStyle(Theme.text(scheme))
            .font(Theme.font(13))
            .fixedSize()
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
                FlyoutManager.shared.contentSizeChanged(size, token: token)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}
