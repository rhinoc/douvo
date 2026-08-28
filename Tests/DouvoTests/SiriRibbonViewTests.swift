import AppKit
import MetalKit
import XCTest
@testable import Douvo

@MainActor
final class SiriRibbonViewTests: XCTestCase {
    func testMetalLayerIsTransparent() {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())

        SiriRibbonView.configureTransparentLayer(for: view)

        XCTAssertFalse(view.layer?.isOpaque ?? true)
        XCTAssertEqual(view.layer?.backgroundColor, NSColor.clear.cgColor)
    }
}
