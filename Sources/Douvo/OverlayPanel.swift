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

@MainActor
final class OverlayPanel {
    private let appState: AppState
    private var panel: NSPanel?

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

        panel?.setContentSize(NSSize(width: OverlayMetrics.containerWidth, height: OverlayMetrics.containerHeight))
        positionPanel()
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func positionPanel() {
        guard let panel else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let origin = NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 28)
        panel.setFrameOrigin(origin)
    }
}

private struct OverlayView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(spacing: 8) {
            if let subtitle = subtitleText {
                SubtitleView(text: subtitle)
            }
            pill
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

            if appState.recordingState == .starting || appState.recordingState == .stopping {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
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
