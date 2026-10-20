import Foundation
import Kingfisher
import UIKit

@MainActor
enum RemoteImageLoader {
    static func load(
        url: URL?,
        source: RemoteImageSource?,
        refresher: RemoteImageURLRefresher?,
        manager: KingfisherManager = .shared
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
        try await manager.retrieveImage(with: RemoteImageResource.resource(for: url)).image
    }

    private static func validate(scope: String?, refresher: RemoteImageURLRefresher?) throws {
        try Task.checkCancellation()
        guard scope == refresher?.currentScope else { throw CancellationError() }
    }
}
