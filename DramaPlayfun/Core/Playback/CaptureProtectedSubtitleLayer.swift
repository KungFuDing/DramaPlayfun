import AVFoundation
import UIKit

/// Rasterizes legible output into a protected image, without a second video renderer.
@MainActor
final class CaptureProtectedSubtitleLayer: AVSampleBufferDisplayLayer {
    private var displayedStrings: [NSAttributedString] = []
    private var displayBounds = CGRect.zero

    override init() {
        super.init()
        #if targetEnvironment(simulator)
        preventsCapture = false
        #else
        preventsCapture = true
        #endif
        isOpaque = false
        backgroundColor = UIColor.clear.cgColor
        contentsScale = UIScreen.main.scale
        videoGravity = .resize
        isHidden = true
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func display(_ strings: [NSAttributedString], in bounds: CGRect) {
        guard bounds.width > 0, bounds.height > 0,
              strings.contains(where: { !$0.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            clear()
            return
        }
        guard strings != displayedStrings || bounds != displayBounds
                || sampleBufferRenderer.status != .rendering else { return }

        let fontSize = min(24, max(14, bounds.width * 0.05))
        let text = styledText(strings, fontSize: fontSize)
        let padding: CGFloat = 8
        let textWidth = max(1, bounds.width * 0.9 - padding * 2)
        let measured = text.boundingRect(with: CGSize(width: textWidth, height: bounds.height * 0.4),
                                        options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        let size = CGSize(width: min(bounds.width, ceil(measured.width) + padding * 2),
                          height: min(bounds.height * 0.4, ceil(measured.height) + padding * 2))
        guard let sample = makeSample(text: text, size: size, padding: padding) else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame = CGRect(x: bounds.midX - size.width / 2,
                       y: max(bounds.minY, bounds.maxY - bounds.height * 0.06 - size.height),
                       width: size.width, height: size.height)
        isHidden = false
        CATransaction.commit()
        // Only cue or layout changes enqueue images. Keep the current image while
        // discarding any obsolete queued cue before showing its replacement.
        sampleBufferRenderer.flush()
        sampleBufferRenderer.enqueue(sample)
        displayedStrings = strings.map { NSAttributedString(attributedString: $0) }
        displayBounds = bounds
    }

    func clear() {
        displayedStrings = []
        displayBounds = .zero
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        isHidden = true
        CATransaction.commit()
        sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }

    private func styledText(_ strings: [NSAttributedString], fontSize: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let baseFont = UIFont.systemFont(ofSize: fontSize, weight: .medium)
        for source in strings where !source.string.isEmpty {
            if result.length > 0 { result.append(NSAttributedString(string: "\n")) }
            let styled = NSMutableAttributedString(string: source.string, attributes: [
                .font: baseFont, .foregroundColor: UIColor.white, .paragraphStyle: paragraph
            ])
            source.enumerateAttributes(in: NSRange(location: 0, length: source.length)) { attributes, range, _ in
                var traits: UIFontDescriptor.SymbolicTraits = []
                if attributes[NSAttributedString.Key(kCMTextMarkupAttribute_BoldStyle as String)] as? Bool == true {
                    traits.insert(.traitBold)
                }
                if attributes[NSAttributedString.Key(kCMTextMarkupAttribute_ItalicStyle as String)] as? Bool == true {
                    traits.insert(.traitItalic)
                }
                if !traits.isEmpty, let descriptor = baseFont.fontDescriptor.withSymbolicTraits(traits) {
                    styled.addAttribute(.font, value: UIFont(descriptor: descriptor, size: fontSize), range: range)
                }
            }
            result.append(styled)
        }
        return result
    }

    private func makeSample(text: NSAttributedString, size: CGSize, padding: CGFloat) -> CMSampleBuffer? {
        let scale = max(1, contentsScale)
        let width = max(1, Int(ceil(size.width * scale)))
        let height = max(1, Int(ceil(size.height * scale)))
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
                                          kCVPixelBufferCGImageCompatibilityKey: true,
                                          kCVPixelBufferCGBitmapContextCompatibilityKey: true]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &buffer) == kCVReturnSuccess, let buffer,
              CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        UIGraphicsPushContext(context)
        UIColor.black.withAlphaComponent(0.65).setFill()
        UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4).fill()
        text.draw(with: CGRect(origin: .zero, size: size).insetBy(dx: padding, dy: padding),
                  options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        UIGraphicsPopContext()
        CVBufferSetAttachment(buffer, kCVImageBufferAlphaChannelModeKey,
                              kCVImageBufferAlphaChannelMode_PremultipliedAlpha, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferAlphaChannelIsOpaque, kCFBooleanFalse, .shouldPropagate)

        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: buffer, formatDescriptionOut: &format) == noErr, let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
            formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary] {
            attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        return sample
    }
}
