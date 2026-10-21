import Foundation
import Observation

@MainActor @Observable
final class GuestSessionStore {
    private(set) var isReady = false
    private(set) var isLoading = false
    private var signInError: Error?
    var errorMessage: String? {
        _ = LocalizationStore.shared.language
        return signInError?.appLocalizedDescription
    }
    private let network: APIClient
    private let deviceIdentifierProvider: any DeviceIdentifierProviding
    private var accountGeneration = 0
    private var isResettingAccount = false

    var currentVersion: String { network.appVersion }

    init(network: APIClient, defaults: UserDefaults = .standard,
         deviceIdentifierProvider: (any DeviceIdentifierProviding)? = nil) {
        self.network = network
        self.deviceIdentifierProvider = deviceIdentifierProvider ?? DeviceIdentifierStore(defaults: defaults)
    }

    func signInIfNeeded() async {
        guard !isReady, !isLoading, !isResettingAccount else { return }
        let generation = accountGeneration
        isLoading = true
        signInError = nil
        defer { if generation == accountGeneration { isLoading = false } }
        do {
            try Task.checkCancellation()
            let identifier = try deviceIdentifierProvider.identifier()
            network.setDeviceIdentifier(identifier)
            let loginRequest = APIModels.V1GuestLoginReq(currentVersion: currentVersion,
                                                         deviceIdentifier: identifier)
            let result = try await network.request(AppAPI.v1AuthGuestLogin,
                body: loginRequest, unwrapEnvelope: true)
            try Task.checkCancellation()
            guard generation == accountGeneration, !isResettingAccount else { return }
            guard let token = Self.nonempty(result.accessToken),
                  !token.contains(where: { $0.isWhitespace || $0.isNewline }) else {
                throw GuestSessionError.missingToken
            }
            network.setAccessToken(token, accountID: result.user?.userNo)
            isReady = true
        } catch is CancellationError {
        } catch {
            if generation == accountGeneration { signInError = error }
        }
    }

    func prepareForAccountReset() {
        accountGeneration += 1
        isResettingAccount = true
        isReady = false
        isLoading = false
        signInError = nil
    }

    func startNewSession() async {
        network.setAccessToken("")
        isReady = false
        isResettingAccount = false
        await signInIfNeeded()
    }

    private static func nonempty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

nonisolated private enum GuestSessionError: AppLocalizedError {
    case missingToken
    var errorDescription: String? { L10n.text("登录未返回有效的访问令牌，请重试。") }
}
