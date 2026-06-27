import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case english
    case simplifiedChinese

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .english:
            "English"
        case .simplifiedChinese:
            "中文"
        }
    }
}

enum AppLanguageStore {
    private static let key = "appLanguage"

    static var selected: AppLanguage {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: key),
                  let language = AppLanguage(rawValue: rawValue) else {
                return .english
            }
            return language
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            AppLog.info("App language set to \(newValue.rawValue)")
        }
    }
}

enum L10n {
    static func text(en: String, zh: String) -> String {
        AppLanguageStore.selected == .simplifiedChinese ? zh : en
    }
}
