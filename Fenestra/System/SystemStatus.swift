import AppKit
import Carbon

/// Live state for the tray icons. Everything is notification-driven, nothing polls:
/// Wi-Fi (CoreWLAN events), volume (CoreAudio listeners), battery (IOKit run-loop source),
/// keyboard layout (Carbon TIS distributed notifications), clock (one timer per minute).
@MainActor
final class SystemStatus: ObservableObject {
    static let shared = SystemStatus()

    @Published var wifiOn = false
    @Published var wifiConnected = false
    @Published var wifiBars = 0
    @Published var ssid: String?
    @Published var volume: Float = 1
    @Published var muted = false
    @Published var battery = Battery.State()
    @Published var now = Date()
    @Published var inputSources: [InputSource] = []
    @Published var currentInputID: String = ""

    private var clockTimer: Timer?

    struct InputSource: Identifiable, Equatable {
        let id: String
        let name: String
        let language: String     // e.g. "ENG"
        let layout: String       // e.g. "US"
    }

    func start() {
        WiFi.shared.onChange = { [weak self] in self?.refreshWiFi() }
        WiFi.shared.startMonitoring()
        refreshWiFi()

        Audio.observe { DispatchQueue.main.async { SystemStatus.shared.refreshAudio() } }
        refreshAudio()

        Battery.observe { SystemStatus.shared.battery = Battery.read() }
        battery = Battery.read()

        let dnc = DistributedNotificationCenter.default()
        for name in [kTISNotifySelectedKeyboardInputSourceChanged!, kTISNotifyEnabledKeyboardInputSourcesChanged!] {
            dnc.addObserver(forName: Notification.Name(name as String), object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { SystemStatus.shared.refreshInputSources() }
            }
        }
        refreshInputSources()

        scheduleClock()
        NotificationCenter.default.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SystemStatus.shared.scheduleClock() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let s = SystemStatus.shared
                s.scheduleClock(); s.refreshWiFi(); s.battery = Battery.read()
            }
        }
    }

    func refreshWiFi() {
        let w = WiFi.shared
        wifiOn = w.isOn
        ssid = w.ssid
        wifiConnected = w.isOn && w.rssi > -100 && w.rssi != 0
        let bars = w.bars
        if bars != wifiBars { wifiBars = bars }
    }

    func refreshAudio() {
        volume = Audio.volume()
        muted = Audio.isMuted()
    }

    /// Wakes once per minute, exactly on the minute (once per second with "Show seconds").
    func scheduleClock() {
        now = Date()
        clockTimer?.invalidate()
        let seconds = AppSettings.shared.showSeconds
        let next = seconds ? now.addingTimeInterval(1 - now.timeIntervalSince1970.truncatingRemainder(dividingBy: 1))
            : (Calendar.current.nextDate(after: now, matching: DateComponents(second: 0),
                                        matchingPolicy: .nextTime) ?? now.addingTimeInterval(60))
        let t = Timer(fire: next, interval: seconds ? 1 : 60, repeats: true) { _ in
            MainActor.assumeIsolated { SystemStatus.shared.now = Date() }
        }
        t.tolerance = seconds ? 0.05 : 0.5
        RunLoop.main.add(t, forMode: .common)
        clockTimer = t
    }

    // MARK: Keyboard layouts (Carbon Text Input Sources, public)

    func refreshInputSources() {
        let filter = [kTISPropertyInputSourceCategory! as String: kTISCategoryKeyboardInputSource! as String,
                      kTISPropertyInputSourceIsSelectCapable! as String: true] as CFDictionary
        let list = (TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource]) ?? []
        inputSources = list.compactMap { src in
            guard let id = Self.prop(src, kTISPropertyInputSourceID) as String?,
                  let name = Self.prop(src, kTISPropertyLocalizedName) as String? else { return nil }
            let langs = Self.propArray(src, kTISPropertyInputSourceLanguages)
            let lang = langs.first.map { Locale.LanguageCode($0).identifier(.alpha3)?.uppercased() ?? $0.uppercased() } ?? "?"
            let last = id.split(separator: ".").last.map(String.init) ?? name
            let layout = last.count <= 3 ? last.uppercased() : String(last.prefix(3)).uppercased()
            return InputSource(id: id, name: name, language: lang, layout: layout)
        }
        if let cur = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
           let id = Self.prop(cur, kTISPropertyInputSourceID) as String? {
            currentInputID = id
        }
    }

    var currentInput: InputSource? { inputSources.first { $0.id == currentInputID } }

    func selectInput(_ id: String) {
        let filter = [kTISPropertyInputSourceID! as String: id] as CFDictionary
        if let src = (TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource])?.first {
            TISSelectInputSource(src)
        }
    }

    private static func prop(_ src: TISInputSource, _ key: CFString) -> String? {
        guard let p = TISGetInputSourceProperty(src, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
    }
    private static func propArray(_ src: TISInputSource, _ key: CFString) -> [String] {
        guard let p = TISGetInputSourceProperty(src, key) else { return [] }
        return (Unmanaged<CFArray>.fromOpaque(p).takeUnretainedValue() as? [String]) ?? []
    }
}
