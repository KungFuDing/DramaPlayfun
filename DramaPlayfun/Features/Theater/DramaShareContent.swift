import SwiftUI
import CoreImage.CIFilterBuiltins
import Photos

@MainActor
struct DramaShareContent {
    let cover: UIImage
    let qrCode: UIImage

    static func load(item: TheaterFeedItem, network: APIClient,
                     imageURLs: RemoteImageURLRefresher? = nil) async throws -> Self {
        guard let episodeID = (item.firstEpisode?.id).flatMap(Int64.init) else {
            throw TheaterInteractionError.invalidEpisode
        }
        let result = try await network.request(AppAPI.v1ClientDramaShareText,
            body: .init(episodeId: episodeID), unwrapEnvelope: true)
        guard let text = result.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let qrCode = makeQRCode(text: text) else { throw TheaterInteractionError.missingShareText }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-TheaterUITestFixture"),
           let cover = UIImage(named: "RankingsHeader") {
            return Self(cover: cover, qrCode: qrCode)
        }
        #endif
        let cover = try await RemoteImageLoader.load(url: item.drama.coverURL,
            source: .dramaCover(item.drama.id), refresher: imageURLs ?? RemoteImageURLRefresher(network: network))
        try Task.checkCancellation()
        return Self(cover: cover, qrCode: qrCode)
    }

    static func makeQRCode(text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    func render(drama: Drama, width: CGFloat) throws -> UIImage {
        let renderer = ImageRenderer(content: DramaShareCard(drama: drama, content: self, width: width))
        renderer.scale = 3
        guard let image = renderer.uiImage else { throw TheaterInteractionError.imageRendering }
        return image
    }

    static func saveToPhotos(_ image: UIImage) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw TheaterInteractionError.photoPermission }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        }
    }

    static func reportShare(item: TheaterFeedItem, channel: String, network: APIClient) async throws {
        guard let id = (item.firstEpisode?.id).flatMap(Int64.init) else { throw TheaterInteractionError.invalidEpisode }
        _ = try await network.request(AppAPI.v1ClientDramaShare,
            body: .init(episodeId: id, channel: channel), unwrapEnvelope: true)
    }

    static func channel(for activity: UIActivity.ActivityType?) -> String {
        switch activity {
        case .mail: return "email"
        case .message: return "sms"
        case .copyToPasteboard: return "copy"
        case .postToFacebook: return "facebook"
        case .postToTwitter: return "x"
        default:
            let identifier = activity?.rawValue.lowercased() ?? ""
            let aliases: [(String, String)] = [
                ("whatsapp", "whatsapp"), ("messenger", "messenger"), ("instagram", "instagram"),
                ("telegram", "telegram"), ("snapchat", "snapchat"), ("tiktok", "tiktok"),
                ("linkedin", "linkedin"), ("reddit", "reddit"), ("pinterest", "pinterest"),
                ("line", "line"), ("kakaotalk", "kakaotalk"), ("viber", "viber"),
                ("discord", "discord"), ("wechat", "wechat_friend"), ("weibo", "weibo")
            ]
            return aliases.first(where: { identifier.contains($0.0) })?.1 ?? "qr"
        }
    }
}
