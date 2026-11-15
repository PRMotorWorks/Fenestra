import AppKit
import ApplicationServices

/// Windows-style notification list for the taskbar bell.
/// macOS gives other apps no way to read Notification Center's history, so Fenestra watches the
/// NotificationCenter process through Accessibility and records each banner/alert as it appears.
/// Limits: notifications that arrive while Fenestra isn't running, or that show no banner
/// (Focus on, banner style "None"), aren't captured.
@MainActor
final class NotificationStore: ObservableObject {
    static let shared = NotificationStore()

    struct Item: Identifiable, Codable, Equatable {
        var id = UUID()
        let app: String
        let title: String
        let body: String
        let date: Date
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var unread = 0

    private var observer: AXObserver?
    private var ncPID: pid_t = 0
    private var scanScheduled = false
    private var seen: [String: Date] = [:]
    private let file = Lifecycle.supportDir.appendingPathComponent("notifications.json")

    func start() {
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([Item].self, from: data) {
            items = saved
        }
        attach()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                                          object: nil, queue: .main) { n in
            let id = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            if id == "com.apple.notificationcenterui" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    MainActor.assumeIsolated { NotificationStore.shared.attach() }
                }
            }
        }
    }

    private func attach() {
        guard AXIsProcessTrusted(),
              let nc = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first
        else { return }
        if let old = observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(old), .defaultMode) }
        ncPID = nc.processIdentifier
        var obs: AXObserver?
        let cb: AXObserverCallback = { _, _, _, _ in
            MainActor.assumeIsolated { NotificationStore.shared.scheduleScan() }
        }
        guard AXObserverCreate(ncPID, cb, &obs) == .success, let obs else { return }
        let appEl = AX.app(ncPID)
        for n in [kAXWindowCreatedNotification, kAXCreatedNotification, kAXLayoutChangedNotification] {
            AXObserverAddNotification(obs, appEl, n as CFString, nil)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs
        Log.write("notifications: watching NotificationCenter pid \(ncPID)")
    }

    private func scheduleScan() {
        guard !scanScheduled else { return }
        scanScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            MainActor.assumeIsolated {
                NotificationStore.shared.scanScheduled = false
                NotificationStore.shared.scan()
            }
        }
    }

    private func scan() {
        guard let wins: [AXUIElement] = AX.attr(AX.app(ncPID), kAXWindowsAttribute) else { return }
        for w in wins { collect(w, depth: 0) }
    }

    /// Finds banner/alert groups and reads their texts.
    private func collect(_ el: AXUIElement, depth: Int) {
        guard depth < 9 else { return }
        let sub: String? = AX.attr(el, kAXSubroleAttribute)
        if let sub, sub.hasPrefix("AXNotificationCenter") {          // ...Banner, ...Alert
            record(el)
            return
        }
        for c in (AX.attr(el, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { collect(c, depth: depth + 1) }
    }

    private func record(_ group: AXUIElement) {
        var texts: [String] = []
        gatherTexts(group, &texts, depth: 0)
        let desc: String = AX.attr(group, kAXDescriptionAttribute) ?? ""
        guard !texts.isEmpty || !desc.isEmpty else { return }

        // The group's description usually starts with the app name ("Messages, Anna, See you at 8").
        let parts = desc.components(separatedBy: ", ")
        let app = parts.count > 1 ? parts[0] : (texts.count > 2 ? texts[0] : "Notification")
        var lines = texts
        if lines.first == app { lines.removeFirst() }
        let title = lines.first ?? (parts.count > 1 ? parts[1] : desc)
        let body = lines.dropFirst().joined(separator: "\n")

        let key = "\(app)|\(title)|\(body)"
        if let t = seen[key], Date().timeIntervalSince(t) < 120 { return }   // the same banner re-reported
        seen[key] = Date()

        items.insert(Item(app: app, title: title, body: body, date: Date()), at: 0)
        if items.count > 50 { items.removeLast(items.count - 50) }
        unread += 1
        save()
        Log.write("notification captured from \(app)")
    }

    private func gatherTexts(_ el: AXUIElement, _ out: inout [String], depth: Int) {
        guard depth < 6 else { return }
        let role: String? = AX.attr(el, kAXRoleAttribute)
        if role == kAXStaticTextRole, let v: String = AX.attr(el, kAXValueAttribute), !v.isEmpty, !out.contains(v) {
            out.append(v)
        }
        for c in (AX.attr(el, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { gatherTexts(c, &out, depth: depth + 1) }
    }

    func markRead() { unread = 0 }

    func remove(_ item: Item) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func clearAll() {
        items = []
        unread = 0
        save()
    }

    func open(_ item: Item) {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == item.app }) {
            app.unhide()
            AX.focus(pid: app.processIdentifier, window: nil)
        } else if let entry = StartModel.shared.apps.first(where: { $0.name == item.app }) {
            NSWorkspace.shared.openApplication(at: entry.url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func icon(for item: Item) -> NSImage? {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == item.app }) {
            return app.icon
        }
        return StartModel.shared.apps.first(where: { $0.name == item.app }).map { StartModel.shared.icon($0) }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: file) }
    }
}
