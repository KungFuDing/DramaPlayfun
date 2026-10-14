import SwiftUI

struct WalletView: View {
    @Environment(AppContainer.self) private var app
    @State private var kind: WalletRecordKind = .recharge
    @State private var changingAutoPlay = false
    @State private var showingRecharge = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            CoinPageHeader(title: "我的钱包", identifier: "wallet-back")
            ScrollView {
                VStack(spacing: 0) {
                    balanceCard.padding(.top, 10)
                    autoPlayRow.padding(.top, 10)
                    recordTabs.padding(.top, 26).padding(.bottom, 10)
                    records
                }.padding(.horizontal, 12).padding(.bottom, 24)
            }.scrollIndicators(.hidden)
                .refreshable {
                    await app.wallet.reloadBalance()
                    await app.profile.reloadProfile()
                    await app.wallet.load(kind, refresh: true)
                }
        }
        .foregroundStyle(.white).background(Theme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar).toolbar(.hidden, for: .tabBar)
        .buttonStyle(.plain)
        .sheet(isPresented: $showingRecharge) {
            NavigationStack {
                MembershipView(initialCategory: .coins, showsNavigationBar: true)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { showingRecharge = false }
                        }
                    }
            }
        }
        .task { await app.wallet.reloadBalance() }
        .task(id: kind) { await app.wallet.load(kind, refresh: true) }
        .alert("提示", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("确定", role: .cancel) { message = nil }
        } message: { Text(message ?? "") }
    }

    private var balanceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("金币余额").font(.system(size: 16))
            HStack(spacing: 6) {
                Image("WelfareCoin").resizable().scaledToFit().frame(width: 21, height: 21)
                Text(app.wallet.balanceText).font(.system(size: 30, weight: .medium))
                    .lineLimit(1).minimumScaleFactor(0.6).accessibilityIdentifier("wallet-balance")
                Spacer(minLength: 10)
                Button { showingRecharge = true } label: {
                    Text("去充值").font(.system(size: 16, weight: .medium)).foregroundStyle(Color(white: 0.18))
                        .frame(width: 89, height: 33).background(Theme.accent, in: Capsule())
                }.accessibilityIdentifier("wallet-recharge")
            }
        }.padding(12).frame(height: 98)
            .background(LinearGradient(colors: [Color(red: 0.30, green: 0.20, blue: 0.01),
                Color(red: 0.43, green: 0.37, blue: 0.15), Color(red: 0.31, green: 0.21, blue: 0.02)],
                startPoint: .bottomLeading, endPoint: .topTrailing), in: RoundedRectangle(cornerRadius: 12))
    }

    private var autoPlayRow: some View {
        HStack {
            Text("自动播放下一集").font(.system(size: 15))
            Spacer()
            if changingAutoPlay { ProgressView().scaleEffect(0.7).frame(width: 20) }
            Toggle("自动播放下一集", isOn: Binding(get: { app.profile.autoPlaysNext }, set: { enabled in
                changingAutoPlay = true
                Task {
                    defer { changingAutoPlay = false }
                    do { try await app.profile.setAutoPlayNext(enabled) }
                    catch { message = error.localizedDescription }
                }
            }))
            .labelsHidden().toggleStyle(CoinAutoPlayToggleStyle()).disabled(changingAutoPlay)
            .accessibilityIdentifier("wallet-autoplay")
        }.padding(.horizontal, 12).frame(height: 46)
            .background(Color(red: 0.32, green: 0.29, blue: 0.21), in: RoundedRectangle(cornerRadius: 10))
    }

    private var recordTabs: some View {
        HStack(spacing: 24) {
            ForEach(WalletRecordKind.allCases) { item in
                Button { kind = item } label: {
                    VStack(spacing: 5) {
                        Text(item.rawValue).font(.system(size: 15, weight: kind == item ? .semibold : .regular))
                            .foregroundStyle(kind == item ? .white : Color(white: 0.58))
                        Capsule().fill(kind == item ? Theme.accent : .clear).frame(width: 18, height: 4)
                    }.frame(height: 28)
                }.accessibilityIdentifier("wallet-tab-\(item.billTypeForID)")
                    .accessibilityAddTraits(kind == item ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var records: some View {
        let store = app.wallet
        let groups = store.groups[kind] ?? []
        if groups.isEmpty, store.loading.contains(kind) {
            ProgressView().frame(maxWidth: .infinity).padding(40)
        } else {
            LazyVStack(spacing: 12) {
                ForEach(groups) { group in
                    VStack(spacing: 0) {
                        Text(group.title).font(.system(size: 13)).foregroundStyle(Color(white: 0.58))
                            .frame(maxWidth: .infinity).frame(height: 41)
                            .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 10))
                        ForEach(Array(group.records.enumerated()), id: \.element.id) { index, record in
                            WalletRecordRow(record: record, isIncome: kind == .income)
                            if index < group.records.count - 1 {
                                Rectangle().fill(Color(white: 0.22)).frame(height: 0.5)
                            }
                        }
                    }
                }
                if let error = store.errors[kind] {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                    Button("重新加载") { Task { await store.load(kind, refresh: groups.isEmpty) } }
                } else if groups.isEmpty {
                    Text("暂无\(kind.rawValue.dropFirst(2))记录").font(.system(size: 14))
                        .foregroundStyle(Color(white: 0.58)).padding(.vertical, 40)
                }
                if store.hasMore[kind] == true {
                    Button { Task { await store.load(kind) } } label: {
                        if store.loading.contains(kind) { ProgressView() }
                        else { Text("加载更多").font(.system(size: 14)).foregroundStyle(Theme.accent) }
                    }.frame(height: 44).disabled(store.loading.contains(kind))
                }
                if let error = store.balanceError {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                    Button("重试余额") { Task { await store.reloadBalance() } }
                }
            }
        }
    }
}

private extension WalletRecordKind {
    var billTypeForID: String { self == .recharge ? "recharge" : billType }
}

private struct WalletRecordRow: View {
    let record: WalletRecord
    let isIncome: Bool
    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(record.title).font(.system(size: 15)).foregroundStyle(Color(white: 0.9)).lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: "clock").font(.system(size: 12))
                    Text(record.date).font(.system(size: 13))
                }.foregroundStyle(Color(white: 0.58))
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(record.amount).font(.system(size: 14)).foregroundStyle(isIncome ? Theme.accent : Color(white: 0.9))
                .fixedSize()
        }.frame(height: 65)
    }
}

private struct CoinAutoPlayToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Capsule().fill(configuration.isOn ? Theme.accent : Color(white: 0.58))
                .frame(width: 42, height: 22)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle().fill(configuration.isOn ? Theme.background : .white).frame(width: 18, height: 18).padding(2)
                }.frame(minHeight: 44)
        }.accessibilityLabel("自动播放下一集")
            .accessibilityValue(configuration.isOn ? "开启" : "关闭")
    }
}

struct CoinPageHeader: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let identifier: String
    var body: some View {
        HStack(spacing: 6) {
            Button { dismiss() } label: {
                Image("SettingsBack").renderingMode(.original).resizable().scaledToFit()
                    .frame(width: 22, height: 22).frame(width: 22, height: 44)
            }.accessibilityLabel("返回").accessibilityIdentifier(identifier)
            Text(title).font(.system(size: 18, weight: .semibold))
            Spacer()
        }.padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 0)
    }
}
