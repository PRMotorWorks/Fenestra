import AppKit

/// Flyout animation smoothness test (only with `captionDebug`): distributed notification "local.fenestra.debug.flyout"
/// with object "switch" opens Quick Settings, then switches to the calendar and back the way a tray click does
/// (outside-click close, then the button's toggle), sampling the open panel's frame while it animates.
/// Results: `grep flyouttest ~/Library/Logs/Fenestra-app.log`.
@MainActor
enum FlyoutDiagnostics {
    static func install() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("local.fenestra.debug.flyout"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { run() }
        }
    }

    private static var samples: [(t: CFTimeInterval, y: CGFloat)] = []
    private static var timer: Timer?

    private static func anchors() -> (quick: NSRect, calendar: NSRect) {
        let f = NSScreen.screens[0].frame
        return (NSRect(x: f.maxX - 200, y: f.minY + 4, width: 90, height: 40),
                NSRect(x: f.maxX - 110, y: f.minY + 4, width: 80, height: 40))
    }

    private static func run() {
        let a = anchors()
        let fm = FlyoutManager.shared
        fm.close(animated: false)
        let steps: [(String, () -> Void)] = [
            ("open quick", { fm.toggle(id: "quick", anchor: a.quick) { QuickSettingsView() } }),
            ("quick -> calendar", { fm.close(); fm.toggle(id: "calendar", anchor: a.calendar) { CalendarFlyout() } }),
            ("calendar -> quick", { fm.close(); fm.toggle(id: "quick", anchor: a.quick) { QuickSettingsView() } }),
            ("quick -> calendar again", { fm.close(); fm.toggle(id: "calendar", anchor: a.calendar) { CalendarFlyout() } }),
            ("close", { fm.close() }),
        ]
        for (i, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.8) {
                MainActor.assumeIsolated { measure(step.0, step.1) }
            }
        }
    }

    private static func measure(_ name: String, _ action: () -> Void) {
        let start = CACurrentMediaTime()
        action()
        let callMs = (CACurrentMediaTime() - start) * 1000
        samples = []
        timer?.invalidate()
        let t = Timer(timeInterval: 0.002, repeats: true) { _ in
            MainActor.assumeIsolated {
                if let f = FlyoutManager.shared.panelFrame { samples.append((CACurrentMediaTime(), f.minY)) }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            MainActor.assumeIsolated {
                timer?.invalidate(); timer = nil
                report(name, start: start, callMs: callMs)
            }
        }
    }

    private static func report(_ name: String, start: CFTimeInterval, callMs: Double) {
        // Distinct positions and the gaps between them while the panel moved.
        var changes: [CFTimeInterval] = []
        var last: CGFloat?
        for s in samples where s.y != last { changes.append(s.t); last = s.y }
        let gaps = zip(changes.dropFirst(), changes).map { ($0 - $1) * 1000 }
        let first = changes.first.map { String(format: "%.0f", ($0 - start) * 1000) } ?? "-"
        let maxGap = gaps.max().map { String(format: "%.0f", $0) } ?? "-"
        let median = gaps.sorted().dropFirst(gaps.count / 2).first.map { String(format: "%.1f", $0) } ?? "-"
        let moveMs = changes.count > 1 ? String(format: "%.0f", (changes.last! - changes.first!) * 1000) : "-"
        let base = changes.first ?? start
        var tl: [String] = []
        last = nil
        for s in samples where s.y != last { tl.append(String(format: "%.0f@%.0f", s.y, (s.t - base) * 1000)); last = s.y }
        Log.write("flyouttest: \(name) timeline y@ms: " + tl.joined(separator: " "))
        Log.write("flyouttest: \(name): call \(String(format: "%.0f", callMs)) ms (show \(String(format: "%.0f", FlyoutManager.shared.lastShowMs)) ms), "
                  + "first move +\(first) ms, \(changes.count) positions over \(moveMs) ms, "
                  + "median step \(median) ms, max step \(maxGap) ms, samples \(samples.count)")
    }
}
