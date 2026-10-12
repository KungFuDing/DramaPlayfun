# DramaPlayfun

SwiftUI 短剧 App 基础架构，最低 iOS 17，使用 Moya、CleanJSON 和 Kingfisher。直接打开 `DramaPlayfun.xcodeproj`，运行 `DramaPlayfun` Scheme。

## 目录与依赖方向

```text
DramaPlayfun/
├── App/                    依赖组装、五 Tab 路由、每个 Tab 独立导航栈
├── Domain/                 剧集、选集、观看进度模型，DramaRepository 协议
├── Data/                   示例仓库、剧集状态、本地收藏和观看记录
├── Core/
│   ├── DesignSystem/       深色/金色主题、海报、网格、分类、加载组件
│   ├── Playback/           AVPlayer 生命周期、播放错误、断点与进度保存
│   └── Subscriptions/      订阅协议、StoreKit 2 实现、会员权益状态
└── Features/
    ├── Home/               推荐、分类、搜索、继续观看
    ├── Theater/            首集短视频、点赞收藏、进度上报及分享海报
    ├── Rankings/           热度榜单
    ├── Membership/         商品展示、购买、恢复、管理订阅
    ├── Profile/            资料、收藏/点赞、历史、会员卡、设置与底部弹窗
    ├── DramaDetail/        简介、收藏、选集、会员门禁
    └── Player/             全屏播放页
```

`Features → Domain / Core`；`Data → Domain`；`AppContainer` 在组合入口注入具体实现。当前是单 Xcode Target 的按功能分目录架构，尚未拆为独立 Swift Package。

共享状态使用 `@Observable` 和 `@Environment`，App 根持有依赖；分类、搜索和弹窗等视图状态保持在本地。播放器由全屏播放页持有，退出释放资源；进入后台暂停，返回前台由用户恢复播放。收藏和观看进度写入 UserDefaults；未来可替换为 SwiftData 或账户同步服务。

## 当前完成与接入边界

- 五 Tab、独立导航、剧集详情、选集、收藏和历史已连通。
- 我的模块按 `设计图/我的` 实现资料区、两种会员卡、福利/历史/钱包入口、收藏/点赞瀑布流、设置与语言/客服/账号注销底部弹窗；使用提供的 2x/3x 切图。资料、昵称更新、收藏/点赞分页、应用配置、语言字典和注销使用现有接口。清理缓存清理 Kingfisher 图片缓存；注销成功后清理本地收藏/历史并创建新的游客身份，失败保留资料。语言弹窗持久化选择，整站文案翻译未接入；福利和金币充值保留提示入口。
- 首页参照设计图的颜色、卡片和布局结构。设计图是整页截图，未提供独立海报，因此当前使用明确的图形占位。`Drama.coverURL` 可接入实际海报。
- `DemoDramaRepository` 提供离线示例目录；无真实视频资源，点击免费集会显示可重试的资源未提供状态。AVPlayer 播放、加载超时、后台暂停、进度保存、断点恢复和重播流程已实现，但需真实资源进一步验证。
- `StoreKitSubscriptionService` 已实现商品加载、已验证交易、购买取消/待批准、恢复购买和交易更新监听。`AppContainer` 的商品 ID 默认为空，因此不展示虚构价格、不发起模拟收费。
- 默认数据仅用于搭建架构，已接入启动游客登录和请求鉴权；不包含推荐算法、广告、埋点或后台播放。

## 接入真实服务

1. 实现 `DramaRepository`，在 `AppContainer` 注入。目录与选集使用稳定 ID；播放接口应由服务端验证用户权益并返回短时签名 URL。客户端的会员判断只用于展示付费入口，不能作为媒体访问保护。
2. 在 App Store Connect 配置自动续订订阅，把实际商品 ID 注入 `StoreKitSubscriptionService`。使用 StoreKit Configuration / Sandbox 验证购买、恢复、退款、过期、待批准和跨设备更新。
3. 会员页上线前补充实际隐私政策和用户协议入口，接入服务端交易与账户关联、App Store Server Notifications，完善权益到期及宽限期策略。当前客户端仅依据已验证且未过期/撤销/升级的 currentEntitlements。
4. 接入视频后验证播放失败、弱网、音频中断、后台切换、断点续播与长时间播放。当前不包含自动下一集、清晰度切换或缓存。

## 验证

```sh
xcodebuild -project DramaPlayfun.xcodeproj -scheme DramaPlayfun \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build

xcodebuild -project DramaPlayfun.xcodeproj -scheme DramaPlayfun \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:DramaPlayfunTests CODE_SIGNING_ALLOWED=NO test
```

单元测试覆盖分类搜索、收藏/断点持久化、Tab 导航隔离、待批准/取消不授予会员以及购买/恢复后的权益刷新。真实支付与视频端到端测试需要对应服务配置。

## 接口与网络

本地接口入口：[离线 HTML](接口文档/index.html) · [Markdown 参考](接口文档/API参考.md) · [网络模块接入](接口文档/网络模块接入.md)。

通过 Swift Package Manager 管理 Moya、CleanJSON、Kingfisher。Debug 环境已将 `API_BASE_URL` 配置为 `https://pre.aijccz.com/aigc-mobile`（Release 仍需按部署环境单独配置）。首页 Banner 和横向栏目从 `POST /mobile/v1/theater/home` 加载，热播瀑布流从 `POST /mobile/v1/theater/home/hot/page` 分页加载（解析实际的 `code/message/data` 包装）；未配置时显示演示数据。首页固定“精选”，其余 Tab 从 `POST /mobile/v1/drama/tag/list` 获取，瀑布流按 `tagId` 请求 `POST /mobile/v1/drama/tag/series/list`。排行榜 Tab 从 `POST /mobile/v1/drama/category/list` 获取（`type=ranking`），列表按 `categoryId` 请求 `POST /mobile/v2/theater/rank/list`，保留服务端排序。分类数据独立缓存，支持刷新、分页及切换取消。首页“继续观看”从 `POST /mobile/v1/client/me/history/list` 获取，支持横向分页、刷新和进度恢复，空数据隐藏。接口文件更新后执行 `python3 Scripts/generate_api_docs.py`。

Debug 构建在 Xcode 控制台输出 API 请求、响应和错误日志，鉴权及个人敏感字段会脱敏；Release 构建不输出。

Debug 专用请求头从本机 `Config/Debug.local.xcconfig` 注入（可参考 `Config/Debug.local.example.xcconfig`）；启动游客登录后，返回的令牌覆盖 `accessToken` 和 `Authorization: Bearer <token>`；登录完成后再加载业务页面，失败可重试。本机配置文件已忽略提交。Xcode 控制台会脱敏显示 accessToken、deviceId 和 IP。

剧场首集已接入点赞、收藏、观看进度和分享接口。分享弹窗使用接口文案生成二维码，封面、标题和标签合成同一海报，可保存相册或调起系统图片分享。详见 [网络模块接入](接口文档/网络模块接入.md#剧场互动与分享)。
