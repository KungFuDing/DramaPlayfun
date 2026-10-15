import Foundation
import Security

nonisolated enum DeviceIdentifierError: Error, LocalizedError, Equatable {
    case keychain(OSStatus)
    case corruptStoredIdentifier

    var errorDescription: String? {
        switch self {
        case .keychain:
            "暂时无法读取或保存设备标识，请解锁设备后重试。"
        case .corruptStoredIdentifier:
            "设备标识数据异常，无法继续请求。"
        }
    }
}

@MainActor
protocol DeviceIdentifierStorage {
    func read() throws -> String?
    func insertIfAbsent(_ identifier: String) throws -> String
}

/// Stores one identity in this app's Keychain scope without updating or deleting existing items.
@MainActor
struct DeviceIdentifierKeychain: DeviceIdentifierStorage {
    typealias CopyItem = ([String: Any]) -> (OSStatus, CFTypeRef?)
    typealias AddItem = ([String: Any]) -> OSStatus

    private let copyItem: CopyItem
    private let addItem: AddItem

    init(
        copyItem: @escaping CopyItem = { query in
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result)
        },
        addItem: @escaping AddItem = { attributes in
            SecItemAdd(attributes as CFDictionary, nil)
        }
    ) {
        self.copyItem = copyItem
        self.addItem = addItem
    }

    func read() throws -> String? {
        var query = itemAttributes
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        let (status, result) = copyItem(query)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw DeviceIdentifierError.keychain(status) }
        guard let data = result as? Data, let identifier = String(data: data, encoding: .utf8) else {
            throw DeviceIdentifierError.corruptStoredIdentifier
        }
        return try Self.validatedIdentifier(identifier)
    }

    func insertIfAbsent(_ identifier: String) throws -> String {
        let identifier = try Self.validatedIdentifier(identifier)
        var attributes = itemAttributes
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecValueData as String] = Data(identifier.utf8)
        let status = addItem(attributes)
        switch status {
        case errSecSuccess:
            return identifier
        case errSecDuplicateItem:
            // Another store may have inserted first. Its persisted identity always wins.
            guard let existing = try read() else {
                throw DeviceIdentifierError.keychain(errSecItemNotFound)
            }
            return existing
        default:
            throw DeviceIdentifierError.keychain(status)
        }
    }

    nonisolated static func validatedIdentifier(_ value: String) throws -> String {
        let identifier = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty,
              identifier.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else {
            throw DeviceIdentifierError.corruptStoredIdentifier
        }
        return identifier
    }

    private var itemAttributes: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            // Keep these stable across releases so reinstalling can find the same item.
            kSecAttrService as String: "com.dramaplayfun.device-identity",
            kSecAttrAccount as String: "device-id-v1",
            kSecAttrSynchronizable as String: false,
        ]
    }
}
