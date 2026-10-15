import Foundation

nonisolated struct AppConfiguration: Sendable {
    let userAgreementUrl: String
    let privacyPolicyUrl: String
    let customerServiceEmail: String

    init(remote: APIModels.V1GetAppConfigRes = .init()) {
        userAgreementUrl = Self.webURL(remote.userAgreementUrl)
            ?? "https://dramaplayfun.com/en/terms-of-use.html"
        privacyPolicyUrl = Self.webURL(remote.privacyPolicyUrl)
            ?? "https://dramaplayfun.com/privacy-policy.html"
        customerServiceEmail = Self.nonEmpty(remote.customerServiceEmail)
            ?? "contact@idoltimeltd.co.uk"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func webURL(_ value: String?) -> String? {
        guard let value = nonEmpty(value), let url = URL(string: value),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false else { return nil }
        return value
    }
}
