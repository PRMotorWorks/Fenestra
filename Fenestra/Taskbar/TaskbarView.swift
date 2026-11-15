import AppKit
import SwiftUI

struct TaskbarView: View {
    /// Phase 5: which display this taskbar is on. Secondary taskbars (Windows: "Show my taskbar on all
    /// displays") have no tray icons or Quick Settings, only the clock, bell and show-desktop corner.
    var displayID: CGDirectDisplayID = 0
    var isMain = true
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var model = TaskbarModel.shared
    @ObservedObject private var tracker = WindowTracker.shared
    @ObservedObject private var badges = DockBadges.shared
    @Environment(\.colorScheme) private var scheme
    @State private var dragID: String?
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        ZStack {
            // Background: blur + Windows 11 tint + top hairline. Right-click on empty space = taskbar menu.
            ZStack(alignment: .top) {
                VisualEffect(material: .hudWindow)
                Theme.taskbarTint(scheme)
                Rectangle().fill(Theme.border(scheme)).frame(height: 1)
            }
            .overlay(MouseCatcher(onRight: { _, view in
                let loc = view.convert(view.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
                TaskbarMenu.shared.show(in: view, at: loc)
            }))

            HStack(spacing: 0) {
                if settings.alignment == .left {
                    appGroup.padding(.leading, 12)
                    Spacer(minLength: 0)
                } else {
                    Spacer(minLength: 0)
                    appGroup
                    Spacer(minLength: 0)
                }
            }
            HStack {
                Spacer()
                TrayView(secondary: !isMain, displayID: displayID)
            }
        }
        .frame(height: Theme.taskbarHeight)
        .foregroundStyle(Theme.text(scheme))
        .font(Theme.font(12))
    }

    private var buttonWidth: CGFloat { model.small ? 36 : 44 }
    private var separate: Bool {
        model.showsSeparateWindows(screenWidth: TaskbarController.shared.screen?.frame.width ?? 1920)
    }

    private var appGroup: some View {
        HStack(spacing: 4) {
            StartButton()
            SearchButton()
            if settings.showTaskView { TaskViewButton() }
            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                let all = tracker.windows(for: item)
                if showsItem(item, all) {
                let wins = separate ? windowsHere(all) : []
                Group {
                    if wins.isEmpty {
                        AppButton(item: item, badge: badges.badge(for: item), scope: scope,
                                  hasWindowsHere: !filtered || all.contains(where: isHere) || all.isEmpty,
                                  label: separate && item.isRunning ? item.name : nil,
                                  onDrag: { dx in dragID = item.id; dragOffset = dx },
                                  onDragEnd: { dx in finishDrag(item, index: index, dx: dx) })
                    } else {
                        ForEach(wins) { w in
                            WindowButton(item: item, window: w, badge: w.id == wins.first?.id ? badges.badge(for: item) : nil,
                                         scope: scope)
                        }
                    }
                }
                .offset(x: dragID == item.id ? dragOffset : 0)
                .zIndex(dragID == item.id ? 1 : 0)
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.items.map(\.id))
    }

    // MARK: Multiple displays ("When using multiple displays, show my taskbar apps on")

    /// True when this taskbar shows only some apps (not "All taskbars").
    private var filtered: Bool {
        settings.taskbarAllDisplays && settings.taskbarAppsOn != .all
            && !(isMain && settings.taskbarAppsOn == .mainAndWhereOpen)
    }

    /// What this taskbar's buttons act on: only its display's windows when it shows only some apps.
    private var scope: TaskbarActions.Scope? {
        filtered ? TaskbarActions.Scope(display: displayID, isMain: isMain) : nil
    }

    private func isHere(_ w: WindowTracker.Win) -> Bool {
        TaskbarActions.Scope(display: displayID, isMain: isMain).contains(w.display)
    }

    /// Main taskbar: pinned apps and apps without a window stay there. Other taskbars: apps with a window on that display.
    private func showsItem(_ item: AppItem, _ wins: [WindowTracker.Win]) -> Bool {
        guard filtered else { return true }
        if wins.contains(where: isHere) { return true }
        return isMain && (item.pinned || wins.isEmpty)
    }

    private func windowsHere(_ wins: [WindowTracker.Win]) -> [WindowTracker.Win] {
        filtered ? wins.filter(isHere) : wins
    }

    private func finishDrag(_ item: AppItem, index: Int, dx: CGFloat) {
        let shift = Int((dx / (buttonWidth + 4)).rounded())
        dragID = nil
        dragOffset = 0
        if shift != 0 { model.move(item.id, to: index + shift) }
    }
}

struct StartButton: View {
    @ObservedObject private var model = TaskbarModel.shared
    @ObservedObject private var start = StartController.shared
    var body: some View {
        // Generic 2x2 grid glyph (SF Symbol), not Microsoft's logo.
        TaskbarButtonChrome(width: model.small ? 36 : 40, height: model.small ? 32 : 40,
                            highlighted: start.isOpen,
                            onLeft: { rect in StartController.shared.toggle() },
                            onRight: { _, view in StartController.shared.showQuickLinkMenu(in: view) }) {
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: model.small ? 16 : 19, weight: .regular))
                .foregroundStyle(LinearGradient(colors: [Theme.accent.opacity(0.85), Theme.accent],
                                                startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .help("Start")
    }
}

struct SearchButton: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var model = TaskbarModel.shared
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        switch settings.searchStyle {
        case .hidden:
            EmptyView()
        case .icon:
            TaskbarButtonChrome(width: model.small ? 36 : 40, height: model.small ? 32 : 40,
                                onLeft: { _ in StartController.shared.show(searchFocused: true) }) {
                Image(systemName: "magnifyingglass").font(.system(size: 16))
            }
            .help("Search")
        case .iconLabel:
            TaskbarButtonChrome(width: nil, height: model.small ? 32 : 40,
                                onLeft: { _ in StartController.shared.show(searchFocused: true) }) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 15))
                    Text("Search").font(Theme.font(13))
                }
                .padding(.horizontal, 12)
            }
        case .box:
            SearchBox()
        }
    }
}

struct SearchBox: View {
    @ObservedObject private var model = TaskbarModel.shared
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 14))
            Text("Search").foregroundStyle(Theme.secondaryText(scheme))
            Spacer(minLength: 0)
        }
        .font(Theme.font(13))
        .padding(.horizontal, 12)
        .frame(width: 210, height: model.small ? 28 : 32)
        .background(Capsule().fill(hovering ? Theme.hover(scheme).opacity(2) : Theme.control(scheme).opacity(scheme == .dark ? 1 : 0.6)))
        .overlay(Capsule().strokeBorder(Theme.border(scheme), lineWidth: 1))
        .padding(.horizontal, 4)
        .overlay(MouseCatcher(onLeft: { _ in StartController.shared.show(searchFocused: true) },
                              onHover: { h, _ in hovering = h }))
    }
}

struct TaskViewButton: View {
    @ObservedObject private var model = TaskbarModel.shared
    var body: some View {
        TaskbarButtonChrome(width: model.small ? 36 : 40, height: model.small ? 32 : 40,
                            onLeft: { _ in TaskView.shared.toggle() }) {
            Image(systemName: "square.on.square").font(.system(size: model.small ? 15 : 17))
        }
        .help("Task view")
    }
}

/// Red unread badge, top-right of an icon (Windows shows a small colored count).
/// "99+" used to wrap onto two lines inside the icon-sized overlay and bulge out of the circle: one line, never
/// squeezed, slightly smaller text for three characters. Counts over 99 show "99+", as on Windows.
struct BadgeView: View {
    let text: String
    private var shown: String {
        let numeric = text.allSatisfy { $0.isNumber || $0 == "," || $0 == "." }
        if numeric, let n = Int(text.filter(\.isNumber)), n > 99 { return "99+" }
        return text.count > 3 ? "99+" : text
    }
    var body: some View {
        let wide = shown.count > 2
        Text(shown)
            .font(.system(size: wide ? 8 : 9, weight: .bold))
            .monospacedDigit()
            .kerning(wide ? -0.3 : 0)
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, wide ? 3 : 0)
            .frame(minWidth: 15, minHeight: 15)
            .background(Capsule().fill(Color(red: 0.86, green: 0.2, blue: 0.2)))
            .fixedSize()
    }
}

struct AppButton: View {
    let item: AppItem
    var badge: String? = nil
    /// Phase 5: set on a taskbar that shows only its display's windows; clicks and previews use only those.
    var scope: TaskbarActions.Scope? = nil
    /// False for a pinned app whose windows are all on another taskbar's display: no running pill here.
    var hasWindowsHere = true
    var label: String? = nil
    var onDrag: ((CGFloat) -> Void)? = nil
    var onDragEnd: ((CGFloat) -> Void)? = nil
    @ObservedObject private var model = TaskbarModel.shared
    @ObservedObject private var tracker = WindowTracker.shared
    @Environment(\.colorScheme) private var scheme

    private var running: Bool { item.isRunning && hasWindowsHere }
    /// Scoped: highlighted only when the app's focused window is on this taskbar's display.
    private var active: Bool {
        guard item.isActive, running else { return false }
        guard let scope else { return true }
        let wins = tracker.windows(for: item)
        guard let f = wins.first(where: { tracker.focused[$0.pid] == $0.windowID && $0.windowID != nil }) else {
            return wins.isEmpty || scope.isMain
        }
        return scope.contains(f.display)
    }

    var body: some View {
        let small = model.small
        TaskbarButtonChrome(
            width: label == nil ? (small ? 36 : 44) : nil, height: small ? 32 : 40,
            highlighted: active,
            onLeft: { rect in TaskbarActions.click(item, anchor: rect, scope: scope) },
            onRight: { _, view in JumpListMenu.shared.show(for: item, in: view, scope: scope) },
            onMiddle: { _ in TaskbarActions.newWindow(item) },
            onHoverChange: { inside, rect in
                if inside {
                    if running { ThumbnailController.shared.hoverBegan(item: item, anchor: rect, scope: scope) }
                }
                else { ThumbnailController.shared.hoverEnded() }
            },
            onDrag: onDrag, onDragEnd: onDragEnd
        ) {
            HStack(spacing: 8) {
                Image(nsImage: TaskbarModel.shared.icon(for: item))
                    .resizable().interpolation(.high)
                    .frame(width: small ? 20 : 26, height: small ? 20 : 26)
                    .overlay(alignment: .topTrailing) {
                        if let badge { BadgeView(text: badge).offset(x: 7, y: -5) }
                    }
                if let label {
                    Text(label).font(Theme.font(12)).lineLimit(1).frame(maxWidth: 120, alignment: .leading)
                }
            }
            .padding(.horizontal, label == nil ? 0 : 8)
        }
        .overlay(alignment: .bottom) {
            if running {
                Capsule()
                    .fill(active ? Theme.accent : Theme.runningPill(scheme))
                    .frame(width: active ? 16 : 6, height: 3)
                    .padding(.bottom, small ? 0 : 1)
                    .animation(.easeOut(duration: 0.18), value: active)
            }
        }
        .help(item.name)
    }
}

/// One button per window, with its title ("Combine taskbar buttons and hide labels: Never").
struct WindowButton: View {
    let item: AppItem
    let window: WindowTracker.Win
    var badge: String? = nil
    var scope: TaskbarActions.Scope? = nil
    @ObservedObject private var model = TaskbarModel.shared
    @ObservedObject private var tracker = WindowTracker.shared
    @Environment(\.colorScheme) private var scheme

    private var active: Bool {
        item.isActive && tracker.focused[window.pid] == window.windowID && !window.minimized
    }

    var body: some View {
        let small = model.small
        TaskbarButtonChrome(
            width: nil, height: small ? 32 : 40, highlighted: active,
            onLeft: { _ in TaskbarActions.clickWindow(window, item: item) },
            onRight: { _, view in JumpListMenu.shared.show(for: item, in: view, scope: scope) },
            onMiddle: { _ in TaskbarActions.newWindow(item) }
        ) {
            HStack(spacing: 8) {
                Image(nsImage: TaskbarModel.shared.icon(for: item))
                    .resizable().interpolation(.high)
                    .frame(width: small ? 18 : 22, height: small ? 18 : 22)
                    .overlay(alignment: .topTrailing) {
                        if let badge { BadgeView(text: badge).offset(x: 7, y: -5) }
                    }
                Text(window.title.isEmpty ? item.name : window.title)
                    .font(Theme.font(12)).lineLimit(1)
                    .frame(maxWidth: 120, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .frame(width: 160, alignment: .leading)
        }
        .overlay(alignment: .bottom) {
            Capsule()
                .fill(active ? Theme.accent : Theme.runningPill(scheme))
                .frame(width: active ? 16 : 6, height: 3)
                .padding(.bottom, small ? 0 : 1)
        }
        .help(window.title.isEmpty ? item.name : window.title)
    }
}
