import Foundation
import Observation

enum EpisodeUnlockOutcome: Equatable {
    case unlocked(coins: Int64)
    case needsConfirmation
    case needsRecharge
}

enum EpisodeUnlockError: AppLocalizedError {
    case playbackUnavailable
    case walletUnavailable
    case membershipUnavailable
    case accessUnavailable
    case settingsUnavailable

    var errorDescription: String? {
        switch self {
        case .playbackUnavailable: L10n.text("本集已解锁，播放地址暂时不可用，请重试。")
        case .walletUnavailable: L10n.text("暂时无法获取金币余额，请稍后重试。")
        case .membershipUnavailable: L10n.text("会员播放权益暂未更新，请稍后重试。")
        case .accessUnavailable: L10n.text("暂时无法确认本集播放权限，请稍后重试。")
        case .settingsUnavailable: L10n.text("暂时无法读取自动解锁设置，请稍后重试。")
        }
    }
}

@MainActor @Observable
final class EpisodeUnlockCoordinator {
    private(set) var unlockingEpisodeIDs: Set<String> = []
    var isUnlocking: Bool { !unlockingEpisodeIDs.isEmpty }

    private let playback: DramaPlaybackStore
    private let wallet: WalletStore
    private let profile: ProfileStore
    private let membership: MembershipStore
    private struct Resolution {
        let id: UUID
        let task: Task<EpisodeUnlockOutcome, Error>
    }
    private var inFlight: [String: Resolution] = [:]
    private var previousResolution: Task<EpisodeUnlockOutcome, Error>?

    init(playback: DramaPlaybackStore, wallet: WalletStore, profile: ProfileStore,
         membership: MembershipStore) {
        self.playback = playback
        self.wallet = wallet
        self.profile = profile
        self.membership = membership
    }

    /// Automatic requests respect the wallet's shared preference. Manual confirmation
    /// can buy one episode with that preference disabled; VIP never uses the coin API.
    func resolve(_ episode: Episode, automatically: Bool) async throws -> EpisodeUnlockOutcome {
        try Task.checkCancellation()
        if let existing = inFlight[episode.id] {
            if !existing.task.isCancelled { return try await existing.task.value }
            // A quick return to an episode can race the canceled request's cleanup.
            // Let any already-started payment settle, then give this new visit its own
            // request. The generation check keeps the old defer from removing it.
            _ = try? await existing.task.value
            try Task.checkCancellation()
            if inFlight[episode.id]?.id == existing.id {
                inFlight[episode.id] = nil
                unlockingEpisodeIDs.remove(episode.id)
            }
            return try await resolve(episode, automatically: automatically)
        }

        // Serialize different episodes too: a swipe must see the previous deduction
        // before checking whether the next episode can be purchased.
        let previous = previousResolution
        let task = Task {
            _ = try? await previous?.value
            try Task.checkCancellation()
            return try await performResolution(episode, automatically: automatically)
        }
        let resolutionID = UUID()
        inFlight[episode.id] = Resolution(id: resolutionID, task: task)
        previousResolution = task
        unlockingEpisodeIDs.insert(episode.id)
        defer {
            if inFlight[episode.id]?.id == resolutionID {
                inFlight[episode.id] = nil
                unlockingEpisodeIDs.remove(episode.id)
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            // Cancels status/balance reads. Once a payment has started, its separate
            // task must settle the shared balance even if this page disappears.
            task.cancel()
        }
    }

    private func performResolution(_ requested: Episode, automatically: Bool) async throws -> EpisodeUnlockOutcome {
        let episode = playback.items.first(where: { $0.firstEpisode?.id == requested.id })?.firstEpisode ?? requested
        if playback.hasAuthorizedPlayback(episode) || !episode.requiresCoinUnlock {
            if playback.items.first(where: { $0.firstEpisode?.id == episode.id })?.videoURL == nil {
                try await playback.refreshPlayableEpisode(episode)
            }
            return .unlocked(coins: 0)
        }

        // Checking server access first also protects accounts whose VIP/profile state
        // has not refreshed yet, and recovers an earlier transaction with a lost reply.
        let status = try await playback.unlockStatus(episode)
        try Task.checkCancellation()
        guard status.canWatch != nil else { throw EpisodeUnlockError.accessUnavailable }
        if status.canWatch == true {
            if status.watchAccessType == "vip", status.isVipActive != true {
                throw EpisodeUnlockError.membershipUnavailable
            }
            playback.authorizePlayback(episode)
            try await playback.refreshPlayableEpisode(episode)
            return .unlocked(coins: 0)
        }
        if status.hasCoinUnlocked == true {
            throw EpisodeUnlockError.playbackUnavailable
        }
        if status.isVipActive == true || profile.hasVIP || membership.isActive {
            throw EpisodeUnlockError.membershipUnavailable
        }
        if automatically, !profile.hasLoadedProfile {
            await profile.reloadProfile()
            try Task.checkCancellation()
            guard profile.hasLoadedProfile else { throw EpisodeUnlockError.settingsUnavailable }
        }
        if profile.hasVIP || membership.isActive { throw EpisodeUnlockError.membershipUnavailable }
        if automatically, !profile.autoPlaysNext { return .needsConfirmation }

        // A known shared balance avoids an extra round trip during continuous play.
        // Re-entering from recharge updates this same wallet through the purchase backend.
        if !automatically || wallet.availableBalance == nil {
            await wallet.reloadBalance()
            guard wallet.balanceError == nil else { throw EpisodeUnlockError.walletUnavailable }
        }
        try Task.checkCancellation()
        guard let balance = wallet.availableBalance else { throw EpisodeUnlockError.walletUnavailable }
        guard balance >= episode.unlockCoin else {
            return automatically ? .needsConfirmation : .needsRecharge
        }
        // The preference may have changed while server access/wallet reads were pending.
        if automatically, !profile.autoPlaysNext { return .needsConfirmation }
        try Task.checkCancellation()

        let payment = Task { try await completeCoinUnlock(episode, balanceBefore: balance) }
        return try await payment.value
    }

    private func completeCoinUnlock(_ episode: Episode, balanceBefore: Int64) async throws -> EpisodeUnlockOutcome {
        let response: APIModels.V1UnlockDramaEpisodeRes
        do {
            response = try await playback.unlock(episode)
        } catch {
            // Keep the balance fresh for the next attempt, while preserving the actual
            // failure. The contract does not define an insufficient-funds error code.
            await wallet.reloadBalance()
            throw error
        }
        if let balance = response.walletBalance {
            wallet.updateBalance(balance)
        } else {
            await wallet.reloadBalance()
        }
        // Reuse the prewarmed URL/item after the grant. Only an absent URL needs a
        // list refresh, which can be retried without charging this episode again.
        try await playback.refreshPlayableEpisode(episode)
        // Other wallet activity can make the returned balance differ by more than this
        // episode's price. Never attribute that unrelated difference to this unlock.
        let spent = response.walletBalance.map { min(episode.unlockCoin, max(0, balanceBefore - $0)) }
            ?? episode.unlockCoin
        return .unlocked(coins: spent)
    }
}
