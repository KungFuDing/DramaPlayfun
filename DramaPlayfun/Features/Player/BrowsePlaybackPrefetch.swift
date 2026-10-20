import SwiftUI

/// Geometry is kept in the browse view's coordinate space, including nested scroll clipping.
struct BrowsePlaybackCandidate: Equatable {
    let dramaID: String
    let frame: CGRect
    var clipFrames: [CGRect] = []
}

enum BrowsePlaybackPrefetch {
    static func selectedDramaIDs(
        from candidates: [BrowsePlaybackCandidate],
        viewport: CGRect,
        limit: Int = 3,
        minimumVisibleFraction: CGFloat = 0.55
    ) -> [String] {
        guard viewport.width > 0, viewport.height > 0, limit > 0 else { return [] }
        var distances: [String: CGFloat] = [:]
        for candidate in candidates {
            let frame = candidate.frame
            guard !candidate.dramaID.isEmpty, frame.width > 0, frame.height > 0 else { continue }
            let visible = candidate.clipFrames.reduce(frame.intersection(viewport)) {
                $0.intersection($1)
            }
            guard !visible.isNull, !visible.isEmpty,
                  visible.width * visible.height / (frame.width * frame.height) >= minimumVisibleFraction else {
                continue
            }
            let dx = frame.midX - viewport.midX
            let dy = frame.midY - viewport.midY
            let distance = dx * dx + dy * dy
            distances[candidate.dramaID] = min(distance, distances[candidate.dramaID] ?? .infinity)
        }
        return distances.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value
        }.prefix(limit).map(\.key)
    }

    /// A new geometry snapshot cancels this task, including items not yet started in the batch.
    @MainActor
    static func afterDwell(
        dramaIDs: [String],
        delay: Duration = .milliseconds(400),
        prefetch: @MainActor (String) async -> Void
    ) async {
        guard !dramaIDs.isEmpty else { return }
        do { try await Task.sleep(for: delay) }
        catch { return }
        for dramaID in dramaIDs {
            guard !Task.isCancelled else { return }
            await prefetch(dramaID)
        }
    }
}

private struct BrowsePlaybackGeometry {
    struct Card {
        let dramaID: String
        let bounds: Anchor<CGRect>
        let clipIDs: [UUID]
    }
    var cards: [Card] = []
    var clips: [UUID: Anchor<CGRect>] = [:]
}

private struct BrowsePlaybackGeometryKey: PreferenceKey {
    static var defaultValue: BrowsePlaybackGeometry { BrowsePlaybackGeometry() }

    static func reduce(value: inout BrowsePlaybackGeometry, nextValue: () -> BrowsePlaybackGeometry) {
        let next = nextValue()
        value.cards.append(contentsOf: next.cards)
        value.clips.merge(next.clips) { _, new in new }
    }
}

private struct BrowsePlaybackClipIDsKey: EnvironmentKey {
    static let defaultValue: [UUID] = []
}

private struct BrowsePlaybackEligibleKey: EnvironmentKey {
    static let defaultValue = true
}

private extension EnvironmentValues {
    var browsePlaybackClipIDs: [UUID] {
        get { self[BrowsePlaybackClipIDsKey.self] }
        set { self[BrowsePlaybackClipIDsKey.self] = newValue }
    }

    var browsePlaybackEligible: Bool {
        get { self[BrowsePlaybackEligibleKey.self] }
        set { self[BrowsePlaybackEligibleKey.self] = newValue }
    }
}

private struct BrowsePlaybackCardModifier: ViewModifier {
    let dramaID: String
    let enabled: Bool
    @Environment(\.browsePlaybackClipIDs) private var clipIDs
    @Environment(\.browsePlaybackEligible) private var eligible

    func body(content: Content) -> some View {
        content.anchorPreference(key: BrowsePlaybackGeometryKey.self, value: .bounds) { bounds in
            BrowsePlaybackGeometry(cards: enabled && eligible
                ? [.init(dramaID: dramaID, bounds: bounds, clipIDs: clipIDs)] : [])
        }
    }
}

private struct BrowsePlaybackClipModifier: ViewModifier {
    @Environment(\.browsePlaybackClipIDs) private var parentClipIDs
    @State private var clipID = UUID()

    func body(content: Content) -> some View {
        content
            .environment(\.browsePlaybackClipIDs, parentClipIDs + [clipID])
            .transformAnchorPreference(key: BrowsePlaybackGeometryKey.self, value: .bounds) { value, bounds in
                value.clips[clipID] = bounds
            }
    }
}

private struct BrowsePlaybackSnapshot: Equatable {
    var viewport: CGRect = .zero
    var candidates: [BrowsePlaybackCandidate] = []
}

private struct BrowsePlaybackRequest: Equatable {
    let active: Bool
    let categoryID: String
    let snapshot: BrowsePlaybackSnapshot
}

private struct BrowsePlaybackViewportModifier: ViewModifier {
    let active: Bool
    let categoryID: String
    let obscuredTop: CGFloat
    @Environment(AppContainer.self) private var app
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .overlayPreferenceValue(BrowsePlaybackGeometryKey.self) { anchors in
                GeometryReader { geometry in
                    let request = BrowsePlaybackRequest(
                        active: active && scenePhase == .active,
                        categoryID: categoryID,
                        snapshot: snapshot(anchors: anchors, geometry: geometry)
                    )
                    Color.clear
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .task(id: request) {
                            guard request.active else { return }
                            let ids = BrowsePlaybackPrefetch.selectedDramaIDs(
                                from: request.snapshot.candidates, viewport: request.snapshot.viewport
                            )
                            await BrowsePlaybackPrefetch.afterDwell(dramaIDs: ids) { dramaID in
                                await app.playbackDetails.prefetch(dramaID: dramaID)
                            }
                        }
                }
            }
    }

    private func snapshot(anchors: BrowsePlaybackGeometry, geometry: GeometryProxy) -> BrowsePlaybackSnapshot {
        let top = min(max(0, obscuredTop), geometry.size.height)
        let viewport = CGRect(x: 0, y: top, width: geometry.size.width, height: geometry.size.height - top)
        let candidates = anchors.cards.map { card in
            BrowsePlaybackCandidate(
                dramaID: card.dramaID,
                frame: geometry[card.bounds],
                clipFrames: card.clipIDs.map { id in
                    // A missing clip must never make an off-screen card eligible.
                    anchors.clips[id].map { geometry[$0] } ?? .zero
                }
            )
        }
        return BrowsePlaybackSnapshot(viewport: viewport, candidates: candidates)
    }
}

extension View {
    func playbackPrefetchCandidate(dramaID: String, enabled: Bool = true) -> some View {
        modifier(BrowsePlaybackCardModifier(dramaID: dramaID, enabled: enabled))
    }

    /// Register a clipping container so horizontal neighbors outside its bounds cannot prefetch.
    func playbackPrefetchClipped() -> some View {
        modifier(BrowsePlaybackClipModifier())
    }

    func playbackPrefetchEligible(_ eligible: Bool) -> some View {
        environment(\.browsePlaybackEligible, eligible)
    }

    func playbackDetailPrefetch(active: Bool, categoryID: String, obscuredTop: CGFloat = 0) -> some View {
        modifier(BrowsePlaybackViewportModifier(active: active, categoryID: categoryID, obscuredTop: obscuredTop))
    }
}
