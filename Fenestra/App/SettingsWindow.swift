import AppKit
import SwiftUI

// Settings window. Mirrors Windows 11 25H2 Settings > Personalization > Taskbar and > Start, plus Fenestra's own pages.
//
// Every setting is one `SettingEntry` in `SettingsCatalog`, so the pages and the search results draw the same
// controls: searching finds a setting and lets you change it right there, or jump to its page.

enum SettingsPage: String, CaseIterable, Identifiable {
    case taskbar, start, windows, keyboard, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .taskbar: "Taskbar"
        case .start: "Start"
        case .windows: "Windows"
        case .keyboard: "Keyboard"
        case .about: "Fenestra"
        }
    }
    var symbol: String {
        switch self {
        case .taskbar: "dock.rectangle"
        case .start: "square.grid.2x2"
        case .windows: "macwindow"
        case .keyboard: "keyboard"
        case .about: "info.circle"
        }
    }
}

/// Which page is showing and what is typed in the search field. Shared, so a link on one page can open another.
@MainActor
final class SettingsNav: ObservableObject {
    static let shared = SettingsNav()
    @Published var page: SettingsPage {
        didSet { UserDefaults.standard.set(page.rawValue, forKey: "settingsPage") }
    }
    @Published var query = ""
    private init() {
        page = SettingsPage(rawValue: UserDefaults.standard.string(forKey: "settingsPage") ?? "") ?? .taskbar
    }
    func go(_ p: SettingsPage) {
        query = ""
        page = p
    }
}

/// One setting (or one group of controls that belong together, like the Quick Settings tile list).
struct SettingEntry: Identifiable {
    let id: String
    let page: SettingsPage
    let section: String
    let title: String
    let keywords: String
    let view: () -> AnyView

    func matches(_ words: [String]) -> Bool {
        let text = "\(page.title) \(section) \(title) \(keywords)".lowercased()
        return words.allSatisfy { text.contains($0) }
    }
}

struct SettingSection {
    let page: SettingsPage
    let title: String
    var footer: String? = nil
}

/// Draws its content with the live settings: `v` to read, `b` for bindings.
struct Bound<Content: View>: View {
    @ObservedObject private var s = AppSettings.shared
    let content: (AppSettings, ObservedObject<AppSettings>.Wrapper) -> Content
    var body: some View { content(s, $s) }
}

/// A link to another settings page, for settings that live there.
struct PageLink: View {
    let title: String
    let page: SettingsPage
    var body: some View {
        Button {
            SettingsNav.shared.go(page)
        } label: {
            Label(title, systemImage: "arrow.right.circle")
        }
        .buttonStyle(.link)
    }
}

@MainActor
enum SettingsCatalog {
    private static func item<V: View>(_ id: String, _ page: SettingsPage, _ section: String, _ title: String,
                                      _ keywords: String = "",
                                      @ViewBuilder _ content: @escaping (AppSettings, ObservedObject<AppSettings>.Wrapper) -> V)
        -> SettingEntry {
        SettingEntry(id: id, page: page, section: section, title: title, keywords: keywords,
                     view: { AnyView(Bound(content: content)) })
    }

    static let sections: [SettingSection] = [
        SettingSection(page: .taskbar, title: "Taskbar items"),
        SettingSection(page: .taskbar, title: "System tray"),
        SettingSection(page: .taskbar, title: "Quick Settings",
                       footer: "Tiles in the Wi-Fi, sound and battery flyout, in this order (drag to reorder). You can "
                           + "also click the pencil at the bottom of Quick Settings to unpin, add or drag tiles there, "
                           + "as on Windows. Keyboard layout on Automatic hides the taskbar's ENG US button while the "
                           + "Keyboard layout tile is in Quick Settings."),
        SettingSection(page: .taskbar, title: "Other system tray icons",
                       footer: "Your menu bar icons. Switched on: shown on the taskbar. Off: in the hidden icons menu "
                           + "(^). Wi-Fi, sound, battery, clock, Control Center, keyboard layout and Spotlight are left "
                           + "out: the taskbar has its own."),
        SettingSection(page: .taskbar, title: "Taskbar behaviors"),
        SettingSection(page: .taskbar, title: "Pinned apps",
                       footer: "Drag icons on the taskbar to reorder them. Right-click an icon to pin or unpin it; "
                           + "with more than one display, \"Pin to this taskbar only\" keeps it on that display's "
                           + "taskbar. A pin on a display that isn't connected shows on the main taskbar."),
        SettingSection(page: .start, title: "Start"),
        SettingSection(page: .start, title: "Folders", footer: "These folders appear on Start next to the power button."),
        SettingSection(page: .start, title: "Pinned", footer: "Right-click apps in Start to pin, unpin or move them."),
        SettingSection(page: .windows, title: "Title bar buttons",
                       footer: "With \"Keep the buttons on a window while I drag it\" off, the buttons hide while a "
                           + "window moves and the traffic lights show until you let go (try it if they look choppy on "
                           + "high refresh rate displays). With \"Closing an app's last window\" off, apps keep "
                           + "running after their last window closes, as on a Mac. "
                           + "Maximize fills the screen above the taskbar, never a full-screen Space. Granting Screen "
                           + "Recording lets the buttons match each title bar's color exactly."),
        SettingSection(page: .windows, title: "Snap windows",
                       footer: "Drag a window to a screen edge or corner, or press Control+Option+arrow keys (Windows "
                           + "key + arrows). Quick snap also snaps a window you let go just before a screen edge: "
                           + "thrown toward it, still moving toward it, or just below the top. Gentle needs a clear "
                           + "throw; Strong catches more, but may snap a window you meant to place near an edge."),
        SettingSection(page: .windows, title: "Menu bar and app menus",
                       footer: "Without \"Keep it hidden\", the hidden menu bar slides down when the pointer touches "
                           + "the top of the screen. Menus of menu bar icons still open at the top right. Right-click "
                           + "the title bar buttons for the window menu (Restore, Move, Size, Minimize, Maximize, "
                           + "Close) and the app's menus. In Automatic button size the menu button is left out where "
                           + "it would cover the app's own controls, and in Chromium and Electron apps."),
        SettingSection(page: .windows, title: "Clipboard"),
        SettingSection(page: .windows, title: "Multiple displays",
                       footer: "When a display comes back, its windows return to it: same place and size, still "
                           + "snapped or maximized."),
        SettingSection(page: .keyboard, title: "Start key",
                       footer: "Tap the key alone, without pressing another key, to open or close Start (the Windows "
                           + "key). If you swap Control and Command with Karabiner-Elements, your Command key sends "
                           + "Control: choose Control to open Start with it."),
        SettingSection(page: .keyboard, title: "Alt+Tab",
                       footer: "Hold Option and press Tab to walk through your windows; let go to switch. Shift+Tab "
                           + "or a tap on Shift goes back, arrows move, Esc cancels, Delete closes the selected window."),
        SettingSection(page: .keyboard, title: "Shortcuts",
                       footer: "Click a shortcut, then press the new key combination (with Control, Option or Command). "
                           + "Esc cancels. The arrow resets it to the default."),
        SettingSection(page: .keyboard, title: "Fixed shortcuts"),
        SettingSection(page: .about, title: "Fenestra"),
        SettingSection(page: .about, title: "macOS changes",
                       footer: "Settings Fenestra changes in macOS. Switching one off puts your original value back; "
                           + "quitting Fenestra puts all of them back. The menu bar has its own switch (Windows page)."),
    ]

    static let entries: [SettingEntry] = taskbar + start + windows + keyboard + about

    // MARK: Taskbar

    private static let taskbar: [SettingEntry] = [
        item("searchStyle", .taskbar, "Taskbar items", "Search", "box icon label hide") { _, b in
            Picker("Search", selection: b.searchStyle) {
                ForEach(SearchStyle.allCases) { Text($0.label).tag($0) }
            }
        },
        item("showTaskView", .taskbar, "Taskbar items", "Task view", "button") { _, b in
            Toggle("Task view", isOn: b.showTaskView)
        },
        item("showClock", .taskbar, "System tray", "Show time and date", "clock") { _, b in
            Toggle("Show time and date", isOn: b.showClock)
        },
        item("showSeconds", .taskbar, "System tray", "Show seconds in system tray clock", "clock") { v, b in
            Toggle("Show seconds in system tray clock", isOn: b.showSeconds).disabled(!v.showClock)
        },
        item("showBell", .taskbar, "System tray", "Show notification bell icon", "notifications") { _, b in
            Toggle("Show notification bell icon", isOn: b.showBell)
        },
        item("showMacNC", .taskbar, "System tray", "Show \"Open macOS Notification Center\" in notifications") { _, b in
            Toggle("Show \"Open macOS Notification Center\" in notifications", isOn: b.showMacNotificationCenter)
        },
        item("batteryPercent", .taskbar, "System tray", "Show battery percentage", "power") { _, b in
            if Battery.isPresent { Toggle("Show battery percentage", isOn: b.showBatteryPercent) }
        },
        item("inputIndicator", .taskbar, "System tray", "Keyboard layout (ENG US)", "input language") { _, b in
            Picker("Keyboard layout (ENG US)", selection: b.inputIndicator) {
                ForEach(InputIndicator.allCases) { Text($0.label).tag($0) }
            }
        },
        item("quickTiles", .taskbar, "Quick Settings", "Quick Settings tiles",
             "wifi bluetooth sound volume brightness battery focus tiles reorder") { v, _ in
            QuickTilesEditor()
        },
        item("trayIcons", .taskbar, "Other system tray icons", "Menu bar icons on the taskbar",
             "menu extras overflow hidden icons") { _, _ in
            TrayIconsEditor()
        },
        item("alignment", .taskbar, "Taskbar behaviors", "Taskbar alignment", "center left") { _, b in
            Picker("Taskbar alignment", selection: b.alignment) {
                ForEach(TaskbarAlignment.allCases) { Text($0.label).tag($0) }
            }
        },
        item("autoHide", .taskbar, "Taskbar behaviors", "Automatically hide the taskbar", "auto-hide") { _, b in
            Toggle("Automatically hide the taskbar", isOn: b.autoHide)
        },
        item("badges", .taskbar, "Taskbar behaviors", "Show badges on taskbar apps", "unread count") { v, b in
            Toggle("Show badges on taskbar apps", isOn: b.showBadges)
                .onChange(of: v.showBadges) { _, _ in DockBadges.shared.start() }
        },
        item("flashing", .taskbar, "Taskbar behaviors", "Show flashing on taskbar apps", "attention") { _, _ in
            Toggle("Show flashing on taskbar apps", isOn: .constant(false)).disabled(true)
                .help("macOS doesn't tell other apps when an app asks for attention.")
        },
        item("desktopCorner", .taskbar, "Taskbar behaviors",
             "Select the far corner of the taskbar to show the desktop", "show desktop peek") { _, b in
            Toggle("Select the far corner of the taskbar to show the desktop", isOn: b.showDesktopCorner)
        },
        item("desktopAll", .taskbar, "Taskbar behaviors", "The corner shows the desktop on every display",
             "show desktop monitors") { v, b in
            Toggle("The corner shows the desktop on every display (off: only its own display)",
                   isOn: b.showDesktopAllDisplays)
                .disabled(!v.showDesktopCorner)
        },
        item("endTask", .taskbar, "Taskbar behaviors", "End task: force quit an app from its right-click menu",
             "kill force quit") { _, b in
            Toggle("End task: force quit an app from its right-click menu", isOn: b.endTask)
        },
        item("combine", .taskbar, "Taskbar behaviors", "Combine taskbar buttons and hide labels", "group") { _, b in
            Picker("Combine taskbar buttons and hide labels", selection: b.combine) {
                ForEach(WhenMode.allCases) { Text($0.label).tag($0) }
            }
        },
        item("smallButtons", .taskbar, "Taskbar behaviors", "Show smaller taskbar buttons", "compact") { _, b in
            Picker("Show smaller taskbar buttons", selection: b.smallButtons) {
                ForEach(WhenMode.allCases) { Text($0.label).tag($0) }
            }
        },
        item("allDisplays", .taskbar, "Taskbar behaviors", "Show my taskbar on all displays",
             "multiple monitors screens") { _, b in
            Toggle("Show my taskbar on all displays", isOn: b.taskbarAllDisplays)
        },
        item("appsOn", .taskbar, "Taskbar behaviors", "When using multiple displays, show my taskbar apps on",
             "monitors screens") { v, b in
            Picker("When using multiple displays, show my taskbar apps on", selection: b.taskbarAppsOn) {
                ForEach(TaskbarAppsOn.allCases) { Text($0.label).tag($0) }
            }
            .disabled(!v.taskbarAllDisplays)
        },
        item("pinned", .taskbar, "Pinned apps", "Pinned apps", "pin unpin monitor display this taskbar only") { _, _ in
            PinnedAppsEditor()
        },
    ]

    // MARK: Start

    private static let start: [SettingEntry] = [
        item("startKeyLink", .start, "Start", "Key that opens Start", "windows key command control tap") { v, _ in
            LabeledContent("Key that opens Start") {
                HStack {
                    Text(v.startTapKey.label).foregroundStyle(.secondary)
                    PageLink(title: "Change", page: .keyboard)
                }
            }
        },
        item("startRecommended", .start, "Start", "Show recommended section") { _, b in
            Toggle("Show recommended section", isOn: b.startShowRecommended)
        },
        item("startRecent", .start, "Start", "Show recently added apps") { v, b in
            Toggle("Show recently added apps", isOn: b.startShowRecentlyAdded).disabled(!v.startShowRecommended)
        },
        item("startFiles", .start, "Start", "Show recommended files in Start and items in jump lists", "recent") { v, b in
            Toggle("Show recommended files in Start and items in jump lists", isOn: b.startShowRecommendedFiles)
                .disabled(!v.startShowRecommended)
        },
        item("startAllView", .start, "Start", "All section view", "category grid list") { _, b in
            Picker("All section view", selection: b.startAllView) {
                ForEach(StartAllView.allCases) { Text($0.label).tag($0) }
            }
        },
        item("startLock", .start, "Start", "Show a Lock button next to the power button",
             "lock screen power bottom bar") { _, b in
            Toggle("Show a Lock button next to the power button", isOn: b.startLockButton)
        },
        item("startFolders", .start, "Folders", "Folders next to the power button",
             "documents downloads music pictures videos network settings explorer finder") { v, _ in
            ForEach(StartFolder.allCases) { f in
                Toggle(isOn: Binding(get: { v.startFolders.contains(f.rawValue) }, set: { _ in v.toggleFolder(f) })) {
                    Label(f.label, systemImage: f.symbol)
                }
            }
        },
        item("startPinnedReset", .start, "Pinned", "Reset pinned apps to default") { v, _ in
            Button("Reset pinned apps to default") {
                UserDefaults.standard.removeObject(forKey: "startPinned")
                v.startPinned = ["com.apple.Safari", "com.apple.mail", "com.apple.iCal", "com.apple.Photos",
                                 "com.apple.Notes", "com.apple.reminders", "com.apple.Music", "com.apple.TV",
                                 "com.apple.AppStore", "com.apple.systempreferences", "com.apple.finder",
                                 "com.apple.Maps", "com.apple.MobileSMS", "com.apple.FaceTime",
                                 "com.apple.calculator", "com.apple.TextEdit"]
            }
        },
    ]

    // MARK: Windows

    private static let windows: [SettingEntry] = [
        item("captionButtons", .windows, "Title bar buttons",
             "Replace the traffic lights with minimize, maximize and close buttons", "caption") { _, b in
            Toggle("Replace the traffic lights with minimize, maximize and close buttons", isOn: b.captionButtons)
        },
        item("captionSize", .windows, "Title bar buttons", "Button size", "caption compact") { v, b in
            Picker("Button size", selection: b.captionSize) {
                ForEach(CaptionSize.allCases) { Text($0.label).tag($0) }
            }
            .disabled(!v.captionButtons)
        },
        item("captionDrag", .windows, "Title bar buttons", "Keep the buttons on a window while I drag it",
             "choppy") { v, b in
            Toggle("Keep the buttons on a window while I drag it", isOn: b.captionFollowDrag)
                .disabled(!v.captionButtons)
        },
        item("quitLast", .windows, "Title bar buttons", "Closing an app's last window quits the app") { _, b in
            Toggle("Closing an app's last window quits the app (Finder stays open)", isOn: b.quitOnLastWindow)
        },
        item("snapWindows", .windows, "Snap windows", "Snap windows", "tiling") { _, b in
            Toggle("Snap windows", isOn: b.snapWindows)
        },
        item("snapBar", .windows, "Snap windows", "Show snap layouts when I drag a window to the top of my screen") { v, b in
            Toggle("Show snap layouts when I drag a window to the top of my screen", isOn: b.snapBarOnDrag)
                .disabled(!v.snapWindows)
        },
        item("quickSnap", .windows, "Snap windows", "Quick snap", "throw edge") { v, b in
            Picker("Quick snap", selection: b.quickSnap) {
                ForEach(QuickSnap.allCases) { Text($0.label).tag($0) }
            }
            .disabled(!v.snapWindows)
        },
        item("snapHover", .windows, "Snap windows",
             "Show snap layouts when I hover over a window's maximize button") { v, b in
            Toggle("Show snap layouts when I hover over a window's maximize button", isOn: b.snapLayoutsOnHover)
                .disabled(!v.captionButtons)
        },
        item("snapAssist", .windows, "Snap windows", "When I snap a window, suggest what I can snap next to it",
             "snap assist") { _, b in
            Toggle("When I snap a window, suggest what I can snap next to it", isOn: b.snapAssist)
        },
        item("snapGroups", .windows, "Snap windows", "Show my snapped windows when I hover over taskbar apps",
             "snap groups") { _, b in
            Toggle("Show my snapped windows when I hover over taskbar apps", isOn: b.snapGroups)
        },
        item("hideMenuBar", .windows, "Menu bar and app menus", "Hide the macOS menu bar") { _, b in
            Toggle("Hide the macOS menu bar", isOn: b.hideMenuBar)
        },
        item("menuNoReveal", .windows, "Menu bar and app menus",
             "Keep it hidden when the pointer touches the top of the screen", "menu bar reveal") { v, b in
            Toggle("Keep it hidden when the pointer touches the top of the screen", isOn: b.menuBarNoReveal)
                .disabled(!v.hideMenuBar)
        },
        item("menuButton", .windows, "Menu bar and app menus", "Show a menu button next to the title bar buttons") { v, b in
            Toggle("Show a menu button next to the title bar buttons", isOn: b.menuButton)
                .disabled(!v.captionButtons)
        },
        item("menuKeysLink", .windows, "Menu bar and app menus", "Keyboard shortcuts for menus",
             "option tap alt space") { _, _ in
            PageLink(title: "Option tap and Option+Space are on the Keyboard page", page: .keyboard)
        },
        item("clipboardHistory", .windows, "Clipboard", "Clipboard history", "copy paste") { _, b in
            Toggle("Clipboard history", isOn: b.clipboardHistory)
        },
        item("clipboardLimit", .windows, "Clipboard", "Items to keep", "clipboard history") { v, b in
            Picker("Items to keep", selection: b.clipboardLimit) {
                ForEach([10, 25, 50, 100], id: \.self) { Text("\($0)" + ($0 == 25 ? " (Windows)" : "")).tag($0) }
            }
            .disabled(!v.clipboardHistory)
        },
        item("clipboardClear", .windows, "Clipboard", "Clear clipboard data", "history") { _, _ in
            LabeledContent("Clear clipboard data") {
                Button("Clear") { ClipboardHistory.shared.clearData() }
            }
        },
        item("clipboardNote", .windows, "Clipboard", "How clipboard history works", "paste pinned") { v, _ in
            Text("\(v.combo(.clipboard).words) opens it (Windows key + V). Click an item or press Return to paste "
                 + "it into the app you were typing in. Text, images and files copied in Finder; items over 4 MB and "
                 + "copies password managers mark as concealed are left out. Kept in memory only: the history, "
                 + "pinned items included, starts empty when Fenestra restarts. Clear removes everything except "
                 + "pinned items, and what is on the clipboard now.")
                .foregroundStyle(.secondary)
        },
        item("rememberLocations", .windows, "Multiple displays",
             "Remember window locations based on monitor connection", "displays screens") { _, b in
            Toggle("Remember window locations based on monitor connection", isOn: b.rememberWindowLocations)
        },
        item("minimizeDisconnect", .windows, "Multiple displays", "Minimize windows when a monitor is disconnected",
             "displays screens") { _, b in
            Toggle("Minimize windows when a monitor is disconnected", isOn: b.minimizeOnDisconnect)
        },
    ]

    // MARK: Keyboard

    private static let keyboard: [SettingEntry] = [
        item("startTapKey", .keyboard, "Start key", "Tap this key alone to open Start",
             "windows key command control cmd ctrl karabiner swap") { _, b in
            Picker("Tap this key alone to open Start", selection: b.startTapKey) {
                ForEach(StartTapKey.allCases) { Text($0.label).tag($0) }
            }
        },
        item("altTab", .keyboard, "Alt+Tab", "Option+Tab switches between windows", "alt tab switcher") { _, b in
            Toggle("Option+Tab switches between windows (Alt+Tab)", isOn: b.altTab)
        },
        item("altTabDisplays", .keyboard, "Alt+Tab", "Show windows from",
             "alt tab monitor display screen current only") { v, b in
            Picker("Show windows from", selection: b.altTabDisplays) {
                ForEach(AltTabDisplays.allCases) { Text($0.label).tag($0) }
            }
            .disabled(!v.altTab)
        },
        item("altTabShift", .keyboard, "Alt+Tab", "Tap Shift to go back one window", "alt tab reverse backwards") { v, b in
            Toggle("Tap Shift to go back one window", isOn: b.altTabShiftTap)
                .disabled(!v.altTab)
        },
        item("keyTaskView", .keyboard, "Shortcuts", ShortcutAction.taskView.title, "windows tab") { _, b in
            ShortcutRow(action: .taskView, enabled: b.taskViewShortcut)
        },
        item("keySnapLayouts", .keyboard, "Shortcuts", ShortcutAction.snapLayouts.title, "windows z snap") { v, _ in
            ShortcutRow(action: .snapLayouts, note: v.snapWindows ? nil : "Off while Snap windows is off")
        },
        item("keyShowDesktop", .keyboard, "Shortcuts", ShortcutAction.showDesktop.title, "windows d") { _, b in
            ShortcutRow(action: .showDesktop, enabled: b.showDesktopShortcut)
        },
        item("keyClipboard", .keyboard, "Shortcuts", ShortcutAction.clipboard.title, "windows v paste") { _, _ in
            ShortcutRow(action: .clipboard)
        },
        item("keyWindowMenu", .keyboard, "Shortcuts", ShortcutAction.windowMenu.title,
             "alt space restore move size") { _, b in
            ShortcutRow(action: .windowMenu, enabled: b.altSpaceMenu)
        },
        item("keyResetAll", .keyboard, "Shortcuts", "Reset all shortcuts", "default") { v, _ in
            Button("Reset all shortcuts to default") { v.shortcuts = [:] }
                .disabled(v.shortcuts.isEmpty)
        },
        item("optionTap", .keyboard, "Fixed shortcuts", "Tap Option to open the app's menus", "alt menus") { _, b in
            Toggle("Tap Option to open the app's menus (Alt)", isOn: b.optionTapMenus)
        },
        item("fixedList", .keyboard, "Fixed shortcuts", "Snap and switch keys",
             "arrows snap move display alt tab") { _, _ in
            FixedShortcut(keys: "⌃⌥ ← → ↑ ↓", title: "Snap the window in front (Windows key + arrows)")
            FixedShortcut(keys: "⌃⌥⇧ ← →", title: "Move the window to the next display (Windows key + Shift + arrows)")
            FixedShortcut(keys: "⌥ Tab", title: "Next window (Alt+Tab)")
            FixedShortcut(keys: "⌥⇧ Tab", title: "Previous window (Alt+Shift+Tab)")
        },
    ]

    // MARK: Fenestra

    private static let about: [SettingEntry] = [
        item("aboutButtons", .about, "Fenestra", "Permissions, restore script, quit", "accessibility screen recording") { _, _ in
            HStack {
                Button("Permissions…") { PermissionsWindow.show() }
                Button("Show restore script") {
                    NSWorkspace.shared.activateFileViewerSelecting([Lifecycle.supportDir.appendingPathComponent("restore.sh")])
                }
                Spacer()
                Button("Quit and restore Dock") { Lifecycle.quitAndRestore() }
            }
        },
        item("version", .about, "Fenestra", "Version", "about") { _, _ in
            LabeledContent("Version") {
                Text((Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?")
            }
        },
        item("uninstall", .about, "Fenestra", "Remove Fenestra from this Mac", "uninstall") { _, _ in
            LabeledContent("Remove Fenestra from this Mac") {
                Button("Uninstall…") {
                    let a = NSAlert()
                    a.messageText = "Uninstall Fenestra?"
                    a.informativeText = "Your Dock, menu bar and every macOS setting Fenestra changed go back "
                        + "to how they were, then the app, its login item and its settings are removed. "
                        + "Permissions you gave it can be removed in System Settings > Privacy & Security."
                    a.addButton(withTitle: "Uninstall")
                    a.addButton(withTitle: "Cancel")
                    a.buttons.first?.hasDestructiveAction = true
                    if a.runModal() == .alertFirstButtonReturn { Lifecycle.uninstall() }
                }
            }
        },
        item("font", .about, "Fenestra", "Font", "segoe") { _, _ in
            Text(Theme.segoeFamily.map { "Font: \($0) (installed)" } ?? "Font: system font (install Segoe UI Variable to use it)")
                .foregroundStyle(.secondary)
        },
        item("macOSChanges", .about, "macOS changes", "macOS changes",
             "dock finder double-click tiling wallpaper minimize genie defaults") { v, _ in
            ForEach(MacOSChange.allCases) { c in
                Toggle(c.label, isOn: Binding(get: { v.macOSChange(c) }, set: { v.setMacOSChange(c, $0) }))
            }
        },
    ]
}

// MARK: Window

struct SettingsView: View {
    @ObservedObject private var nav = SettingsNav.shared
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 8) {
                SearchField(text: $nav.query, focused: $searchFocused)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                List(selection: Binding(get: { nav.query.isEmpty ? nav.page : nil },
                                        set: { if let p = $0 { nav.go(p) } })) {
                    ForEach(SettingsPage.allCases) { p in
                        Label(p.title, systemImage: p.symbol).tag(p as SettingsPage?)
                    }
                }
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            if nav.query.trimmingCharacters(in: .whitespaces).isEmpty {
                SettingsPageView(page: nav.page)
                    .id(nav.page)
            } else {
                SettingsSearchResults(query: nav.query)
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        .background {
            // Command+F searches, as in System Settings.
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
        }
    }
}

struct SearchField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search settings", text: $text)
                .textFieldStyle(.plain)
                .focused(focused)
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
    }
}

struct SettingsPageView: View {
    let page: SettingsPage
    var body: some View {
        Form {
            ForEach(SettingsCatalog.sections.filter { $0.page == page }, id: \.title) { sec in
                Section {
                    ForEach(SettingsCatalog.entries.filter { $0.page == page && $0.section == sec.title }) { e in
                        e.view()
                    }
                } header: {
                    Text(sec.title)
                } footer: {
                    if let f = sec.footer { Text(f).foregroundStyle(.secondary) }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(page.title)
    }
}

struct SettingsSearchResults: View {
    let query: String
    private var words: [String] {
        query.lowercased().split(whereSeparator: { $0 == " " || $0 == "+" }).map(String.init)
    }
    var body: some View {
        let hits = SettingsCatalog.entries.filter { $0.matches(words) }
        if hits.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            Form {
                ForEach(SettingsCatalog.sections, id: \.title) { sec in
                    let inSection = hits.filter { $0.page == sec.page && $0.section == sec.title }
                    if !inSection.isEmpty {
                        Section {
                            ForEach(inSection) { $0.view() }
                        } header: {
                            HStack {
                                Text("\(sec.page.title) › \(sec.title)")
                                Spacer()
                                Button("Show page") { SettingsNav.shared.go(sec.page) }
                                    .buttonStyle(.link)
                                    .font(.caption)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Search")
        }
    }
}

// MARK: Editors used by more than one control

struct QuickTilesEditor: View {
    @ObservedObject private var s = AppSettings.shared
    var body: some View {
        ForEach(s.tiles + QSTileKind.allCases.filter { !s.tiles.contains($0) }) { k in
            Toggle(isOn: Binding(get: { s.tiles.contains(k) }, set: { s.setTile(k, $0) })) {
                Label(k.title, systemImage: k.symbol)
            }
        }
        .onMove { from, to in
            // Only the shown tiles have an order; moving among them reorders Quick Settings.
            var shown = s.tiles
            guard let f = from.first, f < shown.count else { return }
            shown.move(fromOffsets: from, toOffset: min(to, shown.count))
            s.quickTiles = shown.map(\.rawValue)
        }
        Button("Reset to default tiles") { s.quickTiles = QSTileKind.defaults.map(\.rawValue) }
    }
}

struct TrayIconsEditor: View {
    @ObservedObject private var s = AppSettings.shared
    @ObservedObject private var extras = MenuExtras.shared
    var body: some View {
        if extras.items.isEmpty {
            Text("No menu bar icons found.").foregroundStyle(.secondary)
        }
        ForEach(extras.items) { e in
            Toggle(isOn: Binding(get: { s.trayPinned.contains(e.id) }, set: { s.setTrayPinned(e.id, $0) })) {
                HStack(spacing: 8) {
                    MenuExtraIcon(extra: e).frame(width: 20)
                    Text(e.name)
                }
            }
        }
    }
}

/// Pinned taskbar apps, each on every taskbar or on one display's taskbar only.
struct PinnedAppsEditor: View {
    @ObservedObject private var s = AppSettings.shared
    private static let everywhere = "*"

    private var screens: [(uuid: String, name: String)] {
        NSScreen.screens.map { (Displays.uuid(Displays.id($0)), $0.localizedName) }
    }

    var body: some View {
        if s.pinned.isEmpty { Text("No pinned apps.").foregroundStyle(.secondary) }
        ForEach(s.pinned, id: \.self) { id in
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) ?? URL(fileURLWithPath: id)
            HStack {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable().frame(width: 20, height: 20)
                Text(TaskbarModel.displayName(url))
                Spacer()
                if screens.count > 1 || s.pinnedDisplays[id] != nil {
                    Picker("", selection: Binding(
                        get: { s.pinnedDisplays[id] ?? Self.everywhere },
                        set: { s.pin(id, display: $0 == Self.everywhere ? nil : $0) })) {
                        Text("All taskbars").tag(Self.everywhere)
                        ForEach(screens, id: \.uuid) { Text("Only on \($0.name)").tag($0.uuid) }
                        if let only = s.pinnedDisplays[id], !screens.contains(where: { $0.uuid == only }) {
                            Text("Only on a display that isn't connected").tag(only)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Button("Unpin") { s.togglePin(id) }
            }
        }
    }
}

// MARK: Shortcuts

/// One rebindable shortcut: what it does, its key combination (click to record another) and its switch.
struct ShortcutRow: View {
    let action: ShortcutAction
    var enabled: Binding<Bool>? = nil
    var note: String? = nil
    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                ShortcutRecorder(action: action)
                    .disabled(enabled.map { !$0.wrappedValue } ?? false)
                if let enabled {
                    Toggle("", isOn: enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }
        } label: {
            Text(action.title)
            Text(note ?? action.windowsName)
        }
    }
}

/// Click, then press a key combination. Esc cancels. Shows why a combination can't be used.
struct ShortcutRecorder: View {
    let action: ShortcutAction
    @ObservedObject private var s = AppSettings.shared
    @State private var recording = false
    @State private var monitor: Any?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 4) {
                Button {
                    recording ? stop() : start()
                } label: {
                    Text(recording ? "Press keys…" : s.combo(action).symbols)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .frame(minWidth: 96)
                }
                .buttonStyle(.bordered)
                .tint(recording ? .accentColor : nil)
                .help(recording ? "Press the new shortcut, or Esc to cancel"
                                : "\(s.combo(action).words). Click to change.")
                if s.combo(action) != action.defaultCombo {
                    Button {
                        s.setCombo(action, nil)
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .help("Reset to \(action.defaultCombo.words)")
                }
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        problem = nil
        recording = true
        HotKeys.shared.setRecording(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            MainActor.assumeIsolated { record(e) }
            return nil
        }
    }

    private func record(_ e: NSEvent) {
        let mods = e.modifierFlags.intersection([.control, .option, .command, .shift])
        if e.keyCode == 53 && mods.isEmpty { stop(); return }          // Esc
        guard let c = KeyCombo(event: e) else {
            problem = "Use Control, Option or Command with the key."
            return
        }
        if let why = action.conflict(c) {
            problem = why
            return
        }
        s.setCombo(action, c)
        stop()
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { HotKeys.shared.setRecording(false) }
        recording = false
    }
}

struct FixedShortcut: View {
    let keys: String
    let title: String
    var body: some View {
        LabeledContent(title) {
            Text(keys)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
        }
    }
}

@MainActor
enum SettingsWindow {
    private static var window: NSWindow?
    static func show(page: SettingsPage? = nil) {
        if let page { SettingsNav.shared.go(page) }
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "Settings"
            w.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 820, height: 640))
            w.center()
            w.setFrameAutosaveName("FenestraSettings")
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
