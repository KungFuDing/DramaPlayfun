import Foundation
import Moya
import Alamofire
import CryptoKit

nonisolated struct APIEndpoint<Request: Encodable & Sendable, Response: Decodable & Sendable>: Sendable {
    let path: String
}

nonisolated struct APIConfiguration: Sendable {
    let baseURL: URL
    let timeout: TimeInterval

    init(baseURL: URL, timeout: TimeInterval = 30) throws {
        guard baseURL.scheme == "https", baseURL.host?.isEmpty == false,
              baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil,
              timeout.isFinite, timeout > 0 else { throw APIError.invalidConfiguration }
        self.baseURL = baseURL
        self.timeout = timeout
    }

    static func fromBundle(_ bundle: Bundle = .main) throws -> Self {
        guard let raw = bundle.object(forInfoDictionaryKey: "APIBaseURL") as? String,
              !raw.isEmpty, let url = URL(string: raw) else { throw APIError.missingBaseURL }
        return try Self(baseURL: url)
    }
}

nonisolated enum APIError: AppLocalizedError {
    case missingBaseURL, invalidConfiguration
    case encoding(Error), transport(Error), httpStatus(Int), business(Int, String?), decoding(Error)
    case encryption(Error), decryption(Error)
    case missingEncryptionKey

    var errorDescription: String? {
        switch self {
        case .missingBaseURL: L10n.text("尚未配置 API_BASE_URL。")
        case .invalidConfiguration: L10n.text("接口地址或超时配置无效。")
        case .encoding: L10n.text("请求参数编码失败。")
        case .encryption: L10n.text("请求数据加密失败。")
        case .decryption: L10n.text("响应数据解密或完整性校验失败。")
        case .missingEncryptionKey: L10n.text("服务端已开启接口加密，但客户端未配置加密密钥。")
        case .transport: L10n.text("网络连接失败，请稍后重试。")
        case .httpStatus(let status): L10n.text("服务器返回 HTTP %d。", status)
        case .business(let code, let message):
            if let message, !message.isEmpty { L10n.text("服务器返回业务错误 %d：%@", code, message) }
            else { L10n.text("服务器返回业务错误 %d。", code) }
        case .decoding: L10n.text("接口返回的数据格式无法解析。")
        }
    }
}

nonisolated enum APIResponseDecoding: Sendable {
    case strict, tolerant
}

nonisolated struct APITarget: TargetType {
    let baseURL: URL
    let path: String
    let body: Data
    let requestHeaders: [String: String]
    var method: Moya.Method { .post }
    var task: Moya.Task { .requestData(body) }
    var headers: [String: String]? { requestHeaders }
    var validationType: ValidationType { .none }
}

/// Headers are supplied per path; the OpenAPI source does not define an authentication scheme.
@MainActor
final class APIClient {
    private let configuration: APIConfiguration?
    private let provider: MoyaProvider<APITarget>
    private let headerProvider: (String) -> [String: String]
    private let networkLocationProvider: (any NetworkLocationProviding)?
    private let clientMetadata = ClientMetadata.current
    private let payloadCipher: APIPayloadCipher?
    private let usesServerEncryptionConfiguration: Bool
    private var serverEncryptionEnabled: Bool?
    private var encryptionConfigurationTask: _Concurrency.Task<Bool, Error>?
    private var encryptionConfigurationTaskID: UUID?
    private var accountGeneration = UUID()
    private var isResettingAccount = false
    private var pendingRequests: [UUID: PendingAPIRequest] = [:]
    private var accessToken: String?
    private var accountID: String?
    private var deviceIdentifier: String?

    var appVersion: String { clientMetadata.appVersion }
    var accountSessionID: UUID { accountGeneration }

    init(configuration: APIConfiguration? = nil,
         provider: MoyaProvider<APITarget>? = nil,
         payloadCipher: APIPayloadCipher? = nil,
         usesServerEncryptionConfiguration: Bool = false,
         networkLocationProvider: (any NetworkLocationProviding)? = nil,
         headerProvider: @escaping (String) -> [String: String] = { _ in [:] }) {
        self.configuration = configuration
        self.headerProvider = headerProvider
        self.networkLocationProvider = networkLocationProvider
        self.payloadCipher = payloadCipher
        self.usesServerEncryptionConfiguration = usesServerEncryptionConfiguration
        let timeout = configuration?.timeout ?? 30
        self.provider = provider ?? MoyaProvider<APITarget>(requestClosure: { endpoint, completion in
            do {
                var request = try endpoint.urlRequest()
                request.timeoutInterval = timeout
                completion(.success(request))
            } catch let error as MoyaError { completion(.failure(error)) }
            catch { completion(.failure(.underlying(error, nil))) }
        })
    }

    func setDeviceIdentifier(_ identifier: String) { deviceIdentifier = identifier }

    func setAccessToken(_ token: String, accountID: String? = nil) {
        accessToken = token
        self.accountID = token.isEmpty ? nil : accountID
    }

    /// Close request admission before clearing account-owned stores and caches.
    /// The device identity and transport configuration belong to the installation.
    func beginAccountReset() {
        isResettingAccount = true
        accountGeneration = UUID()
        accessToken = ""
        accountID = nil
        encryptionConfigurationTaskID = nil
        encryptionConfigurationTask?.cancel()
        encryptionConfigurationTask = nil
        let requests = Array(pendingRequests.values)
        pendingRequests.removeAll()
        requests.forEach { $0.cancel() }
    }

    /// Reopen admission only after old account state has been removed.
    func endAccountReset() {
        isResettingAccount = false
    }

    private func validateAccountGeneration(_ generation: UUID) throws {
        try _Concurrency.Task<Never, Never>.checkCancellation()
        guard !isResettingAccount, accountGeneration == generation else { throw CancellationError() }
    }

    /// A stable server account survives token renewal; older servers fall back to
    /// the credential itself. Credentials never appear in cache filenames.
    var playbackCacheScope: String {
        let baseURL = (try? configuration ?? APIConfiguration.fromBundle())?.baseURL.absoluteString ?? ""
        let authorization = headers(for: AppAPI.v1ClientDramaEpisodeList.path, networkLocation: nil)
            .first { $0.key.lowercased() == "authorization" }?.value ?? ""
        let identity = accountID.flatMap { $0.isEmpty ? nil : "account:\($0)" } ?? "credential:\(authorization)"
        let data = (try? JSONEncoder().encode([baseURL, identity, deviceIdentifier ?? "", AppLanguage.current.rawValue])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func reloadTransportEncryptionConfiguration() async throws {
        try validateAccountGeneration(accountGeneration)
        guard usesServerEncryptionConfiguration else { return }
        serverEncryptionEnabled = nil
        _ = try await loadTransportEncryptionConfigurationIfNeeded()
    }

    private func loadTransportEncryptionConfigurationIfNeeded() async throws -> Bool {
        let generation = accountGeneration
        try validateAccountGeneration(generation)
        if let serverEncryptionEnabled { return serverEncryptionEnabled }
        if let encryptionConfigurationTask {
            let enabled = try await encryptionConfigurationTask.value
            try validateAccountGeneration(generation)
            return enabled
        }
        let taskID = UUID()
        let task = _Concurrency.Task {
            try validateAccountGeneration(generation)
            let result = try await request(AppAPI.v1ClientTransportEncryptionConfig,
                body: .init(), unwrapEnvelope: true)
            try validateAccountGeneration(generation)
            if result.enabled, payloadCipher == nil { throw APIError.missingEncryptionKey }
            return result.enabled
        }
        encryptionConfigurationTask = task
        encryptionConfigurationTaskID = taskID
        do {
            let enabled = try await task.value
            try validateAccountGeneration(generation)
            serverEncryptionEnabled = enabled
            if encryptionConfigurationTaskID == taskID {
                encryptionConfigurationTask = nil
                encryptionConfigurationTaskID = nil
            }
            return enabled
        } catch {
            if encryptionConfigurationTaskID == taskID {
                encryptionConfigurationTask = nil
                encryptionConfigurationTaskID = nil
            }
            throw error
        }
    }

    private func headers(for path: String, networkLocation: NetworkLocation?) -> [String: String] {
        var runtimeHeaders = clientMetadata.headers
        runtimeHeaders["language"] = AppLanguage.current.rawValue
        if let networkLocation { runtimeHeaders.merge(networkLocation.headers) { _, current in current } }
        if let deviceIdentifier { runtimeHeaders["deviceId"] = deviceIdentifier }
        let runtimeKeys = Set(runtimeHeaders.keys.map { $0.lowercased() }).union(["ip", "countrycode", "deviceid"])
        var values = headerProvider(path).filter {
            let key = $0.key.lowercased()
            return key != "accesstoken" && !runtimeKeys.contains(key)
        }
        values.merge(runtimeHeaders) { _, runtimeValue in runtimeValue }
        let isBootstrap = path == AppAPI.v1AuthGuestLogin.path
            || path == AppAPI.v1ClientTransportEncryptionConfig.path
        if isBootstrap || accessToken != nil {
            values = values.filter { $0.key.lowercased() != "authorization" }
        }
        if !isBootstrap, let accessToken {
            values["Authorization"] = "Bearer \(accessToken)"
        }
        return values
    }

    func request<Body, Output>(_ endpoint: APIEndpoint<Body, Output>, body: Body,
                              decoding: APIResponseDecoding = .strict,
                              unwrapEnvelope: Bool = false) async throws -> Output {
        let generation = accountGeneration
        #if DEBUG
        let requestID = String(UUID().uuidString.prefix(8))
        let startedAt = Date()
        #endif
        do {
            try validateAccountGeneration(generation)
            let configuration = try configuration ?? APIConfiguration.fromBundle()
            // Capture the negotiated mode so a refresh cannot change how this response is decoded.
            let requestCipher: APIPayloadCipher?
            if endpoint.requiresPlaintextTransport {
                requestCipher = nil
            } else if usesServerEncryptionConfiguration {
                let enabled = try await loadTransportEncryptionConfigurationIfNeeded()
                try validateAccountGeneration(generation)
                requestCipher = enabled ? payloadCipher : nil
            } else { requestCipher = payloadCipher }
            let networkLocation = await networkLocationProvider?.current()
            try validateAccountGeneration(generation)
            var headers = headers(for: endpoint.path, networkLocation: networkLocation).filter {
                !["content-type", "accept", "x-payload-encryption"].contains($0.key.lowercased())
            }
            let payload = try await APIPayloadProcessing.encode(body, cipher: requestCipher)
            try validateAccountGeneration(generation)
            if requestCipher != nil {
                headers["Content-Type"] = "text/plain; charset=utf-8"
                headers["Accept"] = "text/plain"
            } else {
                headers["Content-Type"] = "application/json"
                headers["Accept"] = "application/json"
            }
            let target = APITarget(baseURL: configuration.baseURL, path: endpoint.path,
                                   body: payload.wireBody, requestHeaders: headers)
            #if DEBUG
            APIDebugLogger.request(id: requestID, target: target, plaintextBody: payload.plaintextBody)
            #endif
            let pending = PendingAPIRequest()
            let pendingID = UUID()
            pendingRequests[pendingID] = pending
            defer { pendingRequests[pendingID] = nil }
            let response: Moya.Response = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    guard pending.begin(continuation) else { return }
                    let token = provider.request(target) { result in
                        pending.finish(result.mapError { APIError.transport($0) })
                    }
                    pending.setToken(token)
                }
            } onCancel: { pending.cancel() }
            #if DEBUG
            func logResponse(plaintextBody: Data? = nil) {
                APIDebugLogger.response(id: requestID, response: response,
                    duration: Date().timeIntervalSince(startedAt), plaintextBody: plaintextBody,
                    isEncrypted: requestCipher != nil)
            }
            #endif
            try validateAccountGeneration(generation)
            guard (200..<300).contains(response.statusCode) else {
                #if DEBUG
                logResponse()
                #endif
                throw APIError.httpStatus(response.statusCode)
            }
            let processed = try await APIPayloadProcessing.decode(
                Output.self, from: response.data, cipher: requestCipher,
                decoding: decoding, unwrapEnvelope: unwrapEnvelope)
            try validateAccountGeneration(generation)
            #if DEBUG
            logResponse(plaintextBody: processed.plaintextBody)
            #endif
            return try processed.result.get()
        } catch {
            // Superseded failures must not become errors in the replacement account.
            try validateAccountGeneration(generation)
            #if DEBUG
            APIDebugLogger.failure(id: requestID, path: endpoint.path, error: error)
            #endif
            throw error
        }
    }

}

/// Lock protects callback/cancellation races, including cancellation before Moya returns its token.
nonisolated final class PendingAPIRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Moya.Response, Error>?
    private var token: Cancellable?
    private var finished = false
    private var cancelled = false

    func begin(_ continuation: CheckedContinuation<Moya.Response, Error>) -> Bool {
        lock.lock()
        if finished {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func setToken(_ token: Cancellable) {
        lock.lock()
        let shouldCancel = cancelled
        if !finished { self.token = token }
        lock.unlock()
        if shouldCancel { token.cancel() }
    }

    func finish(_ result: Result<Moya.Response, APIError>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        token = nil
        lock.unlock()
        continuation?.resume(with: result.mapError { $0 as Error })
    }

    func cancel() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        cancelled = true
        finished = true
        let continuation = self.continuation
        let token = self.token
        self.continuation = nil
        self.token = nil
        lock.unlock()
        token?.cancel()
        continuation?.resume(throwing: CancellationError())
    }
}
