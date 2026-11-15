import SwiftUI

/// Every tile Quick Settings can show (Windows: Edit quick settings > Add). The Windows tiles first, then the
/// controls macOS's own Control Center offers. Which ones show, and in what order, is `AppSettings.quickTiles`.
enum QSTileKind: String, CaseIterable, Identifiable {
    case wifi, bluetooth, airplane, batterySaver, nightLight, focus, nearbySharing, cast, accessibility, keyboard,
         liveCaptions
    case darkMode, screenSaver, captureScreen, captureSelection, screenshot, voiceMemo, quickNote, calculator, clock

    var id: String { rawValue }

    /// What shows until you change it: the eleven Windows tiles.
    static let defaults: [QSTileKind] = [.wifi, .bluetooth, .airplane, .batterySaver, .nightLight, .focus,
                                         .nearbySharing, .cast, .accessibility, .keyboard, .liveCaptions]

    var title: String {
        switch self {
        case .wifi: "Wi-Fi"
        case .bluetooth: "Bluetooth"
        case .airplane: "Airplane mode"
        case .batterySaver: "Battery saver"
        case .nightLight: "Night light"
        case .focus: "Focus"
        case .nearbySharing: "Nearby sharing"
        case .cast: "Cast"
        case .accessibility: "Accessibility"
        case .keyboard: "Keyboard layout"
        case .liveCaptions: "Live captions"
        case .darkMode: "Dark mode"
        case .screenSaver: "Screen saver"
        case .captureScreen: "Capture screen"
        case .captureSelection: "Capture selection"
        case .screenshot: "Screenshot and record"
        case .voiceMemo: "Voice memo"
        case .quickNote: "Quick note"
        case .calculator: "Calculator"
        case .clock: "Clock"
        }
    }

    var symbol: String {
        switch self {
        case .wifi: "wifi"
        case .bluetooth: "dot.radiowaves.left.and.right"
        case .airplane: "airplane"
        case .batterySaver: "leaf"
        case .nightLight: "sun.max"
        case .focus: "moon"
        case .nearbySharing: "dot.radiowaves.up.forward"
        case .cast: "rectangle.on.rectangle"
        case .accessibility: "accessibility"
        case .keyboard: "keyboard"
        case .liveCaptions: "captions.bubble"
        case .darkMode: "circle.lefthalf.filled"
        case .screenSaver: "tv"
        case .captureScreen: "camera.viewfinder"
        case .captureSelection: "rectangle.dashed"
        case .screenshot: "record.circle"
        case .voiceMemo: "waveform"
        case .quickNote: "note.text"
        case .calculator: "plus.forwardslash.minus"
        case .clock: "alarm"
        }
    }

    /// From Control Center rather than Windows (shown under their own heading in Add).
    var fromMac: Bool { QSTileKind.allCases.firstIndex(of: self)! >= QSTileKind.allCases.firstIndex(of: .darkMode)! }
}
