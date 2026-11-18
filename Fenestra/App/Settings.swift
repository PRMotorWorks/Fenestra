import Foundation
import Combine

enum TaskbarAlignment: String, CaseIterable, Identifiable {
    case center, left
    var id: String { rawValue }
    var label: String { self == .center ? "Center" : "Left" }
}

/// Settings > Personalization > Taskbar > Search
enum SearchStyle: String, CaseIterable, Identifiable {
    case hidden, icon, iconLabel, box
    var id: String { rawValue }
    var label: String {
        switch self {
        case .hidden: return "Hide"
        case .icon: return "Search icon only"
        case .iconLabel: return "Search icon and label"
        case .box: return "Search box"
        }
    }
}

/// "Combine taskbar buttons and hide labels" and "Show smaller taskbar buttons"
enum WhenMode: String, CaseIterable, Identifiable {
    case always, whenFull, never
    var id: String { rawValue }
    var label: String {
        switch self {
        case .always: return "Always"
        case .whenFull: return "When taskbar is full"
        case .never: return "Never"
        }
    }
}

/// Width of the caption buttons that replace the traffic lights.
enum CaptionSize: String, CaseIterable, Identifiable {
    case automatic, windows, compact
    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic: return "Automatic (Windows size unless it would cover app controls)"
        case .windows: return "Windows size (46 x 32)"
        case .compact: return "Compact (same width as the traffic lights)"
        }
    }
}

/// "When using multiple displays, show my taskbar apps on" (Settings > Personalization > Taskbar > Taskbar behaviors).
enum TaskbarAppsOn: String, CaseIterable, Identifiable {
    case all, mainAndWhereOpen, whereOpen
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "All taskbars"
        case .mainAndWhereOpen: return "Main taskbar and taskbar where window is open"
        case .whereOpen: return "Taskbar where window is open"
        }
    }
}

/// The modifier key that opens Start when tapped alone (the Windows key). Control is there for keyboards
/// remapped with Karabiner-Elements (Control and Command swapped), where the physical Command key sends Control.
enum StartTapKey: String, CaseIterable, Identifiable {
    case off, command, leftCommand, rightCommand, control, leftControl, rightControl
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: "Off"
        case .command: "Command (either)"
        case .leftCommand: "Left Command"
        case .rightCommand: "Right Command"
        case .control: "Control (either)"
        case .leftControl: "Left Control"
        case .rightControl: "Right Control"
        }
    }
    /// Virtual key codes of the key(s): Command 55 left / 54 right, Control 59 left / 62 right.
    var keyCodes: Set<UInt16> {
        switch self {
        case .off: []
        case .command: [55, 54]
        case .leftCommand: [55]
        case .rightCommand: [54]
        case .control: [59, 62]
        case .leftControl: [59]
        case .rightControl: [62]
        }
    }
    var isControl: Bool { self == .control || self == .leftControl || self == .rightControl }
}

/// Which windows Alt+Tab (Option+Tab) shows when there are several displays.
enum AltTabDisplays: String, CaseIterable, Identifiable {
    case all, activeDisplay, pointerDisplay
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: "All displays"
        case .activeDisplay: "Only the display with the window in front"
        case .pointerDisplay: "Only the display with the pointer"
        }
    }
}

enum StartAllView: String, CaseIterable, Identifiable {
    case category, grid, list
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// Folders that can appear next to the Start power button (Settings > Personalization > Start > Folders).
enum StartFolder: String, CaseIterable, Identifiable {
    case settings, explorer, documents, downloads, music, pictures, videos, network, personal
    var id: String { rawValue }
    var label: String {
        switch self {
        case .settings: return "Settings"
        case .explorer: return "File Explorer (Finder)"
        case .documents: return "Documents"
        case .downloads: return "Downloads"
        case .music: return "Music"
        case .pictures: return "Pictures"
        case .videos: return "Videos (Movies)"
        case .network: return "Network"
        case .personal: return "Personal folder"
        }
    }
    var symbol: String {
        switch self {
        case .settings: return "gearshape"
        case .explorer: return "folder"
        case .documents: return "doc"
        case .downloads: return "arrow.down.circle"
        case .music: return "music.note"
        case .pictures: return "photo"
        case .videos: return "film"
        case .network: return "network"
        case .personal: return "person.crop.circle"
        }
    }
}

/// User settings, stored in UserDefaults (domain local.fenestra.Fenestra).
/// Mirrors Windows 11 25H2 Settings > Personalization > Taskbar and Start.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    // Taskbar items
    @Published var searchStyle: SearchStyle { didSet { d.set(searchStyle.rawValue, forKey: "searchStyle2") } }
    @Published var showTaskView: Bool { didSet { d.set(showTaskView, forKey: "showTaskView") } }
    // System tray
    @Published var showClock: Bool { didSet { d.set(showClock, forKey: "showClock") } }
    @Published var showSeconds: Bool { didSet { d.set(showSeconds, forKey: "showSeconds"); SystemStatus.shared.scheduleClock() } }
    @Published var showBell: Bool { didSet { d.set(showBell, forKey: "showBell") } }
    @Published var showBatteryPercent: Bool { didSet { d.set(showBatteryPercent, forKey: "showBatteryPercent") } }
    @Published var showMacNotificationCenter: Bool {
        didSet { d.set(showMacNotificationCenter, forKey: "showMacNotificationCenter") }
    }
    // Taskbar behaviors
    @Published var alignment: TaskbarAlignment { didSet { d.set(alignment.rawValue, forKey: "alignment") } }
    @Published var autoHide: Bool { didSet { d.set(autoHide, forKey: "autoHide") } }
    @Published var showBadges: Bool { didSet { d.set(showBadges, forKey: "showBadges") } }
    @Published var showDesktopCorner: Bool { didSet { d.set(showDesktopCorner, forKey: "showDesktopCorner") } }
    /// Windows 11 "End task" in a taskbar app's right-click menu (Windows: off, under For developers; on here
    /// because the user asked for it).
    @Published var endTask: Bool { didSet { d.set(endTask, forKey: "endTask") } }
    /// The far corner clears every display (Windows) instead of only its own (default, the user's choice).
    @Published var showDesktopAllDisplays: Bool { didSet { d.set(showDesktopAllDisplays, forKey: "showDesktopAllDisplays") } }
    /// The key that opens Start when tapped alone (Windows key). Replaces the earlier on/off "commandTapStart".
    @Published var startTapKey: StartTapKey { didSet { d.set(startTapKey.rawValue, forKey: "startTapKey") } }
    /// Control+Option+Tab = Windows key + Tab (Task view); Control+Option+D = Windows key + D (show desktop).
    @Published var taskViewShortcut: Bool { didSet { d.set(taskViewShortcut, forKey: "taskViewShortcut"); HotKeys.shared.configure() } }
    @Published var showDesktopShortcut: Bool { didSet { d.set(showDesktopShortcut, forKey: "showDesktopShortcut"); HotKeys.shared.configure() } }
    /// Snap groups in taskbar previews (Windows: "Show my snapped windows when I hover over taskbar apps").
    @Published var snapGroups: Bool { didSet { d.set(snapGroups, forKey: "snapGroups") } }
    /// Windows behavior: closing an app's last window quits the app (Finder never). Off = Mac behavior.
    @Published var quitOnLastWindow: Bool { didSet { d.set(quitOnLastWindow, forKey: "quitOnLastWindow") } }
    /// macOS changes (apply-defaults.sh groups) switched off: those keys get your original values back.
    @Published var macOSChangesOff: [String] {
        didSet { d.set(macOSChangesOff, forKey: "macOSChangesOff"); Lifecycle.applyDefaults() }
    }
    func macOSChange(_ c: MacOSChange) -> Bool { !macOSChangesOff.contains(c.rawValue) }
    func setMacOSChange(_ c: MacOSChange, _ on: Bool) {
        var off = macOSChangesOff.filter { $0 != c.rawValue }
        if !on { off.append(c.rawValue) }
        macOSChangesOff = off
    }
    @Published var combine: WhenMode { didSet { d.set(combine.rawValue, forKey: "combine") } }
    @Published var smallButtons: WhenMode { didSet { d.set(smallButtons.rawValue, forKey: "smallButtons") } }
    @Published var pinned: [String] { didSet { d.set(pinned, forKey: "pinned") } }
    /// Apps pinned to one display's taskbar only: bundle ID -> display UUID (`Displays.uuid`, stable across
    /// reconnects). Apps in `pinned` without an entry are pinned on every taskbar.
    @Published var pinnedDisplays: [String: String] { didSet { d.set(pinnedDisplays, forKey: "pinnedDisplays") } }
    /// Phase 5: "Show my taskbar on all displays" and "When using multiple displays, show my taskbar apps on".
    @Published var taskbarAllDisplays: Bool {
        didSet { d.set(taskbarAllDisplays, forKey: "taskbarAllDisplays"); TaskbarController.shared.layout() }
    }
    @Published var taskbarAppsOn: TaskbarAppsOn {
        didSet { d.set(taskbarAppsOn.rawValue, forKey: "taskbarAppsOn"); WindowTracker.shared.displaysNeededChanged() }
    }

    // Start
    @Published var startPinned: [String] { didSet { d.set(startPinned, forKey: "startPinned") } }
    @Published var startShowRecentlyAdded: Bool { didSet { d.set(startShowRecentlyAdded, forKey: "startShowRecentlyAdded") } }
    @Published var startShowRecommendedFiles: Bool { didSet { d.set(startShowRecommendedFiles, forKey: "startShowRecommendedFiles") } }
    @Published var startShowRecommended: Bool { didSet { d.set(startShowRecommended, forKey: "startShowRecommended") } }
    @Published var startAllView: StartAllView { didSet { d.set(startAllView.rawValue, forKey: "startAllView") } }
    @Published var startFolders: [String] { didSet { d.set(startFolders, forKey: "startFolders") } }
    /// Lock button next to the power button on Start.
    @Published var startLockButton: Bool { didSet { d.set(startLockButton, forKey: "startLockButton") } }

    // Windows: caption buttons and Settings > System > Multitasking > Snap windows
    @Published var captionButtons: Bool {
        didSet { d.set(captionButtons, forKey: "captionButtons"); CaptionController.shared.settingsChanged() }
    }
    @Published var captionSize: CaptionSize {
        didSet { d.set(captionSize.rawValue, forKey: "captionSize"); CaptionController.shared.settingsChanged() }
    }
    @Published var snapLayoutsOnHover: Bool { didSet { d.set(snapLayoutsOnHover, forKey: "snapLayoutsOnHover") } }
    /// On: the buttons move with a dragged window. Off: they hide during the drag and the traffic lights show
    /// (as before 2026-11-15), for anyone who finds the following choppy. Read at each title bar press.
    @Published var captionFollowDrag: Bool { didSet { d.set(captionFollowDrag, forKey: "captionFollowDrag") } }
    /// Phase 4: Settings > System > Multitasking > Snap windows (master switch: edge drags and Control+Option+arrows).
    @Published var snapWindows: Bool { didSet { d.set(snapWindows, forKey: "snapWindows"); HotKeys.shared.configure() } }
    @Published var snapBarOnDrag: Bool { didSet { d.set(snapBarOnDrag, forKey: "snapBarOnDrag") } }
    /// Quick snap: how readily a drag let go short of an outer screen edge snaps there (not in Windows).
    @Published var quickSnap: QuickSnap { didSet { d.set(quickSnap.rawValue, forKey: "quickSnap") } }
    var snapThrow: Bool { quickSnap != .off }
    @Published var snapAssist: Bool { didSet { d.set(snapAssist, forKey: "snapAssist") } }
    /// Option+Tab window switcher (Alt+Tab). Off: Option+Tab reaches apps again.
    @Published var altTab: Bool { didSet { d.set(altTab, forKey: "altTab"); HotKeys.shared.configure() } }
    /// Alt+Tab shows every display's windows, or only the current display's.
    @Published var altTabDisplays: AltTabDisplays { didSet { d.set(altTabDisplays.rawValue, forKey: "altTabDisplays") } }
    /// While Alt+Tab is open, tapping Shift moves the selection back one window (Shift+Tab always does).
    @Published var altTabShiftTap: Bool {
        didSet { d.set(altTabShiftTap, forKey: "altTabShiftTap"); HotKeys.shared.configure() }
    }
    /// Custom key combinations for the rebindable shortcuts: `ShortcutAction` raw value -> `KeyCombo.stored`.
    /// Missing entries use the default combination.
    @Published var shortcuts: [String: String] { didSet { d.set(shortcuts, forKey: "shortcuts"); HotKeys.shared.configure() } }
    func combo(_ a: ShortcutAction) -> KeyCombo { shortcuts[a.rawValue].flatMap(KeyCombo.init(stored:)) ?? a.defaultCombo }
    func setCombo(_ a: ShortcutAction, _ c: KeyCombo?) {
        var m = shortcuts
        if let c, c != a.defaultCombo { m[a.rawValue] = c.stored } else { m[a.rawValue] = nil }
        shortcuts = m
    }
    /// Phase 5: Settings > System > Display > Multiple displays.
    @Published var rememberWindowLocations: Bool { didSet { d.set(rememberWindowLocations, forKey: "rememberWindowLocations") } }
    @Published var minimizeOnDisconnect: Bool { didSet { d.set(minimizeOnDisconnect, forKey: "minimizeOnDisconnect") } }
    /// Phase 6: menu bar migration.
    /// Auto-hide the macOS menu bar (NSGlobalDomain _HIHideMenuBar through apply-defaults.sh, backed up).
    @Published var hideMenuBar: Bool { didSet { d.set(hideMenuBar, forKey: "hideMenuBar"); Lifecycle.applyDefaults() } }
    /// Keep the hidden menu bar from sliding in at the top edge (MenuBarBlocker, private SkyLight alpha).
    @Published var menuBarNoReveal: Bool {
        didSet { d.set(menuBarNoReveal, forKey: "menuBarNoReveal"); MenuBarBlocker.shared.update(reason: "setting") }
    }
    /// Menu button to the right of the caption buttons: the app's menus as a dropdown.
    @Published var menuButton: Bool { didSet { d.set(menuButton, forKey: "menuButton"); CaptionController.shared.settingsChanged() } }
    /// Tapping Option alone opens the front app's menus (Alt on Windows).
    @Published var optionTapMenus: Bool { didSet { d.set(optionTapMenus, forKey: "optionTapMenus"); HotKeys.shared.configure() } }
    /// Option+Space = Alt+Space: the focused window's window menu (Restore, Move, Size, Minimize, Maximize, Close).
    @Published var altSpaceMenu: Bool { didSet { d.set(altSpaceMenu, forKey: "altSpaceMenu"); HotKeys.shared.configure() } }
    /// Menu bar icons shown on the taskbar ("Other system tray icons" switched on); the rest sit in the overflow.
    @Published var trayPinned: [String] { didSet { d.set(trayPinned, forKey: "trayPinned") } }
    /// Quick Settings tiles shown, in order (Windows: Edit quick settings). Raw values of `QSTileKind`.
    @Published var quickTiles: [String] { didSet { d.set(quickTiles, forKey: "quickTiles") } }
    /// Keyboard layout (ENG US) on the taskbar: automatic = hidden while the Keyboard layout tile is in Quick Settings.
    @Published var inputIndicator: InputIndicator { didSet { d.set(inputIndicator.rawValue, forKey: "inputIndicator") } }
    /// Settings > System > Clipboard > Clipboard history (Control+Option+V). Memory only.
    @Published var clipboardHistory: Bool {
        didSet { d.set(clipboardHistory, forKey: "clipboardHistory"); ClipboardHistory.shared.settingsChanged() }
    }
    /// Unpinned items kept (Windows: 25).
    @Published var clipboardLimit: Int { didSet { d.set(clipboardLimit, forKey: "clipboardLimit"); ClipboardHistory.shared.trim() } }
    /// Middle-click a taskbar app: new window (Windows: new instance). On by default.
    @Published var middleClickNewWindow: Bool { didSet { d.set(middleClickNewWindow, forKey: "middleClickNewWindow") } }
    /// Middle-click a link in a web browser: opens it in a new window instead of a background tab (`MiddleClick`).
    /// On by default (the user asked for it). Tabs close on middle-click in the browsers themselves.
    @Published var browserMiddleClick: Bool {
        didSet { d.set(browserMiddleClick, forKey: "browserMiddleClick"); MiddleClick.shared.configure() }
    }

    private init() {
        let defs = UserDefaults.standard
        func bool(_ k: String, _ def: Bool) -> Bool { defs.object(forKey: k) as? Bool ?? def }
        searchStyle = SearchStyle(rawValue: d.string(forKey: "searchStyle2") ?? "") ?? .box
        showTaskView = bool("showTaskView", true)
        showClock = bool("showClock", true)
        showSeconds = bool("showSeconds", false)
        showBell = bool("showBell", true)
        showBatteryPercent = bool("showBatteryPercent", true)
        showMacNotificationCenter = bool("showMacNotificationCenter", false)
        alignment = TaskbarAlignment(rawValue: d.string(forKey: "alignment") ?? "") ?? .center
        autoHide = bool("autoHide", false)
        showBadges = bool("showBadges", true)
        showDesktopCorner = bool("showDesktopCorner", true)
        endTask = bool("endTask", true)
        showDesktopAllDisplays = bool("showDesktopAllDisplays", false)
        startTapKey = StartTapKey(rawValue: d.string(forKey: "startTapKey") ?? "")
            ?? (bool("commandTapStart", true) ? .command : .off)
        taskViewShortcut = bool("taskViewShortcut", true)
        showDesktopShortcut = bool("showDesktopShortcut", true)
        snapGroups = bool("snapGroups", true)
        quitOnLastWindow = bool("quitOnLastWindow", true)
        macOSChangesOff = d.stringArray(forKey: "macOSChangesOff") ?? []
        combine = WhenMode(rawValue: d.string(forKey: "combine") ?? "") ?? .always
        smallButtons = WhenMode(rawValue: d.string(forKey: "smallButtons") ?? "") ?? .whenFull
        pinnedDisplays = d.dictionary(forKey: "pinnedDisplays") as? [String: String] ?? [:]
        pinned = d.stringArray(forKey: "pinned") ?? [
            "com.apple.finder", "com.apple.Safari", "com.apple.AppStore", "com.apple.mail",
        ]
        startPinned = d.stringArray(forKey: "startPinned") ?? [
            "com.apple.Safari", "com.apple.mail", "com.apple.iCal", "com.apple.Photos", "com.apple.Notes",
            "com.apple.reminders", "com.apple.Music", "com.apple.TV", "com.apple.AppStore", "com.apple.systempreferences",
            "com.apple.finder", "com.apple.Maps", "com.apple.MobileSMS", "com.apple.FaceTime", "com.apple.calculator",
            "com.apple.TextEdit",
        ]
        startShowRecentlyAdded = bool("startShowRecentlyAdded", true)
        startShowRecommendedFiles = bool("startShowRecommendedFiles", true)
        startShowRecommended = bool("startShowRecommended", true)
        startAllView = StartAllView(rawValue: d.string(forKey: "startAllView") ?? "") ?? .category
        startFolders = d.stringArray(forKey: "startFolders") ?? ["settings", "explorer", "downloads"]
        startLockButton = bool("startLockButton", false)
        captionButtons = bool("captionButtons", true)
        captionSize = CaptionSize(rawValue: d.string(forKey: "captionSize") ?? "") ?? .automatic
        snapLayoutsOnHover = bool("snapLayoutsOnHover", true)
        // The earlier hidden switch `captionHideWhileDragging` decides the default if it was set.
        captionFollowDrag = bool("captionFollowDrag", !d.bool(forKey: "captionHideWhileDragging"))
        snapWindows = bool("snapWindows", true)
        snapBarOnDrag = bool("snapBarOnDrag", true)
        snapAssist = bool("snapAssist", true)
        // Replaces the earlier on/off "snapThrow" switch (off stays off).
        quickSnap = QuickSnap(rawValue: d.string(forKey: "quickSnap") ?? "")
            ?? (bool("snapThrow", true) ? .normal : .off)
        altTab = bool("altTab", true)
        altTabDisplays = AltTabDisplays(rawValue: d.string(forKey: "altTabDisplays") ?? "") ?? .all
        altTabShiftTap = bool("altTabShiftTap", true)
        shortcuts = d.dictionary(forKey: "shortcuts") as? [String: String] ?? [:]
        taskbarAllDisplays = bool("taskbarAllDisplays", true)
        taskbarAppsOn = TaskbarAppsOn(rawValue: d.string(forKey: "taskbarAppsOn") ?? "") ?? .all
        rememberWindowLocations = bool("rememberWindowLocations", true)
        minimizeOnDisconnect = bool("minimizeOnDisconnect", true)
        hideMenuBar = bool("hideMenuBar", true)
        menuBarNoReveal = bool("menuBarNoReveal", true)
        menuButton = bool("menuButton", true)
        optionTapMenus = bool("optionTapMenus", true)
        altSpaceMenu = bool("altSpaceMenu", true)
        trayPinned = d.stringArray(forKey: "trayPinned") ?? []
        quickTiles = d.stringArray(forKey: "quickTiles") ?? QSTileKind.defaults.map(\.rawValue)
        inputIndicator = InputIndicator(rawValue: d.string(forKey: "inputIndicator") ?? "") ?? .automatic
        clipboardHistory = bool("clipboardHistory", true)
        clipboardLimit = defs.object(forKey: "clipboardLimit") as? Int ?? 25
        middleClickNewWindow = bool("middleClickNewWindow", true)
        browserMiddleClick = bool("browserMiddleClick", true)
    }

    var tiles: [QSTileKind] { quickTiles.compactMap(QSTileKind.init(rawValue:)) }

    func setTile(_ k: QSTileKind, _ on: Bool) {
        quickTiles.removeAll { $0 == k.rawValue }
        if on { quickTiles.append(k.rawValue) }
    }

    /// Whether the keyboard layout button shows on the taskbar.
    var showInputIndicator: Bool {
        switch inputIndicator {
        case .automatic: !quickTiles.contains(QSTileKind.keyboard.rawValue)
        case .show: true
        case .hide: false
        }
    }

    func setTrayPinned(_ id: String, _ on: Bool) {
        trayPinned.removeAll { $0 == id }
        if on { trayPinned.append(id) }
    }

    func togglePin(_ bundleID: String) {
        if let i = pinned.firstIndex(of: bundleID) {
            pinnedDisplays[bundleID] = nil
            pinned.remove(at: i)
        } else {
            pinned.append(bundleID)
        }
    }
    /// Pins an app to one display's taskbar only (`display` = `Displays.uuid`), or to every taskbar (nil).
    func pin(_ bundleID: String, display: String?) {
        pinnedDisplays[bundleID] = display
        if !pinned.contains(bundleID) { pinned.append(bundleID) }
    }
    /// Whether a pinned app shows as pinned on the taskbar of `display` (a UUID). A pin on a display that is
    /// not connected (or has no taskbar) shows on the main taskbar, so the app is never out of reach.
    func isPinned(_ bundleID: String, onDisplay display: String, isMain: Bool, connected: Set<String>) -> Bool {
        guard pinned.contains(bundleID) else { return false }
        guard let only = pinnedDisplays[bundleID] else { return true }
        return only == display || (isMain && !connected.contains(only))
    }
    func toggleStartPin(_ bundleID: String) {
        if let i = startPinned.firstIndex(of: bundleID) { startPinned.remove(at: i) } else { startPinned.append(bundleID) }
    }
    func moveStartPin(_ bundleID: String, toFront: Bool) {
        guard let i = startPinned.firstIndex(of: bundleID) else { return }
        let id = startPinned.remove(at: i)
        if toFront { startPinned.insert(id, at: 0) } else { startPinned.append(id) }
    }
    func toggleFolder(_ f: StartFolder) {
        if let i = startFolders.firstIndex(of: f.rawValue) { startFolders.remove(at: i) } else { startFolders.append(f.rawValue) }
    }
}

enum InputIndicator: String, CaseIterable, Identifiable {
    case automatic, show, hide
    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic: "Automatic"
        case .show: "Always show"
        case .hide: "Never show"
        }
    }
}

/// The groups of macOS settings Fenestra changes (keys in Resources/apply-defaults.sh, group names must match).
/// The menu bar has its own switch ("Hide the macOS menu bar").
enum MacOSChange: String, CaseIterable, Identifiable {
    case dock, finder, doubleclick, tiling, wallpaper, minimize
    var id: String { rawValue }
    var label: String {
        switch self {
        case .dock: "Hide the Dock (the taskbar replaces it)"
        case .finder: "Explorer-like Finder: path bar, status bar, folders first, new windows open Home, all extensions"
        case .doubleclick: "Double-clicking a title bar fills the screen"
        case .tiling: "Turn off macOS window tiling (it reacts to the same drags as Fenestra's snapping)"
        case .wallpaper: "Clicking the wallpaper doesn't hide your windows"
        case .minimize: "Minimize with the Scale effect instead of Genie"
        }
    }
}

/// Quick snap levels (Settings > Windows > Snap windows). Off: only touching the edge snaps, as on Windows.
enum QuickSnap: String, CaseIterable, Identifiable {
    case off, gentle, normal, strong
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: "Off (touch the edge, like Windows)"
        case .gentle: "Gentle"
        case .normal: "Normal"
        case .strong: "Strong"
        }
    }
    /// Thresholds for DragSnap. Normal is what the user tuned on 2026-11-15.
    struct Tuning {
        let topMagnet: CGFloat        // letting go this close below the top counts as touching it
        let nearEdge: CGFloat         // close call: this near an outer edge ...
        let nearSpeed: CGFloat        // ... still moving toward it this fast (pt/s) ...
        let nearTravel: CGFloat       // ... or having moved this far toward it in the last 0.25 s
        let throwSpeed: CGFloat       // throw: at least this fast (pt/s) ...
        let throwAhead: Double        // ... reaching the edge within this time (s) ...
        let throwReach: CGFloat       // ... and this distance (pt)
    }
    var tuning: Tuning {
        switch self {
        case .off: Tuning(topMagnet: 0, nearEdge: 0, nearSpeed: .infinity, nearTravel: .infinity,
                          throwSpeed: .infinity, throwAhead: 0, throwReach: 0)
        case .gentle: Tuning(topMagnet: 20, nearEdge: 60, nearSpeed: 600, nearTravel: 100,
                             throwSpeed: 1800, throwAhead: 0.2, throwReach: 300)
        case .normal: Tuning(topMagnet: 40, nearEdge: 120, nearSpeed: 400, nearTravel: 60,
                             throwSpeed: 1200, throwAhead: 0.3, throwReach: 600)
        case .strong: Tuning(topMagnet: 60, nearEdge: 200, nearSpeed: 300, nearTravel: 40,
                             throwSpeed: 900, throwAhead: 0.4, throwReach: 900)
        }
    }
}
