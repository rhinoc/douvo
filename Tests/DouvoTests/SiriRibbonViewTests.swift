import AppKit
import MetalKit
import XCTest
@testable import Douvo

@MainActor
final class SiriRibbonViewTests: XCTestCase {
    func testLegacyRibbonStyleMapsToSiri() {
        XCTAssertEqual(OverlayAppearanceStore.WaveformStyle(rawValue: "ribbon"), .siri)
        XCTAssertEqual(OverlayAppearanceStore.WaveformStyle(rawValue: "siri"), .siri)
        XCTAssertEqual(OverlayAppearanceStore.WaveformStyle.siri.displayName, "Siri")
    }

    func testGPTStyleIsAvailable() {
        XCTAssertEqual(OverlayAppearanceStore.WaveformStyle.gpt.displayName, "GPT")
        XCTAssertTrue(OverlayAppearanceStore.WaveformStyle.allCases.contains(.gpt))
    }

    func testMetalLayerIsTransparent() {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())

        SiriRibbonView.configureTransparentLayer(for: view)

        XCTAssertFalse(view.layer?.isOpaque ?? true)
        XCTAssertEqual(view.layer?.backgroundColor, NSColor.clear.cgColor)
    }
}
