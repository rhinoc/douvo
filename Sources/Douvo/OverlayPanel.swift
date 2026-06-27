import AppKit
import SwiftUI

private enum OverlayMetrics {
    static let pillWidth: CGFloat = 150
    static let pillHeight: CGFloat = 40
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
        HStack(spacing: 10) {
            Button(action: { appState.onCancelTapped?() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.85))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("取消 (Esc)")

            WaveformView(levels: appState.audioLevels, isActive: appState.recordingState == .recording)
                .frame(maxWidth: .infinity)

            if appState.recordingState == .starting {
                ProcessingIndicatorView(accessibilityLabel: "准备中")
                    .frame(width: 24, height: 24)
            } else if appState.recordingState == .stopping {
                ProcessingIndicatorView(accessibilityLabel: "处理中")
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
                .help("提交 (Enter)")
            }
        }
        .padding(.horizontal, 10)
        .frame(width: OverlayMetrics.pillWidth, height: OverlayMetrics.pillHeight)
        .background(Color.black.opacity(0.62), in: Capsule())
        .overlay(
            Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
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
