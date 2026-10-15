import Foundation
import Observation

@MainActor @Observable
final class GuestSessionStore {
    private(set) var isReady = false
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private let network: APIClient
    private let deviceIdentifierProvider: any DeviceIdentifierProviding

    var currentVersion: String { network.appVersion }

    init(network: APIClient, defaults: UserDefaults = .standard,
         deviceIdentifierProvider: (any DeviceIdentifierProviding)? = nil) {
        self.network = network
        self.deviceIdentifierProvider = deviceIdentifierProvider ?? DeviceIdentifierStore(defaults: defaults)
    }

    func signInIfNeeded() async {
        guard !isReady, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            try Task.checkCancellation()
            let identifier = try deviceIdentifierProvider.identifier()
            network.setDeviceIdentifier(identifier)
            let loginRequest = APIModels.V1GuestLoginReq(currentVersion: currentVersion,
                                                         deviceIdentifier: identifier)
            let result = try await network.request(AppAPI.v1AuthGuestLogin,
                body: loginRequest, unwrapEnvelope: true)
            try Task.checkCancellation()
            guard let token = Self.nonempty(result.accessToken),
                  !token.contains(where: { $0.isWhitespace || $0.isNewline }) else {
                throw GuestSessionError.missingToken
            }
            network.setAccessToken(token)
            isReady = true
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startNewSession() async {
        network.setAccessToken("")
        isReady = false
        await signInIfNeeded()
    }

    private static func nonempty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

nonisolated private enum GuestSessionError: LocalizedError {
    case missingToken
    var errorDescription: String? { "登录未返回有效的访问令牌，请重试。" }
}
