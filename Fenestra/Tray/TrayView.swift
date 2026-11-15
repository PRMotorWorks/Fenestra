import AppKit
import SwiftUI

/// Right side of the taskbar: overflow chevron, pinned menu bar icons (Phase 6), keyboard layout, Quick Settings (Wi-Fi + volume + battery),
/// clock with date and the notification bell, then the show-desktop sliver.
struct TrayView: View {
    /// Phase 5: a secondary taskbar shows only the clock and bell, then the show-desktop corner (as Windows 11).
    var secondary = false
    var displayID: CGDirectDisplayID = 0
    @ObservedObject private var s = SystemStatus.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var extras = MenuExtras.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 2) {
            if !secondary { trayIcons }
            clockAndBell
            if settings.showDesktopCorner { ShowDesktopSliver(displayID: displayID) } else { Color.clear.frame(width: 6) }
        }
        .padding(.trailing, 0)
    }

    @ViewBuilder private var trayIcons: some View {
            TaskbarButtonChrome(width: 24, onLeft: { rect in
                FlyoutManager.shared.toggle(id: "overflow", anchor: rect, align: .center) { OverflowFlyout() }
            }) {
                Image(systemName: "chevron.up").font(.system(size: 11, weight: .semibold))
            }
            .help("Show hidden icons")

            // Phase 6: menu bar icons switched on under "Other system tray icons".
            ForEach(extras.items.filter { settings.trayPinned.contains($0.id) }) { e in
                TaskbarButtonChrome(width: 28, onLeft: { rect in MenuExtras.shared.open(e, anchor: rect) },
                                    onRight: { rect, _ in MenuExtras.shared.contextMenu(e, anchor: rect) }) {
                    MenuExtraIcon(extra: e)
                }
                .help(e.name)
            }

            if settings.showInputIndicator, settings.inputIndicator == .show || s.inputSources.count > 1,
               let cur = s.currentInput {
                TaskbarButtonChrome(width: 40, onLeft: { rect in
                    FlyoutManager.shared.toggle(id: "input", anchor: rect) { InputFlyout() }
                }) {
                    VStack(spacing: 0) {
                        Text(cur.language).font(Theme.font(11))
                        Text(cur.layout).font(Theme.font(11))
                    }
                }
                .help(cur.name)
            }

            // One button, as on Windows 11, but each icon has its own tooltip, and scrolling over the speaker
            // changes the volume.
            TaskbarButtonChrome(width: nil, onLeft: { rect in
                TrayTip.shared.hide()
                FlyoutManager.shared.toggle(id: "quick", anchor: rect) { QuickSettingsView() }
            }, onHoverChange: { inside, _ in
                if !inside { TrayTip.shared.hide() }
            }, onMove: { point, rect in
                let k = trayIcon(at: point.x)
                TrayTip.shared.hover(k, iconX: rect.minX + (k.flatMap { iconFrames[$0]?.midX } ?? point.x), button: rect)
            }, onScroll: { event, point, rect in
                guard trayIcon(at: point.x) == .volume else { return }
                let steps = TrayTip.shared.volumeScroll.steps(event)
                guard steps != 0 else { return }
                s.stepVolume(steps)
                TrayTip.shared.hover(.volume, iconX: rect.minX + (iconFrames[.volume]?.midX ?? point.x), button: rect, now: true)
            }) {
                HStack(spacing: 10) {
                    Image(systemName: wifiSymbol).font(.system(size: 14))
                        .modifier(TrayIconFrame(kind: .wifi, frames: $iconFrames))
                    Image(systemName: volumeSymbol).font(.system(size: 14))
                        .modifier(TrayIconFrame(kind: .volume, frames: $iconFrames))
                    if Battery.isPresent && s.battery.present {
                        HStack(spacing: 3) {
                            BatteryIcon(state: s.battery, size: 15)
                            if settings.showBatteryPercent { Text("\(s.battery.percent)%").font(Theme.font(12)) }
                        }
                        .modifier(TrayIconFrame(kind: .battery, frames: $iconFrames))
                    }
                }
                .padding(.horizontal, 10)
                .coordinateSpace(.named(TrayIconFrame.space))
            }
    }

    @State private var iconFrames: [TrayTip.Kind: CGRect] = [:]

    /// The Quick Settings icon nearest the pointer (x from the button's left edge).
    private func trayIcon(at x: CGFloat) -> TrayTip.Kind? {
        var shown: [TrayTip.Kind] = [.wifi, .volume]
        if Battery.isPresent && s.battery.present { shown.append(.battery) }
        return shown.compactMap { k in iconFrames[k].map { (k, abs($0.midX - x)) } }.min { $0.1 < $1.1 }?.0
    }

    @ViewBuilder private var clockAndBell: some View {
            if settings.showClock || settings.showBell {
                TaskbarButtonChrome(width: nil, height: model.small ? 32 : 40, onLeft: { rect in
                    NotificationStore.shared.markRead()
                    FlyoutManager.shared.toggle(id: "calendar", anchor: rect) { CalendarFlyout() }
                }) {
                    HStack(spacing: 10) {
                        if settings.showClock {
                            VStack(alignment: .trailing, spacing: model.small ? 0 : 1) {
                                Text(s.now, format: settings.showSeconds
                                     ? .dateTime.hour().minute().second() : .dateTime.hour().minute())
                                Text(s.now, format: Date.FormatStyle(date: .numeric, time: .omitted))
                            }
                            .font(Theme.font(model.small ? 11 : 12))
                        }
                        if settings.showBell {
                            Image(systemName: FocusControl.isOn ? "bell.slash" : (notes.unread > 0 ? "bell.badge" : "bell"))
                                .font(.system(size: 13))
                                .overlay(alignment: .topTrailing) {
                                    if notes.unread > 0 { BadgeView(text: "\(notes.unread)").offset(x: 9, y: -7) }
                                }
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .help(s.now.formatted(date: .complete, time: .omitted))
            }
    }

    @ObservedObject private var notes = NotificationStore.shared
    @ObservedObject private var model = TaskbarModel.shared

    private var wifiSymbol: String {
        if !WiFi.shared.isAvailable { return "network" }
        if !s.wifiOn { return "wifi.slash" }
        if !s.wifiConnected { return "wifi.exclamationmark" }
        return "wifi"
    }
    private var volumeSymbol: String {
        if s.muted || s.volume == 0 { return "speaker.slash" }
        if s.volume < 0.34 { return "speaker.wave.1" }
        if s.volume < 0.67 { return "speaker.wave.2" }
        return "speaker.wave.3"
    }
}

/// Remembers where a Quick Settings icon sits inside the tray button, for its tooltip and the volume scroll.
struct TrayIconFrame: ViewModifier {
    static let space = "trayIcons"
    let kind: TrayTip.Kind
    @Binding var frames: [TrayTip.Kind: CGRect]
    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(Self.space)) }) { frames[kind] = $0 }
    }
}

/// Battery level with a bolt while charging or a plug while on the adapter without charging (macOS's battery menu
/// uses the same two marks). Shared by the taskbar and the Quick Settings footer.
struct BatteryIcon: View {
    let state: Battery.State
    var size: CGFloat = 15
    var body: some View {
        Image(systemName: Battery.symbol(state)).font(.system(size: size))
            .overlay(alignment: .center) {
                if let badge = Battery.badge(state) {
                    // Knocked out of the level fill (as the system's own bolt battery) so it reads at any level.
                    let glyph = Image(systemName: badge)
                        .font(.system(size: size * (badge == "bolt.fill" ? 0.6 : 0.5), weight: .bold))
                        .offset(x: -size * 0.06)
                    glyph.background(glyph.scaleEffect(1.35).blendMode(.destinationOut))
                }
            }
            .compositingGroup()
    }
}

/// Thin slice at the far right; click shows the desktop (click again to bring windows back).
struct ShowDesktopSliver: View {
    /// Phase 5: the corner clears only the display its taskbar is on.
    var displayID: CGDirectDisplayID
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(Theme.border(scheme).opacity(hovering ? 3 : 1.5)).frame(width: 1, height: 16)
            Color.clear.frame(width: 7)
        }
        .frame(width: 10)
        .frame(maxHeight: .infinity)
        .background(hovering ? Theme.hover(scheme) : .clear)
        .overlay(MouseCatcher(onLeft: { _ in
            if AppSettings.shared.showDesktopAllDisplays { TaskbarActions.toggleShowDesktop() }
            else { TaskbarActions.toggleShowDesktop(display: displayID) }
        }, onHover: { h, _ in hovering = h }))
        .help("Show desktop")
    }
}

struct InputFlyout: View {
    @ObservedObject private var s = SystemStatus.shared
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(s.inputSources) { src in
                FlyoutRow(selected: src.id == s.currentInputID) {
                    s.selectInput(src.id)
                    FlyoutManager.shared.close()
                } content: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(src.name)
                        Text("\(src.language) · \(src.layout)").font(Theme.font(11)).foregroundStyle(Theme.secondaryText(scheme))
                    }
                }
            }
            Divider().padding(.vertical, 4)
            FlyoutRow(selected: false) {
                FlyoutManager.shared.close()
                SystemActions.openSettings("com.apple.Keyboard-Settings.extension")
            } content: { Text("More keyboard settings") }
        }
        .padding(6)
        .frame(width: 260)
    }
}

/// "Show hidden icons": menu bar icons not shown on the taskbar (Phase 6), then Fenestra's own icons.
/// Windows 11 lays them out in a grid of up to five per row.
struct OverflowFlyout: View {
    @ObservedObject private var extras = MenuExtras.shared
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let hidden = extras.items.filter { !settings.trayPinned.contains($0.id) }
        let count = hidden.count + 2
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 4), count: min(5, count)), spacing: 4) {
            ForEach(hidden) { e in
                OverflowCell(help: e.name, onLeft: { rect in MenuExtras.shared.open(e, anchor: rect) },
                             onRight: { rect in MenuExtras.shared.contextMenu(e, anchor: rect) }) {
                    MenuExtraIcon(extra: e)
                }
            }
            OverflowIcon(symbol: "gearshape", help: "Fenestra settings") { SettingsWindow.show() }
            OverflowIcon(symbol: "lock.shield", help: "Fenestra permissions") { PermissionsWindow.show() }
        }
        .padding(8)
        .onAppear { MenuExtras.shared.refresh() }
    }
}

/// A mirrored menu bar icon: the app's icon, or an SF Symbol for system items.
struct MenuExtraIcon: View {
    let extra: MenuExtra
    var body: some View {
        if let symbol = extra.symbol {
            Image(systemName: symbol).font(.system(size: 14))
        } else {
            Image(nsImage: MenuExtras.shared.icon(for: extra)).resizable().interpolation(.high).frame(width: 18, height: 18)
        }
    }
}

/// Overflow grid cell with left and right click (opens the item, or its pin menu).
struct OverflowCell<Content: View>: View {
    let help: String
    let onLeft: (NSRect) -> Void
    let onRight: (NSRect) -> Void
    @ViewBuilder var content: () -> Content
    var body: some View {
        TaskbarButtonChrome(width: 36, height: 36, onLeft: onLeft, onRight: { rect, _ in onRight(rect) }) { content() }
            .help(help)
    }
}

struct OverflowIcon: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false
    var body: some View {
        Image(systemName: symbol).font(.system(size: 15))
            .frame(width: 36, height: 36)
            .background(RoundedRectangle(cornerRadius: 4).fill(hovering ? Theme.hover(scheme) : .clear))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { FlyoutManager.shared.close(); action() }
            .help(help)
    }
}

/// Generic hoverable row used in flyout lists.
struct FlyoutRow<Content: View>: View {
    var selected: Bool
    var action: () -> Void
    @ViewBuilder var content: () -> Content
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5).fill(selected ? Theme.accent : .clear).frame(width: 3, height: 16)
            content()
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6).padding(.trailing, 10)
        .background(RoundedRectangle(cornerRadius: 4).fill(hovering || selected ? Theme.hover(scheme) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
    }
}
