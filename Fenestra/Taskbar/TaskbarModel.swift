import AppKit
import Combine

struct AppItem: Identifiable, Equatable {
    let id: String              // bundle ID (or path for apps without one)
    let url: URL
    let name: String
    var pinned: Bool
    var pids: [pid_t]
    var isActive: Bool

    var isRunning: Bool { !pids.isEmpty }
    static func == (a: AppItem, b: AppItem) -> Bool {
        a.id == b.id && a.pinned == b.pinned && a.pids == b.pids && a.isActive == b.isActive
    }
}

/// Pinned and running apps, kept current from NSWorkspace notifications (no polling).
@MainActor
final class TaskbarModel: ObservableObject {
    static let shared = TaskbarModel()

    @Published private(set) var items: [AppItem] = []
    private var iconCache: [String: NSImage] = [:]
    private var cancellables = Set<AnyCancellable>()
    @Published var small = false

    /// Rough width check for the "When taskbar is full" options (combine / smaller buttons).
    func isFull(screenWidth: CGFloat, buttonWidth: CGFloat) -> Bool {
        let s = AppSettings.shared
        var fixed: CGFloat = 44 + 360            // Start + tray
        switch s.searchStyle {
        case .box: fixed += 220
        case .iconLabel: fixed += 110
        case .icon: fixed += 44
        case .hidden: break
        }
        if s.showTaskView { fixed += 44 }
        var buttons = CGFloat(items.count) * buttonWidth
        if s.combine == .never {
            let wins = items.reduce(0) { $0 + max(1, WindowTracker.shared.windows(for: $1).count) }
            buttons = CGFloat(wins) * 168
        }
        return fixed + buttons > screenWidth - 24
    }

    func useSmallButtons(screenWidth: CGFloat) -> Bool {
        switch AppSettings.shared.smallButtons {
        case .always: return true
        case .never: return false
        case .whenFull: return isFull(screenWidth: screenWidth, buttonWidth: 44)
        }
    }

    /// Whether this item shows one labeled button per window ("Combine taskbar buttons" = Never / When full).
    func showsSeparateWindows(screenWidth: CGFloat) -> Bool {
        switch AppSettings.shared.combine {
        case .always: return false
        case .never: return true
        case .whenFull: return !isFull(screenWidth: screenWidth, buttonWidth: 168)
        }
    }

    /// Drag-to-reorder: moves `id` to `index` among the taskbar items and stores the order as pins.
    func move(_ id: String, to index: Int) {
        var order = items.map(\.id)
        guard let from = order.firstIndex(of: id) else { return }
        order.remove(at: from)
        order.insert(id, at: min(max(index, 0), order.count))
        // The dragged app is pinned at its new spot; other pins keep their relative order.
        let s = AppSettings.shared
        let pinnedSet = Set(s.pinned).union([id])
        s.pinned = order.filter { pinnedSet.contains($0) }
    }

    private init() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { TaskbarModel.shared.rebuild() }
            }
        }
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            let pid = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { if let pid { TaskbarActions.resetShowDesktopIfNeeded(activated: pid) } }
        }
        AppSettings.shared.$pinned
            .dropFirst()
            .sink { _ in DispatchQueue.main.async { TaskbarModel.shared.rebuild() } }
            .store(in: &cancellables)
        rebuild()
    }

    func icon(for item: AppItem) -> NSImage {
        if let i = iconCache[item.id] { return i }
        let i = NSWorkspace.shared.icon(forFile: item.url.path)
        i.size = NSSize(width: 48, height: 48)
        iconCache[item.id] = i
        return i
    }

    func runningApps(for item: AppItem) -> [NSRunningApplication] {
        item.pids.compactMap { NSRunningApplication(processIdentifier: $0) }
    }

    func rebuild() {
        let me = ProcessInfo.processInfo.processIdentifier
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != me && !$0.isTerminated
        }
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        var byID: [String: [NSRunningApplication]] = [:]
        var order: [String] = []
        for app in running.sorted(by: { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }) {
            let key = app.bundleIdentifier ?? app.bundleURL?.path ?? "\(app.processIdentifier)"
            if byID[key] == nil { order.append(key) }
            byID[key, default: []].append(app)
        }

        var result: [AppItem] = []
        let pinned = AppSettings.shared.pinned
        for id in pinned {
            let apps = byID[id] ?? []
            guard let url = apps.first?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            else { continue }
            result.append(AppItem(id: id, url: url, name: Self.displayName(url), pinned: true,
                                  pids: apps.map(\.processIdentifier),
                                  isActive: apps.contains { $0.processIdentifier == frontPID }))
        }
        for id in order where !pinned.contains(id) {
            let apps = byID[id]!
            guard let url = apps.first?.bundleURL else { continue }
            result.append(AppItem(id: id, url: url, name: apps.first?.localizedName ?? Self.displayName(url),
                                  pinned: false, pids: apps.map(\.processIdentifier),
                                  isActive: apps.contains { $0.processIdentifier == frontPID }))
        }
        if result != items { items = result }
    }

    static func displayName(_ url: URL) -> String {
        FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}
