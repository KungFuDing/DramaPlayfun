import Foundation

extension APIEndpoint {
    // These routes always exchange JSON, independently of the server encryption setting.
    var requiresPlaintextTransport: Bool {
        switch path {
        case AppAPI.v1ClientTransportEncryptionConfig.path,
             AppAPI.v1ClientServiceNotice.path,
             AppAPI.v1ClientAppConfig.path,
             AppAPI.v1ClientAppUpdateCheck.path:
            true
        default:
            false
        }
    }
}

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
