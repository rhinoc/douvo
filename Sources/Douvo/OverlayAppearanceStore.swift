import Foundation
import CoreGraphics

enum OverlayAppearanceStore {
    enum WaveformStyle: String, CaseIterable, Identifiable {
        case capsules
        case dots
        case ribbon

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .capsules:
                L10n.text(en: "Bars", zh: "条形")
            case .dots:
                L10n.text(en: "Dots", zh: "点阵")
            case .ribbon:
                L10n.text(en: "Ribbon", zh: "丝带")
            }
        }
    }

    enum Size: String, CaseIterable, Identifiable {
        case small
        case medium
        case large

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .small:
                L10n.text(en: "Small", zh: "小")
            case .medium:
                L10n.text(en: "Medium", zh: "中")
            case .large:
                L10n.text(en: "Large", zh: "大")
            }
        }

        var pillWidth: CGFloat {
            switch self {
            case .small:
                58
            case .medium:
                76
            case .large:
                96
            }
        }

        var pillHeight: CGFloat {
            switch self {
            case .small:
                34
            case .medium:
                38
            case .large:
                42
            }
        }

        var controlButtonSize: CGFloat {
            switch self {
            case .small:
                20
            case .medium:
                22
            case .large:
                24
            }
        }

        var controlGap: CGFloat {
            switch self {
            case .small:
                6
            case .medium:
                7
            case .large:
                8
            }
        }

        var horizontalPadding: CGFloat {
            switch self {
            case .small:
                7
            case .medium:
                8
            case .large:
                9
            }
        }

        var waveformBarWidth: CGFloat {
            switch self {
            case .small:
                2.4
            case .medium:
                2.7
            case .large:
                3
            }
        }

        var waveformBarCount: Int {
            switch self {
            case .small:
                8
            case .medium:
                10
            case .large:
                12
            }
        }
    }

    static let showCancelControlKey = "overlayShowCancelControl"
    static let showSubmitControlKey = "overlayShowSubmitControl"
    static let showBorderLightKey = "overlayShowBorderLight"
    static let sizeKey = "overlaySize"
    static let waveformStyleKey = "overlayWaveformStyle"
    static let waveformNoiseFloorKey = "overlayWaveformNoiseFloor"

    static let defaultWaveformNoiseFloor: Double = 0.2
    static let waveformNoiseFloorRange: ClosedRange<Double> = 0.05...0.45

    static var showsCancelControl: Bool {
        get {
            guard UserDefaults.standard.object(forKey: showCancelControlKey) != nil else {
                return true
            }
            return UserDefaults.standard.bool(forKey: showCancelControlKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: showCancelControlKey)
        }
    }

    static var showsSubmitControl: Bool {
        get {
            guard UserDefaults.standard.object(forKey: showSubmitControlKey) != nil else {
                return true
            }
            return UserDefaults.standard.bool(forKey: showSubmitControlKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: showSubmitControlKey)
        }
    }

    static var size: Size {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: sizeKey),
                  let size = Size(rawValue: rawValue) else {
                return .large
            }
            return size
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: sizeKey)
        }
    }

    static var waveformNoiseFloor: Double {
        get {
            guard UserDefaults.standard.object(forKey: waveformNoiseFloorKey) != nil else {
                return defaultWaveformNoiseFloor
            }
            let value = UserDefaults.standard.double(forKey: waveformNoiseFloorKey)
            return min(waveformNoiseFloorRange.upperBound, max(waveformNoiseFloorRange.lowerBound, value))
        }
        set {
            let value = min(waveformNoiseFloorRange.upperBound, max(waveformNoiseFloorRange.lowerBound, newValue))
            UserDefaults.standard.set(value, forKey: waveformNoiseFloorKey)
        }
    }

    static var waveformStyle: WaveformStyle {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: waveformStyleKey),
                  let style = WaveformStyle(rawValue: rawValue) else {
                return .capsules
            }
            return style
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: waveformStyleKey)
        }
    }

    static var showsBorderLight: Bool {
        get {
            guard UserDefaults.standard.object(forKey: showBorderLightKey) != nil else {
                return true
            }
            return UserDefaults.standard.bool(forKey: showBorderLightKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: showBorderLightKey)
        }
    }
}
