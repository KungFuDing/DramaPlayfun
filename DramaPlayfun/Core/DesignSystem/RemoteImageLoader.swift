import Foundation
import Kingfisher
import UIKit

@MainActor
enum RemoteImageLoader {
    private static var generation = UUID()
    private static var isResettingAccount = false
    private static var requests: [UUID: Task<UIImage, Error>] = [:]

    static func load(
        url: URL?,
        source: RemoteImageSource?,
        refresher: RemoteImageURLRefresher?,
        manager: KingfisherManager = .shared
    ) async throws -> UIImage {
        try Task.checkCancellation()
        guard !isResettingAccount else { throw CancellationError() }
        let revision = generation
        let id = UUID()
        let task = Task {
            try await loadImage(url: url, source: source, refresher: refresher, manager: manager)
        }
        requests[id] = task
        defer { requests[id] = nil }
        let image = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
        try Task.checkCancellation()
        guard revision == generation else { throw CancellationError() }
        return image
    }

    static func clearForAccountChange() async {
        isResettingAccount = true
        generation = UUID()
        let pending = Array(requests.values)
        pending.forEach { $0.cancel() }
        KingfisherManager.shared.downloader.cancelAll()
        // Waiting for processing and disk writes prevents old downloads from
        // repopulating the cache after it has been cleared.
        for task in pending { _ = await task.result }
        ImageCache.default.clearMemoryCache()
        await ImageCache.default.clearDiskCache()
        isResettingAccount = false
    }

    private static func loadImage(
        url: URL?, source: RemoteImageSource?, refresher: RemoteImageURLRefresher?,
        manager: KingfisherManager
    ) async throws -> UIImage {
        let scope = refresher?.currentScope
        try Task.checkCancellation()
        guard let url else {
            guard let source, let refresher,
                  let fresh = await refresher.refreshedURL(for: source, replacing: nil) else {
                throw URLError(.badURL)
            }
            try validate(scope: scope, refresher: refresher)
            do {
                let image = try await retrieve(fresh, manager: manager)
                try validate(scope: scope, refresher: refresher)
                return image
            } catch {
                try validate(scope: scope, refresher: refresher)
                if isAuthorizationFailure(error) { refresher.rejected(fresh, for: source) }
                throw error
            }
        }
        do {
            // Kingfisher checks memory and disk using the token-independent content key first.
            let image = try await retrieve(url, manager: manager)
            try validate(scope: scope, refresher: refresher)
            return image
        } catch {
            try validate(scope: scope, refresher: refresher)
            guard RemoteImageResource.hasMediaToken(url), isAuthorizationFailure(error),
                  let source, let refresher,
                  let fresh = await refresher.refreshedURL(for: source, replacing: url) else { throw error }
            try validate(scope: scope, refresher: refresher)
            do {
                // The replacement retains its own content key if the server changed image/version/size.
                let image = try await retrieve(fresh, manager: manager)
                try validate(scope: scope, refresher: refresher)
                return image
            } catch {
                try validate(scope: scope, refresher: refresher)
                if isAuthorizationFailure(error) { refresher.rejected(fresh, for: source) }
                throw error
            }
        }
    }

    static func isAuthorizationFailure(_ error: Error) -> Bool {
        guard let error = error as? KingfisherError else { return false }
        return error.isInvalidResponseStatusCode(401) || error.isInvalidResponseStatusCode(403)
    }

    private static func retrieve(_ url: URL, manager: KingfisherManager) async throws -> UIImage {
        try await manager.retrieveImage(with: RemoteImageResource.resource(for: url), options: [.waitForCache]).image
    }

    private static func validate(scope: String?, refresher: RemoteImageURLRefresher?) throws {
        try Task.checkCancellation()
        guard scope == refresher?.currentScope else { throw CancellationError() }
    }
}
