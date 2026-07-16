import Foundation

/// Stores recent successful dictation results for recognition and AI context.
///
/// Rules:
/// - Keeps the most recent 3 successful results.
/// - Only content within 10 minutes is eligible.
/// - Maximum 1200 characters injected.
/// - Current dictation is never included in its own context.
/// - Used only for understanding references, terminology, and context.
actor RecentDictationContext {
    static let shared = RecentDictationContext()

    private struct Entry: Sendable {
        let text: String
        let timestamp: Date
    }

    private var entries: [Entry] = []

    private static let maxCount = 3
    private static let maxAge: TimeInterval = 10 * 60 // 10 minutes
    private static let maxChars = 1200

    /// Record a successful dictation result. Call AFTER post-processing succeeds.
    func record(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        entries.append(Entry(text: trimmed, timestamp: Date()))
        // Keep only recent entries to avoid unbounded growth
        let cutoff = Date().addingTimeInterval(-Self.maxAge * 2)
        entries.removeAll { $0.timestamp < cutoff }
    }

    /// Fetch formatted context string from recent dictation results.
    /// Call BEFORE post-processing the current dictation.
    func fetchContext() -> String {
        let now = Date()
        let eligible = entries
            .filter { now.timeIntervalSince($0.timestamp) <= Self.maxAge }
            .suffix(Self.maxCount)

        guard !eligible.isEmpty else { return "" }

        var result = ""
        for entry in eligible {
            let separator = result.isEmpty ? "" : "\n---\n"
            let candidate = result + separator + entry.text
            if candidate.count > Self.maxChars {
                // Truncate to fit
                let remaining = Self.maxChars - result.count - separator.count
                if remaining > 0 {
                    result = String(candidate.prefix(Self.maxChars))
                }
                break
            }
            result = candidate
        }
        return result
    }
}
