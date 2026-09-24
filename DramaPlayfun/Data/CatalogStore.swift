import Foundation
import Observation

@MainActor @Observable
final class CatalogStore {
    private(set) var dramas: [Drama] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var hasLoaded = false
    private let repository: any DramaRepository

    init(repository: any DramaRepository) { self.repository = repository }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await reload()
    }

    func reload() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            dramas = try await repository.fetchDramas()
            hasLoaded = true
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func filtered(category: DramaCategory, query: String = "") -> [Drama] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return dramas.filter {
            (category == .all || $0.category == category) &&
            (query.isEmpty || $0.title.localizedStandardContains(query) || $0.category.rawValue.localizedStandardContains(query))
        }
    }
}
