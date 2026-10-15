import Foundation

@MainActor
protocol DeviceIdentifierProviding {
    func identifier() throws -> String
}

@MainActor
final class DeviceIdentifierStore: DeviceIdentifierProviding {
    private let storage: any DeviceIdentifierStorage
    private let defaults: UserDefaults
    private let makeIdentifier: () -> String
    private var cached: String?
    private static let legacyKey = "guest.deviceIdentifier.v1"

    init(defaults: UserDefaults = .standard,
         storage: (any DeviceIdentifierStorage)? = nil,
         makeIdentifier: @escaping () -> String = { UUID().uuidString }) {
        self.defaults = defaults
        self.storage = storage ?? DeviceIdentifierKeychain()
        self.makeIdentifier = makeIdentifier
    }

    func identifier() throws -> String {
        if let cached { return cached }
        if let saved = try storage.read() {
            return try remember(saved)
        }
        let candidate: String
        if let legacy = defaults.object(forKey: Self.legacyKey) {
            guard let legacy = legacy as? String else { throw DeviceIdentifierError.corruptStoredIdentifier }
            candidate = try DeviceIdentifierKeychain.validatedIdentifier(legacy)
        } else {
            candidate = try DeviceIdentifierKeychain.validatedIdentifier(makeIdentifier())
        }
        // Do not expose a newly generated ID until persistence succeeds.
        return try remember(storage.insertIfAbsent(candidate))
    }

    private func remember(_ identifier: String) throws -> String {
        let identifier = try DeviceIdentifierKeychain.validatedIdentifier(identifier)
        cached = identifier
        // Future device backups must not copy this device's ID through UserDefaults.
        defaults.removeObject(forKey: Self.legacyKey)
        return identifier
    }
}
