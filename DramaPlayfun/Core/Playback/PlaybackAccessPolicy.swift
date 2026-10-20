import Foundation

/// Metadata freshness and a server-confirmed playback grant have separate clocks.
enum PlaybackAccessPolicy {
    static let maxAge: TimeInterval = 300

    static func validUntil(for status: APIModels.V1GetEpisodeUnlockStatusRes,
                           now: Date) throws -> Date {
        guard status.canWatch == true else { throw EpisodeUnlockError.accessUnavailable }
        if status.watchAccessType == "vip", status.isVipActive != true {
            throw EpisodeUnlockError.membershipUnavailable
        }
        var deadline = now.addingTimeInterval(maxAge)
        // Without a positive expiry, conservatively cap the grant at maxAge.
        let timestamps = [status.expireAt, status.watchAccessType == "vip" ? status.vipExpireAt : nil]
        for timestamp in timestamps.compactMap({ $0 }) {
            guard timestamp >= 0 else { throw EpisodeUnlockError.accessUnavailable }
            if timestamp == 0 { continue }
            let expiration = Date(timeIntervalSince1970: Double(timestamp) / 1_000)
            guard expiration > now else { throw EpisodeUnlockError.accessUnavailable }
            deadline = min(deadline, expiration)
        }
        return deadline
    }
}
