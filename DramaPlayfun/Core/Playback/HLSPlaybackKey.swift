import CryptoKit
import Foundation

struct HLSKeyIdentity: Hashable, Sendable {
    let version: String
    let rootDramaID: Int64
    let episodeID: Int64

    init(version: String = "v1", rootDramaID: Int64, episodeID: Int64) {
        self.version = version
        self.rootDramaID = rootDramaID
        self.episodeID = episodeID
    }

    var isValid: Bool { !version.isEmpty && rootDramaID > 0 && episodeID > 0 }
    var material: Data { Data("\(version)|\(rootDramaID)|\(episodeID)".utf8) }

    init?(drama: Drama, episode: Episode) {
        guard let rootDramaID = drama.rootDramaID, let episodeID = Int64(episode.id) else { return nil }
        self.init(rootDramaID: rootDramaID, episodeID: episodeID)
        guard isValid else { return nil }
    }
}

enum HLSKeyError: LocalizedError {
    case missingConfiguration, invalidIdentity, invalidMediaToken

    var errorDescription: String? {
        switch self {
        case .missingConfiguration: "视频密钥配置缺失。"
        case .invalidIdentity: "视频剧集标识无效。"
        case .invalidMediaToken: "视频授权参数缺失。"
        }
    }
}

enum HLSPlaybackKey {
    static func derive(_ identity: HLSKeyIdentity, secret: Data) throws -> Data {
        guard identity.isValid else { throw HLSKeyError.invalidIdentity }
        guard !secret.isEmpty else { throw HLSKeyError.missingConfiguration }
        let digest = HMAC<SHA256>.authenticationCode(for: identity.material,
                                                      using: SymmetricKey(data: secret))
        return Data(digest.prefix(16))
    }

    static func configuredSecret(in bundle: Bundle = .main) throws -> Data {
        guard let value = bundle.object(forInfoDictionaryKey: "HLSSharedSecret") as? String,
              !value.isEmpty, !value.hasPrefix("$(") else { throw HLSKeyError.missingConfiguration }
        return Data(value.utf8)
    }
}
