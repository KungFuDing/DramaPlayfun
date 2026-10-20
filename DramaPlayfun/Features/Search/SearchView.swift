import SwiftUI

struct SearchView: View {
    @Environment(AppContainer.self) private var app
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var store: SearchStore
    @State private var input = ""
    @State private var submittedKeyword: String?
    @State private var retry = 0
    @FocusState private var isInputFocused: Bool

    init(network: APIClient) { _store = State(initialValue: SearchStore(network: network)) }

    private var isShowingResults: Bool { submittedKeyword != nil }
    private var isInputEmpty: Bool { input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var intent: SearchIntent { .init(input: input, submittedKeyword: submittedKeyword, retry: retry) }
    private var inputBinding: Binding<String> {
        Binding(get: { input }, set: { value in
            // Resigning focus can commit the same text again; only edits reset the results.
            guard value != input else { return }
            input = value
            submittedKeyword = nil
        })
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = BrowseLayout(width: geometry.size.width)
            VStack(spacing: 0) {
                SearchInputBar(input: inputBinding, isFocused: $isInputFocused,
                    onBack: { dismiss() }, onSearch: submit)
                    .frame(width: layout.contentWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.top, layout.searchTopInset)

                RefreshLoadScrollView(
                    hasMore: isShowingResults ? store.hasMore : app.homeFeed.hasMoreHot,
                    isLoadingMore: isShowingResults ? store.isLoadingMore : app.homeFeed.isLoadingMore,
                    loadError: isShowingResults ? store.loadMoreError : app.homeFeed.hotErrorMessage,
                    coordinateSpaceName: "searchScroll",
                    onRefresh: {
                        await store.loadHistory()
                        if let submittedKeyword { await store.search(submittedKeyword) }
                        else { await app.homeFeed.reload() }
                    },
                    onLoadMore: {
                        if isShowingResults { await store.loadMore() }
                        else { await app.homeFeed.loadMore() }
                    }
                ) {
                    VStack(alignment: .leading, spacing: 24) {
                        if isInputEmpty && !isShowingResults {
                            SearchHistorySection(store: store) { keyword in
                                input = keyword
                                submit()
                            }
                        } else {
                            matches(layout: layout)
                        }
                        hotDramas(layout: layout)
                    }
                    .frame(width: layout.contentWidth, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.top, isInputEmpty ? 24 : 21)
                    .padding(.bottom, 20)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .accessibilityIdentifier("search-feed")
            }
        }
        .background { SearchBackground().ignoresSafeArea() }
        .toolbar(.hidden, for: .navigationBar, .tabBar)
        .navigationBackGesture()
        .buttonStyle(.plain)
        .task { await store.loadHistory() }
        .task { await app.homeFeed.loadIfNeeded() }
        .task(id: intent) {
            if let submittedKeyword { await store.search(submittedKeyword) }
            else { await store.suggest(input) }
        }
    }

    @ViewBuilder private func matches(layout: BrowseLayout) -> some View {
        if store.isSearching || store.isLoadingSuggestions {
            ProgressView(L10n.tr("搜索中…")).frame(maxWidth: .infinity).padding(.vertical, 24)
        } else if store.searchError != nil {
            NetworkFailureContent {
                if let submittedKeyword { await store.search(submittedKeyword) }
                else { await store.suggest(input, debounce: .zero) }
            }
            .padding(.vertical, 10)
        } else {
            let dramas = isShowingResults ? store.results : store.suggestions
            if dramas.isEmpty {
                SearchEmptyView()
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 24, alignment: .top),
                        count: layout.resultColumnCount),
                    alignment: .leading,
                    spacing: 20
                ) {
                    ForEach(dramas) { drama in
                        SearchResultRow(drama: drama) { router.openPlayback(drama) }
                    }
                }
                .accessibilityIdentifier(isShowingResults ? "search-results" : "search-suggestions")
            }
        }
    }

    private func hotDramas(layout: BrowseLayout) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack(alignment: .trailing) {
                Image("HomeHeadingGlow").resizable().scaledToFit()
                    .frame(width: 30, height: 30).offset(x: 11, y: 1)
                Text(L10n.tr("热播剧集")).font(.system(size: 16, weight: .semibold))
            }.frame(height: 20)
            if !app.homeFeed.hotDramas.isEmpty {
                SearchHotGrid(dramas: app.homeFeed.hotDramas, layout: layout)
            } else if app.homeFeed.isLoading || app.homeFeed.isLoadingMore {
                ProgressView(L10n.tr("加载剧集…")).frame(maxWidth: .infinity).padding(24)
            } else if app.homeFeed.hotErrorMessage == nil {
                Text(L10n.tr("暂无热播剧集")).font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(24)
            }
        }
    }

    private func submit() {
        let keyword = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { isInputFocused = true; return }
        isInputFocused = false
        submittedKeyword = keyword
        retry += 1
    }
}

private struct SearchIntent: Hashable {
    let input: String
    let submittedKeyword: String?
    let retry: Int
}

private struct SearchInputBar: View {
    @Binding var input: String
    var isFocused: FocusState<Bool>.Binding
    let onBack: () -> Void
    let onSearch: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image("SearchBack").resizable().scaledToFit().frame(width: 22, height: 22)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }.accessibilityLabel(L10n.tr("返回")).accessibilityIdentifier("search-back")
            HStack(spacing: 8) {
                Image("SearchIcon").renderingMode(.template).resizable().scaledToFit()
                    .foregroundStyle(.white.opacity(0.65)).frame(width: 16, height: 16)
                TextField("", text: $input, prompt: Text(L10n.tr("请输入剧名、类型")).foregroundStyle(.white.opacity(0.55)))
                    .font(.system(size: 14)).foregroundStyle(.white)
                    .frame(minHeight: 44)
                    .focused(isFocused).submitLabel(.search)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .onSubmit(onSearch).accessibilityLabel(L10n.tr("请输入剧名、类型"))
                    .accessibilityIdentifier("search-input")
                Button(action: onSearch) {
                    Text(L10n.tr("搜索")).font(.system(size: 14)).foregroundStyle(Color(white: 0.12))
                        .frame(width: 56, height: 26)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 6))
                        .frame(height: 44)
                        .contentShape(Rectangle())
                }.accessibilityIdentifier("search-submit")
            }
            .padding(.leading, 10).padding(.trailing, 4).frame(height: 44)
            .background(.white.opacity(0.13), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct SearchHistorySection: View {
    let store: SearchStore
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.tr("最近搜索")).font(.system(size: 16, weight: .semibold))
                Spacer()
                Button { Task { await store.clearHistory() } } label: {
                    Group {
                        if store.isClearingHistory { ProgressView().frame(width: 16, height: 16) }
                        else { Image("SearchHistoryDelete").resizable().scaledToFit().frame(width: 16, height: 16) }
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .disabled(store.isClearingHistory || store.history.isEmpty)
                .accessibilityLabel(L10n.tr("清空最近搜索")).accessibilityIdentifier("search-clear-history")
            }
            if let message = store.historyError {
                VStack(alignment: .leading, spacing: 6) {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                    Button(L10n.tr("重新加载历史")) { Task { await store.loadHistory() } }
                }
            }
            if !store.history.isEmpty {
                SearchHistoryFlow(horizontalSpacing: 10, verticalSpacing: 4) {
                    ForEach(Array(store.history.enumerated()), id: \.offset) { _, keyword in
                        Button { onSelect(keyword) } label: {
                            Text(keyword).font(.system(size: 12)).foregroundStyle(Color(white: 0.8))
                                .lineLimit(1).padding(.horizontal, 10).frame(height: 25)
                                .frame(maxWidth: 156)
                                .background(.white.opacity(0.12), in: Capsule())
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }.accessibilityLabel(keyword)
                    }
                }.accessibilityIdentifier("search-history")
            } else if store.isLoadingHistory {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 12)
            } else if store.historyError == nil {
                Text(L10n.tr("暂无搜索记录")).font(.system(size: 12)).foregroundStyle(Color(white: 0.6))
                    .padding(.vertical, 8).accessibilityIdentifier("search-history-empty")
            }
        }
    }
}

private struct SearchResultRow: View {
    let drama: Drama
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 10) {
                DramaPoster(drama: drama, aspectRatio: 95.0 / 123, cornerRadius: 10).frame(width: 95)
                VStack(alignment: .leading, spacing: 8) {
                    Text(drama.title).font(.system(size: 14)).foregroundStyle(Color(white: 0.9)).lineLimit(2)
                    if !drama.tagNames.isEmpty {
                        Text(drama.tagNames.joined(separator: "   "))
                            .font(.system(size: 11)).foregroundStyle(Color(white: 0.6)).lineLimit(1)
                    }
                    if !drama.summary.isEmpty {
                        Text(drama.summary).font(.system(size: 12)).foregroundStyle(Color(white: 0.6))
                            .lineSpacing(3).lineLimit(3)
                    }
                }.padding(.top, 2).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }.accessibilityIdentifier("search-result-\(drama.id)")
    }
}

private struct SearchHotGrid: View {
    let dramas: [Drama]
    let layout: BrowseLayout

    var body: some View {
        HStack(alignment: .top, spacing: layout.columnSpacing) {
            ForEach(0..<layout.columnCount, id: \.self) { index in
                column(index: index)
            }
        }
    }

    private func column(index: Int) -> some View {
        LazyVStack(spacing: 16) {
            ForEach(dramas.enumerated().compactMap { $0.offset % layout.columnCount == index ? $0.element : nil }) { drama in
                SearchHotCard(drama: drama)
            }
        }.frame(maxWidth: .infinity, alignment: .top)
    }
}

private struct SearchHotCard: View {
    @Environment(AppRouter.self) private var router
    let drama: Drama

    var body: some View {
        Button { router.openPlayback(drama) } label: {
            VStack(alignment: .leading, spacing: 0) {
                DramaPoster(drama: drama, aspectRatio: 0.77, cornerRadius: 0)
                VStack(alignment: .leading, spacing: 7) {
                    Text(drama.title).font(.system(size: 14)).lineLimit(2)
                    if !drama.tagNames.isEmpty {
                        Text(drama.tagNames.joined(separator: "   "))
                            .font(.system(size: 11)).foregroundStyle(Color(white: 0.6)).lineLimit(1)
                    }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: 12))
        }.accessibilityIdentifier("search-hot-\(drama.id)")
    }
}

private struct SearchBackground: View {
    var body: some View {
        GeometryReader { geometry in
            Theme.background
            Canvas { context, size in
                let glowWidth = min(size.width, 600)
                let bounds = Path(CGRect(origin: .zero, size: size))
                context.fill(bounds, with: .radialGradient(
                    Gradient(colors: [Color(red: 0.61, green: 0.46, blue: 0.25), .clear]),
                    center: .zero, startRadius: 0, endRadius: glowWidth * 0.95))
                context.fill(bounds, with: .radialGradient(
                    Gradient(colors: [Color(red: 0.35, green: 0.11, blue: 0.12), .clear]),
                    center: CGPoint(x: size.width, y: 0), startRadius: 0, endRadius: glowWidth * 0.9))
                let scale = glowWidth / 375
                context.fill(Path(ellipseIn: CGRect(x: -57 * scale, y: -95 * scale, width: 212 * scale, height: 205 * scale)),
                    with: .color(.white.opacity(0.04)))
                context.fill(Path(ellipseIn: CGRect(x: 112 * scale, y: -53 * scale, width: 86 * scale, height: 96 * scale)),
                    with: .color(.white.opacity(0.04)))
            }.frame(height: min(geometry.size.width * 1.5, 650))
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// Packs intrinsic chip widths into rows and truncates only chips wider than a row.
private struct SearchHistoryFlow: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? 375).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrange(subviews, width: bounds.width)
        for (index, frame) in layout.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let itemWidth = min(size.width, width)
            if x > 0 && x + itemWidth > width {
                x = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            frames.append(CGRect(x: x, y: y, width: itemWidth, height: size.height))
            rowHeight = max(rowHeight, size.height)
            x += itemWidth + horizontalSpacing
        }
        return (CGSize(width: width, height: y + rowHeight), frames)
    }
}
