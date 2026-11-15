import AppKit
import SwiftUI

/// Windows 11 Snap Layouts: hover a window's maximize button and a flyout offers layouts; click a zone to
/// put the window there. Layouts adapt to the display's shape like Windows does: landscape screens get
/// halves, 2/3 + 1/3, thirds (1800 pt wide or more), half + quarters and quadrants, ultrawide screens add
/// 1/4 + 1/2 + 1/4, portrait screens get stacked rows.
enum SnapLayouts {
    /// Each layout is a list of zones as unit rects (origin top-left, y down) of the work area.
    static func layouts(for size: CGSize) -> [[CGRect]] {
        let aspect = size.width / max(size.height, 1)
        func col(_ x: CGFloat, _ w: CGFloat) -> CGRect { CGRect(x: x, y: 0, width: w, height: 1) }
        func row(_ y: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: 0, y: y, width: 1, height: h) }
        let third: CGFloat = 1 / 3

        if aspect < 1 {
            var out: [[CGRect]] = [
                [row(0, 0.5), row(0.5, 0.5)],
                [row(0, 2 * third), row(2 * third, third)],
            ]
            if size.height >= 1800 { out.append([row(0, third), row(third, third), row(2 * third, third)]) }
            out.append([row(0, 0.5), CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5), CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)])
            return out
        }
        var out: [[CGRect]] = [
            [col(0, 0.5), col(0.5, 0.5)],
            [col(0, 2 * third), col(2 * third, third)],
        ]
        if size.width >= 1800 { out.append([col(0, third), col(third, third), col(2 * third, third)]) }
        out.append([col(0, 0.5), CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5), CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)])
        out.append([CGRect(x: 0, y: 0, width: 0.5, height: 0.5), CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5),
                    CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5), CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)])
        if aspect >= 2.1 { out.append([col(0, 0.25), col(0.25, 0.5), col(0.75, 0.25)]) }
        return out
    }

    /// Miniature size, same shape as the screen.
    static func tileSize(for size: CGSize) -> CGSize {
        let aspect = size.width / max(size.height, 1)
        if aspect < 1 { return CGSize(width: 44, height: min(max((44 / aspect).rounded(), 52), 88)) }
        return CGSize(width: min(max((46 * aspect).rounded(), 62), 112), height: 46)
    }
}

/// Hover timing for the flyout (shows after a short rest on maximize, closes once the pointer has left
/// both the button and the flyout), on top of `FlyoutManager`.
@MainActor
final class SnapController {
    static let shared = SnapController()
    private(set) var windowID: CGWindowID?
    private var showTimer: Timer?
    private var closeTimer: Timer?
    private var buttonRect: NSRect = .zero
    private var flyoutHovered = false

    private var isOpen: Bool { FlyoutManager.shared.currentID?.hasPrefix("snap:") == true }
    /// Control+Option+Z: the flyout follows the keyboard (numbers on layouts, then on zones).
    let keys = SnapKeyboard()
    private var layouts: [[CGRect]] = []
    private var workArea: CGRect = .zero
    /// The zone under the pointer (or picked with the keyboard) is previewed on the screen, as on Windows 11.
    private let preview = SnapPreview()

    func hoverBegan(window id: CGWindowID, button rect: NSRect) {
        closeTimer?.invalidate()
        buttonRect = rect
        if isOpen && windowID == id { return }
        if keys.stage != .off { return }              // keyboard flyout open: hovering doesn't replace it
        guard AppSettings.shared.snapLayoutsOnHover else { return }
        showTimer?.invalidate()
        showTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { _ in
            MainActor.assumeIsolated { SnapController.shared.show(id) }
        }
    }

    func hoverEnded() {
        showTimer?.invalidate()
        scheduleCloseCheck()
    }

    func flyoutHover(_ inside: Bool) {
        flyoutHovered = inside
        if inside { closeTimer?.invalidate() } else { scheduleCloseCheck() }
    }

    func dismiss() {
        preview.hide()
        showTimer?.invalidate()
        closeTimer?.invalidate()
        if isOpen { FlyoutManager.shared.close(animated: false) }
        windowID = nil
        flyoutHovered = false
    }

    private func scheduleCloseCheck() {
        guard isOpen, keys.stage == .off else { return }
        closeTimer?.invalidate()
        closeTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
            MainActor.assumeIsolated {
                let s = SnapController.shared
                let m = NSEvent.mouseLocation
                let inFlyout = FlyoutManager.shared.panelFrame?.insetBy(dx: -2, dy: -2).contains(m) ?? false
                if !s.flyoutHovered && !inFlyout && !s.buttonRect.insetBy(dx: -1, dy: -1).contains(m) { s.dismiss() }
            }
        }
    }

    /// Control+Option+Z (Windows key + Z): the flyout for the focused window, without hovering.
    func showFromKeyboard(_ id: CGWindowID) {
        guard let e = CaptionController.shared.entry(id), e.shown else { return }
        showTimer?.invalidate()
        closeTimer?.invalidate()
        buttonRect = e.view.screenRect(of: .maximize)
        show(id, keyboard: true)
    }

    private func show(_ id: CGWindowID, keyboard: Bool = false) {
        guard let e = CaptionController.shared.entry(id), e.shown,
              keyboard || e.view.screenRect(of: .maximize).insetBy(dx: -1, dy: -1).contains(NSEvent.mouseLocation)
        else { return }
        let wa = CaptionController.workArea(for: e.frame)
        let layouts = SnapLayouts.layouts(for: wa.size)
        let tile = SnapLayouts.tileSize(for: wa.size)
        windowID = id
        self.layouts = layouts
        workArea = wa
        preview.hide()
        flyoutHovered = false
        let keys = self.keys
        FlyoutManager.shared.show(id: "snap:\(id)", anchor: buttonRect, align: .center, gap: 4, placement: .below,
                                  keyable: !keyboard,
                                  onClose: keyboard ? {
                                      SnapController.shared.keys.stage = .off
                                      HotKeys.shared.setModal(.none)
                                  } : nil) {
            SnapLayoutsView(layouts: layouts, tile: tile, keys: keys,
                            onZone: { SnapController.shared.previewZone($0) }) { layout, zone in
                SnapController.shared.dismiss()
                CaptionController.shared.snap(id, zone: zone, layout: layout)
            } onHover: { SnapController.shared.flyoutHover($0) }
        }
        // After show(): closing the previous flyout runs its onClose, which resets the keyboard state.
        keys.stage = keyboard ? .layouts(0) : .off
        if keyboard { HotKeys.shared.setModal(.snapLayouts) }
    }

    /// Shows where the window would go for the hovered (or keyboard-picked) zone; nil hides it.
    func previewZone(_ unit: CGRect?) {
        guard let unit, let id = windowID, let e = CaptionController.shared.entry(id) else { preview.hide(); return }
        preview.show(WindowSnap.rect(unit, in: workArea), from: e.frame, icon: WindowList.icon(e.pid), above: id)
    }

    /// Keys while the keyboard flyout is open (Windows key + Z, then a number for the layout and one for the zone).
    /// Arrows move the highlight, Return picks, Esc or any other key closes.
    func keyboardKey(_ code: Int64) {
        guard isOpen, let id = windowID else { keys.stage = .off; HotKeys.shared.setModal(.none); return }
        let next: Int? = [124, 125].contains(code) ? 1 : [123, 126].contains(code) ? -1 : nil
        switch keys.stage {
        case .off:
            return
        case .layouts(let sel):
            if let n = HotKeys.digit(code) {
                if n <= layouts.count { keys.stage = .zones(layout: n - 1, zone: 0); previewZone(layouts[n - 1][0]) }
            } else if let d = next {
                keys.stage = .layouts((sel + d + layouts.count) % layouts.count)
            } else if code == 36 || code == 76 {
                keys.stage = .zones(layout: sel, zone: 0)
                previewZone(layouts[sel][0])
            } else {
                dismiss()
            }
        case .zones(let l, let z):
            let zones = layouts[l]
            var pick: Int?
            if let n = HotKeys.digit(code) {
                if n <= zones.count { pick = n - 1 }
            } else if let d = next {
                let nz = (z + d + zones.count) % zones.count
                keys.stage = .zones(layout: l, zone: nz)
                previewZone(zones[nz])
            } else if code == 36 || code == 76 {
                pick = z
            } else {
                dismiss()
            }
            if let pick {
                Log.write("snap layouts: keyboard picked layout \(l + 1) zone \(pick + 1)")
                dismiss()
                CaptionController.shared.snap(id, zone: zones[pick], layout: zones)
            }
        }
    }
}

/// Keyboard state of the Snap Layouts flyout (Control+Option+Z).
@MainActor
final class SnapKeyboard: ObservableObject {
    enum Stage: Equatable { case off, layouts(Int), zones(layout: Int, zone: Int) }
    @Published var stage: Stage = .off
}

/// The flyout content: layout miniatures, three per row; the zone under the pointer turns the accent color.
/// Opened from the keyboard, each layout shows its number, then the chosen layout numbers its zones (Windows 11).
struct SnapLayoutsView: View {
    @Environment(\.colorScheme) private var scheme
    let layouts: [[CGRect]]
    let tile: CGSize
    @ObservedObject var keys: SnapKeyboard
    var onZone: (CGRect?) -> Void = { _ in }
    let onPick: ([CGRect], CGRect) -> Void
    let onHover: (Bool) -> Void

    private struct Key: Hashable { let layout: Int; let zone: Int }
    @State private var hovered: Key?

    var body: some View {
        let rows = stride(from: 0, to: layouts.count, by: 3).map { Array($0..<min($0 + 3, layouts.count)) }
        VStack(alignment: .leading, spacing: 14) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: 14) {
                    ForEach(rows[r], id: \.self) { i in tileView(i) }
                }
            }
        }
        .padding(14)
        .contentShape(Rectangle())
        .onHover { onHover($0) }
        .onChange(of: hovered) { _, k in onZone(k.map { layouts[$0.layout][$0.zone] }) }
    }

    private func tileView(_ i: Int) -> some View {
        var layoutSelected = false, zoneStage = false, dimmed = false
        var keyZone: Int?
        switch keys.stage {
        case .off: break
        case .layouts(let sel): layoutSelected = sel == i
        case .zones(let l, let z):
            if l == i { zoneStage = true; keyZone = z } else { dimmed = true }
        }
        return ZStack(alignment: .topLeading) {
            ForEach(layouts[i].indices, id: \.self) { z in
                let unit = layouts[i][z]
                let r = CGRect(x: unit.minX * tile.width, y: unit.minY * tile.height,
                               width: unit.width * tile.width, height: unit.height * tile.height).insetBy(dx: 1.5, dy: 1.5)
                let key = Key(layout: i, zone: z)
                let on = hovered == key || keyZone == z
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(on ? Theme.accent : zoneFill)
                    .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(on ? Theme.accent : Theme.border(scheme).opacity(2), lineWidth: 1))
                    .overlay {
                        if zoneStage {
                            Text("\(z + 1)").font(Theme.font(12, .semibold))
                                .foregroundStyle(on ? Color.white : Theme.text(scheme))
                        }
                    }
                    .frame(width: r.width, height: r.height)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { hovered = key } else if hovered == key { hovered = nil }
                    }
                    .onTapGesture { onPick(layouts[i], unit) }
                    .position(x: r.midX, y: r.midY)
            }
        }
        .frame(width: tile.width, height: tile.height, alignment: .topLeading)
        .opacity(dimmed ? 0.4 : 1)
        .overlay {
            if case .layouts = keys.stage {
                Text("\(i + 1)").font(Theme.font(13, .semibold))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(layoutSelected ? Theme.accent : Theme.control(scheme)))
                    .foregroundStyle(layoutSelected ? Color.white : Theme.text(scheme))
                    .allowsHitTesting(false)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
            .strokeBorder(layoutSelected ? Theme.accent : .clear, lineWidth: 2).padding(-4))
    }

    private var zoneFill: Color { scheme == .dark ? Color.white.opacity(0.09) : Color.white.opacity(0.85) }
}
