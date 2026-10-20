import SwiftUI

struct DramaShareView: View {
    let item: TheaterFeedItem
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var content: DramaShareContent?
    @State private var loadError: String?
    @State private var actionMessage: String?
    @State private var attempt = 0
    @State private var isSaving = false
    @State private var activity: ShareImagePayload?

    var body: some View {
        GeometryReader { geometry in
            // Reserve space inside the safe area for the close row, both gaps,
            // the actions and vertical padding before sizing the poster.
            let reservedHeight: CGFloat = 44 + 8 + 24 + 44 + 24
            let width = min(geometry.size.width * 0.75,
                            max(0, (geometry.size.height - reservedHeight) / DramaShareCard.aspectRatio), 360)
            let actionWidth = min(max(width, 280), max(0, geometry.size.width - 32))
            ZStack {
                Rectangle().fill(.ultraThinMaterial).overlay(.black.opacity(0.55))
                    .ignoresSafeArea()
                if let content {
                    Image(uiImage: content.cover).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped().blur(radius: 22)
                        .overlay(.black.opacity(0.7)).ignoresSafeArea()
                }
                VStack(spacing: 8) {
                    Button { dismiss() } label: {
                        Image("ShareClose").renderingMode(.original).resizable()
                            .scaledToFit().frame(width: 24, height: 24)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.tr("关闭分享"))
                    .frame(width: actionWidth, alignment: .trailing)
                    VStack(spacing: 24) {
                        Group {
                            if let content {
                                DramaShareCard(drama: item.drama, content: content, width: width)
                            } else {
                                VStack(spacing: 16) {
                                    if let loadError {
                                        Text(loadError).multilineTextAlignment(.center).font(.subheadline)
                                        Button(L10n.tr("重试")) { attempt += 1 }.buttonStyle(.bordered)
                                    } else {
                                        ProgressView(L10n.tr("正在生成分享图片…")).tint(.white)
                                    }
                                }.frame(width: width, height: width * DramaShareCard.aspectRatio)
                            }
                        }
                        if let content {
                            HStack(spacing: 12) {
                                Button { save(content, width: width) } label: {
                                    HStack(spacing: 7) {
                                        Image("ShareSave").renderingMode(.original)
                                        Text(isSaving ? L10n.tr("保存中…") : L10n.tr("保存相册"))
                                            .lineLimit(2).minimumScaleFactor(0.85)
                                    }
                                }.disabled(isSaving)
                                Button { share(content, width: width) } label: {
                                    HStack(spacing: 7) {
                                        Image("ShareSend").renderingMode(.original)
                                        Text(L10n.tr("分享至"))
                                    }
                                }.disabled(isSaving)
                            }
                            .font(.system(size: 16, weight: .medium))
                            .buttonStyle(ShareOutlineButtonStyle())
                            .frame(width: actionWidth)
                        }
                    }
                }
                .padding(.vertical, 12)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .presentationBackground(.clear)
        .task(id: attempt) {
            loadError = nil
            do {
                let result = try await DramaShareContent.load(item: item, network: app.network, imageURLs: app.imageURLs)
                try Task.checkCancellation()
                content = result
            }
            catch is CancellationError { }
            catch {
                guard !Task.isCancelled else { return }
                loadError = L10n.errorMessage(error, fallback: "无法处理分享图片，请稍后重试。")
            }
        }
        .sheet(item: $activity) { payload in
            SystemImageShareView(image: payload.image) { type, completed, error in
                activity = nil
                if let error { actionMessage = L10n.errorMessage(error, fallback: "无法处理分享图片，请稍后重试。") }
                if completed {
                    Task {
                        do {
                            try await DramaShareContent.reportShare(item: item,
                                channel: DramaShareContent.channel(for: type), network: app.network)
                        } catch { actionMessage = L10n.tr("图片已分享，分享记录上报失败：%@", L10n.errorMessage(error, fallback: "无法处理分享图片，请稍后重试。")) }
                    }
                }
            }
        }
        .alert(L10n.tr("提示"), isPresented: Binding(get: { actionMessage != nil },
                                           set: { if !$0 { actionMessage = nil } })) {
            Button(L10n.tr("知道了"), role: .cancel) { actionMessage = nil }
        } message: { Text(actionMessage ?? "") }
    }

    private func save(_ content: DramaShareContent, width: CGFloat) {
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                let image = try content.render(drama: item.drama, width: width)
                try await DramaShareContent.saveToPhotos(image)
                actionMessage = L10n.tr("已保存到相册")
                do { try await DramaShareContent.reportShare(item: item, channel: "qr", network: app.network) }
                catch { actionMessage = L10n.tr("已保存到相册，分享记录上报失败：%@", L10n.errorMessage(error, fallback: "无法处理分享图片，请稍后重试。")) }
            } catch { actionMessage = L10n.errorMessage(error, fallback: "无法处理分享图片，请稍后重试。") }
        }
    }

    private func share(_ content: DramaShareContent, width: CGFloat) {
        do { activity = ShareImagePayload(image: try content.render(drama: item.drama, width: width)) }
        catch { actionMessage = L10n.errorMessage(error, fallback: "无法处理分享图片，请稍后重试。") }
    }
}

private struct ShareOutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(.white)
            .background(.white.opacity(configuration.isPressed ? 0.15 : 0), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.9), lineWidth: 0.6))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

private struct ShareImagePayload: Identifiable {
    let id = UUID()
    let image: UIImage
}

private struct SystemImageShareView: UIViewControllerRepresentable {
    let image: UIImage
    let completion: @MainActor (UIActivity.ActivityType?, Bool, Error?) -> Void
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [image], applicationActivities: nil)
        controller.completionWithItemsHandler = { type, completed, _, error in
            Task { @MainActor in completion(type, completed, error) }
        }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}
