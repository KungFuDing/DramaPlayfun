import Foundation

// This endpoint is not present in the current OpenAPI source; keep it outside generated files.
extension AppAPI {
    static let v1ClientTransportEncryptionConfig = APIEndpoint<
        APIModels.V1GetTransportEncryptionConfigReq,
        APIModels.V1GetTransportEncryptionConfigRes
    >(path: "/mobile/v1/client/transport/encryption/config")
}

extension APIModels {
    struct V1GetTransportEncryptionConfigReq: Codable, Sendable { }

    struct V1GetTransportEncryptionConfigRes: Codable, Sendable {
        let enabled: Bool
    }
}
