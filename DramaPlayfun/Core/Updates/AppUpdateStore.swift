import Foundation
import Observation

nonisolated struct AppUpdateNotice: Identifiable, Equatable, Sendable {
    var id: String { "\(version)|\(isForced)" }
    let version: String
    let title: String
    let content: String
    let isForced: Bool
    let downloadURL: URL?

    init?(response: APIModels.V1CheckAppUpdateRes) {
        guard response.hasUpdate == true else { return nil }
        isForced = response.forceUpdate == true
        version = Self.nonempty(response.latestVersion) ?? ""
        title = Self.nonempty(response.title) ?? (isForced ? "版本升级提醒" : "新版本已就绪")
        content = Self.nonempty(response.content) ?? (isForced
            ? "为了保障服务稳定，请完成本次版本升级后继续使用"
            : "本次更新优化了播放体验，并带来更多内容推荐。立即更新，体验更流畅")
        downloadURL = Self.downloadURL(response.downloadUrl)
    }

    private static func nonempty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    private static func downloadURL(_ text: String?) -> URL? {
        guard let text = nonempty(text),
              !text.contains(where: { $0.isWhitespace || $0.isNewline }),
              let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              ["https", "http", "itms-apps"].contains(scheme),
              components.host?.isEmpty == false,
              components.user == nil, components.password == nil else { return nil }
        return components.url
    }
}

@MainActor @Observable
final class AppUpdateStore {
    private let network: APIClient
    private let currentVersion: String
    private var dismissedOptionalVersions: Set<String> = []
    private(set) var notice: AppUpdateNotice?
    private(set) var isChecking = false
    private(set) var isOpening = false
    private(set) var errorMessage: String?

    init(network: APIClient, currentVersion: String) {
        self.network = network
        self.currentVersion = currentVersion
    }

    func checkForUpdates() async {
        guard !isChecking else { return }
        isChecking = true
        errorMessage = nil
        defer { isChecking = false }
        do {
            let response = try await network.request(AppAPI.v1ClientAppUpdateCheck,
                body: .init(currentVersion: currentVersion), unwrapEnvelope: true)
            try Task.checkCancellation()
            guard let hasUpdate = response.hasUpdate else { throw AppUpdateError.invalidResponse }
            guard hasUpdate else {
                notice = nil
                return
            }
            guard let update = AppUpdateNotice(response: response) else { throw AppUpdateError.invalidResponse }
            // An incomplete response must not silently remove an existing mandatory update.
            if notice?.isForced == true, response.forceUpdate == nil || update.version.isEmpty {
                throw AppUpdateError.invalidResponse
            }
            notice = !update.isForced && dismissedOptionalVersions.contains(update.version) ? nil : update
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func dismiss() {
        guard let notice, !notice.isForced else { return }
        dismissedOptionalVersions.insert(notice.version)
        self.notice = nil
        errorMessage = nil
    }

    func openUpdate(using openURL: @MainActor (URL) async -> Bool) async {
        guard let notice, !isOpening else { return }
        guard let url = notice.downloadURL else {
            errorMessage = "更新地址暂不可用，请稍后重试。"
            return
        }
        isOpening = true
        errorMessage = nil
        defer { isOpening = false }
        let opened = await openURL(url)
        guard self.notice?.id == notice.id else { return }
        if !opened { errorMessage = "无法打开更新页面，请稍后重试。" }
    }
}

nonisolated private enum AppUpdateError: LocalizedError {
    case invalidResponse
    var errorDescription: String? { "更新信息暂不可用，请稍后重试。" }
}
