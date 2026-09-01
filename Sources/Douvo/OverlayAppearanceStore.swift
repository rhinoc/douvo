import Foundation
import CoreGraphics

enum OverlayAppearanceStore {
    enum AnimationIntensity: String, CaseIterable, Identifiable {
        case none
        case reduced
        case normal

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .none:
                L10n.text(en: "None", zh: "无")
            case .reduced:
                L10n.text(en: "Reduced", zh: "降低")
            case .normal:
                L10n.text(en: "Normal", zh: "正常")
            }
        }

        var allowsOpacityAnimation: Bool {
            self != .none
        }

        var allowsMotionAnimation: Bool {
            self == .normal
        }
    }

    enum WaveformStyle: String, CaseIterable, Identifiable {
        case capsules
        case dots
        case siri
        case gpt

        var id: String { rawValue }

        init?(rawValue: String) {
            switch rawValue {
            case "ribbon", "siri":
                self = .siri
            case "capsules":
                self = .capsules
            case "dots":
                self = .dots
            case "gpt":
                self = .gpt
            default:
                return nil
            }
        }

        var displayName: String {
            switch self {
            case .capsules:
                L10n.text(en: "Bars", zh: "条形")
            case .dots:
                L10n.text(en: "Dots", zh: "点阵")
            case .siri:
                "Siri"
            case .gpt:
                "GPT"
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
                1
            case .medium:
                2
            case .large:
                2
            }
        }

        var waveformBarCount: Int {
            switch self {
            case .small:
                20
            case .medium:
                20
            case .large:
                24
            }
        }
    }

    static let showCancelControlKey = "overlayShowCancelControl"
    static let showSubmitControlKey = "overlayShowSubmitControl"
    static let showBorderLightKey = "overlayShowBorderLight"
    static let sizeKey = "overlaySize"
    static let waveformStyleKey = "overlayWaveformStyle"
    static let waveformNoiseFloorKey = "overlayWaveformNoiseFloor"
    static let animationIntensityKey = "overlayAnimationIntensity"
    static let surfaceOpacityKey = "overlaySurfaceOpacity"

    static let defaultWaveformNoiseFloor: Double = 0.2
    static let waveformNoiseFloorRange: ClosedRange<Double> = 0.05...0.45
    static let defaultSurfaceOpacity: Double = 0.9
    static let surfaceOpacityRange: ClosedRange<Double> = 0.35...0.9

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

    static var animationIntensity: AnimationIntensity {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: animationIntensityKey),
                  let intensity = AnimationIntensity(rawValue: rawValue) else {
                return .normal
            }
            return intensity
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: animationIntensityKey)
        }
    }

    static var surfaceOpacity: Double {
        get {
            guard UserDefaults.standard.object(forKey: surfaceOpacityKey) != nil else {
                return defaultSurfaceOpacity
            }
            let value = UserDefaults.standard.double(forKey: surfaceOpacityKey)
            return min(surfaceOpacityRange.upperBound, max(surfaceOpacityRange.lowerBound, value))
        }
        set {
            let value = min(surfaceOpacityRange.upperBound, max(surfaceOpacityRange.lowerBound, newValue))
            UserDefaults.standard.set(value, forKey: surfaceOpacityKey)
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
