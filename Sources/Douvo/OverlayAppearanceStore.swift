import Foundation
import CoreGraphics

enum OverlayAppearanceStore {
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
                96
            case .medium:
                108
            case .large:
                120
            }
        }
    }

    static let showControlsKey = "overlayShowControls"
    static let showBorderLightKey = "overlayShowBorderLight"
    static let sizeKey = "overlaySize"

    static var showsControls: Bool {
        get {
            guard UserDefaults.standard.object(forKey: showControlsKey) != nil else {
                return true
            }
            return UserDefaults.standard.bool(forKey: showControlsKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: showControlsKey)
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
