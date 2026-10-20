import Foundation
import SwiftUI

nonisolated enum RemoteImageSource: Hashable, Sendable {
    case dramaCover(String)
    case dramaLandscape(String)
    case homeBanner(String)
    case profileAvatar
}

/// Image credentials come from the endpoint that owns the image, never the video-token endpoint.
@MainActor
final class RemoteImageURLRefresher {
    private enum Group: Hashable {
        case drama(String), home, profile
    }
    private struct Attempt: Hashable {
        let source: RemoteImageSource
        let oldURL: URL?
    }
    private struct Pending {
        let id: UUID
        let task: Task<[RemoteImageSource: URL], Error>
    }
    private struct Replacement {
        let url: URL
        let oldURL: URL?
        let expiresAt: Date
    }
    private let network: APIClient
    private let now: () -> Date
    private let retryDelay: TimeInterval
    private var scope: String?
    private var generation = 0
    private var pending: [Group: Pending] = [:]
    private var retryAfter: [Attempt: Date] = [:]
    private var recent: [RemoteImageSource: Replacement] = [:]

    init(network: APIClient, retryDelay: TimeInterval = 60, now: @escaping () -> Date = Date.init) {
        self.network = network
        self.retryDelay = retryDelay
        self.now = now
    }

    var currentScope: String { network.playbackCacheScope }

    func clear() {
        generation += 1
        pending.values.forEach { $0.task.cancel() }
        pending.removeAll()
        retryAfter.removeAll()
        recent.removeAll()
        scope = nil
    }

    func refreshedURL(for source: RemoteImageSource, replacing oldURL: URL?) async -> URL? {
        guard !Task.isCancelled else { return nil }
        let requestScope = currentScope
        if scope != requestScope {
            clear()
            scope = requestScope
        }
        let requestGeneration = generation
        let attempt = Attempt(source: source, oldURL: oldURL)
        // A URL that has itself just failed must not be offered to another waiter.
        if recent[source]?.url == oldURL { recent[source] = nil }
        if let replacement = recent[source], replacement.expiresAt > now(),
           oldURL == nil || oldURL.map(RemoteImageResource.cacheKey(for:)) == replacement.oldURL.map(RemoteImageResource.cacheKey(for:))
                || oldURL.map(RemoteImageResource.cacheKey(for:)) == RemoteImageResource.cacheKey(for: replacement.url) {
            return replacement.url
        }
        let group = group(for: source)
        let work: Pending
        if let existing = pending[group] {
            work = existing
        } else {
            guard retryAfter[attempt].map({ $0 > now() }) != true else { return nil }
            retryAfter = retryAfter.filter { $0.value > now() }
            recent = recent.filter { $0.value.expiresAt > now() }
            let task = Task { try await self.fetch(group: group) }
            work = Pending(id: UUID(), task: task)
            pending[group] = work
        }
        retryAfter[attempt] = now().addingTimeInterval(retryDelay)
        do {
            let urls = try await work.task.value
            guard currentScope == requestScope, generation == requestGeneration else { return nil }
            if pending[group]?.id == work.id {
                pending[group] = nil
                for (source, url) in urls {
                    recent[source] = Replacement(url: url, oldURL: nil, expiresAt: now().addingTimeInterval(retryDelay))
                }
            }
            guard !Task.isCancelled, let url = urls[source], url != oldURL else { return nil }
            recent[source] = Replacement(url: url, oldURL: oldURL, expiresAt: now().addingTimeInterval(retryDelay))
            return url
        } catch {
            if currentScope == requestScope, generation == requestGeneration, pending[group]?.id == work.id {
                pending[group] = nil
            }
            return nil
        }
    }

    /// Remember a renewed URL rejected by the image server, so later views cannot loop on it.
    func rejected(_ url: URL, for source: RemoteImageSource) {
        guard scope == currentScope else { return }
        if recent[source]?.url == url { recent[source] = nil }
        retryAfter[Attempt(source: source, oldURL: url)] = now().addingTimeInterval(retryDelay)
    }

    private func group(for source: RemoteImageSource) -> Group {
        switch source {
        case .dramaCover(let id), .dramaLandscape(let id): .drama(id)
        case .homeBanner: .home
        case .profileAvatar: .profile
        }
    }

    private func fetch(group: Group) async throws -> [RemoteImageSource: URL] {
        switch group {
        case .drama(let id):
            guard let dramaID = Int64(id), dramaID > 0 else { return [:] }
            let result = try await network.request(AppAPI.v1ClientDramaDetail,
                body: .init(dramaId: dramaID), unwrapEnvelope: true)
            var urls: [RemoteImageSource: URL] = [:]
            urls[.dramaCover(id)] = RemoteImageResource.validRefreshedURL(result.drama?.coverUrl)
            urls[.dramaLandscape(id)] = RemoteImageResource.validRefreshedURL(result.drama?.coverFourThreeUrl)
            return urls
        case .home:
            let result = try await network.request(AppAPI.v1TheaterHome, body: .init(), unwrapEnvelope: true)
            var urls: [RemoteImageSource: URL] = [:]
            for banner in result.banners ?? [] {
                guard let id = banner.id else { continue }
                urls[.homeBanner(String(id))] = RemoteImageResource.validRefreshedURL(banner.bannerImage)
            }
            return urls
        case .profile:
            let result = try await network.request(AppAPI.v1ClientMe, body: .init(), unwrapEnvelope: true)
            guard let url = RemoteImageResource.validRefreshedURL(result.avatarUrl) else { return [:] }
            return [.profileAvatar: url]
        }
    }
}

private struct RemoteImageURLRefresherKey: EnvironmentKey {
    static let defaultValue: RemoteImageURLRefresher? = nil
}

extension EnvironmentValues {
    var remoteImageURLRefresher: RemoteImageURLRefresher? {
        get { self[RemoteImageURLRefresherKey.self] }
        set { self[RemoteImageURLRefresherKey.self] = newValue }
    }
}
