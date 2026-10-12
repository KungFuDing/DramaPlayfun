import SwiftUI
import AVFoundation

/// Shared by the theater feed and the episode player. The track stays thin,
/// while its 44-point control handles touches above and below the visible line.
struct PlaybackProgressBar: View {
    let playback: TheaterPlayerPool
    let itemID: TheaterFeedItem.ID
    let isActive: Bool
    let identifier: String

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.5,
            paused: !isActive || playback.states[itemID] != .ready || playback.isPaused ||
                playback.isScrubbing || playback.isBuffering || playback.hasEnded)) { _ in
            let player = playback.player(for: itemID)
            let duration = player?.currentItem?.duration.seconds ?? 0
            let seconds = player?.currentTime().seconds ?? 0
            let validDuration = duration.isFinite && duration > 0
            let fraction = validDuration && seconds.isFinite ? min(max(seconds / duration, 0), 1) : 0
            ProgressSlider(fraction: fraction,
                isEnabled: isActive && validDuration && playback.states[itemID] == .ready,
                preservesPreview: playback.isScrubbing, identifier: identifier,
                onBegin: { playback.beginScrubbing(itemID) },
                onEnd: { playback.endScrubbing(itemID, fraction: $0) },
                onCancel: { playback.cancelScrubbing(itemID) })
        }
        .frame(height: 44)
        // Keep the full control above the track without reserving that space
        // between the track and the drama information.
        .padding(.top, -30)
        .onChange(of: isActive) { _, active in
            if !active { playback.cancelScrubbing(itemID) }
        }
        .onDisappear { playback.cancelScrubbing(itemID) }
    }
}

private struct ProgressSlider: UIViewRepresentable {
    let fraction: Double
    let isEnabled: Bool
    let preservesPreview: Bool
    let identifier: String
    let onBegin: () -> Bool
    let onEnd: (Double) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ScrubbingSlider {
        let slider = ScrubbingSlider()
        slider.minimumValue = 0
        slider.maximumValue = 1
        slider.minimumTrackTintColor = UIColor(Theme.accent)
        slider.maximumTrackTintColor = .white.withAlphaComponent(0.25)
        slider.accessibilityLabel = "播放进度"
        slider.accessibilityIdentifier = identifier
        slider.addTarget(context.coordinator, action: #selector(Coordinator.begin), for: .touchDown)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.end), for: [.touchUpInside, .touchUpOutside])
        slider.addTarget(context.coordinator, action: #selector(Coordinator.cancel), for: .touchCancel)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.adjust), for: .primaryActionTriggered)
        return slider
    }

    func updateUIView(_ slider: ScrubbingSlider, context: Context) {
        context.coordinator.parent = self
        slider.isEnabled = isEnabled
        if !slider.isScrubbing && !preservesPreview { slider.setValue(Float(fraction), animated: false) }
        if !isEnabled && slider.isScrubbing { slider.cancelTracking(with: nil) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ScrubbingSlider, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 44, height: 44)
    }

    @MainActor final class Coordinator: NSObject {
        var parent: ProgressSlider
        init(_ parent: ProgressSlider) { self.parent = parent }

        @objc func begin(_ slider: ScrubbingSlider) {
            if !parent.onBegin() { slider.cancelTracking(with: nil) }
        }
        @objc func end(_ slider: ScrubbingSlider) { parent.onEnd(Double(slider.value)) }
        @objc func cancel(_ slider: ScrubbingSlider) { parent.onCancel() }
        @objc func adjust(_ slider: ScrubbingSlider) {
            if parent.onBegin() { parent.onEnd(Double(slider.value)) }
        }
    }
}

private final class ScrubbingSlider: UISlider {
    private(set) var isScrubbing = false
    private let smallThumb = ScrubbingSlider.thumb(diameter: 6)
    private let largeThumb = ScrubbingSlider.thumb(diameter: 18)

    override init(frame: CGRect) {
        super.init(frame: frame)
        setThumbImage(smallThumb, for: .normal)
        setThumbImage(largeThumb, for: .highlighted)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func trackRect(forBounds bounds: CGRect) -> CGRect {
        let height: CGFloat = isScrubbing ? 6 : 2
        return CGRect(x: 0, y: bounds.maxY - 10 - height / 2, width: bounds.width, height: height)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isEnabled, let touch = touches.first else { return }
        setScrubbing(true)
        move(to: touch.location(in: self))
        sendActions(for: .touchDown)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isScrubbing, let touch = touches.first else { return }
        move(to: touch.location(in: self))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isScrubbing else { return }
        if let touch = touches.first { move(to: touch.location(in: self)) }
        setScrubbing(false)
        sendActions(for: .touchUpInside)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        cancelTracking(with: event)
    }

    override func cancelTracking(with event: UIEvent?) {
        guard isScrubbing else { return }
        setScrubbing(false)
        sendActions(for: .touchCancel)
    }

    override func accessibilityIncrement() { adjust(by: 0.05) }
    override func accessibilityDecrement() { adjust(by: -0.05) }

    private func adjust(by step: Float) {
        guard isEnabled else { return }
        setValue(min(max(value + step, 0), 1), animated: false)
        sendActions(for: .primaryActionTriggered)
    }

    private func move(to point: CGPoint) {
        guard bounds.width > 0 else { return }
        setValue(Float(min(max(point.x / bounds.width, 0), 1)), animated: false)
        sendActions(for: .valueChanged)
    }

    private func setScrubbing(_ active: Bool) {
        isScrubbing = active
        isHighlighted = active
        UIView.animate(withDuration: 0.15) { self.setNeedsLayout(); self.layoutIfNeeded() }
    }

    private static func thumb(diameter: CGFloat) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: diameter, height: diameter)).image { _ in
            UIColor(Theme.accent).setFill()
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: diameter, height: diameter)).fill()
        }
    }
}
