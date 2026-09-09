import AppKit
import MetalKit
import QuartzCore
import SwiftUI

struct GPTFluidOrbView: NSViewRepresentable {
    let activity: CGFloat
    let isActive: Bool
    let animatesMotion: Bool

    func makeCoordinator() -> GPTFluidOrbRenderer {
        GPTFluidOrbRenderer()
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        view.delegate = context.coordinator
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = false
        view.isPaused = !animatesMotion
        view.preferredFramesPerSecond = 60
        view.autoResizeDrawable = true
        view.sampleCount = 4
        Self.configureTransparentLayer(for: view)
        context.coordinator.update(activity: activity, isActive: isActive)
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.update(activity: activity, isActive: isActive)
        view.isPaused = !animatesMotion
        if !animatesMotion {
            view.draw()
        }
    }

    static func configureTransparentLayer(for view: MTKView) {
        view.wantsLayer = true
        view.layer?.isOpaque = false
        view.layer?.backgroundColor = NSColor.clear.cgColor
        (view.layer as? CAMetalLayer)?.isOpaque = false
    }
}

private struct GPTFluidOrbUniforms {
    var resolution: SIMD2<Float>
    var time: Float
    var activity: Float
    var isActive: Float
    var padding: Float = 0
}

final class GPTFluidOrbRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice?

    private let commandQueue: MTLCommandQueue?
    private let pipeline: MTLRenderPipelineState?
    private let startTime = CACurrentMediaTime()
    private var activity: Float = 0
    private var isActive: Float = 0

    override init() {
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        self.commandQueue = device?.makeCommandQueue()
        self.pipeline = Self.makePipeline(device: device)
        super.init()
    }

    func update(activity: CGFloat, isActive: Bool) {
        self.activity = Float(max(0, min(1, activity)))
        self.isActive = isActive ? 1 : 0
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard
            let pipeline,
            let commandQueue,
            let drawable = view.currentDrawable,
            let renderPassDescriptor = view.currentRenderPassDescriptor,
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let commandEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
        else {
            return
        }

        var uniforms = GPTFluidOrbUniforms(
            resolution: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)),
            time: Float(CACurrentMediaTime() - startTime),
            activity: activity,
            isActive: isActive
        )

        commandEncoder.setRenderPipelineState(pipeline)
        commandEncoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<GPTFluidOrbUniforms>.stride,
            index: 0
        )
        commandEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        commandEncoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private static func makePipeline(device: MTLDevice?) -> MTLRenderPipelineState? {
        guard
            let device,
            let sourceURL = DouvoResourceLocator.url(forResource: "GPTFluidOrbShaders", withExtension: "metal"),
            let source = try? String(contentsOf: sourceURL, encoding: .utf8),
            let library = try? device.makeLibrary(source: source, options: nil),
            let vertexFunction = library.makeFunction(name: "douvoGPTFullscreenVertex"),
            let fragmentFunction = library.makeFunction(name: "douvoGPTOrbFragment")
        else {
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.rasterSampleCount = 4
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }
}
