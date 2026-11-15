import AppKit
import ApplicationServices

/// Unread badges ("Show badges on taskbar apps"). Apps set their badge on the Dock; the Dock still runs
/// (hidden), so its items' AXStatusLabel attribute is read through Accessibility every 5 seconds.
@MainActor
final class DockBadges: ObservableObject {
    static let shared = DockBadges()
    @Published private(set) var badges: [String: String] = [:]     // app name -> badge text
    private var timer: Timer?

    func start() {
        timer?.invalidate()
        guard AppSettings.shared.showBadges, AXIsProcessTrusted() else { badges = [:]; return }
        refresh()
        let t = Timer(timeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { DockBadges.shared.refresh() }
        }
        t.tolerance = 1.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func badge(for item: AppItem) -> String? {
        guard AppSettings.shared.showBadges else { return nil }
        return badges[item.name] ?? NSRunningApplication(processIdentifier: item.pids.first ?? 0)
            .flatMap { $0.localizedName }.flatMap { badges[$0] }
    }

    private func refresh() {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return }
        let appEl = AX.app(dock.processIdentifier)
        guard let kids: [AXUIElement] = AX.attr(appEl, kAXChildrenAttribute),
              let list = kids.first(where: { (AX.attr($0, kAXRoleAttribute) as String?) == kAXListRole }),
              let items: [AXUIElement] = AX.attr(list, kAXChildrenAttribute) else { return }
        var out: [String: String] = [:]
        for it in items {
            guard let title: String = AX.attr(it, kAXTitleAttribute),
                  let label: String = AX.attr(it, "AXStatusLabel"), !label.isEmpty else { continue }
            out[title] = label
        }
        if out != badges { badges = out }
    }
}
