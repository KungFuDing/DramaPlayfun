import Foundation
import Observation

/// App-owned errors provide translated descriptions; SDK errors use local action guidance.
nonisolated protocol AppLocalizedError: LocalizedError {}

extension Error {
    nonisolated var appLocalizedDescription: String { L10n.errorMessage(self) }
}

nonisolated enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case traditionalChinese = "zh-Hant"

    static let preferenceKey = "profile.language.v1"
    var id: String { rawValue }
    var title: String { self == .english ? "English" : "繁體中文" }
    var locale: Locale { Locale(identifier: rawValue) }

    static var current: Self {
        resolve(saved: UserDefaults.standard.string(forKey: preferenceKey),
                preferredLanguages: Locale.preferredLanguages)
    }

    static func resolve(saved: String?, preferredLanguages: [String]) -> Self {
        if let saved, let language = supported(saved) { return language }
        return preferredLanguages.lazy.compactMap(supported).first ?? .english
    }

    private static func supported(_ identifier: String) -> Self? {
        switch identifier.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-").first {
        case "en": .english
        // Migrate the previous "zh" preference and all Chinese system locales.
        case "zh": .traditionalChinese
        default: nil
        }
    }
}

@MainActor @Observable
final class LocalizationStore {
    static let shared = LocalizationStore()
    private(set) var language: AppLanguage
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, preferredLanguages: [String] = Locale.preferredLanguages) {
        self.defaults = defaults
        language = AppLanguage.resolve(saved: defaults.string(forKey: AppLanguage.preferenceKey),
                                       preferredLanguages: preferredLanguages)
        defaults.set(language.rawValue, forKey: AppLanguage.preferenceKey)
    }

    func select(_ language: AppLanguage) {
        defaults.set(language.rawValue, forKey: AppLanguage.preferenceKey)
        self.language = language
    }
}

enum L10n {
    nonisolated static func errorMessage(_ error: Error, fallback: String = "操作失败，请稍后重试。") -> String {
        (error as? any AppLocalizedError)?.errorDescription ?? text(fallback)
    }

    /// Reading the observable selection here also invalidates views using computed labels.
    static func tr(_ key: String, _ arguments: CVarArg...) -> String {
        string(key, language: LocalizationStore.shared.language, arguments: arguments)
    }

    /// Error descriptions can be requested outside the main actor.
    nonisolated static func text(_ key: String, _ arguments: CVarArg...) -> String {
        string(key, language: AppLanguage.current, arguments: arguments)
    }

    nonisolated static func string(_ key: String, language: AppLanguage, arguments: [CVarArg] = []) -> String {
        let bundle = bundles[language] ?? .main
        let format = bundle.localizedString(forKey: key, value: nil, table: "Localizable")
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: language.locale, arguments: arguments)
    }

    nonisolated private static let bundles: [AppLanguage: Bundle] = Dictionary(uniqueKeysWithValues:
        AppLanguage.allCases.compactMap { language in
            guard let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
                  let bundle = Bundle(path: path) else { return nil }
            return (language, bundle)
        }
    )
}
