import SwiftUI
import StoreKit

struct MembershipView: View {
    @Environment(AppContainer.self) private var app
    @State private var managingSubscription = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "crown.fill").font(.system(size: 64)).foregroundStyle(Theme.accent).padding(.top, 24)
                Text(app.membership.isActive ? "会员权益已生效" : "好故事，尽情看").font(.largeTitle.bold())
                Text("解锁会员剧集 · 畅享完整故事").foregroundStyle(.secondary)
                if app.membership.isLoading { ProgressView("加载订阅方案…") }
                ForEach(app.membership.plans) { plan in
                    Button { Task { await app.membership.purchase(plan) } } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(plan.title).font(.headline)
                                Text(plan.period).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(plan.price).font(.title2.bold()).foregroundStyle(Theme.accent)
                        }.padding(20).background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
                    }.buttonStyle(.plain).disabled(app.membership.isPurchasing || app.membership.isActive)
                }
                if app.membership.plans.isEmpty && !app.membership.isLoading {
                    ContentUnavailableView("订阅方案暂未开放", systemImage: "crown", description: Text("请稍后再来查看"))
                    Button("重新加载") { Task { await app.membership.loadPlans() } }
                }
                if app.membership.isPurchasing { ProgressView("正在处理…") }
                if let message = app.membership.message {
                    Text(message).font(.callout).foregroundStyle(Theme.accent)
                }
                Button("恢复购买") { Task { await app.membership.restore() } }
                    .disabled(app.membership.isPurchasing)
                Button("管理订阅") { managingSubscription = true }
                Text("订阅将自动续订，可随时在 Apple 账户的订阅设置中管理或取消。价格和周期以购买确认页为准。")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.padding()
        }.screenBackground().navigationTitle("会员")
            .task { await app.membership.loadPlans() }
            .manageSubscriptionsSheet(isPresented: $managingSubscription)
    }
}
