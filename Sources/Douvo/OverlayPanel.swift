import AppKit
import SwiftUI

private enum OverlayMetrics {
    static let pillHeight: CGFloat = 40
    static let pillGlowPadding: CGFloat = 5
    static let subtitleMinWidth: CGFloat = 200
    static let subtitleMaxWidth: CGFloat = 360
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

    static func borderGradient(tint: Color) -> LinearGradient {
        LinearGradient(
            colors: [
                Color.white.opacity(0.18),
                tint.opacity(0.07),
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
                .environment(\.colorScheme, .dark)
            let hosting = NSHostingView(rootView: view)
            hosting.appearance = NSAppearance(named: .darkAqua)
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
            panel.appearance = NSAppearance(named: .darkAqua)
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
    @AppStorage(OverlayAppearanceStore.showCancelControlKey) private var showCancelControl = true
    @AppStorage(OverlayAppearanceStore.showSubmitControlKey) private var showSubmitControl = true
    @AppStorage(OverlayAppearanceStore.showBorderLightKey) private var showBorderLight = true
    @AppStorage(OverlayAppearanceStore.sizeKey) private var overlaySizeRawValue = OverlayAppearanceStore.Size.large.rawValue
    @AppStorage(OverlayAppearanceStore.waveformStyleKey) private var waveformStyleRawValue = OverlayAppearanceStore.WaveformStyle.capsules.rawValue
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
        .onChange(of: overlaySizeRawValue) {
            appState.resetAudioLevels()
        }
    }

    private var pill: some View {
        ZStack {
            Capsule()
                .fill(Color.black.opacity(0.16))
                .frame(width: overlaySurfaceWidth + 2.4, height: overlaySurfaceHeight + 2.4)
                .blur(radius: 1.5)
                .allowsHitTesting(false)

            Capsule()
                .stroke(overlayTint.opacity(0.035), lineWidth: 1.4)
                .frame(width: overlaySurfaceWidth + 2.2, height: overlaySurfaceHeight + 2.2)
                .blur(radius: 3.2)
                .allowsHitTesting(false)

            Color.clear
                .frame(width: overlaySurfaceWidth, height: overlaySurfaceHeight)
                .overlaySurface(Capsule(), tint: overlayTint)

            Group {
                if isLoading {
                    spinnerOrPlaceholder(accessibilityLabel: loadingAccessibilityLabel)
                        .frame(width: overlaySurfaceWidth, height: overlaySurfaceHeight)
                        .transition(.opacity)
                } else {
                    HStack(spacing: overlayControlGap) {
                        if showCancelControl {
                            Button(action: { appState.onCancelTapped?() }) {
                                Image(systemName: "xmark")
                                    .font(.system(size: overlayControlIconSize + 1, weight: .bold))
                                    .foregroundColor(Color.white.opacity(0.76))
                                    .frame(width: overlayControlButtonSize, height: overlayControlButtonSize)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(L10n.text(en: "Cancel (Esc)", zh: "取消 (Esc)"))
                        }

                        WaveformView(
                            levels: appState.audioLevels,
                            isActive: appState.recordingState == .recording,
                            style: waveformStyle,
                            barWidth: overlaySize.waveformBarWidth,
                            maxHeight: overlayWaveformHeight
                        )
                            .frame(width: overlayWaveformWidth)

                        if showSubmitControl {
                            Button(action: { appState.onSubmitTapped?() }) {
                                Group {
                                    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                                        OverlayIconCircle(
                                            systemName: submitButtonSystemName,
                                            iconSize: submitButtonIconSize,
                                            iconWeight: .bold,
                                            isPrimary: true,
                                            sheenAngle: .degrees(70),
                                            diameter: overlayControlButtonSize,
                                            tint: overlayTint
                                        )
                                    } else {
                                        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                                            OverlayIconCircle(
                                                systemName: submitButtonSystemName,
                                                iconSize: submitButtonIconSize,
                                                iconWeight: .bold,
                                                isPrimary: true,
                                                sheenAngle: borderLightAngle(at: timeline.date),
                                                diameter: overlayControlButtonSize,
                                                tint: overlayTint
                                            )
                                        }
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .help(L10n.text(en: "Submit (Enter)", zh: "提交 (Enter)"))
                        }
                    }
                    .padding(.horizontal, overlayHorizontalPadding)
                    .frame(width: overlaySurfaceWidth, height: overlaySurfaceHeight)
                    .transition(.opacity)
                }
            }

            if showBorderLight {
                Group {
                    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                        BorderFlowLightView(angle: .degrees(70), tint: overlayTint)
                    } else {
                        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                            BorderFlowLightView(angle: borderLightAngle(at: timeline.date), tint: overlayTint)
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
        .animation(surfaceAnimation, value: isLoading)
        .animation(surfaceAnimation, value: overlaySizeRawValue)
        .animation(surfaceAnimation, value: waveformStyleRawValue)
        .animation(surfaceAnimation, value: showCancelControl)
        .animation(surfaceAnimation, value: showSubmitControl)
        .animation(surfaceAnimation, value: appState.overlayMode)
    }

    @ViewBuilder
    private func spinnerOrPlaceholder(accessibilityLabel: String) -> some View {
        if showSpinner {
            ProcessingIndicatorView(
                accessibilityLabel: accessibilityLabel,
                showsLightEffect: showBorderLight,
                tint: overlayTint
            )
                .frame(width: 20, height: 20)
                .transition(.opacity)
        } else {
            Color.clear
                .frame(width: 20, height: 20)
        }
    }

    private var overlayPillWidth: CGFloat {
        overlaySize.pillWidth
    }

    private var overlaySize: OverlayAppearanceStore.Size {
        OverlayAppearanceStore.Size(rawValue: overlaySizeRawValue) ?? .large
    }

    private var waveformStyle: OverlayAppearanceStore.WaveformStyle {
        OverlayAppearanceStore.WaveformStyle(rawValue: waveformStyleRawValue) ?? .capsules
    }

    private var overlayWaveformWidth: CGFloat {
        overlayPillWidth
    }

    private var overlayWaveformHeight: CGFloat {
        switch waveformStyle {
        case .ribbon:
            max(overlayControlButtonSize, overlaySurfaceHeight - 8)
        case .capsules, .dots:
            overlayControlButtonSize
        }
    }

    private var overlaySurfaceWidth: CGFloat {
        isLoading
            ? overlaySurfaceHeight
            : overlayWaveformWidth + overlayHorizontalPadding * 2 + overlayControlsWidth
    }

    private var overlaySurfaceHeight: CGFloat {
        overlaySize.pillHeight
    }

    private var overlayControlsWidth: CGFloat {
        let visibleControlCount = [showCancelControl, showSubmitControl].filter { $0 }.count
        guard visibleControlCount > 0 else { return 0 }
        return CGFloat(visibleControlCount) * overlayControlButtonSize
            + CGFloat(visibleControlCount) * overlayControlGap
    }

    private var overlayControlButtonSize: CGFloat {
        overlaySize.controlButtonSize
    }

    private var overlayControlIconSize: CGFloat {
        max(10, overlayControlButtonSize - 12)
    }

    private var overlayControlGap: CGFloat {
        overlaySize.controlGap
    }

    private var overlayHorizontalPadding: CGFloat {
        overlaySize.horizontalPadding
    }

    private var subtitleMaxWidth: CGFloat {
        min(max(overlaySurfaceWidth * 2, OverlayMetrics.subtitleMinWidth), OverlayMetrics.subtitleMaxWidth)
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

    private var submitButtonSystemName: String {
        switch appState.overlayMode {
        case .dictation:
            "checkmark"
        case .selectionEditing:
            "character.cursor.ibeam"
        case .translation:
            "translate"
        }
    }

    private var submitButtonIconSize: CGFloat {
        let baseSize = overlayControlIconSize + 1
        return switch appState.overlayMode {
        case .dictation:
            baseSize
        case .selectionEditing:
            max(9, baseSize - 2)
        case .translation:
            max(8, baseSize - 4)
        }
    }

    private var overlayTint: Color {
        switch appState.overlayMode {
        case .dictation:
            .cyan
        case .selectionEditing:
            .purple
        case .translation:
            .green
        }
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
    var diameter: CGFloat = 24
    var tint: Color = .cyan

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
                                .init(color: tint.opacity(0.10), location: 0.38),
                                .init(color: Color.white.opacity(0.18), location: 0.50),
                                .init(color: tint.opacity(0.08), location: 0.62),
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
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
    }
}

private struct BorderFlowLightView: View {
    let angle: Angle
    let tint: Color

    var body: some View {
        ZStack {
            Capsule()
                .strokeBorder(glowGradient.opacity(0.5), lineWidth: 4)
                .blur(radius: 1.3)

            Capsule()
                .inset(by: 0.7)
                .strokeBorder(innerGlowGradient, lineWidth: 1.8)
                .blur(radius: 0.75)
                .opacity(0.82)

            Capsule()
                .strokeBorder(coreGradient, lineWidth: 1.15)
        }
        .compositingGroup()
        .blendMode(.screen)
        .clipShape(Capsule(), style: FillStyle(antialiased: true))
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
                cyan: 0.16,
                white: 0.32
            ),
            center: .center,
            angle: angle
        )
    }

    private var innerGlowGradient: AngularGradient {
        AngularGradient(
            stops: gradientStops(
                base: 0.01,
                cyan: 0.15,
                white: 0.28
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
            .init(color: tint.opacity(cyan * 0.55), location: 0.30),
            .init(color: tint.opacity(cyan), location: 0.40),
            .init(color: Color.white.opacity(white), location: 0.50),
            .init(color: tint.opacity(cyan), location: 0.60),
            .init(color: tint.opacity(cyan * 0.55), location: 0.70),
            .init(color: Color.white.opacity(base), location: 0.82),
            .init(color: Color.white.opacity(base), location: 1.00)
        ]
    }
}

private struct ProcessingIndicatorView: View {
    let accessibilityLabel: String
    let showsLightEffect: Bool
    let tint: Color
    @State private var rotation: Double = 0
    @State private var pulse = false

    var body: some View {
        ZStack {
            if showsLightEffect {
                Circle()
                    .stroke(tint.opacity(0.12), lineWidth: 1.4)
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
                        .init(color: tint.opacity(0.26), location: 0.42),
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
    let tint: Color

    func body(content: Content) -> some View {
        content
            .background {
                shape
                    .fill(.ultraThinMaterial, style: FillStyle(antialiased: true))

                shape
                    .fill(Color.black.opacity(backgroundOpacity), style: FillStyle(antialiased: true))
            }
            .overlay(
                ZStack {
                    shape
                        .inset(by: 0.5)
                        .strokeBorder(Color.white.opacity(0.035), lineWidth: 1)
                        .blur(radius: 0.45)

                    shape
                        .strokeBorder(OverlaySurfaceStyle.borderGradient(tint: tint), lineWidth: 1, antialiased: true)
                }
            )
    }
}

private extension View {
    func overlaySurface<SurfaceShape: InsettableShape>(
        _ shape: SurfaceShape,
        backgroundOpacity: Double = OverlaySurfaceStyle.backgroundOpacity,
        tint: Color = Color.cyan
    ) -> some View {
        modifier(OverlaySurfaceModifier(shape: shape, backgroundOpacity: backgroundOpacity, tint: tint))
    }
}

private struct WaveformView: View {
    let levels: [Float]
    let isActive: Bool
    let style: OverlayAppearanceStore.WaveformStyle
    let barWidth: CGFloat
    let maxHeight: CGFloat

    var body: some View {
        let samples = WaveformSamples(levels: levels, isActive: isActive)
        GeometryReader { geo in
            switch style {
            case .capsules:
                capsuleBars(in: geo.size, samples: samples)
            case .dots:
                dotMatrix(in: geo.size, samples: samples)
            case .ribbon:
                if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    ios9Wave(in: geo.size, samples: samples, phase: 0)
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                        let phase = CGFloat(timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 12))
                        ios9Wave(in: geo.size, samples: samples, phase: phase)
                    }
                }
            }
        }
        .frame(height: maxHeight)
        .mask(waveformEdgeFade)
        .animation(.linear(duration: 0.025), value: levels)
    }

    private func dynamicSpacing(for width: CGFloat, itemWidth: CGFloat, sampleCount: Int) -> CGFloat {
        let count = max(sampleCount, 1)
        let availableSpacing = count > 1
            ? (width - itemWidth * CGFloat(count)) / CGFloat(count - 1)
            : 0
        return max(2, min(5, availableSpacing))
    }

    private func capsuleBars(in size: CGSize, samples: WaveformSamples) -> some View {
        let spacing = dynamicSpacing(for: size.width, itemWidth: barWidth, sampleCount: samples.count)
        return HStack(alignment: .center, spacing: spacing) {
            ForEach(Array(samples.levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(Color.white.opacity(samples.hasSound ? 0.96 : 0.42))
                    .frame(width: barWidth, height: barHeight(for: level, in: size.height, samples: samples))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .center)
    }

    private func dotMatrix(in size: CGSize, samples: WaveformSamples) -> some View {
        let dotRows = 7
        let verticalGap = min(1.25, max(0.8, size.height / 22))
        let dotSize = max(1.5, min(2.4, (size.height - verticalGap * CGFloat(dotRows - 1)) / CGFloat(dotRows)))
        let columnCount = dotColumnCount(for: samples)
        let horizontalGap = dotHorizontalGap(width: size.width, dotSize: dotSize, columnCount: columnCount)
        return HStack(alignment: .center, spacing: horizontalGap) {
            ForEach(0..<columnCount, id: \.self) { column in
                let level = samples.level(at: column, count: columnCount)
                VStack(spacing: verticalGap) {
                    ForEach(0..<dotRows, id: \.self) { row in
                        Circle()
                            .fill(Color.white.opacity(dotOpacity(row: row, rowCount: dotRows, level: level, samples: samples)))
                            .frame(width: dotSize, height: dotSize)
                    }
                }
                .frame(width: dotSize, height: size.height, alignment: .center)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .center)
    }

    private func dotColumnCount(for samples: WaveformSamples) -> Int {
        max(1, Int((CGFloat(samples.count) * 1.5).rounded()))
    }

    private func dotHorizontalGap(width: CGFloat, dotSize: CGFloat, columnCount: Int) -> CGFloat {
        guard columnCount > 1 else { return 0 }
        let availableSpacing = (width - dotSize * CGFloat(columnCount)) / CGFloat(columnCount - 1)
        return max(0.9, min(2.4, availableSpacing))
    }

    private func ios9Wave(in size: CGSize, samples: WaveformSamples, phase: CGFloat) -> some View {
        let supportHeight = max(0.7, barWidth * 0.26)
        return ZStack {
            Capsule()
                .fill(ios9SupportLineFill(samples: samples))
                .frame(height: supportHeight)

            ForEach(Array(IOS9WaveLayer.layers.enumerated()), id: \.offset) { _, layer in
                ForEach([-1.0, 1.0], id: \.self) { sign in
                    IOS9WaveFillShape(
                        samples: samples,
                        sign: CGFloat(sign),
                        phase: phase,
                        layer: layer
                    )
                    .fill(layer.color.opacity(samples.hasSound ? layer.opacity : layer.opacity * 0.34))
                    .blendMode(.plusLighter)
                }
            }

            Circle()
                .fill(Color.white.opacity(samples.hasSound ? 0.22 : 0.10))
                .frame(width: supportHeight * 2.1, height: supportHeight * 2.1)
                .blur(radius: 1.0)
                .blendMode(.screen)
        }
        .frame(width: size.width, height: size.height, alignment: .center)
        .compositingGroup()
    }

    private func barHeight(for level: CGFloat, in maxHeight: CGFloat, samples: WaveformSamples) -> CGFloat {
        guard samples.hasSound else { return barWidth }
        let eased = pow(level, 0.78)
        return barWidth + eased * (maxHeight - barWidth)
    }

    private func dotOpacity(row: Int, rowCount: Int, level: CGFloat, samples: WaveformSamples) -> Double {
        let midpoint = CGFloat(rowCount - 1) / 2
        let distance = abs(CGFloat(row) - midpoint) / max(midpoint, 1)
        let isCenterRow = row == Int(midpoint.rounded())

        guard samples.hasSound else {
            return isCenterRow ? 0.48 : 0
        }

        let band = 0.08 + pow(level, 0.70) * 0.92
        let edgeWidth: CGFloat = 0.18
        let coverage = 1 - smoothstep(edge0: band, edge1: band + edgeWidth, x: distance)
        let baseline = isCenterRow ? 0.62 : 0
        guard coverage > 0.001 else {
            return baseline
        }

        let rowFalloff = 1 - distance * 0.28
        return Double(max(baseline, min(0.98, 0.36 + coverage * rowFalloff * 0.62)))
    }

    private func smoothstep(edge0: CGFloat, edge1: CGFloat, x: CGFloat) -> CGFloat {
        guard edge0 != edge1 else { return x < edge0 ? 0 : 1 }
        let t = max(0, min(1, (x - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }

    private func ios9SupportLineFill(samples: WaveformSamples) -> LinearGradient {
        LinearGradient(
            stops: [
                .init(color: Color.white.opacity(0), location: 0.00),
                .init(color: Color.white.opacity(samples.hasSound ? 0.08 : 0.04), location: 0.18),
                .init(color: Color.white.opacity(samples.hasSound ? 0.22 : 0.10), location: 0.50),
                .init(color: Color.white.opacity(samples.hasSound ? 0.08 : 0.04), location: 0.82),
                .init(color: Color.white.opacity(0), location: 1.00)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var waveformEdgeFade: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0.00),
                .init(color: .black.opacity(0.45), location: 0.035),
                .init(color: .black, location: 0.075),
                .init(color: .black, location: 0.925),
                .init(color: .black.opacity(0.45), location: 0.965),
                .init(color: .clear, location: 1.00)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

private struct WaveformSamples {
    let levels: [CGFloat]
    let hasSound: Bool
    let peak: CGFloat
    let average: CGFloat

    var count: Int {
        levels.count
    }

    var globalLevel: CGFloat {
        min(1, peak * 0.98 + average * 0.62)
    }

    init(levels: [Float], isActive: Bool) {
        let clampedLevels = levels.map { CGFloat(max(0, min(1, $0))) }
        self.levels = clampedLevels
        self.peak = clampedLevels.max() ?? 0
        self.average = clampedLevels.reduce(0, +) / CGFloat(max(clampedLevels.count, 1))
        self.hasSound = isActive && peak > 0.001
    }

    func level(at column: Int, count columnCount: Int) -> CGFloat {
        guard columnCount > 1 else { return levels.first ?? 0 }
        let progress = CGFloat(column) / CGFloat(columnCount - 1)
        return level(at: progress)
    }

    func level(at progress: CGFloat) -> CGFloat {
        guard let firstLevel = levels.first else { return 0 }
        guard levels.count > 1 else { return firstLevel }

        let clampedProgress = max(0, min(1, progress))
        let scaledIndex = clampedProgress * CGFloat(levels.count - 1)
        let lowerIndex = min(levels.count - 1, max(0, Int(floor(scaledIndex))))
        let upperIndex = min(levels.count - 1, lowerIndex + 1)
        let fraction = scaledIndex - CGFloat(lowerIndex)
        let lowerValue = levels[lowerIndex]
        let upperValue = levels[upperIndex]
        return lowerValue + (upperValue - lowerValue) * fraction
    }
}

private struct IOS9WaveLayer {
    let color: Color
    let opacity: Double
    let amplitude: CGFloat
    let curves: [IOS9WaveCurve]

    static let layers = [
        IOS9WaveLayer(
            color: Color(red: 0.08, green: 0.38, blue: 1.00),
            opacity: 0.58,
            amplitude: 1.10,
            curves: [
                IOS9WaveCurve(offset: 0.2, width: 3.8, speed: 0.58, verse: -1, finalAmplitude: 0.92)
            ]
        ),
        IOS9WaveLayer(
            color: Color(red: 1.00, green: 0.22, blue: 0.42),
            opacity: 0.36,
            amplitude: 0.88,
            curves: [
                IOS9WaveCurve(offset: -1.35, width: 4.35, speed: 0.68, verse: 1, finalAmplitude: 0.74)
            ]
        ),
        IOS9WaveLayer(
            color: Color(red: 0.18, green: 1.00, blue: 0.66),
            opacity: 0.44,
            amplitude: 0.94,
            curves: [
                IOS9WaveCurve(offset: 1.15, width: 4.05, speed: 0.52, verse: 1, finalAmplitude: 0.78)
            ]
        )
    ]
}

private struct IOS9WaveCurve {
    let offset: CGFloat
    let width: CGFloat
    let speed: CGFloat
    let verse: CGFloat
    let finalAmplitude: CGFloat
}

private struct IOS9WaveFillShape: Shape {
    let samples: WaveformSamples
    let sign: CGFloat
    let phase: CGFloat
    let layer: IOS9WaveLayer

    private let graphX: CGFloat = 9.5
    private let attenuationFactor: CGFloat = 4
    private let amplitudeFactor: CGFloat = 1.08

    func path(in rect: CGRect) -> Path {
        guard rect.width > 0, rect.height > 0 else { return Path() }

        let sampleCount = 56
        let verticalInset = max(3, rect.height * 0.14)
        let drawingRect = rect.insetBy(dx: 0, dy: verticalInset)
        let baseY = drawingRect.midY
        var path = Path()
        path.move(to: CGPoint(x: drawingRect.minX, y: baseY))

        for step in 0...sampleCount {
            let progress = CGFloat(step) / CGFloat(sampleCount)
            let i = -graphX + progress * graphX * 2
            let x = drawingRect.minX + drawingRect.width * progress
            let y = yPosition(i: i, progress: progress, maxHeight: drawingRect.height / 2)
            path.addLine(to: CGPoint(x: x, y: baseY - sign * y))
        }

        path.addLine(to: CGPoint(x: drawingRect.maxX, y: baseY))
        path.closeSubpath()
        return path
    }

    private func yPosition(i: CGFloat, progress: CGFloat, maxHeight: CGFloat) -> CGFloat {
        let visualAmplitude = samples.hasSound ? max(0.22, pow(samples.globalLevel, 0.58) * 1.22) : 0.08
        let y = amplitudeFactor
            * maxHeight
            * visualAmplitude
            * layer.amplitude
            * yRelativePosition(i: i)
            * globalAttenuation((i / graphX) * 0.95)
            * spatialEnvelope(at: progress)
        return softLimited(y, limit: maxHeight * 0.72)
    }

    private func yRelativePosition(i: CGFloat) -> CGFloat {
        let curves = layer.curves
        var y: CGFloat = 0

        for curve in curves {
            let x = i / curve.width - curve.offset
            let movingPhase = phase * curve.speed * 3.0
            y += abs(curve.finalAmplitude * sin(Double(curve.verse * x - movingPhase)) * globalAttenuation(x))
        }

        return y / CGFloat(max(curves.count, 1))
    }

    private func spatialEnvelope(at progress: CGFloat) -> CGFloat {
        guard samples.count > 1 else { return 1 }
        let interpolated = samples.level(at: progress)
        return max(0.84, 0.98 + interpolated * 0.20)
    }

    private func softLimited(_ value: CGFloat, limit: CGFloat) -> CGFloat {
        guard limit > 0 else { return 0 }
        let normalized = max(0, value / limit)
        return limit * normalized / pow(1 + pow(normalized, 2.2), 1 / 2.2)
    }

    private func globalAttenuation(_ x: CGFloat) -> CGFloat {
        pow(attenuationFactor / (attenuationFactor + pow(x, 2)), attenuationFactor)
    }
}
