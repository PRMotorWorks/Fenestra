import AppKit
import SwiftUI
import AVKit
import CoreWLAN

/// Windows 11 25H2 Quick Settings: tile grid, brightness and volume sliders, battery footer.
struct QuickSettingsView: View {
    @StateObject private var m = QuickSettingsModel()
    @ObservedObject private var s = SystemStatus.shared
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.colorScheme) private var scheme
    @State private var dragging: QSTileKind?

    var body: some View {
        VStack(spacing: 0) {
            switch m.page {
            case .main: mainPage
            case .wifi: WiFiPage(m: m)
            case .bluetooth: BluetoothPage(m: m)
            case .output: OutputPage(m: m)
            case .keyboard: KeyboardPage(m: m)
            case .addTiles: AddTilesPage(m: m)
            case .focusSetup: FocusSetupPage(m: m)
            case .batterySaverSetup: BatterySaverSetupPage(m: m)
            }
            if let msg = m.message {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                    Text(msg).font(Theme.font(12)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { m.message = nil } label: { Image(systemName: "xmark").font(.system(size: 10)) }.buttonStyle(.plain)
                }
                .padding(12)
                .background(Theme.hover(scheme))
            }
            footer
        }
        .frame(width: 360)
        .onAppear { m.refresh() }
        // Built ahead of time (FlyoutManager.prepare): read the current state again when it actually opens.
        .onReceive(NotificationCenter.default.publisher(for: FlyoutManager.didShow)) { n in
            if n.object as? String == QuickSettingsView.flyoutID { m.refresh() }
        }
    }
    static let flyoutID = "quick"

    private var mainPage: some View {
        VStack(spacing: 18) {
            // The Wi-Fi chevron opens the network list right under the Wi-Fi tile's row.
            let tiles = settings.tiles
            let split = m.wifiListOpen ? tiles.firstIndex(of: .wifi).map { min(($0 / 3 + 1) * 3, tiles.count) } : nil
            VStack(spacing: 14) {
                tileGrid(Array(tiles.prefix(split ?? tiles.count)))
                if let split {
                    WiFiList(m: m, maxHeight: 220)
                        .padding(8)
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Theme.border(scheme), lineWidth: 1))
                    if split < tiles.count { tileGrid(Array(tiles[split...])) }
                }
            }
            .onChange(of: m.editing) { dragging = nil }
            VStack(spacing: 14) {
                if Brightness.shared.isAvailable {
                    QSSlider(symbol: "sun.max", value: Binding(get: { m.brightness }, set: { m.setBrightness($0) }))
                }
                HStack(spacing: 4) {
                    QSSlider(symbol: s.muted ? "speaker.slash" : "speaker.wave.2",
                             value: Binding(get: { s.muted ? 0 : s.volume }, set: { Audio.setVolume($0); SystemStatus.shared.refreshAudio() }),
                             onSymbolTap: { Audio.setMuted(!s.muted); SystemStatus.shared.refreshAudio() },
                             enabled: Audio.canSetVolume())
                    QSIconButton(symbol: "chevron.right", help: "Select a sound output") { m.openOutputs() }
                }
                if !Audio.canSetVolume() {
                    Text("This output's volume is set on the device itself (common for HDMI and DisplayPort monitors).")
                        .font(Theme.font(11)).foregroundStyle(Theme.secondaryText(scheme))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(20)
    }

    private func tileGrid(_ kinds: [QSTileKind]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(104), spacing: 12), count: 3), spacing: 14) {
            ForEach(kinds) { k in
                tile(k)
                    .disabled(m.editing)
                    .overlay(alignment: .topTrailing) {
                        if m.editing {
                            // Windows: the unpin badge on each tile while editing.
                            Image(systemName: "pin.slash").font(.system(size: 9, weight: .semibold))
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(Theme.control(scheme)))
                                .overlay(Circle().strokeBorder(Theme.border(scheme), lineWidth: 1))
                                .contentShape(Circle())
                                .onTapGesture { m.unpin(k) }
                                .help("Unpin")
                                .offset(x: 6, y: -6)
                        }
                    }
                    .opacity(dragging == k ? 0.4 : 1)
                    .modifier(TileDrag(kind: k, enabled: m.editing, m: m, dragging: $dragging))
            }
        }
        // A drop between tiles still ends the drag (otherwise the dragged tile stays dimmed).
        .onDrop(of: [.text], isTargeted: nil) { _ in dragging = nil; return true }
    }

    @ViewBuilder private func tile(_ k: QSTileKind) -> some View {
        switch k {
        case .wifi:
            QSTile(title: s.wifiOn ? (s.ssid ?? "Wi-Fi") : "Wi-Fi", symbol: m.wifiOn ? "wifi" : "wifi.slash",
                   on: m.wifiOn, action: { m.toggleWiFi(); if m.wifiListOpen { m.scan() } },
                   more: m.toggleWiFiList, moreSymbol: "chevron.down", moreOpen: m.wifiListOpen,
                   moreHelp: m.wifiListOpen ? "Hide Wi-Fi networks" : "Show Wi-Fi networks")
        case .bluetooth:
            QSTile(title: k.title, symbol: k.symbol, on: m.bluetoothOn, action: m.toggleBluetooth, more: m.openBluetoothList)
        case .airplane: QSTile(title: k.title, symbol: k.symbol, on: m.airplane, action: m.toggleAirplane)
        case .batterySaver: QSTile(title: k.title, symbol: k.symbol, on: m.lowPower, action: m.toggleLowPower)
        case .nightLight: QSTile(title: k.title, symbol: k.symbol, on: m.nightShift, action: m.toggleNightShift)
        case .focus: QSTile(title: k.title, symbol: k.symbol, on: m.focus, action: m.toggleFocus)
        case .nearbySharing:
            QSTile(title: m.airdrop == .off ? k.title : (m.airdrop == .contacts ? "Contacts only" : "Everyone, 10 min"),
                   symbol: k.symbol, on: m.airdrop != .off, action: m.toggleAirDrop)
        case .cast: QSTile(title: k.title, symbol: k.symbol, on: false, action: m.cast)
        case .accessibility: QSTile(title: k.title, symbol: k.symbol, on: false, action: m.accessibility)
        case .keyboard:
            QSTile(title: s.currentInput.map { "\($0.language) \($0.layout)" } ?? k.title, symbol: k.symbol, on: false,
                   action: { m.page = .keyboard })
        case .liveCaptions: QSTile(title: k.title, symbol: k.symbol, on: false, action: m.liveCaptions)
        case .darkMode: QSTile(title: k.title, symbol: k.symbol, on: m.darkMode, action: m.toggleDarkMode)
        case .screenSaver:
            QSTile(title: k.title, symbol: k.symbol, on: false) { m.open("/System/Library/CoreServices/ScreenSaverEngine.app") }
        case .captureScreen: QSTile(title: k.title, symbol: k.symbol, on: false) { m.capture(selection: false) }
        case .captureSelection: QSTile(title: k.title, symbol: k.symbol, on: false) { m.capture(selection: true) }
        case .screenshot:
            QSTile(title: k.title, symbol: k.symbol, on: false) { m.open("/System/Applications/Utilities/Screenshot.app") }
        case .voiceMemo: QSTile(title: k.title, symbol: k.symbol, on: false) { m.open("/System/Applications/VoiceMemos.app") }
        case .quickNote: QSTile(title: k.title, symbol: k.symbol, on: false, action: m.quickNote)
        case .calculator: QSTile(title: k.title, symbol: k.symbol, on: false) { m.open("/System/Applications/Calculator.app") }
        case .clock: QSTile(title: k.title, symbol: k.symbol, on: false) { m.open("/System/Applications/Clock.app") }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if Battery.isPresent && s.battery.present {
                BatteryIcon(state: s.battery, size: 15)
                Text("\(s.battery.percent)%")
                if let detail = Battery.detail(s.battery) {
                    Text("· " + detail.prefix(1).uppercased() + detail.dropFirst())
                        .foregroundStyle(Theme.secondaryText(scheme)).lineLimit(1)
                }
            }
            Spacer()
            if m.editing {
                Button { m.page = .addTiles } label: { Label("Add", systemImage: "plus") }
                    .disabled(settings.tiles.count == QSTileKind.allCases.count)
                Button("Done") { m.editing = false; m.page = .main }.keyboardShortcut(.defaultAction)
            } else {
                QSIconButton(symbol: "pencil", help: "Edit quick settings") { m.page = .main; m.editing = true }
                QSIconButton(symbol: "gearshape", help: "All settings") {
                    FlyoutManager.shared.close()
                    SystemActions.openApp("/System/Applications/System Settings.app")
                }
            }
        }
        .font(Theme.font(12))
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background(Theme.flyoutFooter(scheme))
    }
}

// MARK: Building blocks

struct QSTile: View {
    let title: String
    let symbol: String
    let on: Bool
    let action: () -> Void
    var more: (() -> Void)? = nil
    var moreSymbol = "chevron.right"
    /// A down chevron that opens something in place turns clockwise to point up while it's open, and on round the same way on closing.
    var moreOpen = false
    var moreHelp: String? = nil
    @Environment(\.colorScheme) private var scheme
    @State private var hoverMain = false
    @State private var hoverMore = false

    private var fg: Color { on ? (scheme == .dark ? .black : .white) : Theme.text(scheme) }
    private func bg(_ hover: Bool) -> Color {
        on ? Theme.accent.opacity(hover ? 0.9 : 1) : (hover ? Theme.hover(scheme).opacity(2) : Theme.control(scheme))
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                Image(systemName: symbol).font(.system(size: 15))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(bg(hoverMain))
                    .contentShape(Rectangle())
                    .onHover { hoverMain = $0 }
                    .onTapGesture(perform: action)
                if let more {
                    Rectangle().fill(on ? Color.black.opacity(0.15) : Theme.border(scheme)).frame(width: 1)
                    Image(systemName: moreSymbol).font(.system(size: 10, weight: .semibold))
                        .modifier(ClockwiseTurn(open: moreOpen))
                        .frame(width: 32).frame(maxHeight: .infinity)
                        .background(bg(hoverMore))
                        .contentShape(Rectangle())
                        .onHover { hoverMore = $0 }
                        .onTapGesture(perform: more)
                        .help(moreHelp ?? "")
                }
            }
            .foregroundStyle(fg)
            .frame(width: 104, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(on ? Color.clear : Theme.border(scheme), lineWidth: 1))
            Text(title).font(Theme.font(12)).lineLimit(1).truncationMode(.tail).frame(width: 104)
        }
    }
}

struct QSSlider: View {
    let symbol: String
    @Binding var value: Float
    var onSymbolTap: (() -> Void)? = nil
    var enabled = true
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 15)).frame(width: 24)
                .contentShape(Rectangle())
                .onTapGesture { onSymbolTap?() }
            Slider(value: $value, in: 0...1)
                .tint(Theme.accent)
                .disabled(!enabled)
            Text("\(Int((value * 100).rounded()))").font(Theme.font(12)).frame(width: 26, alignment: .trailing)
                .foregroundStyle(Theme.secondaryText(scheme))
        }
        .opacity(enabled ? 1 : 0.45)
    }
}

struct QSIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false
    var body: some View {
        Image(systemName: symbol).font(.system(size: 13))
            .frame(width: 32, height: 32)
            .background(RoundedRectangle(cornerRadius: 4).fill(hovering ? Theme.hover(scheme) : .clear))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
            .help(help)
    }
}

struct QSPageHeader: View {
    let title: String
    let back: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            QSIconButton(symbol: "chevron.left", help: "Back", action: back)
            Text(title).font(Theme.font(14, .semibold))
            Spacer()
        }
    }
}

struct QSLink: View {
    let title: String
    let pane: String
    var body: some View {
        Button(title) {
            FlyoutManager.shared.close()
            SystemActions.openSettings(pane)
        }
        .buttonStyle(.link)
        .font(Theme.font(12))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Pages

struct WiFiPage: View {
    @ObservedObject var m: QuickSettingsModel
    @ObservedObject private var s = SystemStatus.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                QSPageHeader(title: "Wi-Fi") { m.page = .main }
                Toggle("", isOn: Binding(get: { m.wifiOn }, set: { _ in m.toggleWiFi(); m.scan() }))
                    .toggleStyle(.switch).labelsHidden().tint(Theme.accent)
            }
            WiFiList(m: m, maxHeight: 300)
        }
        .padding(16)
    }
}

/// The network list, used on the Wi-Fi page and opened in place by the Wi-Fi tile's chevron.
struct WiFiList: View {
    @ObservedObject var m: QuickSettingsModel
    var maxHeight: CGFloat = 300
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if Permissions.shared.location != .authorizedAlways {
                Button("Allow Location to see network names…") {
                    FlyoutManager.shared.close()
                    Permissions.shared.requestLocation()
                }
                .buttonStyle(.link).font(Theme.font(12))
            }
            ScrollView {
                VStack(spacing: 2) {
                    if m.scanning && m.networks.isEmpty {
                        ProgressView().controlSize(.small).padding()
                    }
                    ForEach(m.networks, id: \.self) { n in WiFiRow(m: m, n: n) }
                }
            }
            .frame(height: min(maxHeight, max(56, m.networks.reduce(0) { $0 + ($1.isHotspot ? 52 : 38) }
                                                + (m.expandedSSID == nil ? 0 : 40)
                                                + (m.joiningSSID == nil ? 0 : 40))))
            .overlay(alignment: .top) {
                // Refreshing a list that is already shown: a thin bar, so nothing moves (Windows: dotted bar).
                if m.scanning && !m.networks.isEmpty {
                    ProgressView().progressViewStyle(.linear).controlSize(.mini).offset(y: -8)
                }
            }
            .overlay {
                if !m.scanning && m.networks.isEmpty {
                    Text(Permissions.shared.location != .authorizedAlways
                         ? "macOS hides network names until Fenestra has Location access."
                         : (m.wifiOn ? "No networks found" : "Wi-Fi is off"))
                        .font(Theme.font(12)).foregroundStyle(Theme.secondaryText(scheme))
                        .multilineTextAlignment(.center)
                }
            }
            QSLink(title: "More Wi-Fi settings", pane: "com.apple.wifi-settings-extension")
        }
    }
}

/// One network. Closed: icon, name, lock. Clicked: it opens in place with its status and Connect, or Disconnect for
/// the current one; a new secured network then asks for its key (Windows 11 layout).
struct WiFiRow: View {
    @ObservedObject var m: QuickSettingsModel
    @ObservedObject private var s = SystemStatus.shared
    let n: CWNetwork
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        let ssid = n.ssid ?? ""
        let current = ssid == s.ssid
        let open = m.expandedSSID == ssid
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(current ? Theme.accent : .clear).frame(width: 3, height: 16)
                Image(systemName: n.isHotspot ? "personalhotspot" : "wifi")
                    .opacity(n.isHotspot ? 1 : 0.4 + Double(n.bars) * 0.2)
                    .frame(width: 18)
                    .overlay(alignment: .bottomTrailing) {
                        if n.isSecured { Image(systemName: "lock.fill").font(.system(size: 7)).offset(x: 4, y: 2) }
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(n.ssid ?? "Hidden network").lineLimit(1)
                    if n.isHotspot && !(current || open) {
                        Text("Mobile hotspot").font(Theme.font(11)).foregroundStyle(Theme.secondaryText(scheme))
                    }
                    if current || open {
                        Text(status(current: current)).font(Theme.font(11)).foregroundStyle(Theme.secondaryText(scheme))
                    }
                }
                Spacer(minLength: 0)
            }
            if open && m.joiningSSID == ssid {
                HStack {
                    SecureField("Enter the network security key", text: $m.password)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { m.join(n, password: m.password) }
                    Button("Next") { m.join(n, password: m.password) }.disabled(m.password.isEmpty)
                }
                .padding(.leading, 13)
            } else if open {
                HStack {
                    Spacer()
                    if current {
                        Button("Disconnect") { WiFi.shared.disconnect(); s.refreshWiFi() }
                    } else if m.connectingSSID == ssid {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Connect") { m.connect(n) }.keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .padding(.vertical, 6).padding(.trailing, 10)
        .background(RoundedRectangle(cornerRadius: 4).fill(open || hovering ? Theme.hover(scheme) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { m.choose(n) }
    }

    private func status(current: Bool) -> String {
        if n.isHotspot { return current ? "Mobile hotspot, connected" : "Mobile hotspot" }
        if current { return n.isSecured ? "Connected, secured" : "Connected" }
        if m.connectingSSID == n.ssid { return "Connecting" }
        return n.isSecured ? "Secured" : "Open"
    }
}

struct BluetoothPage: View {
    @ObservedObject var m: QuickSettingsModel
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                QSPageHeader(title: "Bluetooth") { m.page = .main }
                Toggle("", isOn: Binding(get: { m.bluetoothOn }, set: { _ in m.toggleBluetooth() }))
                    .toggleStyle(.switch).labelsHidden().tint(Theme.accent)
            }
            if m.btDevices.isEmpty && m.btLoading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 20)
            } else if m.btDevices.isEmpty {
                Text("No paired devices").foregroundStyle(Theme.secondaryText(scheme)).padding(.vertical, 20)
            }
            ForEach(m.btDevices) { d in BluetoothRow(m: m, d: d) }
            QSLink(title: "More Bluetooth settings", pane: "com.apple.BluetoothSettings")
        }
        .padding(16)
    }
}

/// One device, like Windows: a click opens it to show Connect (paired) or Disconnect (connected).
struct BluetoothRow: View {
    @ObservedObject var m: QuickSettingsModel
    let d: Bluetooth.Device
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        let open = m.expandedBT == d.id
        let connecting = m.connectingBT == d.id
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(d.connected ? Theme.accent : .clear).frame(width: 3, height: 16)
                Image(systemName: d.symbol).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(d.name).lineLimit(1)
                    Text(connecting ? "Connecting" : (d.connected ? "Connected" : "Paired")).font(Theme.font(11))
                        .foregroundStyle(Theme.secondaryText(scheme))
                }
                Spacer(minLength: 0)
            }
            if open {
                if let msg = m.btMessage {
                    Text(msg).font(Theme.font(11)).foregroundStyle(Theme.secondaryText(scheme))
                        .fixedSize(horizontal: false, vertical: true).padding(.leading, 13)
                }
                HStack {
                    Spacer()
                    if connecting {
                        ProgressView().controlSize(.small)
                    } else if d.connected {
                        Button("Disconnect") { m.disconnectDevice(d) }
                    } else {
                        Button("Connect") { m.connectDevice(d) }.keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .padding(.vertical, 6).padding(.trailing, 10)
        .background(RoundedRectangle(cornerRadius: 4).fill(open || hovering ? Theme.hover(scheme) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { m.chooseDevice(d) }
    }
}

struct OutputPage: View {
    @ObservedObject var m: QuickSettingsModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            QSPageHeader(title: "Sound output") { m.page = .main }
            ForEach(m.outputs) { d in
                FlyoutRow(selected: d.id == m.currentOutput) { m.selectOutput(d) } content: {
                    Image(systemName: "speaker.wave.2")
                    Text(d.name)
                }
            }
            HStack(spacing: 8) {
                AirPlayPicker().frame(width: 28, height: 28)
                Text("AirPlay").font(Theme.font(12))
            }
            .padding(.leading, 13)
            QSLink(title: "More sound settings", pane: "com.apple.Sound-Settings.extension")
        }
        .padding(16)
    }
}

/// Tiles can be dragged only in edit mode (Windows: outside it a press is just a click).
struct TileDrag: ViewModifier {
    let kind: QSTileKind
    let enabled: Bool
    let m: QuickSettingsModel
    @Binding var dragging: QSTileKind?
    func body(content: Content) -> some View {
        if enabled {
            content
                .onDrag {
                    dragging = kind
                    return NSItemProvider(object: kind.rawValue as NSString)
                }
                .onDrop(of: [.text], delegate: TileDrop(target: kind, m: m, dragging: $dragging))
        } else {
            content
        }
    }
}

/// Drag a tile over another while editing: it takes that place.
struct TileDrop: DropDelegate {
    let target: QSTileKind
    let m: QuickSettingsModel
    @Binding var dragging: QSTileKind?
    func dropEntered(info: DropInfo) {
        guard let d = dragging, d != target else { return }
        withAnimation(.easeOut(duration: 0.15)) { m.move(d, to: target) }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}

/// Edit quick settings > Add: the tiles not shown yet, Windows ones first, then Control Center's.
struct AddTilesPage: View {
    @ObservedObject var m: QuickSettingsModel
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let shown = Set(settings.quickTiles)
        let rest = QSTileKind.allCases.filter { !shown.contains($0.rawValue) }
        VStack(alignment: .leading, spacing: 8) {
            QSPageHeader(title: "Add") { m.page = .main }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach([false, true], id: \.self) { mac in
                        let group = rest.filter { $0.fromMac == mac }
                        if !group.isEmpty {
                            Text(mac ? "From Control Center" : "Windows").font(Theme.font(11, .semibold))
                                .foregroundStyle(Theme.secondaryText(scheme)).padding(.top, 6).padding(.leading, 13)
                            ForEach(group) { k in
                                FlyoutRow(selected: false) { m.pin(k) } content: {
                                    Image(systemName: k.symbol).frame(width: 20)
                                    Text(k.title)
                                }
                            }
                        }
                    }
                    if rest.isEmpty {
                        Text("Every tile is already shown.").foregroundStyle(Theme.secondaryText(scheme)).padding(13)
                    }
                }
            }
            .frame(height: min(320, CGFloat(rest.count) * 30 + 60))
        }
        .padding(16)
    }
}

/// Keyboard layout tile: every input source, the current one marked; choosing one switches to it.
struct KeyboardPage: View {
    @ObservedObject var m: QuickSettingsModel
    @ObservedObject private var s = SystemStatus.shared
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            QSPageHeader(title: "Keyboard layout") { m.page = .main }
            ForEach(s.inputSources) { src in
                FlyoutRow(selected: src.id == s.currentInputID) { s.selectInput(src.id) } content: {
                    Text(src.language).font(Theme.font(11, .semibold)).frame(width: 30, alignment: .leading)
                    Text(src.name)
                }
            }
            QSLink(title: "Keyboard settings", pane: "com.apple.Keyboard-Settings.extension")
        }
        .padding(16)
    }
}

/// AirPlay outputs only appear in AVKit's own picker (public API).
struct AirPlayPicker: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.isRoutePickerButtonBordered = false
        return v
    }
    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}

struct FocusSetupPage: View {
    @ObservedObject var m: QuickSettingsModel
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            QSPageHeader(title: "Set up Focus") { m.page = .main }
            Text("macOS doesn't let apps turn Do Not Disturb on or off directly, but Shortcuts can. Fenestra adds two "
                 + "shortcuts for it (\(FocusControl.onName) and \(FocusControl.offName)). Shortcuts asks you to "
                 + "confirm each one: click Add Shortcut.")
                .fixedSize(horizontal: false, vertical: true)
            if let status = m.focusSetupStatus {
                Text(status).font(Theme.font(12)).foregroundStyle(Theme.secondaryText(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Add shortcuts") { m.addFocusShortcuts() }.keyboardShortcut(.defaultAction)
                Button("Open Shortcuts") { SystemActions.openApp("/System/Applications/Shortcuts.app") }
            }
            QSLink(title: "Or open Focus settings", pane: "com.apple.Focus-Settings.extension")
        }
        .padding(16)
    }
}

struct BatterySaverSetupPage: View {
    @ObservedObject var m: QuickSettingsModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            QSPageHeader(title: "Battery saver") { m.page = .main }
            Text("Switching Low Power Mode needs administrator rights. Fenestra can ask for your Mac password once and add a rule that allows only `pmset -a lowpowermode 0` and `1` without a password. restore.sh --uninstall removes it.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Allow (asks for your password)") { m.installLowPowerPermission() }
                    .keyboardShortcut(.defaultAction)
            }
            QSLink(title: "Or open Battery settings", pane: "com.apple.Battery-Settings.extension")
        }
        .padding(16)
    }
}
