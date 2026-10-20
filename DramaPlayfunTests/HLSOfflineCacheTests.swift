import AVFoundation
import XCTest
@testable import DramaPlayfun

@MainActor
final class HLSOfflineCacheTests: XCTestCase {
    private func fixture() throws -> (UserDefaults, URL) {
        let suite = "HLSOfflineCacheTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        return (defaults, library)
    }

    private func package(in directory: URL, named name: String = "episode.movpkg") throws -> URL {
        let url = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("legacy package".utf8).write(to: url.appendingPathComponent("payload"))
        return url
    }

    private func completed(_ entries: [String: Any], in defaults: UserDefaults) throws {
        defaults.set(try JSONSerialization.data(withJSONObject: entries),
                     forKey: HLSLegacyAssetMigration.completedKey)
    }

    func testLegacyPackageNeverOverridesFreshGatewayOrCurrentIdentity() async throws {
        let (defaults, library) = try fixture()
        let old = try package(in: library.appendingPathComponent("com.apple.UserManagedAssets.old"))
        try completed(["2531": ["path": old.path, "savedAt": 0]], in: defaults)
        let cache = HLSOfflineCache(defaults: defaults, libraryDirectory: library,
            cancelLegacyDownloads: false, secret: Data("test-secret".utf8))
        XCTAssertNil(defaults.object(forKey: HLSLegacyAssetMigration.completedKey))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))

        let identity = HLSKeyIdentity(rootDramaID: 107, episodeID: 2531)
        let source = URL(string: "https://media.example.invalid/master.m3u8?X-Media-Token=current")!
        let first = try await cache.asset(for: "2531", remoteURL: source, identity: identity)
        let second = try await cache.asset(for: "2531", remoteURL: source, identity: identity)
        XCTAssertEqual(first.url.host, "127.0.0.1")
        XCTAssertEqual(second.url.host, "127.0.0.1")
        XCTAssertFalse(first.url.isFileURL)
        XCTAssertNotEqual(first.url, second.url, "Every playback needs a current gateway lease and key route")
        do {
            _ = try await cache.asset(for: "2531", remoteURL: source,
                identity: HLSKeyIdentity(rootDramaID: 0, episodeID: 2531))
            XCTFail("A stale cached episode must not bypass current key identity validation")
        } catch {
            XCTAssertEqual(error as? HLSKeyError, .invalidIdentity)
        }
    }

    func testMigrationRemovesCompletedPendingAndNoFollowPackagesOnly() throws {
        let (defaults, library) = try fixture()
        let container = library.appendingPathComponent("com.apple.UserManagedAssets.fixture")
        let finished = try package(in: container, named: "finished.movpkg")
        let pending = try package(in: container, named: "pending.movpkg")
        let alias = try package(in: container, named: "alias.movpkg")
        let unrelated = try package(in: container, named: "unrecorded.movpkg")
        try completed([
            "finished": ["path": finished.path],
            "alias": ["path": "/.nofollow" + alias.path],
            "malformed": 42
        ], in: defaults)
        let pendingEntries: [String: Any] = ["pending": pending.path, "bad": 7]
        defaults.set(pendingEntries, forKey: HLSLegacyAssetMigration.pendingKey)

        _ = HLSLegacyAssetMigration(defaults: defaults, libraryDirectory: library)

        for url in [finished, pending, alias] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertNil(defaults.object(forKey: HLSLegacyAssetMigration.completedKey))
        XCTAssertNil(defaults.object(forKey: HLSLegacyAssetMigration.pendingKey))
    }

    func testMigrationRejectsOutsideNestedNonPackageAndSymbolicLinkPaths() throws {
        let (defaults, library) = try fixture()
        let container = library.appendingPathComponent("com.apple.UserManagedAssets.fixture")
        let outside = try package(in: library.deletingLastPathComponent()
            .appendingPathComponent("Other/Library/com.apple.UserManagedAssets.other"))
        let ordinary = try package(in: library.appendingPathComponent("Documents"))
        let nested = try package(in: container.appendingPathComponent("nested"))
        let nonPackage = try package(in: container, named: "keep.data")
        let symlinkTarget = try package(in: container, named: "target.movpkg")
        let packageLink = container.appendingPathComponent("link.movpkg")
        try FileManager.default.createSymbolicLink(at: packageLink, withDestinationURL: symlinkTarget)
        let containerLink = library.appendingPathComponent("com.apple.UserManagedAssets.link")
        try FileManager.default.createSymbolicLink(at: containerLink, withDestinationURL: container)
        let throughContainerLink = containerLink.appendingPathComponent("target.movpkg")
        let candidates = [outside, ordinary, nested, nonPackage, packageLink, throughContainerLink]
        try completed(Dictionary(uniqueKeysWithValues: candidates.enumerated().map {
            (String($0.offset), ["path": $0.element.path])
        }), in: defaults)

        _ = HLSLegacyAssetMigration(defaults: defaults, libraryDirectory: library)

        for url in candidates + [symlinkTarget] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.lastPathComponent)
        }
    }

    func testMalformedIndexesAreRevokedAndLateCallbacksCannotRestoreThem() throws {
        let (defaults, library) = try fixture()
        defaults.set(Data("invalid JSON".utf8), forKey: HLSLegacyAssetMigration.completedKey)
        defaults.set("invalid pending data", forKey: HLSLegacyAssetMigration.pendingKey)
        let migration = HLSLegacyAssetMigration(defaults: defaults, libraryDirectory: library)
        let late = try package(in: library.appendingPathComponent("com.apple.UserManagedAssets.late"))
        migration.record(late)
        migration.record(URL(string: "https://example.invalid/episode.movpkg")!)
        migration.removePackages()
        migration.removePackages()
        XCTAssertFalse(FileManager.default.fileExists(atPath: late.path))
        XCTAssertNil(defaults.object(forKey: HLSLegacyAssetMigration.completedKey))
        XCTAssertNil(defaults.object(forKey: HLSLegacyAssetMigration.pendingKey))
    }
}
