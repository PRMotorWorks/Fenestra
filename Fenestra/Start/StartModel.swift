import AppKit
import Combine

/// Everything Start shows: installed apps (with 25H2 categories), recommendations and search results.
/// File results come from Spotlight (NSMetadataQuery), not a custom index.
@MainActor
final class StartModel: ObservableObject {
    static let shared = StartModel()

    struct AppEntry: Identifiable, Hashable {
        let id: String           // bundle ID, or path when the app has none
        let url: URL
        let name: String
        let category: String
        let added: Date
    }
    struct FileEntry: Identifiable, Hashable {
        var id: String { url.path }
        let url: URL
        let name: String
        let date: Date
    }
    struct SettingEntry: Identifiable, Hashable {
        let id: String           // pane extension bundle ID
        let name: String
    }
    enum Result: Identifiable, Hashable {
        case app(AppEntry), file(FileEntry), setting(SettingEntry)
        var id: String {
            switch self {
            case .app(let a): return "a:" + a.id
            case .file(let f): return "f:" + f.id
            case .setting(let s): return "s:" + s.id
            }
        }
        var name: String {
            switch self {
            case .app(let a): return a.name
            case .file(let f): return f.name
            case .setting(let s): return s.name
            }
        }
        var kind: String {
            switch self {
            case .app: return "App"
            case .file: return "Document"
            case .setting: return "System settings"
            }
        }
    }

    @Published private(set) var apps: [AppEntry] = []
    @Published private(set) var recentFiles: [FileEntry] = []
    @Published var query = "" { didSet { scheduleSearch() } }
    @Published private(set) var results: [Result] = []
    @Published var selection: Result?

    private var settingsPanes: [SettingEntry] = []
    private var iconCache: [String: NSImage] = [:]
    private var fileQuery: NSMetadataQuery?
    private var recentQuery: NSMetadataQuery?
    private var searchWork: DispatchWorkItem?
    private var lastAppScan = Date.distantPast

    // MARK: Catalog

    func reloadIfStale() {
        if Date().timeIntervalSince(lastAppScan) > 120 { reloadApps() }
        refreshRecentFiles()
    }

    func reloadApps() {
        lastAppScan = Date()
        Task.detached(priority: .userInitiated) {
            let (apps, panes) = Self.scan()
            await MainActor.run {
                StartModel.shared.apps = apps
                StartModel.shared.settingsPanes = panes
            }
        }
    }

    nonisolated private static func scan() -> ([AppEntry], [SettingEntry]) {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let roots = ["/Applications", "/Applications/Utilities", "/System/Applications",
                     "/System/Applications/Utilities", home + "/Applications"]
        var seen = Set<String>()
        var out: [AppEntry] = []
        func add(_ url: URL) {
            guard let b = Bundle(url: url), let info = b.infoDictionary else { return }
            if (info["LSUIElement"] as? Bool) == true || (info["LSBackgroundOnly"] as? Bool) == true { return }
            if (info["LSUIElement"] as? String) == "1" { return }
            let id = b.bundleIdentifier ?? url.path
            guard !seen.contains(id) else { return }
            seen.insert(id)
            let name = fm.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            let added = (try? url.resourceValues(forKeys: [.addedToDirectoryDateKey]).addedToDirectoryDate)
                ?? (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            out.append(AppEntry(id: id, url: url, name: name,
                                category: category(info["LSApplicationCategoryType"] as? String, path: url.path),
                                added: added))
        }
        for root in roots {
            guard let items = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for item in items {
                let path = root + "/" + item
                if item.hasSuffix(".app") { add(URL(fileURLWithPath: path)) }
                else if root == "/Applications", !item.hasPrefix("."), item != "Utilities",
                        let sub = try? fm.contentsOfDirectory(atPath: path) {
                    for s in sub where s.hasSuffix(".app") { add(URL(fileURLWithPath: path + "/" + s)) }
                }
            }
        }
        out.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        var panes: [SettingEntry] = []
        let extDir = "/System/Library/ExtensionKit/Extensions"
        for e in (try? fm.contentsOfDirectory(atPath: extDir)) ?? [] where e.hasSuffix(".appex") {
            guard let info = NSDictionary(contentsOfFile: "\(extDir)/\(e)/Contents/Info.plist") as? [String: Any],
                  info["SettingsExtensionAttributes"] != nil,
                  let id = info["CFBundleIdentifier"] as? String,
                  let name = info["CFBundleName"] as? String, !name.contains("Intents") else { continue }
            panes.append(SettingEntry(id: id, name: name))
        }
        return (out, panes)
    }

    /// Windows 11 25H2 "All" category view groups.
    nonisolated static func category(_ type: String?, path: String) -> String {
        let t = (type ?? "").replacingOccurrences(of: "public.app-category.", with: "")
        switch t {
        case "productivity", "business", "finance": return "Productivity"
        case "graphics-design", "photography", "video", "music": return "Creativity"
        case "social-networking": return "Social"
        case "entertainment", "sports": return "Entertainment"
        case _ where t.hasSuffix("games") || t == "games": return "Games"
        case "developer-tools": return "Developer tools"
        case "utilities": return "Utilities & tools"
        case "education", "reference": return "Education"
        case "healthcare-fitness", "medical", "lifestyle": return "Health & lifestyle"
        case "news", "weather", "travel", "books", "magazines-newspapers", "navigation": return "Information & reading"
        default:
            if path.contains("/Utilities/") { return "Utilities & tools" }
            return "Other"
        }
    }

    static let categoryOrder = ["Productivity", "Creativity", "Social", "Entertainment", "Games", "Information & reading",
                                "Education", "Health & lifestyle", "Utilities & tools", "Developer tools", "Other"]

    var categories: [(name: String, apps: [AppEntry])] {
        let groups = Dictionary(grouping: apps, by: \.category)
        return Self.categoryOrder.compactMap { name in groups[name].map { (name, $0) } }
    }

    func app(_ bundleID: String) -> AppEntry? { apps.first { $0.id == bundleID } }

    var recentlyAdded: [AppEntry] {
        let cutoff = Date().addingTimeInterval(-14 * 86400)
        return apps.filter { $0.added > cutoff }.sorted { $0.added > $1.added }.prefix(3).map { $0 }
    }

    func icon(_ a: AppEntry) -> NSImage {
        if let i = iconCache[a.id] { return i }
        let i = NSWorkspace.shared.icon(forFile: a.url.path)
        iconCache[a.id] = i
        return i
    }
    func icon(file: URL) -> NSImage { NSWorkspace.shared.icon(forFile: file.path) }

    // MARK: Recommended files (Spotlight)

    func refreshRecentFiles() {
        guard AppSettings.shared.startShowRecommendedFiles, recentQuery == nil else { return }
        let q = NSMetadataQuery()
        q.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "kMDItemLastUsedDate >= %@", Date().addingTimeInterval(-30 * 86400) as NSDate),
            NSPredicate(format: "kMDItemContentTypeTree == 'public.content'"),
            NSCompoundPredicate(notPredicateWithSubpredicate: NSPredicate(format: "kMDItemContentTypeTree == 'com.apple.application'")),
        ])
        q.sortDescriptors = [NSSortDescriptor(key: "kMDItemLastUsedDate", ascending: false)]
        q.searchScopes = [NSMetadataQueryUserHomeScope]
        NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: q, queue: .main) { _ in
            MainActor.assumeIsolated {
                q.stop()
                let m = StartModel.shared
                m.recentFiles = Self.files(from: q, limit: 6, dateKey: "kMDItemLastUsedDate")
                m.recentQuery = nil
            }
        }
        recentQuery = q
        q.start()
    }

    private static func files(from q: NSMetadataQuery, limit: Int, dateKey: String) -> [FileEntry] {
        (0..<min(q.resultCount, limit * 2)).compactMap { i -> FileEntry? in
            guard let r = q.result(at: i) as? NSMetadataItem,
                  let path = r.value(forAttribute: NSMetadataItemPathKey) as? String,
                  !path.contains("/Library/"), !path.contains("/.") else { return nil }
            let date = r.value(forAttribute: dateKey) as? Date ?? Date()
            return FileEntry(url: URL(fileURLWithPath: path),
                             name: r.value(forAttribute: NSMetadataItemDisplayNameKey) as? String ?? (path as NSString).lastPathComponent,
                             date: date)
        }
        .prefix(limit).map { $0 }
    }

    // MARK: Search

    private func scheduleSearch() {
        searchWork?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { results = []; selection = nil; fileQuery?.stop(); return }
        // Apps and settings are instant; files follow from Spotlight.
        results = localResults(q)
        selection = results.first
        let work = DispatchWorkItem { MainActor.assumeIsolated { StartModel.shared.searchFiles(q) } }
        searchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func localResults(_ q: String) -> [Result] {
        let lq = q.lowercased()
        func score(_ name: String) -> Int? {
            let n = name.lowercased()
            if n == lq { return 0 }
            if n.hasPrefix(lq) { return 1 }
            if n.split(separator: " ").contains(where: { $0.hasPrefix(lq) }) { return 2 }
            if n.contains(lq) { return 3 }
            return nil
        }
        let a = apps.compactMap { e in score(e.name).map { ($0, Result.app(e)) } }.sorted { $0.0 < $1.0 }.prefix(8)
        let s = settingsPanes.compactMap { e in score(e.name).map { ($0, Result.setting(e)) } }.sorted { $0.0 < $1.0 }.prefix(5)
        return a.map(\.1) + s.map(\.1)
    }

    private func searchFiles(_ q: String) {
        fileQuery?.stop()
        let mq = NSMetadataQuery()
        let escaped = q.replacingOccurrences(of: "\"", with: "")
        mq.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "kMDItemDisplayName LIKE[cd] %@", "*\(escaped)*"),
            NSCompoundPredicate(notPredicateWithSubpredicate: NSPredicate(format: "kMDItemContentTypeTree == 'com.apple.application'")),
        ])
        mq.sortDescriptors = [NSSortDescriptor(key: "kMDItemLastUsedDate", ascending: false)]
        mq.searchScopes = [NSMetadataQueryUserHomeScope]
        NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: mq, queue: .main) { _ in
            MainActor.assumeIsolated {
                mq.stop()
                let m = StartModel.shared
                guard m.query.trimmingCharacters(in: .whitespaces) == q else { return }
                let files = Self.files(from: mq, limit: 10, dateKey: "kMDItemLastUsedDate").map(Result.file)
                m.results = m.localResults(q) + files
                if m.selection == nil { m.selection = m.results.first }
            }
        }
        fileQuery = mq
        mq.start()
    }

    // MARK: Actions

    func open(_ r: Result) {
        StartController.shared.hide()
        switch r {
        case .app(let a): launch(a)
        case .file(let f): NSWorkspace.shared.open(f.url)
        case .setting(let s): SystemActions.openSettings(s.id)
        }
    }

    func launch(_ a: AppEntry) {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: a.url, configuration: cfg)
    }

    func reveal(_ url: URL) {
        StartController.shared.hide()
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        let i = results.firstIndex(where: { $0 == selection }) ?? -1
        selection = results[min(max(i + delta, 0), results.count - 1)]
    }
}
