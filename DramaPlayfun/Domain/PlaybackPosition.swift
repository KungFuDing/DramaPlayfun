import Foundation

struct PlaybackPosition: Hashable, Codable, Sendable {
    let episodeNumber: Int
    let seconds: Double

    init(episodeNumber: Int? = nil, seconds: Double? = nil) {
        self.episodeNumber = max(episodeNumber ?? 1, 1)
        self.seconds = seconds.flatMap { $0.isFinite ? max($0, 0) : nil } ?? 0
    }
}
