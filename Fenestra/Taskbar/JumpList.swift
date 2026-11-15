import AppKit

/// Recent files for an app, from Spotlight (NSMetadataQuery). macOS doesn't expose an app's own
/// recent-documents list to other apps, so this matches recently used files of the types the app opens.
@MainActor
final class RecentFiles: NSObject {
    static let shared = RecentFiles()
    private var results: [String: (date: Date, urls: [URL])] = [:]
    private var queries: [String: NSMetadataQuery] = [:]

    private static let generic: Set<String> = [
        "public.data", "public.item", "public.content", "public.folder", "public.directory",
        "public.url", "public.file-url", "com.apple.package", "public.composite-content", "public.text",
    ]

    func recent(for item: AppItem) -> [URL] { results[item.id]?.urls ?? [] }

    func prefetch(_ item: AppItem) {
        if let r = results[item.id], Date().timeIntervalSince(r.date) < 60 { return }
        guard queries[item.id] == nil else { return }
        let types = Self.documentTypes(item.url)
        guard !types.isEmpty else { results[item.id] = (Date(), []); return }

        let q = NSMetadataQuery()
        let since = Date().addingTimeInterval(-30 * 86400)
        let typePreds = types.prefix(12).map { NSPredicate(format: "kMDItemContentTypeTree == %@", $0) }
        q.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "kMDItemLastUsedDate >= %@", since as NSDate),
            NSCompoundPredicate(orPredicateWithSubpredicates: typePreds),
        ])
        q.sortDescriptors = [NSSortDescriptor(key: "kMDItemLastUsedDate", ascending: false)]
        q.searchScopes = [NSMetadataQueryUserHomeScope]
        let id = item.id
        NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: q, queue: .main) { _ in
            MainActor.assumeIsolated {
                q.stop()
                let urls = (0..<min(q.resultCount, 8)).compactMap { i -> URL? in
                    guard let r = q.result(at: i) as? NSMetadataItem,
                          let path = r.value(forAttribute: NSMetadataItemPathKey) as? String else { return nil }
                    return URL(fileURLWithPath: path)
                }
                RecentFiles.shared.results[id] = (Date(), urls)
                RecentFiles.shared.queries[id] = nil
            }
        }
        queries[id] = q
        q.start()
    }

    static func documentTypes(_ appURL: URL) -> [String] {
        guard let info = Bundle(url: appURL)?.infoDictionary,
              let docTypes = info["CFBundleDocumentTypes"] as? [[String: Any]] else { return [] }
        var out: [String] = []
        for t in docTypes {
            if (t["CFBundleTypeRole"] as? String) == "None" { continue }
            for u in (t["LSItemContentTypes"] as? [String]) ?? [] where !generic.contains(u) && !out.contains(u) {
                out.append(u)
            }
        }
        return out
    }
}

/// The right-click "jump list". A native NSMenu (the user kept it over a Windows-styled panel).
@MainActor
final class JumpListMenu: NSObject {
    static let shared = JumpListMenu()
    private var item: AppItem?
    private var scope: TaskbarActions.Scope?

    func show(for item: AppItem, in view: NSView, scope: TaskbarActions.Scope? = nil) {
        ThumbnailController.shared.dismiss()
        FlyoutManager.shared.close(animated: false)
        self.item = item
        self.scope = scope
        let menu = NSMenu()

        let recents = RecentFiles.shared.recent(for: item)
        if !recents.isEmpty {
            menu.addItem(NSMenuItem.sectionHeader(title: "Recent"))
            for url in recents {
                let mi = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = url
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                icon.size = NSSize(width: 16, height: 16)
                mi.image = icon
                menu.addItem(mi)
            }
            menu.addItem(.separator())
        }

        let open = NSMenuItem(title: item.name, action: #selector(newWindow), keyEquivalent: "")
        open.target = self
        let icon = TaskbarModel.shared.icon(for: item).copy() as! NSImage
        icon.size = NSSize(width: 16, height: 16)
        open.image = icon
        menu.addItem(open)

        let pin = NSMenuItem(title: item.pinned ? "Unpin from taskbar" : "Pin to taskbar",
                             action: #selector(togglePin), keyEquivalent: "")
        pin.target = self
        pin.image = NSImage(systemSymbolName: item.pinned ? "pin.slash" : "pin", accessibilityDescription: nil)
        menu.addItem(pin)

        // Not for Finder: it owns the desktop and relaunches itself anyway (user's choice).
        if item.isRunning, AppSettings.shared.endTask, item.id != "com.apple.finder" {
            // Windows 11 puts End task just above Close window.
            let end = NSMenuItem(title: "End task", action: #selector(endTask), keyEquivalent: "")
            end.target = self
            end.image = NSImage(systemSymbolName: "xmark.octagon", accessibilityDescription: nil)
            end.toolTip = "Force quits \(item.name). Unsaved changes are lost."
            menu.addItem(end)
        }

        if item.isRunning {
            let count = Permissions.shared.accessibility ? TaskbarActions.windows(of: item, scope: scope).count : 1
            let close = NSMenuItem(title: count > 1 ? "Close all windows" : "Close window",
                                   action: #selector(closeAll), keyEquivalent: "")
            close.target = self
            close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
            menu.addItem(close)
        }

        let point = NSPoint(x: 0, y: view.bounds.height + 4)
        menu.popUp(positioning: nil, at: point, in: view)
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL, let item else { return }
        NSWorkspace.shared.open([url], withApplicationAt: item.url, configuration: NSWorkspace.OpenConfiguration())
    }
    @objc private func newWindow() { if let item { TaskbarActions.newWindow(item) } }
    @objc private func togglePin() { if let item { AppSettings.shared.togglePin(item.id) } }
    @objc private func closeAll() { if let item { TaskbarActions.closeAll(item, scope: scope) } }
    @objc private func endTask() { if let item { TaskbarActions.endTask(item) } }
}

/// Right-click on an empty part of the taskbar.
@MainActor
final class TaskbarMenu: NSObject {
    static let shared = TaskbarMenu()
    func show(in view: NSView, at point: NSPoint) {
        let menu = NSMenu()
        func add(_ title: String, _ symbol: String, _ sel: Selector) {
            let mi = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            mi.target = self
            mi.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menu.addItem(mi)
        }
        add("Task Manager", "chart.bar.xaxis", #selector(taskManager))
        menu.addItem(.separator())
        add("Taskbar settings", "gearshape", #selector(settings))
        add("Permissions…", "lock.shield", #selector(permissions))
        menu.addItem(.separator())
        add("Quit Fenestra and restore the Dock", "power", #selector(quit))
        menu.popUp(positioning: nil, at: point, in: view)
    }
    @objc private func taskManager() { SystemActions.openTaskManager() }
    @objc private func settings() { SettingsWindow.show() }
    @objc private func permissions() { PermissionsWindow.show() }
    @objc private func quit() { Lifecycle.quitAndRestore() }
}
