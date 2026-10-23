import SwiftUI

struct WelfareView: View {
    @Environment(AppContainer.self) private var app
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var activeTask: WelfareTask?

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                CoinPageHeader(title: L10n.tr("福利"), identifier: "welfare-back")
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(L10n.tr("赚取金币"))
                            Text(L10n.tr("解锁剧集")).padding(.leading, 28)
                        }.font(.system(size: 28, weight: .heavy)).foregroundStyle(Color(red: 1, green: 0.94, blue: 0.85))
                            .frame(maxWidth: .infinity, alignment: .leading).frame(height: 85, alignment: .topLeading)
                            .padding(.leading, 14).padding(.top, 4)
                        signCard
                        HStack(spacing: 0) {
                            Text(L10n.tr("做任务赚金币")).font(.system(size: 16, weight: .semibold))
                            Image("WelfareTitleGlow").resizable().frame(width: 34, height: 34).padding(.leading, -16)
                        }.padding(.top, 24).padding(.bottom, 8)
                        LazyVStack(spacing: 12) {
                            ForEach(app.welfare.tasks) { task in
                                WelfareTaskRow(task: task) { activeTask = task }
                            }
                        }
                        if app.welfare.isLoading { ProgressView().frame(maxWidth: .infinity).padding(20) }
                        if let error = app.welfare.error {
                            Text(error).font(.footnote).foregroundStyle(.secondary).padding(.top, 12)
                            Button(L10n.tr("重新加载")) { Task { await app.welfare.reload() } }.padding(.vertical, 12)
                        } else if app.welfare.hasLoaded && !app.welfare.isLoading && app.welfare.tasks.isEmpty {
                            EmptyStateView(title: L10n.tr("暂无更多内容"))
                                .padding(.vertical, 24)
                        }
                        if let error = app.wallet.balanceError {
                            Text(error).font(.footnote).foregroundStyle(.secondary).padding(.top, 12)
                            Button(L10n.tr("重试余额")) { Task { await app.wallet.reloadBalance() } }.padding(.vertical, 12)
                        }
                    }.padding(.horizontal, 12).padding(.bottom, 32)
                }.scrollIndicators(.hidden)
                    .refreshable { await reload() }
            }
            .background(alignment: .top) {
                Image("WelfareBackground").resizable()
                    .frame(width: geometry.size.width, height: geometry.size.width * 1624 / 750)
                    .offset(y: -geometry.safeAreaInsets.top).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .foregroundStyle(.white).background(Theme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar).toolbar(.hidden, for: .tabBar).buttonStyle(WelfareButtonStyle())
        .navigationBackGesture()
        .task { await reload() }
        .alert(item: $activeTask) { task in
            Alert(title: Text(task.title), message: Text(L10n.tr("在剧场%@，完成任务后金币将按活动规则自动发放。", task.title)),
                primaryButton: .default(Text(L10n.tr("去完成"))) { dismiss(); router.selectedTab = .theater },
                secondaryButton: .cancel(Text(L10n.tr("取消"))))
        }
    }

    private func reload() async {
        async let balance: () = app.wallet.reloadBalance()
        async let welfare: () = app.welfare.reload()
        _ = await (balance, welfare)
    }

    private var signCard: some View {
        VStack(spacing: 0) {
            NavigationLink(value: AppRoute.wallet) {
                HStack(spacing: 6) {
                    Text(L10n.tr("金币余额")).font(.system(size: 14)).foregroundStyle(Color(white: 0.58))
                    Spacer()
                    Image("WelfareCoin").resizable().frame(width: 21, height: 21)
                    Text(app.wallet.balanceText).font(.system(size: 20, weight: .medium))
                        .accessibilityIdentifier("welfare-balance")
                }.padding(.horizontal, 12).frame(height: 45).contentShape(Rectangle())
            }.accessibilityIdentifier("welfare-wallet")
            VStack(alignment: .leading, spacing: 0) {
                Text(L10n.tr("已连续签到%d天", app.welfare.continuousDays)).font(.system(size: 15)).padding(.horizontal, 6).padding(.top, 16).padding(.bottom, 16)
                WelfareDayGrid(days: app.welfare.days, today: app.welfare.today, signed: app.welfare.hasReceivedToday)
                Button { Task { await app.welfare.signIn() } } label: {
                    Image(app.welfare.hasReceivedToday ? "WelfareSignedButton" : "WelfareSignButton")
                        .resizable().scaledToFit().frame(width: 240, height: 50)
                        .overlay {
                            if app.welfare.isSigning { ProgressView().tint(Color(red: 0.36, green: 0.21, blue: 0.06)) }
                            else {
                                Text(app.welfare.hasReceivedToday ? L10n.tr("已签到") : L10n.tr("签到"))
                                    .font(.system(size: 19, weight: .semibold))
                                    .foregroundStyle(app.welfare.hasReceivedToday ? .white : Color(red: 0.36, green: 0.21, blue: 0.06))
                            }
                        }
                }.frame(maxWidth: .infinity).padding(.top, 24).padding(.bottom, 16)
                    .disabled(app.welfare.hasReceivedToday || app.welfare.isSigning || app.welfare.isLoading || !app.welfare.hasLoaded)
                    .accessibilityLabel(app.welfare.hasReceivedToday ? L10n.tr("已签到") : L10n.tr("签到"))
                    .accessibilityIdentifier("welfare-sign")
            }.padding(.horizontal, 12)
                .background {
                    Image("WelfareSignCard").resizable().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
        }.background(Color(red: 0.17, green: 0.16, blue: 0.12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Color(red: 0.63, green: 0.59, blue: 0.40), lineWidth: 1)
                    .frame(height: 65).mask(alignment: .top) { Rectangle().frame(height: 45) }
                    .allowsHitTesting(false)
            }
    }
}

private struct WelfareButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.85 : 1)
    }
}

private struct WelfareDayGrid: View {
    let days: [WelfareDay]
    let today: Int
    let signed: Bool
    var body: some View {
        GeometryReader { geometry in
            let width = (geometry.size.width - 18) / 4
            VStack(spacing: 5) {
                HStack(spacing: 6) {
                    ForEach(days.filter { $0.id <= 4 }) { day in
                        WelfareDayCell(day: day, isToday: day.id == today && !signed).frame(width: width)
                    }
                }
                HStack(spacing: 6) {
                    ForEach(days.filter { $0.id > 4 }) { day in
                        WelfareDayCell(day: day, isToday: day.id == today && !signed)
                            .frame(width: day.id == 7 ? width * 2 + 6 : width)
                    }
                }
            }
        }.frame(height: 153)
    }
}

private struct WelfareDayCell: View {
    let day: WelfareDay
    let isToday: Bool
    var body: some View {
        VStack(spacing: 6) {
            Text(L10n.tr("第%d天", day.id)).font(.system(size: 12))
            HStack(spacing: 4) {
                Image("WelfareCoin").resizable().frame(width: 16, height: 16)
                Text("+\(day.coins)").font(.system(size: 16, weight: .medium))
            }
            if day.received {
                Image("WelfareCheck").resizable().frame(width: 16, height: 16)
            } else if isToday {
                Text(L10n.tr("今天")).font(.system(size: 11)).foregroundStyle(Color(red: 0.33, green: 0.23, blue: 0.08))
                    .padding(.horizontal, 6).frame(minWidth: 28).frame(height: 16).background(Theme.accent, in: Capsule())
            }
        }.frame(maxWidth: .infinity).frame(height: 74)
            .background(background, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(isToday ? Theme.accent : day.received ? Color(red: 0.69, green: 0.52, blue: 0.15) : Color(white: 0.39), lineWidth: 1) }
            .overlay(alignment: .bottomTrailing) {
                if day.id == 7 { Image("WelfareGift").resizable().frame(width: 40, height: 40).padding(.trailing, 2) }
            }
            .opacity(day.received ? 0.5 : 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.tr("第%d天，%lld金币，%@", day.id, day.coins, day.received ? L10n.tr("已领取") : isToday ? L10n.tr("今天") : L10n.tr("待签到")))
    }

    private var background: LinearGradient {
        if isToday {
            LinearGradient(colors: [Color(red: 0.40, green: 0.28, blue: 0.04), Color(red: 0.76, green: 0.59, blue: 0.19)], startPoint: .top, endPoint: .bottom)
        } else if day.received {
            LinearGradient(colors: [Color(red: 0.44, green: 0.31, blue: 0.06), Color(red: 0.62, green: 0.51, blue: 0.25)], startPoint: .top, endPoint: .bottom)
        } else {
            LinearGradient(colors: [Color(red: 0.27, green: 0.26, blue: 0.23)], startPoint: .top, endPoint: .bottom)
        }
    }
}

private struct WelfareTaskRow: View {
    let task: WelfareTask
    let action: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Image(task.icon).resizable().scaledToFit().frame(width: 40, height: 40)
            Text(task.title + (task.limit > 0 ? "(\(task.completed)/\(task.limit))" : ""))
                .font(.system(size: 16)).foregroundStyle(task.isComplete ? Color(white: 0.58) : .white)
                .lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            Button(action: action) {
                HStack(spacing: 3) {
                    if task.isComplete { Text(L10n.tr("已完成")).font(.system(size: 13)) }
                    else {
                        Image("WelfareCoin").resizable().frame(width: 14, height: 14)
                        Text("+\(task.coins)").font(.system(size: 14))
                    }
                }.foregroundStyle(task.isComplete ? Color(white: 0.58) : Theme.accent)
                    .frame(width: 71, height: 32)
                    .background(task.isComplete ? .clear : Theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                    .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(task.isComplete ? Color(white: 0.58) : Theme.accent, lineWidth: 0.5) }
            }.disabled(task.isComplete).accessibilityIdentifier("welfare-task-\(task.id)")
                .accessibilityLabel(task.isComplete ? L10n.tr("%@，已完成", task.title) : L10n.tr("%@，奖励%lld金币", task.title, task.coins))
        }.padding(.horizontal, 12).frame(height: 64)
            .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 12))
    }
}
