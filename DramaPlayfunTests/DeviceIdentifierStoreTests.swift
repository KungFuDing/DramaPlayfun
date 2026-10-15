import XCTest
@testable import DramaPlayfun

@MainActor
final class DeviceIdentifierStoreTests: XCTestCase {
    private let legacyKey = "guest.deviceIdentifier.v1"

    func testCreatesUUIDOnlyOnceAndRestoresItAfterAppDefaultsAreRemoved() throws {
        let storage = MemoryDeviceIdentifierStorage()
        let firstDefaults = isolatedDefaults()
        let first = try DeviceIdentifierStore(defaults: firstDefaults, storage: storage).identifier()
        XCTAssertNotNil(UUID(uuidString: first))
        XCTAssertEqual(storage.value, first)
        XCTAssertNil(firstDefaults.string(forKey: legacyKey))

        // Model a reinstall: a new provider and empty app preferences, with the same Keychain.
        let reinstalled = DeviceIdentifierStore(defaults: isolatedDefaults(), storage: storage)
        XCTAssertEqual(try reinstalled.identifier(), first)
        XCTAssertEqual(try reinstalled.identifier(), first)
        XCTAssertEqual(storage.insertions.count, 1)
    }

    func testMigratesExistingIdentityWithoutChangingBackendUser() throws {
        let storage = MemoryDeviceIdentifierStorage()
        let defaults = isolatedDefaults()
        defaults.set(" previous-device ", forKey: legacyKey)
        let store = DeviceIdentifierStore(defaults: defaults, storage: storage) {
            XCTFail("Migration must not generate a new identity")
            return "unexpected-id"
        }
        XCTAssertEqual(try store.identifier(), "previous-device")
        XCTAssertEqual(storage.value, "previous-device")
        XCTAssertNil(defaults.string(forKey: legacyKey))
    }

    func testKeychainWinsOverLegacyPreferences() throws {
        let storage = MemoryDeviceIdentifierStorage(value: "keychain-device")
        let defaults = isolatedDefaults()
        defaults.set("outdated-device", forKey: legacyKey)
        let store = DeviceIdentifierStore(defaults: defaults, storage: storage)
        XCTAssertEqual(try store.identifier(), "keychain-device")
        XCTAssertTrue(storage.insertions.isEmpty)
        XCTAssertNil(defaults.string(forKey: legacyKey))
    }

    func testDifferentDevicesGenerateDifferentIDs() throws {
        let first = DeviceIdentifierStore(defaults: isolatedDefaults(), storage: MemoryDeviceIdentifierStorage())
        let second = DeviceIdentifierStore(defaults: isolatedDefaults(), storage: MemoryDeviceIdentifierStorage())
        XCTAssertNotEqual(try first.identifier(), try second.identifier())
    }

    func testReadFailureDoesNotGenerateOverwriteOrDiscardLegacyIdentity() throws {
        let storage = MemoryDeviceIdentifierStorage()
        storage.readError = DeviceIdentifierError.keychain(-25308)
        let defaults = isolatedDefaults()
        defaults.set("legacy-device", forKey: legacyKey)
        let store = DeviceIdentifierStore(defaults: defaults, storage: storage) {
            XCTFail("A locked or unavailable Keychain must not create a new ID")
            return "unexpected-id"
        }
        XCTAssertThrowsError(try store.identifier())
        XCTAssertTrue(storage.insertions.isEmpty)
        XCTAssertEqual(defaults.string(forKey: legacyKey), "legacy-device")
        storage.readError = nil
        storage.value = "stored-device"
        XCTAssertEqual(try store.identifier(), "stored-device")
    }

    func testWriteFailureKeepsLegacyIdentityForRetryAndDoesNotCacheUnsavedID() throws {
        let storage = MemoryDeviceIdentifierStorage()
        storage.writeError = DeviceIdentifierError.keychain(-34018)
        let defaults = isolatedDefaults()
        defaults.set("legacy-device", forKey: legacyKey)
        let store = DeviceIdentifierStore(defaults: defaults, storage: storage)
        XCTAssertThrowsError(try store.identifier())
        XCTAssertNil(storage.value)
        XCTAssertEqual(defaults.string(forKey: legacyKey), "legacy-device")
        storage.writeError = nil
        XCTAssertEqual(try store.identifier(), "legacy-device")
        XCTAssertEqual(storage.value, "legacy-device")
        XCTAssertEqual(storage.insertions, ["legacy-device", "legacy-device"])
    }

    func testCompetingInsertionReturnsPersistedWinner() throws {
        let storage = MemoryDeviceIdentifierStorage()
        storage.insertionWinner = "persisted-winner"
        let store = DeviceIdentifierStore(defaults: isolatedDefaults(), storage: storage) { "candidate-id" }
        XCTAssertEqual(try store.identifier(), "persisted-winner")
        XCTAssertEqual(storage.value, "persisted-winner")
    }

    func testCorruptStoredValueDoesNotCreateReplacement() {
        let storage = MemoryDeviceIdentifierStorage(value: "invalid\nidentifier")
        let store = DeviceIdentifierStore(defaults: isolatedDefaults(), storage: storage)
        XCTAssertThrowsError(try store.identifier())
        XCTAssertTrue(storage.insertions.isEmpty)
    }

    func testInvalidLegacyValueIsPreservedWithoutGeneratingAnotherIdentity() {
        for value: Any in ["invalid\nidentifier", "", 42] {
            let storage = MemoryDeviceIdentifierStorage()
            let defaults = isolatedDefaults()
            defaults.set(value, forKey: legacyKey)
            let store = DeviceIdentifierStore(defaults: defaults, storage: storage) {
                XCTFail("A corrupt legacy identity must not silently become a new backend user")
                return "unexpected-id"
            }
            XCTAssertThrowsError(try store.identifier())
            XCTAssertNil(storage.value)
            XCTAssertTrue(storage.insertions.isEmpty)
            XCTAssertNotNil(defaults.object(forKey: legacyKey))
        }
    }

    private func isolatedDefaults() -> UserDefaults {
        let name = "DeviceIdentifierStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
}

@MainActor
private final class MemoryDeviceIdentifierStorage: DeviceIdentifierStorage {
    var value: String?
    var readError: Error?
    var writeError: Error?
    var insertionWinner: String?
    var insertions: [String] = []

    init(value: String? = nil) { self.value = value }

    func read() throws -> String? {
        if let readError { throw readError }
        return value
    }

    func insertIfAbsent(_ identifier: String) throws -> String {
        insertions.append(identifier)
        if let writeError { throw writeError }
        let saved = value ?? insertionWinner ?? identifier
        value = saved
        return saved
    }
}
