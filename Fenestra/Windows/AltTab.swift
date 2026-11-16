import AppKit
import SwiftUI

/// Alt+Tab as Option+Tab (Windows 11 25H2): hold Option and press Tab to walk through the open windows,
/// most recently used first, with live thumbnails; let go of Option to switch. A quick Option+Tab switches
/// to the previous window without showing anything. Shift goes back, arrows move, Esc cancels, Return
/// switches, a click picks a card, the X on a card closes that window.
@MainActor
final class AltTab {
    static let shared = AltTab()

    private(set) var active = false
    private var model: WindowGridModel?
    private var panel: OverlayPanel?
    private var showWork: DispatchWorkItem?
    private var optionWatch: Timer?
    /// The display the switcher shows on: the main one, or the current one when it lists only that display's windows.
    private var screen: NSScreen?

    /// Option+Tab (or Tab again while open).
    func tab(reverse: Bool) {
        if active { model?.move(reverse ? .left : .right); return }
        begin(reverse: reverse)
    }

    private func begin(reverse: Bool) {
        var items = WindowList.all()
        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let frontEl = frontPid.flatMap(AX.focusedWindow)
        let frontWin = frontEl.flatMap(AX.windowID)
        // Settings > Keyboard > Alt+Tab shows windows from: only the current display's windows.
        let target = Self.currentScreen(front: frontEl.flatMap(AX.frame))
        if let target {
            let id = Displays.id(target)
            items = items.filter { Displays.screen(forAX: $0.frame).map(Displays.id) == id }
        }
        screen = target ?? TaskbarController.shared.screen ?? NSScreen.screens[0]
        guard !items.isEmpty else { HotKeys.shared.setSwitcherActive(false); return }
        active = true
        HotKeys.shared.setSwitcherActive(true)
        TaskView.shared.close()
        SnapAssist.shared.dismiss()
        let m = WindowGridModel(items: items)
        // The first card is the window in front; Alt+Tab starts on the one before it.
        let first = items[0].id == frontWin ? 1 : 0
        m.selected = reverse ? items.count - 1 : min(first, items.count - 1)
        m.onPick = { w in AltTab.shared.finish(w) }
        m.onClose = { w in WindowList.close(w) }
        model = m

        let screen = screen ?? NSScreen.screens[0]
        let area = CGSize(width: screen.frame.width * 0.9 - 32, height: screen.frame.height * 0.8 - 32)
        m.layout(in: area, maxH: 170, minH: 64)
        m.loadThumbnails(maxSize: CGSize(width: 380, height: 200))

        // Windows waits a moment before drawing the switcher, so a quick Alt+Tab doesn't flash it.
        let w = DispatchWorkItem { MainActor.assumeIsolated { AltTab.shared.show() } }
        showWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: w)
        // Backstop: if the Option release is ever missed, the switcher must not keep swallowing keys.
        optionWatch = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            MainActor.assumeIsolated {
                if !NSEvent.modifierFlags.contains(.option) { AltTab.shared.commit() }
            }
        }
    }

    private func show() {
        guard active, let m = model else { return }
        let screen = screen ?? NSScreen.screens[0]
        let size = CGSize(width: min(m.contentSize.width + 32, screen.frame.width * 0.9),
                          height: min(m.contentSize.height + 32, screen.frame.height * 0.8))
        let frame = NSRect(x: (screen.frame.midX - size.width / 2).rounded(),
                           y: (screen.frame.midY - size.height / 2).rounded(), width: size.width, height: size.height)
        let p = panel ?? OverlayPanel(level: .popUpMenu, keyable: true)   // keyable: cards take the first click
        p.hasShadow = true
        let host = FirstClickHostingView(rootView: AltTabView(model: m))
        host.sizingOptions = []
        host.roundCorners(8)
        p.contentView = host
        p.setFrame(frame, display: false)
        p.alphaValue = 0
        p.orderFrontRegardless()
        p.invalidateShadow()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.1
            p.animator().alphaValue = 1
        }
        panel = p
    }

    /// Nil = every display's windows. Otherwise the display with the window in front (else the pointer's
    /// display) or the pointer's display, per the setting. One display: always nil.
    private static func currentScreen(front: CGRect?) -> NSScreen? {
        guard NSScreen.screens.count > 1 else { return nil }
        let mouse = NSEvent.mouseLocation
        let pointer = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
        switch AppSettings.shared.altTabDisplays {
        case .all: return nil
        case .pointerDisplay: return pointer
        case .activeDisplay: return front.flatMap(Displays.screen(forAX:)) ?? pointer
        }
    }

    /// Other keys while Option is held.
    func key(_ code: Int64, shift: Bool) {
        guard active, let m = model else { return }
        switch code {
        case 53: cancel()                                    // Esc
        case 36, 76: commit()                                // Return, Enter
        case 123: m.move(.left)
        case 124: m.move(.right)
        case 125: m.move(.down)
        case 126: m.move(.up)
        case 51, 117:                                        // Delete: close the selected window
            if let s = m.selected { m.close(s) }
            if m.items.isEmpty { cancel() }
        default: break
        }
    }

    /// Option released (or Return): switch to the selected window.
    func commit() {
        guard active else { HotKeys.shared.setSwitcherActive(false); return }
        let w = model.flatMap { m in m.selected.flatMap { m.items.indices.contains($0) ? m.items[$0] : nil } }
        end()
        if let w { switchTo(w) }
    }

    private func finish(_ w: SwitchWindow) {
        end()
        switchTo(w)
    }

    func cancel() { end() }

    private func switchTo(_ w: SwitchWindow) {
        Log.write("alt+tab: \(w.appName) window \(w.id)")
        WindowList.focus(w)
    }

    private func end() {
        active = false
        HotKeys.shared.setSwitcherActive(false)
        showWork?.cancel()
        showWork = nil
        optionWatch?.invalidate()
        optionWatch = nil
        model = nil
        guard let p = panel, p.isVisible else { return }
        p.orderOut(nil)
        p.contentView = nil
    }
}

/// Windows 11 Alt+Tab: acrylic panel, rounded corners, cards in rows.
struct AltTabView: View {
    @ObservedObject var model: WindowGridModel
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ScrollView(.vertical) {
            WindowGridView(model: model)
                .padding(16)
                .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        .background(Theme.flyoutTint(scheme))
        .background(VisualEffect(material: .hudWindow, cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border(scheme), lineWidth: 1))
        .foregroundStyle(Theme.text(scheme))
        .font(Theme.font(13))
    }
}
