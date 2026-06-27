import AppKit
import SwiftUI

private enum OverlayMetrics {
    static let pillWidth: CGFloat = 120
    static let pillHeight: CGFloat = 40
    static let pillGlowPadding: CGFloat = 5
    // Subtitle floats above the pill and is capped at 3x the pill width.
    static let subtitleMaxWidth: CGFloat = pillWidth * 3
    static let containerWidth: CGFloat = subtitleMaxWidth
    static let containerHeight: CGFloat = 104
}

private enum OverlayAnimation {
    static let fadeInDuration: TimeInterval = 0.14
    static let fadeOutDuration: TimeInterval = 0.12
}

@MainActor
final class OverlayPanel {
    private let appState: AppState
    private var panel: NSPanel?
    private var animationGeneration = 0

    init(appState: AppState) {
        self.appState = appState
    }

    func show() {
        if panel == nil {
            let view = OverlayView(appState: appState)
            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(
                x: 0,
                y: 0,
                width: OverlayMetrics.containerWidth,
                height: OverlayMetrics.containerHeight
            )

            let panel = NSPanel(
                contentRect: hosting.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.contentView = hosting
            panel.isReleasedWhenClosed = false
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.ignoresMouseEvents = false
            self.panel = panel
        }

        guard let panel else { return }

        animationGeneration += 1
        panel.setContentSize(NSSize(width: OverlayMetrics.containerWidth, height: OverlayMetrics.containerHeight))
        positionPanel()
        guard shouldAnimate else {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            return
        }

        if !panel.isVisible {
            panel.alphaValue = 0
        }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = OverlayAnimation.fadeInDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }

        animationGeneration += 1
        let generation = animationGeneration
        guard shouldAnimate else {
            panel.orderOut(nil)
            panel.alphaValue = 1
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = OverlayAnimation.fadeOutDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self, weak panel] in
            Task { @MainActor in
                guard let self, let panel, self.panel === panel, self.animationGeneration == generation else { return }
                panel.orderOut(nil)
                panel.alphaValue = 1
            }
        }
    }

    private func positionPanel() {
        guard let panel else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let origin = NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 28)
        panel.setFrameOrigin(origin)
    }

    private var shouldAnimate: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

private struct OverlayView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(spacing: 8) {
            if let subtitle = subtitleText {
                if isMessageOnly {
                    SubtitleView(text: subtitle)
                        .frame(height: OverlayMetrics.pillHeight, alignment: .center)
                } else {
                    SubtitleView(text: subtitle)
                }
            }
            if !isMessageOnly {
                pill
            }
        }
        .frame(
            width: OverlayMetrics.containerWidth,
            height: OverlayMetrics.containerHeight,
            alignment: .bottom
        )
    }

    private var pill: some View {
        ZStack {
            Capsule()
                .stroke(Color.white.opacity(0.045), lineWidth: 3)
                .frame(width: OverlayMetrics.pillWidth + 4, height: OverlayMetrics.pillHeight + 4)
                .blur(radius: 2.5)

            HStack(spacing: 8) {
                Button(action: { appState.onCancelTapped?() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color.white.opacity(0.85))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.text(en: "Cancel (Esc)", zh: "取消 (Esc)"))

                WaveformView(levels: appState.audioLevels, isActive: appState.recordingState == .recording)
                    .frame(maxWidth: .infinity)

                if appState.recordingState == .starting {
                    ProcessingIndicatorView(accessibilityLabel: L10n.text(en: "Starting", zh: "准备中"))
                        .frame(width: 24, height: 24)
                } else if appState.recordingState == .stopping {
                    ProcessingIndicatorView(accessibilityLabel: L10n.text(en: "Processing", zh: "处理中"))
                        .frame(width: 24, height: 24)
                } else {
                    Button(action: { appState.onSubmitTapped?() }) {
                        ZStack {
                            Circle().fill(Color.white)
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.black)
                        }
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(L10n.text(en: "Submit (Enter)", zh: "提交 (Enter)"))
                }
            }
            .padding(.horizontal, 9)
            .frame(width: OverlayMetrics.pillWidth, height: OverlayMetrics.pillHeight)
            .background(.ultraThinMaterial, in: Capsule())
            .background(Color.black.opacity(0.82), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.18),
                                Color.white.opacity(0.055),
                                Color.white.opacity(0.1)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )

            Group {
                if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    BorderFlowLightView(phase: 0.18)
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                        BorderFlowLightView(phase: borderLightPhase(at: timeline.date))
                    }
                }
            }
            .frame(width: OverlayMetrics.pillWidth + 4, height: OverlayMetrics.pillHeight + 4)
            .allowsHitTesting(false)
        }
        .frame(
            width: OverlayMetrics.pillWidth + OverlayMetrics.pillGlowPadding * 2,
            height: OverlayMetrics.pillHeight + OverlayMetrics.pillGlowPadding * 2
        )
        .shadow(color: Color.white.opacity(0.03), radius: 4, x: 0, y: 0)
    }

    private func borderLightPhase(at date: Date) -> CGFloat {
        let duration: TimeInterval = 4.2
        let progress = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: duration) / duration
        return CGFloat(progress)
    }

    private var subtitleText: String? {
        if let error = appState.errorMessage, !error.isEmpty {
            return error
        }
        let transcript = appState.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return transcript.isEmpty ? nil : transcript
    }

    private var isMessageOnly: Bool {
        appState.recordingState == .idle && appState.errorMessage?.isEmpty == false
    }
}

private struct BorderFlowLightView: View {
    let phase: CGFloat

    var body: some View {
        Canvas { context, size in
            drawGlow(in: &context, size: size)
            drawCore(in: &context, size: size)
        }
        .allowsHitTesting(false)
    }

    private func drawGlow(in context: inout GraphicsContext, size: CGSize) {
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 1.2))
            drawSamples(
                in: &layer,
                size: size,
                sampleCount: 96,
                bandLength: 0.46,
                segmentLength: 0.012,
                baseLineWidth: 1.8,
                lineWidthBoost: 1.8,
                baseOpacity: 0.006,
                opacityBoost: 0.13,
                color: Color.cyan,
                falloff: 4.0
            )
        }
    }

    private func drawCore(in context: inout GraphicsContext, size: CGSize) {
        drawSamples(
            in: &context,
            size: size,
            sampleCount: 112,
            bandLength: 0.38,
            segmentLength: 0.01,
            baseLineWidth: 1.1,
            lineWidthBoost: 1.0,
            baseOpacity: 0.004,
            opacityBoost: 0.26,
            color: Color.white,
            falloff: 5.6
        )
    }

    private func drawSamples(
        in context: inout GraphicsContext,
        size: CGSize,
        sampleCount: Int,
        bandLength: CGFloat,
        segmentLength: CGFloat,
        baseLineWidth: CGFloat,
        lineWidthBoost: CGFloat,
        baseOpacity: Double,
        opacityBoost: Double,
        color: Color,
        falloff: Double
    ) {
        let middle = CGFloat(sampleCount - 1) / 2

        for index in 0..<sampleCount {
            let relative = (CGFloat(index) - middle) / middle
            let gaussian = exp(-Double(relative * relative) * falloff)
            let center = normalizedPhase(phase + relative * bandLength / 2)
            let startPoint = borderPoint(at: center - segmentLength / 2, size: size)
            let endPoint = borderPoint(at: center + segmentLength / 2, size: size)
            var path = Path()
            path.move(to: startPoint)
            path.addLine(to: endPoint)

            context.stroke(
                path,
                with: .color(color.opacity(baseOpacity + opacityBoost * gaussian)),
                style: StrokeStyle(
                    lineWidth: baseLineWidth + lineWidthBoost * CGFloat(gaussian),
                    lineCap: .round,
                    lineJoin: .round
                )
            )
        }
    }

    private func borderPoint(at phase: CGFloat, size: CGSize) -> CGPoint {
        let normalized = normalizedPhase(phase)
        let inset: CGFloat = 1
        let radius = max(1, (size.height - inset * 2) / 2)
        let top = inset
        let bottom = size.height - inset
        let centerY = size.height / 2
        let leftCenterX = inset + radius
        let rightCenterX = size.width - inset - radius
        let straightLength = max(0, rightCenterX - leftCenterX)
        let arcLength = CGFloat.pi * radius
        let perimeter = straightLength * 2 + arcLength * 2
        var distance = normalized * perimeter

        if distance <= straightLength {
            return CGPoint(x: rightCenterX - distance, y: top)
        }
        distance -= straightLength

        if distance <= arcLength {
            let angle = -CGFloat.pi / 2 - distance / radius
            return CGPoint(
                x: leftCenterX + cos(angle) * radius,
                y: centerY + sin(angle) * radius
            )
        }
        distance -= arcLength

        if distance <= straightLength {
            return CGPoint(x: leftCenterX + distance, y: bottom)
        }
        distance -= straightLength

        let angle = CGFloat.pi / 2 - distance / radius
        return CGPoint(
            x: rightCenterX + cos(angle) * radius,
            y: centerY + sin(angle) * radius
        )
    }

    private func normalizedPhase(_ value: CGFloat) -> CGFloat {
        let wrapped = value.truncatingRemainder(dividingBy: 1)
        return wrapped >= 0 ? wrapped : wrapped + 1
    }
}

private struct ProcessingIndicatorView: View {
    let accessibilityLabel: String
    @State private var rotation: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.18), lineWidth: 2)
            Circle()
                .trim(from: 0, to: 0.68)
                .stroke(
                    Color.white.opacity(0.88),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )
                .rotationEffect(.degrees(rotation))
        }
        .padding(4)
        .accessibilityLabel(accessibilityLabel)
        .onAppear {
            rotation = 0
            withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
    }
}

private struct SubtitleView: View {
    let text: String

    var body: some View {
        // Single line: head truncation keeps the newest tail visible while older
        // text scrolls off to the left.
        Text(text)
            .font(.system(size: 12, weight: .regular))
            .foregroundColor(.white)
            .lineLimit(1)
            .truncationMode(.head)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .frame(maxWidth: OverlayMetrics.subtitleMaxWidth)
            .transition(.opacity)
    }
}

private struct WaveformView: View {
    let levels: [Float]
    let isActive: Bool

    var body: some View {
        GeometryReader { geo in
            let count = max(levels.count, 1)
            let spacing: CGFloat = 2
            let barWidth = max(1.5, (geo.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(Color.white.opacity(isActive ? 0.95 : 0.45))
                        .frame(width: barWidth, height: barHeight(for: level, in: geo.size.height))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.18),
                        .init(color: .black, location: 0.82),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        }
        .frame(height: 20)
        .animation(.linear(duration: 0.08), value: levels)
    }

    private func barHeight(for level: Float, in maxHeight: CGFloat) -> CGFloat {
        let minHeight: CGFloat = 3
        let clamped = CGFloat(max(0, min(1, level)))
        return minHeight + clamped * (maxHeight - minHeight)
    }
}
