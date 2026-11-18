import AppKit
import CoreWLAN

/// State behind the Quick Settings flyout. Every toggle drives the real macOS setting;
/// when one can't, the flyout says why and offers the matching System Settings pane.
@MainActor
final class QuickSettingsModel: ObservableObject {
    enum Page { case main, wifi, bluetooth, output, keyboard, addTiles, focusSetup, batterySaverSetup }

    @Published var page: Page = .main
    @Published var wifiOn = WiFi.shared.isOn
    @Published var bluetoothOn = Bluetooth.isOn
    @Published var airplane = UserDefaults.standard.bool(forKey: "airplaneMode")
    @Published var lowPower = LowPower.isOn
    @Published var nightShift = NightShift.shared.isOn
    @Published var focus = FocusControl.isOn
    @Published var airdrop = AirDrop.mode
    @Published var darkMode = Appearance.isDark
    @Published var editing = false {           // Edit quick settings: unpin, add, drag to reorder
        didSet { if editing { wifiListOpen = false } }
    }
    @Published var wifiListOpen = false        // the Wi-Fi tile's chevron: network list open under its row
    @Published var brightness = Brightness.shared.value
    @Published var message: String?
    @Published var focusSetupStatus: String?   // progress line on the Set up Focus page
    private var focusSetupRunning = false

    // Sub-pages
    @Published var networks: [CWNetwork] = []
    @Published var scanning = false
    @Published var joiningSSID: String?        // asking for the security key
    @Published var expandedSSID: String?       // the clicked network, opened to show Connect / Disconnect
    @Published var connectingSSID: String?
    @Published var password = ""
    @Published var btDevices: [Bluetooth.Device] = []
    @Published var btLoading = false
    @Published var expandedBT: String?         // the clicked device, opened to show Connect / Disconnect
    @Published var connectingBT: String?
    @Published var btMessage: String?          // shown under the opened device when connecting failed
    @Published var outputs: [Audio.Device] = []
    @Published var currentOutput = Audio.defaultOutput

    private var observers: [NSObjectProtocol] = []

    init() {
        let nc = NotificationCenter.default
        observers = [
            nc.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lowPower = LowPower.isOn }
            },
            nc.addObserver(forName: AirDrop.changed, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.airdrop = AirDrop.mode }
            },
        ]
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func refresh() {
        wifiOn = WiFi.shared.isOn
        bluetoothOn = Bluetooth.isOn
        lowPower = LowPower.isOn
        nightShift = NightShift.shared.isOn
        focus = FocusControl.isOn
        airdrop = AirDrop.mode
        darkMode = Appearance.isDark
        brightness = Brightness.shared.value
        if airplane && (wifiOn || bluetoothOn) { setAirplaneFlag(false) }
    }

    // MARK: Toggles

    func toggleWiFi() {
        do { try WiFi.shared.setPower(!wifiOn); wifiOn.toggle() }
        catch { message = "Couldn't change Wi-Fi: \(error.localizedDescription)" }
        SystemStatus.shared.refreshWiFi()
    }

    func toggleBluetooth() {
        let target = !bluetoothOn
        Task {
            if await Bluetooth.setPower(target) {
                bluetoothOn = target
            } else {
                message = "macOS didn't allow Fenestra to change Bluetooth. Allow Bluetooth in Fenestra's permissions, or use Bluetooth settings."
                Permissions.shared.requestBluetooth()
            }
        }
    }

    /// macOS has no airplane mode: this turns Wi-Fi and Bluetooth off, and restores them afterwards.
    func toggleAirplane() {
        let d = UserDefaults.standard
        if !airplane {
            d.set(wifiOn, forKey: "airplaneWiFiWas")
            d.set(bluetoothOn, forKey: "airplaneBTWas")
            setAirplaneFlag(true)
            try? WiFi.shared.setPower(false)
            wifiOn = false
            Task {
                _ = await Bluetooth.setPower(false)
                bluetoothOn = Bluetooth.isOn
                SystemStatus.shared.refreshWiFi()
            }
        } else {
            let w = d.object(forKey: "airplaneWiFiWas") as? Bool ?? true
            let b = d.object(forKey: "airplaneBTWas") as? Bool ?? true
            setAirplaneFlag(false)
            if w { try? WiFi.shared.setPower(true) }
            Task { if b { _ = await Bluetooth.setPower(true) }; refresh() }
        }
        SystemStatus.shared.refreshWiFi()
    }

    private func setAirplaneFlag(_ on: Bool) {
        airplane = on
        UserDefaults.standard.set(on, forKey: "airplaneMode")
    }

    func toggleLowPower() {
        if !LowPower.permissionInstalled { page = .batterySaverSetup; return }
        let target = !lowPower
        Task.detached {
            let ok = LowPower.set(target)
            await MainActor.run {
                let m = self
                if ok { m.lowPower = target } else { m.message = "Couldn't change Low Power Mode." }
            }
        }
    }

    func installLowPowerPermission() {
        if LowPower.installPermission() {
            page = .main
            toggleLowPower()
        } else {
            message = "Permission wasn't installed. You can use Battery settings instead."
        }
    }

    func toggleNightShift() {
        guard NightShift.shared.isAvailable else {
            SystemActions.openSettings("com.apple.Displays-Settings.extension")
            return
        }
        NightShift.shared.set(!nightShift)
        nightShift = NightShift.shared.isOn
    }

    func toggleFocus() {
        let target = !focus
        Task {
            guard await FocusControl.shortcutsInstalled() else { page = .focusSetup; return }
            if await FocusControl.set(target) { focus = target; return }
            Log.write("focus: \(target ? FocusControl.onName : FocusControl.offName) failed")
            focusSetupStatus = "The shortcut couldn't switch Do Not Disturb. In Shortcuts, delete \(FocusControl.onName) "
                + "and \(FocusControl.offName), then click Add shortcuts to add new ones."
            page = .focusSetup
        }
    }

    /// Set up Focus: Fenestra builds the two shortcuts and opens each in Shortcuts, which asks you to add it.
    /// Waits (checking every 1.5 s, only during setup, at most 2 minutes each) until it is there, then does
    /// what the click on the tile asked for.
    func addFocusShortcuts() {
        guard !focusSetupRunning else { return }
        focusSetupRunning = true
        Task {
            defer { focusSetupRunning = false }
            for name in [FocusControl.onName, FocusControl.offName] {
                if await FocusControl.installedNames().contains(name) { continue }
                guard let file = await Task.detached(operation: { FocusControl.build(name) }).value else {
                    focusSetupStatus = "Couldn't create \(name)."
                    return
                }
                focusSetupStatus = "In Shortcuts, click Add Shortcut for \(name)."
                NSWorkspace.shared.open(file)
                var added = false
                for _ in 0..<80 {
                    try? await Task.sleep(for: .milliseconds(1500))
                    if await FocusControl.installedNames().contains(name) { added = true; break }
                }
                guard added else {
                    focusSetupStatus = "\(name) wasn't added. Click Add shortcuts to try again."
                    return
                }
            }
            Log.write("focus: shortcuts added")
            focusSetupStatus = nil
            page = .main
            toggleFocus()
        }
    }

    /// Nearby sharing = AirDrop: each click goes Off, Contacts Only, Everyone (10 minutes), Off.
    /// sharingd restarts, so it runs off the main thread.
    func toggleAirDrop() {
        let target = AirDrop.next(after: airdrop)
        airdrop = target
        Task.detached { AirDrop.set(target) }
    }

    /// Cast = Screen Mirroring: Control Center's own panel (its menu bar item, pressed through Accessibility).
    /// If that item is hidden in System Settings > Menu Bar, Displays settings instead.
    func cast() {
        FlyoutManager.shared.close(animated: false)
        if let e = MenuExtras.shared.items.first(where: { $0.id.hasSuffix("screen-mirroring") }) {
            // Pressed 0.25 s after the flyout is gone: pressed at once (10:06 to 10:24 on 2026-11-15) Control Center
            // opened nothing; with the pause the menu bar slides in and the panel opens.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { MenuExtras.shared.open(e, anchor: .zero) }
        } else {
            SystemActions.openSettings("com.apple.Displays-Settings.extension")
        }
    }

    /// Accessibility: macOS's Accessibility Shortcuts panel (Option+Command+F5), the Mac's quick toggles for Zoom,
    /// VoiceOver, Invert colors, Increase contrast and the rest (Windows: the Accessibility flyout).
    func accessibility() {
        FlyoutManager.shared.close(animated: false)
        Log.write("quicksettings: accessibility panel (Option+Command+F5)")
        SystemActions.postKey(96, flags: [.maskCommand, .maskAlternate, .maskSecondaryFn])   // F keys carry fn
    }

    /// Live captions: macOS has no public switch, so this opens Accessibility > Live Captions, whose first row is it.
    func liveCaptions() {
        FlyoutManager.shared.close()
        SystemActions.openSettings("com.apple.Accessibility-Settings.extension?LiveCaptions")
    }

    // MARK: Control Center tiles

    func toggleDarkMode() {
        darkMode.toggle()
        Appearance.set(dark: darkMode)
    }

    /// Apps behind Control Center controls: Voice Memos, Calculator, Clock (alarms, timers, stopwatch),
    /// the screen saver, and the Screenshot toolbar (custom capture and screen recording).
    func open(_ path: String) {
        FlyoutManager.shared.close()
        SystemActions.openApp(path)
    }

    /// Capture screen (Shift+Command+3) or selection (Shift+Command+4): macOS's own shortcuts, so the picture goes
    /// where your Screenshot settings say. Sent once the flyout has faded so it isn't in the shot.
    func capture(selection: Bool) {
        FlyoutManager.shared.close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            SystemActions.postKey(selection ? 21 : 20, flags: [.maskCommand, .maskShift])
        }
    }

    /// Quick Note: macOS's Globe+Q shortcut (Notes opens a small note window).
    func quickNote() {
        FlyoutManager.shared.close()
        SystemActions.postKey(12, flags: [.maskSecondaryFn])
    }

    // MARK: Edit quick settings

    func unpin(_ k: QSTileKind) { AppSettings.shared.setTile(k, false) }
    func pin(_ k: QSTileKind) { AppSettings.shared.setTile(k, true); page = .main }

    /// Drag reorder: the dragged tile takes the place of the one it is over.
    func move(_ k: QSTileKind, to target: QSTileKind) {
        var list = AppSettings.shared.quickTiles
        guard k != target, let from = list.firstIndex(of: k.rawValue), let to = list.firstIndex(of: target.rawValue) else { return }
        list.remove(at: from)
        list.insert(k.rawValue, at: to)
        AppSettings.shared.quickTiles = list
    }

    func setBrightness(_ v: Float) {
        brightness = v
        Brightness.shared.set(v)
    }

    // MARK: Wi-Fi page

    func openWiFiList() {
        if wifiOn { networks = WiFi.shared.cachedNetworks() }   // the list is there at once, then refreshed
        expandedSSID = SystemStatus.shared.ssid
        joiningSSID = nil
        page = .wifi
        scan()
    }

    /// The Wi-Fi tile's chevron: opens the network list in place under the tile's row, or closes it again.
    func toggleWiFiList() {
        if wifiListOpen { wifiListOpen = false; return }
        if wifiOn { networks = WiFi.shared.cachedNetworks() }
        expandedSSID = SystemStatus.shared.ssid
        joiningSSID = nil
        wifiListOpen = true
        scan()
    }

    func scan() {
        guard wifiOn else { networks = []; return }
        scanning = true
        let started = DispatchTime.now()
        Task {
            let nets = await WiFi.shared.scan()
            let ms = (DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
            Log.write("quicksettings: wifi \(networks.count) cached, \(nets.count) scanned in \(ms) ms")
            if !nets.isEmpty || networks.isEmpty { networks = nets }
            let hotspots = nets.filter(\.isHotspot)
            if !hotspots.isEmpty {
                // Count and flags only: network names stay out of the log (people paste it into public bug reports).
                Log.write("quicksettings: \(hotspots.count) hotspot(s), apple-ie=\(hotspots.map(\.hasAppleIE))")
            }
            scanning = false
        }
    }

    /// Click on a network: it opens to show Connect (or Disconnect when it's the current one), as on Windows.
    func choose(_ n: CWNetwork) {
        guard expandedSSID != n.ssid else { return }
        expandedSSID = n.ssid
        joiningSSID = nil
        password = ""
        message = nil
    }

    /// Connect: an open network joins at once, a known secured one with its saved password (keychain), a new
    /// secured one asks for its key.
    func connect(_ n: CWNetwork) {
        guard let ssid = n.ssid, connectingSSID == nil else { return }    // one join at a time
        let known = WiFi.shared.knownSSIDs().contains(ssid)
        if n.isSecured && !known {
            joiningSSID = ssid
            FlyoutManager.shared.makeKey()
            return
        }
        connectingSSID = ssid
        Task {
            let ok: Bool
            if n.isSecured {
                let result = await Task.detached { WiFi.shared.joinSaved(n) }.value
                Log.write("wifi: saved-password join: \(result)")
                ok = result.hasPrefix("joined")
            } else {
                ok = (try? await WiFi.shared.connect(n, password: nil)) != nil
            }
            connectingSSID = nil
            SystemStatus.shared.refreshWiFi()
            if !ok {
                if n.isSecured { joiningSSID = ssid; FlyoutManager.shared.makeKey() }
                else { message = "Couldn't connect to \(ssid)." }
            }
        }
    }

    func join(_ n: CWNetwork, password: String?) {
        connectingSSID = n.ssid
        Task {
            do {
                try await WiFi.shared.connect(n, password: password)
                joiningSSID = nil
                message = nil
            } catch {
                message = "Couldn't connect to \(n.ssid ?? "network"). Check the security key."
            }
            connectingSSID = nil
            SystemStatus.shared.refreshWiFi()
        }
    }

    // MARK: Bluetooth page

    /// Last list read, so the page opens at its full size right away.
    private static var lastDevices: [Bluetooth.Device] = []

    func openBluetoothList() {
        btDevices = Self.lastDevices
        expandedBT = nil
        btMessage = nil
        page = .bluetooth
        loadDevices()
    }

    /// Click on a device: it opens to show Connect or Disconnect, as on Windows (nothing happens by accident).
    func chooseDevice(_ d: Bluetooth.Device) {
        guard expandedBT != d.id else { return }
        expandedBT = d.id
        btMessage = nil
    }

    func connectDevice(_ d: Bluetooth.Device) {
        guard connectingBT == nil else { return }
        connectingBT = d.id
        btMessage = nil
        Task {
            let r = await Bluetooth.connect(d)
            Log.write("bluetooth: connect -> \(String(format: "0x%08x", r))")
            connectingBT = nil
            if r != kIOReturnSuccess { btMessage = "Couldn't connect. Make sure \(d.name) is on and nearby." }
            loadDevices()
        }
    }

    func disconnectDevice(_ d: Bluetooth.Device) {
        let r = Bluetooth.disconnect(d)
        Log.write("bluetooth: disconnect -> \(String(format: "0x%08x", r))")
        btMessage = r == kIOReturnSuccess ? nil : "Couldn't disconnect \(d.name)."
        Task {
            try? await Task.sleep(for: .milliseconds(400))     // the link takes a moment to go down
            loadDevices()
        }
    }

    /// IOBluetooth asks bluetoothd for every device (name, connection): off the main thread.
    private func loadDevices() {
        let started = DispatchTime.now()
        btLoading = true
        Task {
            let devs = await Task.detached { Bluetooth.pairedDevices() }.value
            let ms = (DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
            Log.write("quicksettings: bluetooth \(devs.count) device(s) in \(ms) ms")
            Self.lastDevices = devs
            btDevices = devs
            btLoading = false
        }
    }

    // MARK: Output page

    func openOutputs() {
        outputs = Audio.outputDevices()
        currentOutput = Audio.defaultOutput
        page = .output
    }

    func selectOutput(_ d: Audio.Device) {
        Audio.setDefaultOutput(d.id)
        currentOutput = d.id
        SystemStatus.shared.refreshAudio()
    }
}
