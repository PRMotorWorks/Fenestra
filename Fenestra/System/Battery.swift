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
    }

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
            if let t = d[kIOPSTimeToEmptyKey] as? Int, t > 0 { s.minutesToEmpty = t }
            return s
        }
        return State()
    }

    private static var source: CFRunLoopSource?
    private static var handler: (() -> Void)?

    static func observe(_ h: @escaping () -> Void) {
        handler = h
        let cb: IOPowerSourceCallbackType = { _ in DispatchQueue.main.async { Battery.handler?() } }
        if let src = IOPSNotificationCreateRunLoopSource(cb, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
            source = src
        }
    }

    /// SF Symbol for the tray, Windows-like battery glyph.
    static func symbol(_ s: State) -> String {
        if s.charging || (s.onAC && s.percent >= 99) { return "battery.100percent.bolt" }
        switch s.percent {
        case 88...: return "battery.100percent"
        case 63..<88: return "battery.75percent"
        case 38..<63: return "battery.50percent"
        case 13..<38: return "battery.25percent"
        default: return "battery.0percent"
        }
    }
}
