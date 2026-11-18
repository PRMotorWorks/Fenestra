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
    /// Measured widths: the tray (grows with pinned menu bar icons) and Start + Search + Task View.
    @State private var trayWidth: CGFloat = 0
    @State private var leadWidth: CGFloat = 0
    @State private var overflowOpen = false

    static let spacing: CGFloat = 4
    static let labeledWidth: CGFloat = 160       // a button with a label (WindowButton, labeled AppButton)
    private static let edgePad: CGFloat = 12     // left edge to Start
    private static let trayGap: CGFloat = 8      // last app button to the tray
    static let overflowID = "taskbar-apps-overflow"

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

            // The app buttons never reach the tray: centered while they fit, pushed left when crowded (as on
            // Windows 11), and the rest behind a "..." button. They used to be centered on the whole width, under
            // the tray, so with labels on a 1440 pt screen the last one showed up right of the clock.
            GeometryReader { geo in
                let plan = layout(barWidth: geo.size.width)
                HStack(spacing: 0) {
                    appGroup(plan).padding(.leading, plan.x)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onChange(of: plan.hidden.map(\.id)) { _, _ in
                    if FlyoutManager.shared.isOpen(Self.overflowID) { FlyoutManager.shared.close() }
                }
            }
            HStack {
                Spacer()
                TrayView(secondary: !isMain, displayID: displayID)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { trayWidth = $0 }
            }
        }
        .frame(height: Theme.taskbarHeight)
        .foregroundStyle(Theme.text(scheme))
        .font(Theme.font(12))
    }

    private var buttonWidth: CGFloat { model.small ? 36 : 44 }

    // MARK: Fitting the app buttons

    private struct Plan {
        var shown: [TaskbarSlot]
        var hidden: [TaskbarSlot]
        var x: CGFloat
    }

    private func width(_ s: TaskbarSlot) -> CGFloat { s.labeled ? Self.labeledWidth : buttonWidth }
    private func need(_ slots: [TaskbarSlot]) -> CGFloat { slots.reduce(0) { $0 + Self.spacing + width($1) } }

    /// Which buttons fit between Start and the tray on this taskbar, and where the row starts.
    private func layout(barWidth: CGFloat) -> Plan {
        let measured = barWidth > 0 && trayWidth > 0 && leadWidth > 0
        let room = barWidth - Self.edgePad - leadWidth - Self.trayGap - trayWidth
        let separate: Bool
        switch settings.combine {
        case .always: separate = false
        case .never: separate = true
        // "When taskbar is full": labels while every window's button fits (counted per window, not per app).
        case .whenFull: separate = !measured || need(slots(separate: true)) <= room
        }
        var shown = slots(separate: separate)
        var hidden: [TaskbarSlot] = []
        if measured && need(shown) > room {
            let limit = room - (Self.spacing + buttonWidth)      // keep room for the "..." button
            var used: CGFloat = 0
            var cut = shown.count
            for (i, s) in shown.enumerated() {
                used += Self.spacing + width(s)
                if used > limit { cut = i; break }
            }
            hidden = Array(shown[cut...])
            shown = Array(shown[..<cut])
        }
        let group = leadWidth + need(shown) + (hidden.isEmpty ? 0 : Self.spacing + buttonWidth)
        var x = Self.edgePad
        if settings.alignment == .center {
            x = max(Self.edgePad, min((barWidth - group) / 2, barWidth - trayWidth - Self.trayGap - group))
        }
        return Plan(shown: shown, hidden: hidden, x: x)
    }

    /// One entry per button: an app, or one of its windows when buttons aren't combined.
    private func slots(separate: Bool) -> [TaskbarSlot] {
        var out: [TaskbarSlot] = []
        for (index, item) in model.items.enumerated() {
            let all = tracker.windows(for: item)
            guard showsItem(item, all) else { continue }
            let wins = separate ? windowsHere(all) : []
            if wins.isEmpty {
                out.append(TaskbarSlot(id: item.id, item: item, index: index, window: nil,
                                       labeled: separate && item.looksRunning(all),
                                       hasWindowsHere: !filtered || all.contains(where: isHere) || all.isEmpty,
                                       badge: badges.badge(for: item)))
            } else {
                for w in wins {
                    out.append(TaskbarSlot(id: w.id, item: item, index: index, window: w, labeled: true,
                                           hasWindowsHere: true,
                                           badge: w.id == wins.first?.id ? badges.badge(for: item) : nil))
                }
            }
        }
        return out
    }

    private func appGroup(_ plan: Plan) -> some View {
        HStack(spacing: Self.spacing) {
            HStack(spacing: Self.spacing) {
                StartButton()
                SearchButton()
                if settings.showTaskView { TaskViewButton() }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { leadWidth = $0 }
            ForEach(plan.shown) { slot in
                TaskbarSlotButton(slot: slot, scope: scope,
                                  onDrag: { dx in dragID = slot.item.id; dragOffset = dx },
                                  onDragEnd: { dx in finishDrag(slot.item, index: slot.index, dx: dx) })
                    .offset(x: dragID == slot.item.id ? dragOffset : 0)
                    .zIndex(dragID == slot.item.id ? 1 : 0)
            }
            if !plan.hidden.isEmpty {
                let hidden = plan.hidden
                let scope = scope
                TaskbarButtonChrome(width: buttonWidth, height: model.small ? 32 : 40, highlighted: overflowOpen,
                                    onLeft: { rect in
                    FlyoutManager.shared.toggle(id: Self.overflowID, anchor: rect, align: .center) {
                        TaskbarOverflowFlyout(slots: hidden, scope: scope)
                    }
                }) {
                    Image(systemName: "ellipsis").font(.system(size: 16, weight: .semibold))
                }
                .help("Show more apps")
                .onReceive(NotificationCenter.default.publisher(for: FlyoutManager.didShow)) { n in
                    overflowOpen = n.object as? String == Self.overflowID
                }
                .onReceive(NotificationCenter.default.publisher(for: FlyoutManager.didClose)) { n in
                    if n.object as? String == Self.overflowID { overflowOpen = false }
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

    /// Pinned on this taskbar: pinned everywhere, or pinned to this display only ("Pin to this taskbar only").
    private func pinnedHere(_ item: AppItem) -> Bool {
        item.pinned && settings.isPinned(item.id, onDisplay: Displays.uuid(displayID), isMain: isMain,
                                         connected: TaskbarController.shared.taskbarDisplayUUIDs)
    }

    /// Main taskbar: pinned apps and apps without a window stay there. Other taskbars: apps with a window on that display.
    private func showsItem(_ item: AppItem, _ wins: [WindowTracker.Win]) -> Bool {
        let pinned = pinnedHere(item)
        // Pinned to another display's taskbar only and not running: that taskbar shows it, this one doesn't.
        if !pinned && !item.isRunning { return false }
        // Finder unpinned and without windows: gone from the taskbar, like a closed app.
        if !pinned && item.isRunning && !item.looksRunning(wins) { return false }
        guard filtered else { return true }
        if wins.contains(where: isHere) { return true }
        return isMain && (pinned || wins.isEmpty)
    }

    private func windowsHere(_ wins: [WindowTracker.Win]) -> [WindowTracker.Win] {
        filtered ? wins.filter(isHere) : wins
    }

    private func finishDrag(_ item: AppItem, index: Int, dx: CGFloat) {
        let shift = Int((dx / (buttonWidth + Self.spacing)).rounded())
        dragID = nil
        dragOffset = 0
        if shift != 0 { model.move(item.id, to: index + shift) }
    }
}

/// One taskbar button: an app, or one of its windows ("Combine taskbar buttons": Never / When full).
struct TaskbarSlot: Identifiable {
    let id: String
    let item: AppItem
    let index: Int                  // in TaskbarModel.items, for drag-to-reorder
    let window: WindowTracker.Win?
    let labeled: Bool
    let hasWindowsHere: Bool
    let badge: String?
}

struct TaskbarSlotButton: View {
    let slot: TaskbarSlot
    var scope: TaskbarActions.Scope? = nil
    /// In the "..." flyout: a click closes it first, and hovering shows no previews (they would replace it).
    var inOverflow = false
    var onDrag: ((CGFloat) -> Void)? = nil
    var onDragEnd: ((CGFloat) -> Void)? = nil

    var body: some View {
        if let w = slot.window {
            WindowButton(item: slot.item, window: w, badge: slot.badge, scope: scope, inOverflow: inOverflow)
        } else {
            AppButton(item: slot.item, badge: slot.badge, scope: scope, hasWindowsHere: slot.hasWindowsHere,
                      label: slot.labeled ? slot.item.name : nil, inOverflow: inOverflow,
                      onDrag: onDrag, onDragEnd: onDragEnd)
        }
    }
}

/// The app buttons that don't fit on the taskbar: icons in rows of five, labeled buttons in two columns.
struct TaskbarOverflowFlyout: View {
    let slots: [TaskbarSlot]
    let scope: TaskbarActions.Scope?

    var body: some View {
        let icons = slots.filter { !$0.labeled }
        let labeled = slots.filter(\.labeled)
        VStack(alignment: .leading, spacing: TaskbarView.spacing) {
            if !icons.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(44), spacing: TaskbarView.spacing),
                                         count: min(5, icons.count)), spacing: TaskbarView.spacing) {
                    ForEach(icons) { TaskbarSlotButton(slot: $0, scope: scope, inOverflow: true) }
                }
            }
            if !labeled.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(TaskbarView.labeledWidth), spacing: TaskbarView.spacing),
                                         count: min(2, labeled.count)), spacing: TaskbarView.spacing) {
                    ForEach(labeled) { TaskbarSlotButton(slot: $0, scope: scope, inOverflow: true) }
                }
            }
        }
        .padding(8)
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

extension AppItem {
    static let finderID = "com.apple.finder"

    /// Whether the taskbar shows the app as open (running pill, label, hover previews). Finder always runs (it
    /// draws the desktop), so it counts as open only while it has a window, open or minimized: closing its last
    /// window looks like closing an app, as with File Explorer. Without Accessibility its windows can't be seen,
    /// so it then counts as open like any running app.
    @MainActor func looksRunning(_ wins: [WindowTracker.Win]) -> Bool {
        guard isRunning else { return false }
        guard id == AppItem.finderID, Permissions.shared.accessibility else { return true }
        return !wins.isEmpty
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
    var inOverflow = false
    var onDrag: ((CGFloat) -> Void)? = nil
    var onDragEnd: ((CGFloat) -> Void)? = nil
    @ObservedObject private var model = TaskbarModel.shared
    @ObservedObject private var tracker = WindowTracker.shared
    @Environment(\.colorScheme) private var scheme

    private var running: Bool { item.looksRunning(tracker.windows(for: item)) && hasWindowsHere }
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
            onLeft: { rect in
                if inOverflow { FlyoutManager.shared.close(animated: false) }
                TaskbarActions.click(item, anchor: rect, scope: scope)
            },
            onRight: { _, view in JumpListMenu.shared.show(for: item, in: view, scope: scope) },
            onMiddle: { _ in if AppSettings.shared.middleClickNewWindow { TaskbarActions.newWindow(item) } },
            onHoverChange: { inside, rect in
                guard !inOverflow else { return }
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
            // Same width as a window's button, so the taskbar knows what fits before laying it out.
            .frame(width: label == nil ? nil : TaskbarView.labeledWidth, alignment: .leading)
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
    var inOverflow = false
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
            onLeft: { _ in
                if inOverflow { FlyoutManager.shared.close(animated: false) }
                TaskbarActions.clickWindow(window, item: item)
            },
            onRight: { _, view in JumpListMenu.shared.show(for: item, in: view, scope: scope) },
            onMiddle: { _ in if AppSettings.shared.middleClickNewWindow { TaskbarActions.newWindow(item) } }
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
            .frame(width: TaskbarView.labeledWidth, alignment: .leading)
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
