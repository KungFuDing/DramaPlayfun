import AVFoundation
import ObjectiveC
import UIKit

/// Only this protected layer displays video; AVPlayer retains audio and timing.
@MainActor
final class CaptureProtectedPlayerView: UIView {
    let videoLayer = AVSampleBufferDisplayLayer()
    let subtitleLayer = CaptureProtectedSubtitleLayer()
    private(set) var player: AVPlayer?
    private var itemObservation: NSKeyValueObservation?
    private var videoOutput: CaptureProtectedVideoOutput?
    private var videoTransform = CGAffineTransform.identity
    private var subtitleStrings: [NSAttributedString] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        // This backing stays visible when the system omits video from a capture.
        backgroundColor = .black
        isOpaque = true
        isUserInteractionEnabled = false
        #if targetEnvironment(simulator)
        // The simulator presents its display through the host's capture path.
        // Protecting this layer also hides normal playback in Device Hub.
        videoLayer.preventsCapture = false
        #else
        videoLayer.preventsCapture = true
        #endif
        videoLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(videoLayer)
        layer.addSublayer(subtitleLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let size = bounds.applying(videoTransform.inverted()).size
        videoLayer.bounds = CGRect(origin: .zero, size: size)
        videoLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        videoLayer.setAffineTransform(videoTransform)
        subtitleLayer.display(subtitleStrings, in: bounds)
        CATransaction.commit()
    }

    func setPlayer(_ player: AVPlayer?) {
        guard self.player !== player else { return }
        itemObservation = nil
        detach()
        self.player = player
        if let player {
            CaptureProtectedVideoOutput.configure(player)
            itemObservation = player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.attachCurrentItem() }
            }
        }
        attachCurrentItem()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        attachCurrentItem()
    }

    private func attachCurrentItem() {
        let next = window == nil ? nil : player?.currentItem.map(CaptureProtectedVideoOutput.prepare)
        guard videoOutput !== next else { return }
        detach()
        videoOutput = next
        next?.add(self)
    }

    private func detach() {
        subtitleStrings = []
        subtitleLayer.clear()
        videoOutput?.remove(self)
        videoOutput = nil
        videoLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }

    fileprivate func displaySubtitles(_ strings: [NSAttributedString]) {
        guard let item = videoOutput?.item, item === player?.currentItem else { return }
        subtitleStrings = strings
        subtitleLayer.display(strings, in: bounds)
    }

    fileprivate func display(_ sample: CMSampleBuffer, transform: CGAffineTransform) {
        // Do not display an old episode while its currentItem KVO task is pending.
        guard let item = videoOutput?.item, item === player?.currentItem else { return }
        if videoTransform != transform {
            videoTransform = transform
            setNeedsLayout()
            layoutIfNeeded()
        }
        let renderer = videoLayer.sampleBufferRenderer
        if renderer.requiresFlushToResumeDecoding || renderer.status == .failed { renderer.flush() }
        if renderer.isReadyForMoreMediaData { renderer.enqueue(sample) }
    }
}

/// The item owns its output, including while prewarming or between page mounts.
/// Adding/removing outputs on a playing HLS item can reset its media clock. Views
/// therefore subscribe to frames without changing the player's output graph.
@MainActor
final class CaptureProtectedVideoOutput: NSObject, AVPlayerItemOutputPullDelegate, AVPlayerItemLegibleOutputPushDelegate {
    private static var associationKey: UInt8 = 0
    private(set) weak var item: AVPlayerItem?
    private let output: AVPlayerItemVideoOutput
    private let subtitleOutput = AVPlayerItemLegibleOutput()
    private var subtitleStrings: [NSAttributedString] = []
    private let surfaces = NSHashTable<CaptureProtectedPlayerView>.weakObjects()
    private var statusObservation: NSKeyValueObservation?
    private var preparation: Task<Void, Never>?
    private var isPreparedForDisplay = false
    private var displayLink: CADisplayLink?
    private var format: CMVideoFormatDescription?
    private var videoTransform = CGAffineTransform.identity
    private var lastFrameHostTime: CFTimeInterval = 0
    private lazy var displayTarget = VideoDisplayLinkTarget(output: self)

    static func configure(_ player: AVPlayer) {
        // Newer systems also block ClearKey pixel extraction. Every extracted
        // frame is shown exclusively by AVSampleBufferDisplayLayer.preventsCapture.
        if #available(iOS 26.4, *) { player.allowsCaptureOfClearKeyVideo = true }
    }

    @discardableResult
    static func prepare(_ item: AVPlayerItem) -> CaptureProtectedVideoOutput {
        if let existing = objc_getAssociatedObject(item, &associationKey) as? CaptureProtectedVideoOutput {
            return existing
        }
        let output = CaptureProtectedVideoOutput(item: item)
        objc_setAssociatedObject(item, &associationKey, output, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return output
    }

    private init(item: AVPlayerItem) {
        self.item = item
        output = AVPlayerItemVideoOutput(outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int]()
        ])
        super.init()
        output.suppressesPlayerRendering = true
        output.setDelegate(self, queue: .main)
        item.add(output)
        subtitleOutput.suppressesPlayerRendering = true
        subtitleOutput.setDelegate(self, queue: .main)
        item.add(subtitleOutput)
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.prepareOrientation() }
        }
    }

    private func prepareOrientation() {
        guard let item, item.status == .readyToPlay, !isPreparedForDisplay, preparation == nil else { return }
        // Query the ready item's track; separately loading an HLS URL asset's
        // tracks can wait for metadata that is unavailable for a stream.
        let track = item.tracks.compactMap(\.assetTrack).first { $0.mediaType == .video }
        preparation = Task { [weak self] in
            let transform = (try? await track?.load(.preferredTransform)) ?? .identity
            guard !Task.isCancelled, let self else { return }
            self.videoTransform = CGAffineTransform(a: transform.a, b: transform.b,
                                                   c: transform.c, d: transform.d, tx: 0, ty: 0)
            self.isPreparedForDisplay = true
            self.preparation = nil
            self.wakeDisplayLink()
        }
    }

    fileprivate func add(_ surface: CaptureProtectedPlayerView) {
        surfaces.add(surface)
        surface.displaySubtitles(subtitleStrings)
        // Request the current image again on remount, even if already acquired.
        // This also restores a paused frame without caching an image across seeks.
        if isPreparedForDisplay, let item { renderSample(at: item.currentTime()) }
        if displayLink == nil {
            let link = CADisplayLink(target: displayTarget, selector: #selector(VideoDisplayLinkTarget.tick(_:)))
            link.isPaused = true
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        wakeDisplayLink()
    }

    fileprivate func remove(_ surface: CaptureProtectedPlayerView) {
        surfaces.remove(surface)
        if surfaces.allObjects.isEmpty {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    private func wakeDisplayLink() {
        guard isPreparedForDisplay else { return }
        lastFrameHostTime = CACurrentMediaTime()
        displayLink?.isPaused = false
    }

    fileprivate func renderFrame(_ link: CADisplayLink) {
        let views = surfaces.allObjects
        guard !views.isEmpty, item != nil else {
            link.invalidate()
            displayLink = nil
            return
        }
        let time = output.itemTime(forHostTime: link.targetTimestamp)
        guard output.hasNewPixelBuffer(forItemTime: time) else {
            // Paused/preloaded pages keep their last frame without polling.
            if CACurrentMediaTime() - lastFrameHostTime > 0.5 {
                link.isPaused = true
                output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.03)
            }
            return
        }
        lastFrameHostTime = CACurrentMediaTime()
        renderSample(at: time)
    }

    private func renderSample(at time: CMTime) {
        let views = surfaces.allObjects
        guard let pixels = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else {
            for view in views {
                view.videoLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
            }
            return
        }
        if format == nil || !CMVideoFormatDescriptionMatchesImageBuffer(format!, imageBuffer: pixels) {
            var newFormat: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                imageBuffer: pixels, formatDescriptionOut: &newFormat) == noErr else { return }
            format = newFormat
        }
        guard let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels,
            formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample else { return }
        // AVPlayer's host-time mapping selects the next refresh's frame, so no
        // second clock is needed for pause, seek, buffering or rate changes.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary] {
            attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        for view in views { view.display(sample, transform: videoTransform) }
    }

    nonisolated func outputMediaDataWillChange(_ sender: AVPlayerItemOutput) {
        // The delegate queue is explicitly .main; don't delay flush/wake events
        // behind another actor task and race with seek completion or page mounts.
        MainActor.assumeIsolated { wakeDisplayLink() }
    }

    nonisolated func outputSequenceWasFlushed(_ output: AVPlayerItemOutput) {
        MainActor.assumeIsolated {
            if output === subtitleOutput { updateSubtitles([]) }
            wakeDisplayLink()
        }
    }

    nonisolated func legibleOutput(_ output: AVPlayerItemLegibleOutput,
                                  didOutputAttributedStrings strings: [NSAttributedString],
                                  nativeSampleBuffers nativeSamples: [Any], forItemTime itemTime: CMTime) {
        // With the default zero advance interval AVPlayer delivers cues on its
        // playback clock, including empty cues, paused seeks and rate changes.
        MainActor.assumeIsolated { updateSubtitles(strings) }
    }

    private func updateSubtitles(_ strings: [NSAttributedString]) {
        subtitleStrings = strings
        for surface in surfaces.allObjects { surface.displaySubtitles(strings) }
    }
}

@MainActor
private final class VideoDisplayLinkTarget: NSObject {
    weak var output: CaptureProtectedVideoOutput?
    init(output: CaptureProtectedVideoOutput) { self.output = output }
    @objc func tick(_ link: CADisplayLink) {
        guard let output else { link.invalidate(); return }
        output.renderFrame(link)
    }
}
