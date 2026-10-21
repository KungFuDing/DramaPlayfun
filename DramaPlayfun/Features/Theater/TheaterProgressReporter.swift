import Foundation

/// Serializes reports and coalesces queued updates so an older request cannot overwrite newer progress.
@MainActor
final class TheaterProgressReporter {
    private let network: APIClient
    private let accountSessionID: UUID
    private let interval: TimeInterval
    private var pending: [String: APIModels.V1ReportDramaProgressReq] = [:]
    private var queue: [String] = []
    private var lastQueued: [String: Date] = [:]
    private var lastSaved: [String: APIModels.V1ReportDramaProgressReq] = [:]
    private var inFlight: APIModels.V1ReportDramaProgressReq?
    private var worker: Task<Void, Never>?
    private var acceptsReports = true

    init(network: APIClient, interval: TimeInterval = 10) {
        self.network = network
        accountSessionID = network.accountSessionID
        self.interval = interval
    }

    func report(_ progress: WatchProgress, force: Bool = false, now: Date = Date()) {
        guard isCurrentAccount else { retireAccount(); return }
        guard let episodeID = Int64(progress.episodeID), let dramaID = Int64(progress.dramaID),
              progress.seconds.isFinite, progress.duration.isFinite,
              progress.seconds >= 0, progress.duration > 0,
              progress.duration < Double(Int.max) else { return }
        let body = APIModels.V1ReportDramaProgressReq(
            dramaId: dramaID, episodeId: episodeID,
            progressSeconds: Int(min(progress.seconds, progress.duration)),
            durationSeconds: Int(progress.duration.rounded(.up)))
        let key = progress.episodeID
        if inFlight?.episodeId != episodeID, let saved = lastSaved[key], saved.progressSeconds == body.progressSeconds,
           saved.durationSeconds == body.durationSeconds, pending[key] == nil { return }
        if let active = inFlight, active.episodeId == episodeID,
           active.progressSeconds == body.progressSeconds, pending[key] == nil { return }
        if !force, let last = lastQueued[key], now.timeIntervalSince(last) < interval { return }
        lastQueued[key] = now
        if pending[key] == nil { queue.append(key) }
        pending[key] = body
        guard worker == nil else { return }
        worker = Task { await drain() }
    }

    /// Useful for lifecycle checks and deterministic tests; does not cancel outstanding reports.
    func flush() async { await worker?.value }

    /// A retired player's callbacks must never send history under a replacement account.
    func retireAccount() {
        acceptsReports = false
        pending.removeAll()
        queue.removeAll()
        lastQueued.removeAll()
        lastSaved.removeAll()
        inFlight = nil
        worker?.cancel()
    }

    private func drain() async {
        defer { inFlight = nil; worker = nil }
        while !queue.isEmpty {
            guard isCurrentAccount, !Task.isCancelled else { return }
            let key = queue.removeFirst()
            guard let body = pending.removeValue(forKey: key) else { continue }
            inFlight = body
            do {
                let result = try await network.request(AppAPI.v1ClientDramaProgress,
                    body: body, unwrapEnvelope: true)
                guard isCurrentAccount, !Task.isCancelled else { return }
                guard result.saved != false else { throw TheaterInteractionError.progressRejected }
                lastSaved[key] = body
            } catch is CancellationError {
                pending.removeAll()
                queue.removeAll()
                return
            } catch {
                // Network logging records the error. The next periodic or final report retries the latest position.
            }
            inFlight = nil
        }
    }

    private var isCurrentAccount: Bool {
        acceptsReports && accountSessionID == network.accountSessionID
    }
}
