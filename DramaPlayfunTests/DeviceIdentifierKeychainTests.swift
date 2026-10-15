import Security
import XCTest
@testable import DramaPlayfun

@MainActor
final class DeviceIdentifierKeychainTests: XCTestCase {
    func testReadIsScopedToOneAppLocalIdentityAndReturnsStoredValue() throws {
        var queries: [[String: Any]] = []
        let storage = DeviceIdentifierKeychain(copyItem: { query in
            queries.append(query)
            return (errSecSuccess, Data("existing-device-id".utf8) as CFData)
        }, addItem: { _ in
            XCTFail("Reading must not mutate the Keychain")
            return errSecParam
        })

        XCTAssertEqual(try storage.read(), "existing-device-id")
        let query = try XCTUnwrap(queries.first)
        XCTAssertEqual(queries.count, 1)
        assertIdentityScope(query)
        XCTAssertEqual(query[kSecMatchLimit as String] as? String, kSecMatchLimitOne as String)
        XCTAssertEqual(query[kSecReturnData as String] as? Bool, true)
        XCTAssertEqual(Set(query.keys), identityKeys.union([
            kSecMatchLimit as String, kSecReturnData as String,
        ]))
    }

    func testOnlyItemNotFoundMeansNoStoredIdentity() throws {
        let storage = DeviceIdentifierKeychain(copyItem: { _ in
            (errSecItemNotFound, nil)
        }, addItem: { _ in
            XCTFail("A read miss must not write a new identity")
            return errSecParam
        })

        XCTAssertNil(try storage.read())
    }

    func testReadFailuresAreNotTreatedAsMissingIdentity() {
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecMissingEntitlement,
                       errSecNotAvailable, errSecDecode, errSecParam] {
            let storage = DeviceIdentifierKeychain(copyItem: { _ in
                (status, nil)
            }, addItem: { _ in
                XCTFail("Failed reads must not replace the identity")
                return errSecParam
            })

            XCTAssertThrowsError(try storage.read()) {
                XCTAssertEqual($0 as? DeviceIdentifierError, .keychain(status))
            }
        }
    }

    func testMalformedStoredDataFailsWithoutChangingIdentity() {
        let malformed: [CFTypeRef?] = [
            nil,
            "not-data" as CFString,
            Data([0xFF, 0xFE]) as CFData,
            Data() as CFData,
            Data(" \n\t".utf8) as CFData,
            Data("invalid device".utf8) as CFData,
            Data("id\r\nAuthorization:secret".utf8) as CFData,
            Data("id\0".utf8) as CFData,
            Data("设备标识".utf8) as CFData,
        ]
        for result in malformed {
            let storage = DeviceIdentifierKeychain(copyItem: { _ in
                (errSecSuccess, result)
            }, addItem: { _ in
                XCTFail("Corrupt items must not be replaced")
                return errSecParam
            })

            XCTAssertThrowsError(try storage.read()) {
                XCTAssertEqual($0 as? DeviceIdentifierError, .corruptStoredIdentifier)
            }
        }
    }

    func testStoredIdentifierAllowsLegacyValuesAndTrimsOnlyEdges() throws {
        let storage = DeviceIdentifierKeychain(copyItem: { _ in
            (errSecSuccess, Data(" \tlegacy-device_01:+/=.\r\n".utf8) as CFData)
        }, addItem: { _ in
            XCTFail("Normalization must not rewrite a stored identity")
            return errSecParam
        })

        XCTAssertEqual(try storage.read(), "legacy-device_01:+/=.")
    }

    func testInsertionUsesDeviceOnlyAfterFirstUnlockAndDoesNotSynchronize() throws {
        var inserts: [[String: Any]] = []
        let storage = DeviceIdentifierKeychain(copyItem: { _ in
            XCTFail("Successful insertion does not need another read")
            return (errSecParam, nil)
        }, addItem: { attributes in
            inserts.append(attributes)
            return errSecSuccess
        })

        XCTAssertEqual(try storage.insertIfAbsent("  new-device-id\n"), "new-device-id")
        let attributes = try XCTUnwrap(inserts.first)
        XCTAssertEqual(inserts.count, 1)
        assertIdentityScope(attributes)
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(attributes[kSecValueData as String] as? Data, Data("new-device-id".utf8))
        XCTAssertEqual(Set(attributes.keys), identityKeys.union([
            kSecAttrAccessible as String, kSecValueData as String,
        ]))
    }

    func testInvalidCandidateDoesNotAccessKeychain() {
        let storage = DeviceIdentifierKeychain(copyItem: { _ in
            XCTFail("Invalid candidates must fail before a Keychain read")
            return (errSecParam, nil)
        }, addItem: { _ in
            XCTFail("Invalid candidates must fail before a Keychain write")
            return errSecParam
        })

        for value in ["", " \n\t", "id space", "id\ttab", "id\nline", "id\u{7F}", "id\u{1F}", "设备"] {
            XCTAssertThrowsError(try storage.insertIfAbsent(value)) {
                XCTAssertEqual($0 as? DeviceIdentifierError, .corruptStoredIdentifier)
            }
        }
    }

    func testDuplicateInsertionReturnsPersistedWinnerWithoutOverwriting() throws {
        var operations: [String] = []
        let storage = DeviceIdentifierKeychain(copyItem: { query in
            operations.append("read")
            self.assertIdentityScope(query)
            return (errSecSuccess, Data("persisted-winner".utf8) as CFData)
        }, addItem: { attributes in
            operations.append("insert")
            XCTAssertEqual(attributes[kSecValueData as String] as? Data, Data("losing-candidate".utf8))
            return errSecDuplicateItem
        })

        XCTAssertEqual(try storage.insertIfAbsent("losing-candidate"), "persisted-winner")
        XCTAssertEqual(operations, ["insert", "read"])
    }

    func testMissingDuplicateWinnerFailsWithoutReturningUnpersistedCandidate() {
        var insertionCount = 0
        let storage = DeviceIdentifierKeychain(copyItem: { _ in
            (errSecItemNotFound, nil)
        }, addItem: { _ in
            insertionCount += 1
            return errSecDuplicateItem
        })

        XCTAssertThrowsError(try storage.insertIfAbsent("candidate")) {
            XCTAssertEqual($0 as? DeviceIdentifierError, .keychain(errSecItemNotFound))
        }
        XCTAssertEqual(insertionCount, 1)
    }

    func testUnreadableDuplicateWinnerFailsWithoutReturningCandidate() {
        let storage = DeviceIdentifierKeychain(copyItem: { _ in
            (errSecInteractionNotAllowed, nil)
        }, addItem: { _ in errSecDuplicateItem })

        XCTAssertThrowsError(try storage.insertIfAbsent("candidate")) {
            XCTAssertEqual($0 as? DeviceIdentifierError, .keychain(errSecInteractionNotAllowed))
        }
    }

    func testCorruptDuplicateWinnerFailsWithoutReturningCandidate() {
        let storage = DeviceIdentifierKeychain(copyItem: { _ in
            (errSecSuccess, Data("corrupt\0identifier".utf8) as CFData)
        }, addItem: { _ in errSecDuplicateItem })

        XCTAssertThrowsError(try storage.insertIfAbsent("candidate")) {
            XCTAssertEqual($0 as? DeviceIdentifierError, .corruptStoredIdentifier)
        }
    }

    func testWriteFailuresAreNotHiddenOrRetriedWithAnotherIdentity() {
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecMissingEntitlement,
                       errSecNotAvailable, errSecParam] {
            var insertionCount = 0
            let storage = DeviceIdentifierKeychain(copyItem: { _ in
                XCTFail("Failed writes must propagate their error")
                return (errSecParam, nil)
            }, addItem: { _ in
                insertionCount += 1
                return status
            })

            XCTAssertThrowsError(try storage.insertIfAbsent("candidate")) {
                XCTAssertEqual($0 as? DeviceIdentifierError, .keychain(status))
            }
            XCTAssertEqual(insertionCount, 1)
        }
    }

    func testErrorsHaveGenericLocalizedMessages() {
        XCTAssertEqual(DeviceIdentifierError.keychain(errSecInteractionNotAllowed).errorDescription,
                       DeviceIdentifierError.keychain(errSecAuthFailed).errorDescription)
        XCTAssertFalse(DeviceIdentifierError.keychain(errSecParam).localizedDescription.isEmpty)
        XCTAssertFalse(DeviceIdentifierError.corruptStoredIdentifier.localizedDescription.isEmpty)
    }

    private var identityKeys: Set<String> {
        [kSecClass as String, kSecAttrService as String,
         kSecAttrAccount as String, kSecAttrSynchronizable as String]
    }

    private func assertIdentityScope(_ attributes: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(attributes[kSecClass as String] as? String, kSecClassGenericPassword as String,
                       file: file, line: line)
        XCTAssertEqual(attributes[kSecAttrService as String] as? String, "com.dramaplayfun.device-identity",
                       file: file, line: line)
        XCTAssertEqual(attributes[kSecAttrAccount as String] as? String, "device-id-v1", file: file, line: line)
        XCTAssertEqual(attributes[kSecAttrSynchronizable as String] as? Bool, false, file: file, line: line)
        XCTAssertNil(attributes[kSecAttrAccessGroup as String], file: file, line: line)
    }
}
