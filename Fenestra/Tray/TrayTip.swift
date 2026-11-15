import AppKit
import SwiftUI

/// Tooltip for the Quick Settings icons on the taskbar: network name, volume and battery, one per icon as on
/// Windows 11. AppKit tooltips can't change while shown and don't appear while Fenestra is in the background,
/// so this is a small click-through panel. Its text is live: scrolling the volume updates the number in place.
@MainActor
final class TrayTip {
    static let shared = TrayTip()
    enum Kind { case wifi, volume, battery }

    fileprivate final class Model: ObservableObject { @Published var kind: Kind = .wifi }
    private let model = Model()
    private var panel: NSPanel?
    private var pending: DispatchWorkItem?
    private var size = CGSize(width: 120, height: 28)
    private var anchorX: CGFloat = 0
    private var anchorTop: CGFloat = 0
    private var screen: NSScreen?
    private(set) var isVisible = false

    /// Pointer over an icon (`kind`) or off all of them (nil). `iconX` is the icon's centre on screen and
    /// `button` the taskbar button's screen rect. The first tip waits 0.5 s like a system tooltip; moving to
    /// another icon while one is shown switches at once. `now` shows it straight away (scrolling the volume).
    func hover(_ kind: Kind?, iconX: CGFloat, button: NSRect, now: Bool = false) {
        guard let kind else { hide(); return }
        anchorX = iconX
        anchorTop = button.maxY
        screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: button.midX, y: button.midY)) }
        if model.kind != kind { model.kind = kind }
        if isVisible || now { show(); return }
        guard pending == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.pending = nil; self?.show() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func hide() {
        pending?.cancel()
        pending = nil
        guard isVisible else { return }
        isVisible = false
        panel?.orderOut(nil)
    }

    private func show() {
        pending?.cancel()
        pending = nil
        // A flyout opened in the meantime (the click that opens Quick Settings): no tip over it.
        if FlyoutManager.shared.currentID != nil { return }
        let p = panel ?? makePanel()
        panel = p
        place()
        if !isVisible { p.orderFrontRegardless(); isVisible = true }
    }

    /// Called by the view when its text changes size: keep it centred over the icon.
    fileprivate func sizeChanged(_ s: CGSize) {
        guard s.width > 0, s.height > 0 else { return }
        size = s
        if isVisible { place() }
    }

    private func place() {
        guard let p = panel else { return }
        let bounds = (screen ?? NSScreen.main ?? NSScreen.screens[0]).frame
        let x = min(max(anchorX - size.width / 2, bounds.minX + 6), bounds.maxX - size.width - 6)
        p.setFrame(NSRect(x: x.rounded(), y: (anchorTop + 6).rounded(), width: size.width, height: size.height),
                   display: true)
        p.invalidateShadow()
    }

    private func makePanel() -> NSPanel {
        let host = NSHostingView(rootView: TrayTipView(model: model))
        host.sizingOptions = []
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .popUpMenu
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        p.contentView = host
        return p
    }

    // MARK: Text

    static func text(_ kind: Kind, _ s: SystemStatus) -> String {
        switch kind {
        case .wifi:
            let w = WiFi.shared
            if !w.isAvailable { return "Network" }
            if !s.wifiOn { return "Wi-Fi is off" }
            if !s.wifiConnected { return "Wi-Fi: not connected" }
            guard let name = s.ssid else { return "Wi-Fi: connected\nAllow Location access to see the network name" }
            return "\(name)\nConnected"
        case .volume:
            let device = Audio.name(Audio.defaultOutput)
            if !Audio.canSetVolume() { return "\(device): volume set on the device" }
            if s.muted { return "\(device): muted" }
            return "\(device): \(Int((s.volume * 100).rounded()))%"
        case .battery:
            return Battery.tooltip(s.battery)
        }
    }

    /// Mouse wheel notches and trackpad scrolling turned into 5% volume steps.
    /// A wheel notch is one step; a trackpad moves one step every 12 points, ignoring the momentum glide.
    final class VolumeScroll {
        private var travel: CGFloat = 0
        func steps(_ e: NSEvent) -> Int {
            if !e.momentumPhase.isEmpty { return 0 }
            if e.phase == .began { travel = 0 }
            // Up (wheel away from you, fingers moving up) is louder, whatever the natural scrolling setting.
            let dy = e.scrollingDeltaY * (e.isDirectionInvertedFromDevice ? -1 : 1)
            guard dy != 0 else { return 0 }
            if !e.hasPreciseScrollingDeltas { travel = 0; return dy > 0 ? 1 : -1 }
            if travel != 0 && (travel > 0) != (dy > 0) { travel = 0 }   // changed direction
            travel += dy
            let n = Int(travel / 12)
            travel -= CGFloat(n) * 12
            return n
        }
    }
    let volumeScroll = VolumeScroll()
}

private struct TrayTipView: View {
    @ObservedObject fileprivate var model: TrayTip.Model
    @ObservedObject private var s = SystemStatus.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text(TrayTip.text(model.kind, s))
            .font(Theme.font(12))
            .multilineTextAlignment(.leading)
            .foregroundStyle(Theme.text(scheme))
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Theme.flyoutTint(scheme))
            .background(VisualEffect(material: .hudWindow, cornerRadius: 5))
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.border(scheme), lineWidth: 1))
            .fixedSize()
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { TrayTip.shared.sizeChanged($0) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
