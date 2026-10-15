import Foundation
import Observation
import UIKit

@MainActor @Observable
final class GuestSessionStore {
    private(set) var isReady = false
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private let network: APIClient
    private var loginRequest: APIModels.V1GuestLoginReq
    private let defaults: UserDefaults

    var currentVersion: String { loginRequest.currentVersion }

    init(network: APIClient, defaults: UserDefaults = .standard) {
        self.network = network
        self.defaults = defaults
        let headers = network.configuredHeaders(for: AppAPI.v1AuthGuestLogin.path)
        let version = Self.nonempty(headers["appVersion"])
            ?? Self.nonempty(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0"
        let deviceKey = "guest.deviceIdentifier.v1"
        let identifier = Self.nonempty(defaults.string(forKey: deviceKey))
            ?? Self.nonempty(headers["deviceId"])
            ?? UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        defaults.set(identifier, forKey: deviceKey)
        loginRequest = .init(currentVersion: version, deviceIdentifier: identifier)
        network.setClientIdentity(version: version, deviceIdentifier: identifier)
    }

    func signInIfNeeded() async {
        guard !isReady, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
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
        let identifier = UUID().uuidString
        defaults.set(identifier, forKey: "guest.deviceIdentifier.v1")
        loginRequest.deviceIdentifier = identifier
        network.setClientIdentity(version: loginRequest.currentVersion, deviceIdentifier: identifier)
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
