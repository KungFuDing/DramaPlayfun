import Foundation
import Moya
import Alamofire
import CleanJSON

nonisolated struct APIEndpoint<Request: Encodable, Response: Decodable>: Sendable {
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

nonisolated enum APIError: LocalizedError {
    case missingBaseURL, invalidConfiguration
    case encoding(Error), transport(Error), httpStatus(Int), business(Int, String?), decoding(Error)

    var errorDescription: String? {
        switch self {
        case .missingBaseURL: "尚未配置 API_BASE_URL。"
        case .invalidConfiguration: "接口地址或超时配置无效。"
        case .encoding: "请求参数编码失败。"
        case .transport: "网络连接失败，请稍后重试。"
        case .httpStatus(let status): "服务器返回 HTTP \(status)。"
        case .business(let code, let message):
            if let message, !message.isEmpty { "服务器返回业务错误 \(code)：\(message)" }
            else { "服务器返回业务错误 \(code)。" }
        case .decoding: "接口返回的数据格式无法解析。"
        }
    }
}

nonisolated enum APIResponseDecoding {
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
    private var accessToken: String?
    private var identityHeaders: [String: String] = [:]

    init(configuration: APIConfiguration? = nil,
         provider: MoyaProvider<APITarget>? = nil,
         headerProvider: @escaping (String) -> [String: String] = { _ in [:] }) {
        self.configuration = configuration
        self.headerProvider = headerProvider
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

    func configuredHeaders(for path: String) -> [String: String] { headerProvider(path) }

    func setClientIdentity(version: String, deviceIdentifier: String) {
        identityHeaders = ["appVersion": version, "deviceId": deviceIdentifier]
    }

    func setAccessToken(_ token: String) { accessToken = token }

    private func headers(for path: String) -> [String: String] {
        var values = headerProvider(path)
        for (key, value) in identityHeaders { values[key] = value }
        let isGuestLogin = path == AppAPI.v1AuthGuestLogin.path
        if isGuestLogin || accessToken != nil {
            values = values.filter { key, _ in
                !["accesstoken", "authorization"].contains(key.lowercased())
            }
        }
        if !isGuestLogin, let accessToken {
            values["accessToken"] = accessToken
            values["Authorization"] = "Bearer \(accessToken)"
        }
        return values
    }

    func request<Body, Output>(_ endpoint: APIEndpoint<Body, Output>, body: Body,
                              decoding: APIResponseDecoding = .strict,
                              unwrapEnvelope: Bool = false) async throws -> Output {
        #if DEBUG
        let requestID = String(UUID().uuidString.prefix(8))
        let startedAt = Date()
        #endif
        do {
            try _Concurrency.Task<Never, Never>.checkCancellation()
            let configuration = try configuration ?? APIConfiguration.fromBundle()
            let data: Data
            do { data = try JSONEncoder().encode(body) }
            catch { throw APIError.encoding(error) }
            var headers = headers(for: endpoint.path)
            headers["Content-Type"] = "application/json"
            headers["Accept"] = "application/json"
            let target = APITarget(baseURL: configuration.baseURL, path: endpoint.path,
                                   body: data, requestHeaders: headers)
            #if DEBUG
            APIDebugLogger.request(id: requestID, target: target)
            #endif
            let pending = PendingAPIRequest()
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
            APIDebugLogger.response(id: requestID, response: response,
                                    duration: Date().timeIntervalSince(startedAt))
            #endif
            try _Concurrency.Task<Never, Never>.checkCancellation()
            guard (200..<300).contains(response.statusCode) else { throw APIError.httpStatus(response.statusCode) }
            let object: [String: Any]
            do {
                guard let root = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
                    throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Expected a JSON object"))
                }
                object = root
            } catch { throw APIError.decoding(error) }
            if unwrapEnvelope, let code = object["code"] as? Int {
                guard code == 200 else { throw APIError.business(code, object["message"] as? String) }
                do {
                    let envelope: APIEnvelope<Output>
                    switch decoding {
                    case .strict: envelope = try JSONDecoder().decode(APIEnvelope<Output>.self, from: response.data)
                    case .tolerant: envelope = try CleanJSONDecoder().decode(APIEnvelope<Output>.self, from: response.data)
                    }
                    guard let data = envelope.data else {
                        throw DecodingError.valueNotFound(Output.self,
                            .init(codingPath: [], debugDescription: "Missing envelope data"))
                    }
                    return data
                } catch { throw APIError.decoding(error) }
            }
            do {
                switch decoding {
                case .strict: return try JSONDecoder().decode(Output.self, from: response.data)
                case .tolerant: return try CleanJSONDecoder().decode(Output.self, from: response.data)
                }
            } catch { throw APIError.decoding(error) }
        } catch {
            #if DEBUG
            APIDebugLogger.failure(id: requestID, path: endpoint.path, error: error)
            #endif
            throw error
        }
    }

}

nonisolated private struct APIEnvelope<Payload: Decodable>: Decodable {
    let data: Payload?
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
