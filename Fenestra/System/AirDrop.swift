import Foundation

/// AirDrop discoverability (Windows: Nearby sharing). The setting is `com.apple.sharingd DiscoverableMode`
/// ("Off", "Contacts Only", "Everyone"); sharingd reads it when it starts, so it is restarted after a change
/// (launchd brings it straight back). The tile cycles Off, Contacts Only, Everyone; Everyone falls back to
/// Contacts Only after 10 minutes, as macOS's own "Everyone for 10 Minutes" does.
enum AirDrop {
    enum Mode: String { case off = "Off", contacts = "Contacts Only", everyone = "Everyone" }

    static let everyoneMinutes = 10
    private static let domain = "com.apple.sharingd" as CFString
    private static let key = "DiscoverableMode" as CFString
    private static let untilKey = "airdropEveryoneUntil"       // Fenestra's own defaults: survives a restart
    nonisolated(unsafe) private static var timer: DispatchSourceTimer?

    static var mode: Mode {
        CFPreferencesAppSynchronize(domain)
        return Mode(rawValue: CFPreferencesCopyAppValue(key, domain) as? String ?? "") ?? .off
    }

    static func next(after m: Mode) -> Mode {
        switch m {
        case .off: .contacts
        case .contacts: .everyone
        case .everyone: .off
        }
    }

    static func set(_ m: Mode) {
        CFPreferencesSetAppValue(key, m.rawValue as CFString, domain)
        CFPreferencesAppSynchronize(domain)
        Shell.run("/usr/bin/killall", ["sharingd"])
        if m == .everyone {
            let until = Date().addingTimeInterval(TimeInterval(everyoneMinutes * 60))
            UserDefaults.standard.set(until, forKey: untilKey)
            schedule(until)
        } else {
            UserDefaults.standard.removeObject(forKey: untilKey)
            timer?.cancel(); timer = nil
        }
        Log.write("quicksettings: AirDrop \(m.rawValue)")
    }

    /// At launch: an Everyone period that was running when Fenestra quit still ends on time.
    static func resumeExpiry() {
        guard let until = UserDefaults.standard.object(forKey: untilKey) as? Date else { return }
        schedule(until)
    }

    /// One timer, no polling. Only switches back if AirDrop is still Everyone (you may have changed it since).
    private static func schedule(_ until: Date) {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + max(0, until.timeIntervalSinceNow), leeway: .seconds(5))
        t.setEventHandler {
            timer = nil
            UserDefaults.standard.removeObject(forKey: untilKey)
            guard mode == .everyone else { return }
            set(.contacts)
            DispatchQueue.main.async { NotificationCenter.default.post(name: AirDrop.changed, object: nil) }
        }
        timer = t
        t.resume()
    }

    static let changed = Notification.Name("FenestraAirDropChanged")
}
