import Foundation

struct LanguageDisplay: Hashable {
    let identifier: String

    var displayName: String {
        if let override = Self.localizedNameOverrides[identifier] {
            return L10n.text(en: override.en, zh: override.zh)
        }
        return Self.appLocale.localizedString(forIdentifier: identifier)
            ?? Self.englishLocale.localizedString(forIdentifier: identifier)
            ?? identifier
    }

    var promptName: String {
        if let override = Self.localizedNameOverrides[identifier] {
            return override.en
        }
        return Self.englishLocale.localizedString(forIdentifier: identifier) ?? identifier
    }

    var flagEmoji: String {
        if identifier == "auto" {
            return "🌐"
        }
        guard let regionCode = Locale(identifier: identifier).region?.identifier else {
            return ""
        }
        return Self.flagEmoji(forRegionCode: regionCode) ?? ""
    }

    var menuTitle: String {
        let flag = flagEmoji
        return flag.isEmpty ? displayName : "\(flag) \(displayName)"
    }

    private static var appLocale: Locale {
        switch AppLanguageStore.selected {
        case .english:
            Locale(identifier: "en")
        case .simplifiedChinese:
            Locale(identifier: "zh-Hans")
        }
    }

    private static let englishLocale = Locale(identifier: "en")

    private static let localizedNameOverrides: [String: (en: String, zh: String)] = [
        "auto": ("Auto", "自动")
    ]

    private static func flagEmoji(forRegionCode regionCode: String) -> String? {
        let scalars = regionCode
            .uppercased()
            .unicodeScalars
            .compactMap { scalar -> UnicodeScalar? in
                guard scalar.value >= 65, scalar.value <= 90 else { return nil }
                return UnicodeScalar(127_397 + scalar.value)
            }
        guard scalars.count == 2 else { return nil }
        return String(String.UnicodeScalarView(scalars))
    }
}

enum SupportedLanguage: String, CaseIterable, Identifiable, LanguageMenuOption, Codable, Sendable {
    case chineseMandarin = "zh-CN"
    case englishUS = "en-US"
    case japanese = "ja-JP"
    case indonesian = "id-ID"
    case spanishMexico = "es-MX"
    case portugueseBrazil = "pt-BR"
    case german = "de-DE"
    case french = "fr-FR"
    case korean = "ko-KR"
    case filipino = "fil-PH"
    case malay = "ms-MY"
    case thai = "th-TH"
    case arabicSaudiArabia = "ar-SA"
    case italian = "it-IT"
    case bengaliBangladesh = "bn-BD"
    case greek = "el-GR"
    case dutch = "nl-NL"
    case russian = "ru-RU"
    case turkish = "tr-TR"
    case vietnamese = "vi-VN"
    case polish = "pl-PL"
    case romanian = "ro-RO"
    case nepaliNepal = "ne-NP"
    case ukrainian = "uk-UA"
    case cantonese = "yue-CN"

    var id: String { rawValue }

    var languageDisplay: LanguageDisplay {
        LanguageDisplay(identifier: rawValue)
    }

    var promptName: String {
        languageDisplay.promptName
    }
}

typealias TranslationTargetLanguage = SupportedLanguage

protocol LanguageMenuOption: Hashable, Identifiable {
    var languageDisplay: LanguageDisplay { get }
}

extension LanguageMenuOption {
    var displayName: String {
        languageDisplay.displayName
    }

    var flagEmoji: String {
        languageDisplay.flagEmoji
    }

    var menuTitle: String {
        languageDisplay.menuTitle
    }
}
