import AppKit
import SwiftUI

/// Task View (taskbar button or Control+Option+Tab, Windows key + Tab): every open window as a thumbnail on
/// its own display, over a blurred backdrop; the taskbar stays visible. Click a window to switch to it, click
/// the backdrop or press Esc to go back. Arrows move, Return picks, the X closes a window.
/// No virtual desktops (your decision), so no desktops strip.
@MainActor
final class TaskView {
    static let shared = TaskView()

    private struct Page {
        let panel: OverlayPanel
        let model: WindowGridModel
    }
    private var pages: [Page] = []
    private var current = 0                 // page holding the keyboard selection
    private var monitors: [Any] = []
    private var closedByClickAt = Date.distantPast

    var isOpen: Bool { !pages.isEmpty }

    func toggle() {
        if isOpen { close(); return }
        // The click that just closed it (on the taskbar button) must not reopen it.
        if Date().timeIntervalSince(closedByClickAt) < 0.35 { return }
        open()
    }

    func open() {
        guard !isOpen else { return }
        if AltTab.shared.active { AltTab.shared.cancel() }
        SnapAssist.shared.dismiss()
        FlyoutManager.shared.close(animated: false)
        StartController.shared.hide(animated: false)
        let all = WindowList.all()
        let ph = CaptionController.primaryHeight
        let screens = NSScreen.screens

        func screenIndex(_ w: SwitchWindow) -> Int {
            let c = NSPoint(x: w.frame.midX, y: ph - w.frame.midY)
            return screens.firstIndex { $0.frame.contains(c) } ?? 0
        }
        for (i, screen) in screens.enumerated() {
            var frame = screen.frame
            if TaskbarController.shared.hasTaskbar(screen) {
                // The taskbar stays usable while Task View is open.
                let h = TaskbarController.shared.reservedHeight > 0 ? Theme.taskbarHeight : 0
                frame.origin.y += h; frame.size.height -= h
            }
            let items = all.filter { screenIndex($0) == i }
            let m = WindowGridModel(items: items)
            let top = CaptionController.menuBarInset(screen)      // menu bar
            m.layout(in: CGSize(width: frame.width - 120, height: frame.height - top - 120),
                     maxH: min(frame.height * 0.32, 300), minH: 70)
            m.onPick = { w in TaskView.shared.pick(w) }
            m.onClose = { w in WindowList.close(w) }
            m.loadThumbnails(maxSize: CGSize(width: 560, height: 320))

            let p = OverlayPanel(level: NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow))),
                                 keyable: true)
            let host = FirstClickHostingView(rootView: TaskViewPage(model: m, topInset: top))
            host.sizingOptions = []
            p.contentView = host
            p.setFrame(frame, display: false)
            p.alphaValue = 0
            p.orderFrontRegardless()
            pages.append(Page(panel: p, model: m))
        }
        // Keyboard focus starts on the most recent window, on its display.
        if let first = all.first {
            current = screenIndex(first)
            pages[current].model.selected = 0
        }
        pages[safe: current]?.panel.makeKey()
        for page in pages {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.1, 0.9, 0.2, 1)
                page.panel.animator().alphaValue = 1
            }
        }
        installMonitors()
        Log.write("task view: open, \(all.count) windows")
    }

    func close() {
        guard isOpen else { return }
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        let old = pages
        pages = []
        for page in old {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
                page.panel.animator().alphaValue = 0
            }, completionHandler: { page.panel.orderOut(nil) })
        }
    }

    private func pick(_ w: SwitchWindow) {
        close()
        Log.write("task view: \(w.appName) window \(w.id)")
        WindowList.focus(w)
    }

    private func installMonitors() {
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { _ in
            MainActor.assumeIsolated { TaskView.shared.close() }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown], handler: { e in
            let swallow = MainActor.assumeIsolated { TaskView.shared.local(e) }
            return swallow ? nil : e
        }) { monitors.append(l) }
    }

    /// Returns true to swallow the event.
    private func local(_ e: NSEvent) -> Bool {
        guard isOpen else { return false }
        if e.type != .keyDown {
            // Clicks on the taskbar (or anything else of ours) close Task View, then do their own thing.
            if !pages.contains(where: { $0.panel === e.window }) {
                closedByClickAt = Date()
                close()
            }
            return false
        }
        guard let page = pages[safe: current] else { return false }
        let m = page.model
        switch e.keyCode {
        case 53: close()
        case 36, 76, 49: if let s = m.selected { m.pick(s) }
        case 125: m.move(.down)
        case 126: m.move(.up)
        case 123, 124:
            let right = e.keyCode == 124
            if let s = m.selected, (right && s == m.items.count - 1) || (!right && s == 0), pages.count > 1 {
                // Past the last window of this display: on to the next display's windows.
                moveSelection(toPage: (current + (right ? 1 : -1) + pages.count) % pages.count, fromEnd: !right)
            } else {
                m.move(right ? .right : .left)
            }
        case 48: m.move(e.modifierFlags.contains(.shift) ? .left : .right)
        default: return false
        }
        return true
    }

    private func moveSelection(toPage i: Int, fromEnd: Bool) {
        var k = i
        for _ in pages.indices {
            if !pages[k].model.items.isEmpty { break }
            k = (k + (fromEnd ? -1 : 1) + pages.count) % pages.count
        }
        guard !pages[k].model.items.isEmpty else { return }
        pages[current].model.selected = nil
        current = k
        pages[k].model.selected = fromEnd ? pages[k].model.items.count - 1 : 0
        pages[k].panel.makeKey()
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// One display's page: blurred, dimmed backdrop (click it to leave) and the window cards centered.
struct TaskViewPage: View {
    @ObservedObject var model: WindowGridModel
    let topInset: CGFloat
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack {
            VisualEffect(material: .fullScreenUI)
            (scheme == .dark ? Color.black.opacity(0.35) : Color.white.opacity(0.25))
                .contentShape(Rectangle())
                .onTapGesture { TaskView.shared.close() }
            if !model.items.isEmpty {
                ScrollView(.vertical) {
                    WindowGridView(model: model).padding(24).frame(maxWidth: .infinity)
                }
                .scrollIndicators(.never)
                .frame(maxHeight: model.contentSize.height + 48)
                .padding(.top, topInset)
            }
        }
        .foregroundStyle(Theme.text(scheme))
        .font(Theme.font(13))
    }
}
