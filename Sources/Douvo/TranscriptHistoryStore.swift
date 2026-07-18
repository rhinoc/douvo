import Foundation

enum TranscriptHistoryStore {
    private static let key = "transcriptHistory"
    static let maxCount = 20

    static func load(defaults: UserDefaults = .standard) -> [String] {
        let entries = defaults.stringArray(forKey: key) ?? []
        return Array(entries.suffix(maxCount))
    }

    @discardableResult
    static func record(_ text: String, defaults: UserDefaults = .standard) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return load(defaults: defaults) }

        var entries = load(defaults: defaults)
        entries.append(trimmed)
        entries = Array(entries.suffix(maxCount))
        defaults.set(entries, forKey: key)
        return entries
    }
}
