import Foundation

enum ASRProvider: String, CaseIterable, Identifiable, Codable, Hashable {
    case web
    case android
    case bageshuo
    case chatterfly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .web:
            "Web"
        case .android:
            "Android"
        case .bageshuo:
            L10n.text(en: "Bage Shuo", zh: "叭哥说")
        case .chatterfly:
            "Chatterfly"
        }
    }

    var detail: String {
        switch self {
        case .web:
            L10n.text(en: "Doubao Web recognition", zh: "豆包网页识别")
        case .android:
            L10n.text(en: "Doubao Android input method", zh: "豆包 Android 输入法")
        case .bageshuo:
            L10n.text(en: "Youdao Bage Shuo realtime recognition", zh: "网易叭哥说实时识别")
        case .chatterfly:
            L10n.text(en: "Chatterfly realtime recognition", zh: "Chatterfly 实时语音识别")
        }
    }

    var usesWebASR: Bool { self == .web }
    var usesAndroidASR: Bool { self == .android }
    var usesBageshuoASR: Bool { self == .bageshuo }
    var usesChatterflyASR: Bool { self == .chatterfly }
    var requiresLogin: Bool { self == .web || self == .bageshuo || self == .chatterfly }
}

struct ASRProviderSelection: Equatable, Hashable, Sendable, Codable {
    let providers: Set<ASRProvider>

    static let `default` = ASRProviderSelection([.web])

    init(_ providers: Set<ASRProvider>) {
        self.providers = providers.isEmpty ? [.web] : providers
    }

    init(_ provider: ASRProvider) {
        self.init([provider])
    }

    var sortedProviders: [ASRProvider] {
        ASRProvider.allCases.filter { providers.contains($0) }
    }

    var storageValue: String {
        sortedProviders.map(\.rawValue).joined(separator: ",")
    }

    var displayName: String {
        sortedProviders.map(\.displayName).joined(separator: " + ")
    }

    var detail: String {
        if providers.count == 1 {
            return sortedProviders[0].detail
        }
        return L10n.text(
            en: "\(displayName) with AI merge",
            zh: "\(displayName)，经 AI 合并"
        )
    }

    var usesWebASR: Bool { providers.contains(.web) }
    var usesAndroidASR: Bool { providers.contains(.android) }
    var usesBageshuoASR: Bool { providers.contains(.bageshuo) }
    var usesChatterflyASR: Bool { providers.contains(.chatterfly) }

    var requiresLogin: Bool {
        sortedProviders.contains(where: { $0.requiresLogin })
    }

    var requiresAICorrection: Bool {
        providers.count > 1
    }

    var activeProviderKeys: Set<String> {
        Set(providers.map(\.rawValue))
    }

    static func parse(_ value: String) -> ASRProviderSelection? {
        let values = value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !values.isEmpty else { return nil }

        // Read the old configuration as the equivalent two-provider selection.
        if values.count == 1, values[0] == "mix" {
            return ASRProviderSelection([.web, .android])
        }

        var providers = Set<ASRProvider>()
        for value in values {
            guard let provider = ASRProvider(rawValue: value) else { return nil }
            providers.insert(provider)
        }
        return providers.isEmpty ? nil : ASRProviderSelection(providers)
    }
}

enum ASRProviderStore {
    private static let providersKey = "asrProviders"
    private static let legacyProviderKey = "asrProvider"

    static var selected: ASRProviderSelection {
        get {
            if let values = UserDefaults.standard.array(forKey: providersKey) as? [String],
               let selection = ASRProviderSelection.parse(values.joined(separator: ",")) {
                return selection
            }

            if let legacyValue = UserDefaults.standard.string(forKey: legacyProviderKey),
               let selection = ASRProviderSelection.parse(legacyValue) {
                return selection
            }
            return .default
        }
        set {
            UserDefaults.standard.set(newValue.sortedProviders.map(\.rawValue), forKey: providersKey)
            AppLog.info("ASR providers set to \(newValue.storageValue)")
        }
    }
}
