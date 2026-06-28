import XCTest
@testable import Douvo

final class AudioInputConditionerTests: XCTestCase {
    func testConditionerReplacesNonFiniteSamples() {
        var conditioner = AudioInputConditioner()

        let output = conditioner.process([0.1, .nan, .infinity, -.infinity, -0.1])

        XCTAssertEqual(output.count, 5)
        XCTAssertTrue(output.allSatisfy(\.isFinite))
    }

    func testConditionerReducesDcOffsetOverTime() {
        var conditioner = AudioInputConditioner()

        let output = conditioner.process(Array(repeating: Float(0.25), count: 240))
        let earlyAverage = averageMagnitude(output.prefix(40))
        let lateAverage = averageMagnitude(output.suffix(40))

        XCTAssertLessThan(lateAverage, earlyAverage * 0.6)
    }

    func testConditionerKeepsOutputBounded() {
        var conditioner = AudioInputConditioner()

        let input = stride(from: 0, to: 128, by: 1).map { index in
            sinf(Float(index) * 0.2) * 1.4
        }
        let output = conditioner.process(input)

        XCTAssertTrue(output.allSatisfy { sample in
            sample >= -1 && sample <= 1
        })
    }

    func testDecibelLevelMappingKeepsQuietSpeechVisible() {
        let quietSpeech = AudioLevelVisualizer.level(fromRMS: 0.003_162_277)
        let moderateSpeech = AudioLevelVisualizer.level(fromRMS: 0.031_622_77)

        XCTAssertGreaterThan(quietSpeech, 0.3)
        XCTAssertGreaterThan(moderateSpeech, quietSpeech)
        XCTAssertLessThanOrEqual(moderateSpeech, 1)
        XCTAssertEqual(AudioLevelVisualizer.level(fromRMS: 0), 0)
        XCTAssertEqual(AudioLevelVisualizer.level(fromRMS: .nan), 0)
    }

    func testNoiseGateRemapsVisibleRangeAboveFloor() {
        let noiseFloor: Float = 0.2
        let belowFloor = AudioLevelVisualizer.normalizedVoiceLevel(from: 0.16, noiseFloor: noiseFloor)
        let atFloor = AudioLevelVisualizer.normalizedVoiceLevel(from: noiseFloor, noiseFloor: noiseFloor)
        let aboveFloor = AudioLevelVisualizer.normalizedVoiceLevel(from: 0.24, noiseFloor: noiseFloor)
        let highLevel = AudioLevelVisualizer.normalizedVoiceLevel(from: 1, noiseFloor: noiseFloor)

        XCTAssertEqual(belowFloor, 0)
        XCTAssertEqual(atFloor, 0)
        XCTAssertGreaterThan(aboveFloor, 0)
        XCTAssertEqual(aboveFloor, 0.05, accuracy: 0.0001)
        XCTAssertEqual(highLevel, 1)
    }

    private func averageMagnitude<S: Sequence>(_ samples: S) -> Float where S.Element == Float {
        let values = Array(samples)
        guard !values.isEmpty else { return 0 }
        let total = values.reduce(Float(0)) { $0 + abs($1) }
        return total / Float(values.count)
    }
}
