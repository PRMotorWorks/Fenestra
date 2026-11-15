import Foundation
import IOKit.ps

/// Battery state from IOKit power sources (public).
enum Battery {
    struct State: Equatable {
        var present = false
        var percent = 100
        var charging = false
        var onAC = true
        var minutesToEmpty: Int? = nil
        var minutesToFull: Int? = nil
        var charged = false        // macOS reports the battery as full
        var saver = false          // Low Power Mode (Fenestra's Battery saver tile)

        /// On the adapter but not taking charge: the charge limit (80% with Optimized Charging) or "Charging On Hold".
        var pluggedNotCharging: Bool { onAC && !charging }
    }

    /// Read once at launch: a Mac without an internal battery (Mac mini, iMac, Mac Studio, Mac Pro) never gains one,
    /// so the battery icon, its tooltip, the footer line, the setting and the IOKit listener all stay off there.
    static let isPresent: Bool = read().present

    static func read() -> State {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return State() }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            var s = State(present: true)
            let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 100
            let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            s.percent = max > 0 ? Int((Double(cur) / Double(max) * 100).rounded()) : cur
            s.charging = d[kIOPSIsChargingKey] as? Bool ?? false
            s.onAC = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            s.charged = d[kIOPSIsChargedKey] as? Bool ?? false
            if let t = d[kIOPSTimeToEmptyKey] as? Int, t > 0 { s.minutesToEmpty = t }
            if let t = d[kIOPSTimeToFullChargeKey] as? Int, t > 0 { s.minutesToFull = t }
            s.saver = ProcessInfo.processInfo.isLowPowerModeEnabled
            return s
        }
        return State()
    }

    private static var source: CFRunLoopSource?
    private static var handler: (() -> Void)?

    static func observe(_ h: @escaping () -> Void) {
        guard isPresent else { return }
        handler = h
        let cb: IOPowerSourceCallbackType = { _ in DispatchQueue.main.async { Battery.handler?() } }
        if let src = IOPSNotificationCreateRunLoopSource(cb, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
            source = src
        }
    }

    /// SF Symbol for the battery level. Charging and plugged in are drawn as a badge on it (`badge`), because
    /// SF Symbols only has a bolt version of the full battery.
    static func symbol(_ s: State) -> String {
        switch s.percent {
        case 88...: return "battery.100percent"
        case 63..<88: return "battery.75percent"
        case 38..<63: return "battery.50percent"
        case 13..<38: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    /// Bolt while charging, a leaf while battery saver is on (Windows 11's energy saver mark), plug while on the
    /// adapter without charging (as macOS's own battery menu), else nothing.
    static func badge(_ s: State) -> String? {
        if s.charging { return "bolt.fill" }
        if s.saver { return "leaf.fill" }
        if s.onAC { return "powerplug.fill" }
        return nil
    }

    static func duration(_ mins: Int) -> String { mins >= 60 ? "\(mins / 60) h \(mins % 60) min" : "\(mins) min" }

    /// What's happening besides the percentage, e.g. "charging", "plugged in, not charging", "3 h 10 min left".
    static func detail(_ s: State) -> String? {
        if s.charging { return s.minutesToFull.map { "charging, \(duration($0)) until full" } ?? "charging" }
        if s.onAC { return s.charged || s.percent >= 99 ? "fully charged" : "plugged in, not charging" }
        return s.minutesToEmpty.map { "\(duration($0)) left" }
    }

    /// Tray tooltip (Windows: "Battery status: 80% available (plugged in)").
    static func tooltip(_ s: State) -> String {
        "Battery: \(s.percent)%" + (detail(s).map { ", \($0)" } ?? "") + (s.saver ? "\nBattery saver is on" : "")
    }
}
