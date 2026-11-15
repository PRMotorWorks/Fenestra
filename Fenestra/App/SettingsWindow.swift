import AppKit
import SwiftUI

/// Mirrors Windows 11 25H2 Settings > Personalization > Taskbar and > Start.
struct SettingsView: View {
    @State private var page = "taskbar"
    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                Label("Taskbar", systemImage: "dock.rectangle").tag("taskbar")
                Label("Start", systemImage: "square.grid.2x2").tag("start")
                Label("Windows", systemImage: "macwindow").tag("windows")
                Label("Fenestra", systemImage: "info.circle").tag("about")
            }
            .navigationSplitViewColumnWidth(170)
        } detail: {
            switch page {
            case "start": StartSettingsView()
            case "windows": WindowsSettingsView()
            case "about": AboutSettingsView()
            default: TaskbarSettingsView()
            }
        }
        .frame(width: 720, height: 600)
    }
}

struct TaskbarSettingsView: View {
    @ObservedObject private var s = AppSettings.shared
    @ObservedObject private var extras = MenuExtras.shared
    var body: some View {
        Form {
            Section("Taskbar items") {
                Picker("Search", selection: $s.searchStyle) {
                    ForEach(SearchStyle.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Task view", isOn: $s.showTaskView)
            }
            Section("System tray") {
                Toggle("Show time and date", isOn: $s.showClock)
                Toggle("Show seconds in system tray clock", isOn: $s.showSeconds).disabled(!s.showClock)
                Toggle("Show notification bell icon", isOn: $s.showBell)
                Toggle("Show battery percentage", isOn: $s.showBatteryPercent)
                Picker("Keyboard layout (ENG US)", selection: $s.inputIndicator) {
                    ForEach(InputIndicator.allCases) { Text($0.label).tag($0) }
                }
            }
            Section {
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
            } header: {
                Text("Quick Settings")
            } footer: {
                Text("Tiles in the Wi-Fi, sound and battery flyout, in this order (drag to reorder). You can also click "
                     + "the pencil at the bottom of Quick Settings to unpin, add or drag tiles there, as on Windows. "
                     + "Keyboard layout on Automatic hides the taskbar's ENG US button while the Keyboard layout tile "
                     + "is in Quick Settings.")
                    .foregroundStyle(.secondary)
            }
            Section {
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
            } header: {
                Text("Other system tray icons")
            } footer: {
                Text("Your menu bar icons. Switched on: shown on the taskbar. Off: in the hidden icons menu (^). "
                     + "Wi-Fi, sound, battery, clock, Control Center, keyboard layout and Spotlight are left out: "
                     + "the taskbar has its own.")
                    .foregroundStyle(.secondary)
            }
            Section("Taskbar behaviors") {
                Picker("Taskbar alignment", selection: $s.alignment) {
                    ForEach(TaskbarAlignment.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Automatically hide the taskbar", isOn: $s.autoHide)
                Toggle("Show badges on taskbar apps", isOn: $s.showBadges)
                    .onChange(of: s.showBadges) { _, _ in DockBadges.shared.start() }
                Toggle("Show flashing on taskbar apps", isOn: .constant(false)).disabled(true)
                    .help("macOS doesn't tell other apps when an app asks for attention.")
                Toggle("Select the far corner of the taskbar to show the desktop", isOn: $s.showDesktopCorner)
                Toggle("The corner shows the desktop on every display (off: only its own display)",
                       isOn: $s.showDesktopAllDisplays)
                    .disabled(!s.showDesktopCorner)
                Toggle("End task: force quit an app from its right-click menu", isOn: $s.endTask)
                Picker("Combine taskbar buttons and hide labels", selection: $s.combine) {
                    ForEach(WhenMode.allCases) { Text($0.label).tag($0) }
                }
                Picker("Show smaller taskbar buttons", selection: $s.smallButtons) {
                    ForEach(WhenMode.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Show my taskbar on all displays", isOn: $s.taskbarAllDisplays)
                Picker("When using multiple displays, show my taskbar apps on", selection: $s.taskbarAppsOn) {
                    ForEach(TaskbarAppsOn.allCases) { Text($0.label).tag($0) }
                }
                .disabled(!s.taskbarAllDisplays)
            }
            Section {
                Text("Drag icons on the taskbar to reorder them. Right-click an icon to pin or unpin it.")
                    .foregroundStyle(.secondary)
                ForEach(s.pinned, id: \.self) { id in
                    HStack {
                        Text(TaskbarModel.displayName(NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                                                       ?? URL(fileURLWithPath: id)))
                        Spacer()
                        Button("Unpin") { s.togglePin(id) }
                    }
                }
            } header: { Text("Pinned apps") }
        }
        .formStyle(.grouped)
    }
}

/// Caption buttons (Phase 3) and Windows' Settings > System > Multitasking > Snap windows.
struct WindowsSettingsView: View {
    @ObservedObject private var s = AppSettings.shared
    var body: some View {
        Form {
            Section("Title bar buttons") {
                Toggle("Replace the traffic lights with minimize, maximize and close buttons", isOn: $s.captionButtons)
                Picker("Button size", selection: $s.captionSize) {
                    ForEach(CaptionSize.allCases) { Text($0.label).tag($0) }
                }
                .disabled(!s.captionButtons)
                Toggle("Closing an app's last window quits the app (Finder stays open)", isOn: $s.quitOnLastWindow)
                Text("Off: apps keep running after their last window closes, as on a Mac. Maximize fills the screen "
                     + "above the taskbar, never a full-screen Space. Granting Screen Recording lets the buttons "
                     + "match each title bar's color exactly.")
                    .foregroundStyle(.secondary)
            }
            Section("Snap windows") {
                Toggle("Snap windows", isOn: $s.snapWindows)
                Toggle("Show snap layouts when I drag a window to the top of my screen", isOn: $s.snapBarOnDrag)
                    .disabled(!s.snapWindows)
                Toggle("Show snap layouts when I hover over a window's maximize button", isOn: $s.snapLayoutsOnHover)
                    .disabled(!s.captionButtons)
                Toggle("When I snap a window, suggest what I can snap next to it", isOn: $s.snapAssist)
                Toggle("Show my snapped windows when I hover over taskbar apps", isOn: $s.snapGroups)
                Text("Drag a window to a screen edge or corner, or press Control+Option+arrow keys (Windows key + arrows).")
                    .foregroundStyle(.secondary)
            }
            Section("Menu bar and app menus") {
                Toggle("Hide the macOS menu bar", isOn: $s.hideMenuBar)
                Toggle("Show a menu button next to the title bar buttons", isOn: $s.menuButton)
                    .disabled(!s.captionButtons)
                Toggle("Tap Option to open the app's menus (Alt)", isOn: $s.optionTapMenus)
                Toggle("Option+Space opens the window menu (Alt+Space)", isOn: $s.altSpaceMenu)
                Text("The hidden menu bar still slides down when the pointer touches the top of the screen. "
                     + "Right-click the title bar buttons for the window menu (Restore, Move, Size, Minimize, Maximize, "
                     + "Close) "
                     + "and the app's menus. In Automatic button size the menu button is left out where it would "
                     + "cover the app's own controls, and in Chromium and Electron apps.")
                    .foregroundStyle(.secondary)
            }
            Section("Switching windows") {
                Toggle("Option+Tab switches between windows (Alt+Tab)", isOn: $s.altTab)
                Toggle("Control+Option+Tab opens Task view (Windows key + Tab)", isOn: $s.taskViewShortcut)
                Toggle("Control+Option+D shows the desktop on every display (Windows key + D)", isOn: $s.showDesktopShortcut)
            }
            Section("Clipboard") {
                Toggle("Clipboard history", isOn: $s.clipboardHistory)
                Picker("Items to keep", selection: $s.clipboardLimit) {
                    ForEach([10, 25, 50, 100], id: \.self) { Text("\($0)" + ($0 == 25 ? " (Windows)" : "")).tag($0) }
                }
                .disabled(!s.clipboardHistory)
                LabeledContent("Clear clipboard data") {
                    Button("Clear") { ClipboardHistory.shared.clearData() }
                }
                Text("Control+Option+V opens it (Windows key + V). Click an item or press Return to paste it into the app "
                     + "you were typing in. Text, images and files copied in Finder; items over 4 MB and copies "
                     + "password managers mark as concealed are left out. Kept in memory only: the history, pinned "
                     + "items included, starts empty when Fenestra restarts. Clear removes everything except pinned "
                     + "items, and what is on the clipboard now.")
                    .foregroundStyle(.secondary)
            }
            Section("Multiple displays") {
                Toggle("Remember window locations based on monitor connection", isOn: $s.rememberWindowLocations)
                Toggle("Minimize windows when a monitor is disconnected", isOn: $s.minimizeOnDisconnect)
                Text("When a display comes back, its windows return to it: same place and size, still snapped or maximized.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct StartSettingsView: View {
    @ObservedObject private var s = AppSettings.shared
    var body: some View {
        Form {
            Section("Start") {
                Toggle("Tap Command alone to open Start (Windows key)", isOn: $s.commandTapStart)
                Toggle("Show recommended section", isOn: $s.startShowRecommended)
                Toggle("Show recently added apps", isOn: $s.startShowRecentlyAdded).disabled(!s.startShowRecommended)
                Toggle("Show recommended files in Start and items in jump lists", isOn: $s.startShowRecommendedFiles)
                    .disabled(!s.startShowRecommended)
                Picker("All section view", selection: $s.startAllView) {
                    ForEach(StartAllView.allCases) { Text($0.label).tag($0) }
                }
            }
            Section("Folders") {
                Text("These folders appear on Start next to the power button.").foregroundStyle(.secondary)
                ForEach(StartFolder.allCases) { f in
                    Toggle(isOn: Binding(get: { s.startFolders.contains(f.rawValue) }, set: { _ in s.toggleFolder(f) })) {
                        Label(f.label, systemImage: f.symbol)
                    }
                }
            }
            Section("Pinned") {
                Text("Right-click apps in Start to pin, unpin or move them.").foregroundStyle(.secondary)
                Button("Reset pinned apps to default") {
                    UserDefaults.standard.removeObject(forKey: "startPinned")
                    s.startPinned = ["com.apple.Safari", "com.apple.mail", "com.apple.iCal", "com.apple.Photos",
                                     "com.apple.Notes", "com.apple.reminders", "com.apple.Music", "com.apple.TV",
                                     "com.apple.AppStore", "com.apple.systempreferences", "com.apple.finder",
                                     "com.apple.Maps", "com.apple.MobileSMS", "com.apple.FaceTime",
                                     "com.apple.calculator", "com.apple.TextEdit"]
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct AboutSettingsView: View {
    @ObservedObject private var s = AppSettings.shared
    var body: some View {
        Form {
            Section("Fenestra") {
                HStack {
                    Button("Permissions…") { PermissionsWindow.show() }
                    Button("Show restore script") {
                        NSWorkspace.shared.activateFileViewerSelecting([Lifecycle.supportDir.appendingPathComponent("restore.sh")])
                    }
                    Spacer()
                    Button("Quit and restore Dock") { Lifecycle.quitAndRestore() }
                }
                Text(Theme.segoeFamily.map { "Font: \($0) (installed)" } ?? "Font: system font (install Segoe UI Variable to use it)")
                    .foregroundStyle(.secondary)
            }
            Section("macOS changes") {
                Text("Settings Fenestra changes in macOS. Switching one off puts your original value back; quitting "
                     + "Fenestra puts all of them back. The menu bar has its own switch (Windows tab).")
                    .foregroundStyle(.secondary)
                ForEach(MacOSChange.allCases) { c in
                    Toggle(c.label, isOn: Binding(get: { s.macOSChange(c) }, set: { s.setMacOSChange(c, $0) }))
                }
            }
        }
        .formStyle(.grouped)
    }
}

@MainActor
enum SettingsWindow {
    private static var window: NSWindow?
    static func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "Personalization"
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
