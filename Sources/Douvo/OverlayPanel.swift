import AppKit
import SwiftUI

private enum OverlayMetrics {
    static let maxPillWidth: CGFloat = 120
    static let pillHeight: CGFloat = 40
    static let pillGlowPadding: CGFloat = 5
    // Subtitle floats above the pill and is capped at 3x the pill width.
    static let subtitleMaxWidth: CGFloat = maxPillWidth * 3
    static let containerWidth: CGFloat = subtitleMaxWidth
    static let containerHeight: CGFloat = 104
}

private enum OverlayAnimation {
    static let fadeInDuration: TimeInterval = 0.14
    static let fadeOutDuration: TimeInterval = 0.12
    static let contentFadeDuration: TimeInterval = 0.14
}

private enum OverlaySurfaceStyle {
    static let backgroundOpacity = 0.9

    static var borderGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color.white.opacity(0.18),
                Color.white.opacity(0.055),
                Color.white.opacity(0.1)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
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
    @AppStorage(OverlayAppearanceStore.showControlsKey) private var showControls = true
    @AppStorage(OverlayAppearanceStore.showBorderLightKey) private var showBorderLight = true
    @AppStorage(OverlayAppearanceStore.sizeKey) private var overlaySizeRawValue = OverlayAppearanceStore.Size.large.rawValue
    @State private var showSpinner = false
    @State private var spinnerGeneration = 0

    var body: some View {
        VStack(spacing: 8) {
            if isMessageOnly {
                if let subtitle = subtitleText {
                    SubtitleView(text: subtitle, maxWidth: subtitleMaxWidth)
                        .frame(height: pillOuterHeight, alignment: .center)
                        .id("message-subtitle")
                        .transition(.opacity)
                }
            } else {
                if let subtitle = subtitleText {
                    SubtitleView(text: subtitle, maxWidth: subtitleMaxWidth)
                        .id("live-subtitle")
                        .transition(.opacity)
                }
                pill
                    .transition(.opacity)
            }
        }
        .frame(
            width: OverlayMetrics.containerWidth,
            height: OverlayMetrics.containerHeight,
            alignment: .bottom
        )
        .animation(contentFadeAnimation, value: hasSubtitle)
        .animation(contentFadeAnimation, value: isMessageOnly)
        .onAppear {
            scheduleSpinnerVisibility(for: appState.recordingState)
        }
        .onChange(of: appState.recordingState) { _, newValue in
            scheduleSpinnerVisibility(for: newValue)
        }
    }

    private var pill: some View {
        ZStack {
            Capsule()
                .stroke(Color.white.opacity(0.045), lineWidth: 3)
                .frame(width: overlaySurfaceWidth + 4, height: overlaySurfaceHeight + 4)
                .blur(radius: 2.5)

            Color.clear
                .frame(width: overlaySurfaceWidth, height: overlaySurfaceHeight)
                .overlaySurface(Capsule())

            Group {
                if isLoading {
                    spinnerOrPlaceholder(accessibilityLabel: loadingAccessibilityLabel)
                        .frame(width: overlaySurfaceWidth, height: overlaySurfaceHeight)
                        .transition(.opacity)
                } else {
                    HStack(spacing: 8) {
                        if showControls {
                            Button(action: { appState.onCancelTapped?() }) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(Color.white.opacity(0.76))
                                    .frame(width: 24, height: 24)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(L10n.text(en: "Cancel (Esc)", zh: "取消 (Esc)"))
                        }

                        WaveformView(levels: appState.audioLevels, isActive: appState.recordingState == .recording)
                            .frame(maxWidth: .infinity)

                        if showControls {
                            Button(action: { appState.onSubmitTapped?() }) {
                                Group {
                                    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                                        OverlayIconCircle(systemName: "checkmark", iconSize: 13, iconWeight: .bold, isPrimary: true, sheenAngle: .degrees(70))
                                    } else {
                                        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                                            OverlayIconCircle(systemName: "checkmark", iconSize: 13, iconWeight: .bold, isPrimary: true, sheenAngle: borderLightAngle(at: timeline.date))
                                        }
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .help(L10n.text(en: "Submit (Enter)", zh: "提交 (Enter)"))
                        }
                    }
                    .padding(.horizontal, 9)
                    .frame(width: overlaySurfaceWidth, height: overlaySurfaceHeight)
                    .transition(.opacity)
                }
            }

            if showBorderLight {
                Group {
                    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                        BorderFlowLightView(angle: .degrees(70))
                    } else {
                        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                            BorderFlowLightView(angle: borderLightAngle(at: timeline.date))
                        }
                    }
                }
                .frame(width: overlaySurfaceWidth, height: overlaySurfaceHeight)
                .allowsHitTesting(false)
            }
        }
        .frame(
            width: overlaySurfaceWidth + OverlayMetrics.pillGlowPadding * 2,
            height: overlaySurfaceHeight + OverlayMetrics.pillGlowPadding * 2
        )
        .shadow(color: Color.white.opacity(0.03), radius: 4, x: 0, y: 0)
        .animation(surfaceAnimation, value: isLoading)
        .animation(surfaceAnimation, value: overlaySizeRawValue)
    }

    @ViewBuilder
    private func spinnerOrPlaceholder(accessibilityLabel: String) -> some View {
        if showSpinner {
            ProcessingIndicatorView(
                accessibilityLabel: accessibilityLabel,
                showsLightEffect: showBorderLight
            )
                .frame(width: 20, height: 20)
                .transition(.opacity)
        } else {
            Color.clear
                .frame(width: 20, height: 20)
        }
    }

    private var overlayPillWidth: CGFloat {
        (OverlayAppearanceStore.Size(rawValue: overlaySizeRawValue) ?? .large).pillWidth
    }

    private var overlaySurfaceWidth: CGFloat {
        isLoading ? OverlayMetrics.pillHeight : overlayPillWidth
    }

    private var overlaySurfaceHeight: CGFloat {
        OverlayMetrics.pillHeight
    }

    private var subtitleMaxWidth: CGFloat {
        overlayPillWidth * 3
    }

    private var pillOuterHeight: CGFloat {
        OverlayMetrics.pillHeight + OverlayMetrics.pillGlowPadding * 2
    }

    private var isLoading: Bool {
        appState.recordingState == .starting || appState.recordingState == .stopping
    }

    private var loadingAccessibilityLabel: String {
        appState.recordingState == .starting
            ? L10n.text(en: "Starting", zh: "准备中")
            : L10n.text(en: "Processing", zh: "处理中")
    }

    private func borderLightAngle(at date: Date) -> Angle {
        let duration: TimeInterval = 5.2
        let progress = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: duration) / duration
        return .degrees(progress * 360)
    }

    private func scheduleSpinnerVisibility(for state: RecordingState) {
        spinnerGeneration += 1
        let generation = spinnerGeneration

        guard state == .starting || state == .stopping else {
            showSpinner = false
            return
        }

        showSpinner = false
        let delay = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : OverlayAnimation.fadeInDuration
        Task { @MainActor in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard spinnerGeneration == generation else { return }
            guard appState.recordingState == state else { return }
            withAnimation(.easeInOut(duration: 0.08)) {
                showSpinner = true
            }
        }
    }

    private var subtitleText: String? {
        if let error = appState.errorMessage, !error.isEmpty {
            return error
        }
        let transcript = appState.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return transcript.isEmpty ? nil : transcript
    }

    private var hasSubtitle: Bool {
        subtitleText != nil
    }

    private var isMessageOnly: Bool {
        appState.recordingState == .idle && appState.errorMessage?.isEmpty == false
    }

    private var contentFadeAnimation: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? nil
            : .easeInOut(duration: OverlayAnimation.contentFadeDuration)
    }

    private var surfaceAnimation: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? nil
            : .spring(response: 0.28, dampingFraction: 0.86)
    }
}

private struct OverlayIconCircle: View {
    let systemName: String
    let iconSize: CGFloat
    let iconWeight: Font.Weight
    var isPrimary = false
    var sheenAngle: Angle?

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(isPrimary ? 0.18 : 0.08))

            if let sheenAngle {
                Circle()
                    .fill(
                        AngularGradient(
                            stops: [
                                .init(color: Color.white.opacity(0.02), location: 0.00),
                                .init(color: Color.cyan.opacity(0.10), location: 0.38),
                                .init(color: Color.white.opacity(0.18), location: 0.50),
                                .init(color: Color.cyan.opacity(0.08), location: 0.62),
                                .init(color: Color.white.opacity(0.02), location: 1.00)
                            ],
                            center: .center,
                            angle: sheenAngle
                        )
                    )
                    .opacity(0.72)
                    .blendMode(.screen)
            }

            Image(systemName: systemName)
                .font(.system(size: iconSize, weight: iconWeight))
                .foregroundColor(Color.white.opacity(isPrimary ? 0.96 : 0.82))
        }
        .frame(width: 24, height: 24)
        .contentShape(Circle())
    }
}

private struct BorderFlowLightView: View {
    let angle: Angle

    var body: some View {
        ZStack {
            Capsule()
                .strokeBorder(glowGradient.opacity(0.5), lineWidth: 4)
                .blur(radius: 1.3)

            Capsule()
                .strokeBorder(coreGradient, lineWidth: 1.15)
        }
        .compositingGroup()
        .blendMode(.screen)
        .allowsHitTesting(false)
    }

    private var glowGradient: AngularGradient {
        AngularGradient(
            stops: gradientStops(
                base: 0.02,
                cyan: 0.1,
                white: 0.18
            ),
            center: .center,
            angle: angle
        )
    }

    private var coreGradient: AngularGradient {
        AngularGradient(
            stops: gradientStops(
                base: 0.035,
                cyan: 0.14,
                white: 0.26
            ),
            center: .center,
            angle: angle
        )
    }

    private func gradientStops(
        base: Double,
        cyan: Double,
        white: Double
    ) -> [Gradient.Stop] {
        [
            .init(color: Color.white.opacity(base), location: 0.00),
            .init(color: Color.white.opacity(base), location: 0.18),
            .init(color: Color.cyan.opacity(cyan * 0.55), location: 0.30),
            .init(color: Color.cyan.opacity(cyan), location: 0.40),
            .init(color: Color.white.opacity(white), location: 0.50),
            .init(color: Color.cyan.opacity(cyan), location: 0.60),
            .init(color: Color.cyan.opacity(cyan * 0.55), location: 0.70),
            .init(color: Color.white.opacity(base), location: 0.82),
            .init(color: Color.white.opacity(base), location: 1.00)
        ]
    }
}

private struct ProcessingIndicatorView: View {
    let accessibilityLabel: String
    let showsLightEffect: Bool
    @State private var rotation: Double = 0
    @State private var pulse = false

    var body: some View {
        ZStack {
            if showsLightEffect {
                Circle()
                    .stroke(Color.cyan.opacity(0.12), lineWidth: 1.4)
                    .blur(radius: 2)
                    .scaleEffect(pulse ? 1.02 : 0.86)
                    .opacity(pulse ? 0.46 : 0.18)
            }

            Circle()
                .trim(from: 0, to: showsLightEffect ? 0.68 : 0.58)
                .stroke(spinnerStroke, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                .rotationEffect(.degrees(rotation))
        }
        .accessibilityLabel(accessibilityLabel)
        .onAppear {
            rotation = 0
            pulse = false
            withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                rotation = 360
            }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private var spinnerStroke: AnyShapeStyle {
        if showsLightEffect {
            AnyShapeStyle(
                AngularGradient(
                    stops: [
                        .init(color: Color.white.opacity(0), location: 0),
                        .init(color: Color.cyan.opacity(0.26), location: 0.42),
                        .init(color: Color.white.opacity(0.5), location: 0.72),
                        .init(color: Color.white.opacity(0), location: 1)
                    ],
                    center: .center
                )
            )
        } else {
            AnyShapeStyle(Color.white.opacity(0.86))
        }
    }
}

private struct SubtitleView: View {
    let text: String
    let maxWidth: CGFloat

    var body: some View {
        // Single line: head truncation keeps the newest tail visible while older
        // text scrolls off to the left.
        Text(text)
            .font(.system(size: 12, weight: .regular))
            .foregroundColor(Color.white.opacity(0.9))
            .lineLimit(1)
            .truncationMode(.head)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .overlaySurface(RoundedRectangle(cornerRadius: 10, style: .continuous), backgroundOpacity: 0.6)
            .frame(maxWidth: maxWidth)
            .transition(.opacity)
    }
}

private struct OverlaySurfaceModifier<SurfaceShape: InsettableShape>: ViewModifier {
    let shape: SurfaceShape
    let backgroundOpacity: Double

    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: shape)
            .background(Color.black.opacity(backgroundOpacity), in: shape)
            .overlay(
                shape.stroke(OverlaySurfaceStyle.borderGradient, lineWidth: 1)
            )
    }
}

private extension View {
    func overlaySurface<SurfaceShape: InsettableShape>(
        _ shape: SurfaceShape,
        backgroundOpacity: Double = OverlaySurfaceStyle.backgroundOpacity
    ) -> some View {
        modifier(OverlaySurfaceModifier(shape: shape, backgroundOpacity: backgroundOpacity))
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
