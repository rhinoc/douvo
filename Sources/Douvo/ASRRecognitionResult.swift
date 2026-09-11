import Foundation

struct ASRRecognitionSegment: Sendable {
    let id: String
    let text: String
    let index: Int?
    let startTime: Int?
    let endTime: Int?
    let isFinal: Bool
}

struct ASRRecognitionResult: Sendable {
    let text: String
    let provider: String
    let kind: String
    let segmentCount: Int
    let isFinal: Bool
    let metadata: [String: String]
    let segments: [ASRRecognitionSegment]

    static func web(_ text: String) -> ASRRecognitionResult {
        ASRRecognitionResult(
            text: text,
            provider: "web",
            kind: "full",
            segmentCount: text.isEmpty ? 0 : 1,
            isFinal: false,
            metadata: [:],
            segments: []
        )
    }

    static func android(
        text: String,
        kind: String,
        segmentCount: Int,
        isFinal: Bool,
        metadata: [String: String],
        segments: [ASRRecognitionSegment]
    ) -> ASRRecognitionResult {
        ASRRecognitionResult(
            text: text,
            provider: "android",
            kind: kind,
            segmentCount: segmentCount,
            isFinal: isFinal,
            metadata: metadata,
            segments: segments
        )
    }

    static func bageshuo(
        text: String,
        kind: String,
        isFinal: Bool,
        metadata: [String: String] = [:]
    ) -> ASRRecognitionResult {
        ASRRecognitionResult(
            text: text,
            provider: "bageshuo",
            kind: kind,
            segmentCount: text.isEmpty ? 0 : 1,
            isFinal: isFinal,
            metadata: metadata,
            segments: []
        )
    }
}
