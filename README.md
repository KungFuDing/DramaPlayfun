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
    ├── Home/               推荐、分类、搜索入口、继续观看
    ├── Search/             最近搜索、输入联想、搜索结果分页、热播推荐
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

- 启动页使用提供的 2x/3x 背景、海报和品牌切图，系统启动屏与游客登录等待页共用 `LaunchScreen.storyboard`，适配 iPhone/iPad 横竖屏及窗口尺寸变化。品牌图等比例缩放并限制最大尺寸；登录完成立即进入首页，连接失败保留可滚动的错误提示及重试入口。
- 版本更新在游客登录完成和回到前台时调用 `POST /mobile/v1/client/app/update/check`，当前版本与登录请求一致。使用提供的 2x/3x 火箭和面板切图，按服务端 `hasUpdate/forceUpdate` 展示两种底部弹窗，标题、版本、说明和跳转地址取接口。非强制更新可选择“稍后”，本次启动内不再提示同一版本；强制更新不能通过遮罩、下滑或返回操作关闭，覆盖其他弹窗和全屏播放。弹窗出现时暂停视频；跳转失败会显示错误并保留弹窗，返回 App 后重新检查。检查失败不会清除已展示的强制更新。`AppUpdateTests` 和 `AppUpdateUITests` 覆盖接口、稍后抑制、强制拦截、错误处理和弹窗层级。
- 五 Tab、独立导航、剧集详情、选集、收藏和历史已连通。
- 福利和我的钱包按 `设计图/福利:我的钱包` 还原，使用本地 2x/3x 金色背景、签到按钮及任务切图。已接入钱包余额、按月分组的充值/获取/消耗流水、分页、签到状态和奖励领取、福利任务列表；签到同步个人中心金币余额。自动播放下一集开关保存到服务端并控制播放器连播。任务按钮进入剧场完成任务；当前接口文档未提供通用任务领取接口。金币充值保留“暂未开放”提示，待接入购买流程。`WalletWelfareTests` 覆盖分页合并、签到余额同步、失败保留状态，`WalletWelfareUITests` 验证页面切换、开关和签到交互。
- 我的模块按 `设计图/我的` 实现资料区、两种会员卡、福利/历史/钱包入口、收藏/点赞瀑布流、设置与语言/客服/账号注销底部弹窗；使用提供的 2x/3x 切图。资料、昵称更新、收藏/点赞分页、应用配置和注销使用现有接口。清理缓存清理 Kingfisher 图片缓存；注销成功后清理本地收藏/历史并重新建立游客会话，沿用同一设备 ID，注销后的账号关系由服务端处理；失败保留资料。语言选项固定为 English、繁體中文，使用 `en.lproj/Localizable.strings` 和 `zh-Hant.lproj/Localizable.strings`；切换即时生效并持久化，首次启动匹配系统语言，不支持的语言回退 English，旧的 `zh` 选择迁移为 `zh-Hant`。请求头 `language` 跟随应用选择，覆盖旧 Debug 值；`/mobile/v1/client/language/list` 已废弃，不再调用。服务端返回的剧名、简介、公告等内容保留原文，由服务端按请求语言提供。
- 会员页和设置页的用户协议、隐私政策及客服邮箱统一读取 `AppConfiguration`。内置默认值在接口加载前即可使用；`/mobile/v1/client/app/config` 返回有效值时逐项覆盖，缺失、空白字段或无效协议链接回退默认值，接口无数据或失败时使用默认配置。
- 首页参照设计图的颜色、卡片和布局结构。设计图是整页截图，未提供独立海报，因此当前使用明确的图形占位。`Drama.coverURL` 可接入实际海报。
- 首页和搜索按当前窗口宽度适配 iPhone Duo、iPad 与普通 iPhone：内容居中限宽 1200pt，热播瀑布流显示 2–6 列，宽屏搜索结果显示两列；首页顶栏跟随安全区、轮播受窗口宽高约束，宽屏今日片刻采用横排。`HomeSearchAdaptiveUITests` 覆盖当前窗口、横竖屏切换、分类吸顶联动、搜索历史与结果及卡片边界。
- 我的、观看历史和会员页按当前窗口宽度适配 iPhone Duo、iPad 与普通 iPhone：我的与历史内容居中限宽 1200pt；我的页面在可用宽度达到 700pt 时采用左右分栏，左侧沿用 iPhone 的个人资料、会员卡及快捷入口排布，右侧显示收藏/点赞，并按所在栏宽度计算列数；窄屏保持上下排列，历史显示 3–6 列。会员页限宽 1040pt，插画最大宽度 440pt，宽屏权益与购买说明分栏；充值显示 3–6 列。`ProfileMembershipAdaptiveUITests` 覆盖旋转后的内容边界、分类与充值档位保持、历史入口、滑动切换和模拟充值。
- `DemoDramaRepository` 提供离线示例目录；无真实视频资源，点击免费集会显示可重试的资源未提供状态。AVPlayer 播放、加载超时、后台暂停、进度保存、断点恢复和重播流程已实现，但需真实资源进一步验证。
- `StoreKitSubscriptionService` 已实现商品加载、已验证交易、购买取消/待批准、恢复购买和交易更新监听。`AppContainer` 的商品 ID 默认为空，因此不展示虚构价格、不发起模拟收费。
- 默认数据仅用于搭建架构，已接入启动游客登录和请求鉴权；不包含推荐算法、广告、埋点或后台播放。

## 接入真实服务

1. 实现 `DramaRepository`，在 `AppContainer` 注入。目录与选集使用稳定 ID；播放接口应由服务端验证用户权益并返回短时签名 URL。客户端的会员判断只用于展示付费入口，不能作为媒体访问保护。
2. 在 App Store Connect 配置自动续订订阅，把实际商品 ID 注入 `StoreKitSubscriptionService`。使用 StoreKit Configuration / Sandbox 验证购买、恢复、退款、过期、待批准和跨设备更新。
3. 接入服务端交易与账户关联、App Store Server Notifications，完善权益到期及宽限期策略。当前客户端仅依据已验证且未过期/撤销/升级的 currentEntitlements。
4. 接入视频后验证播放失败、弱网、音频中断、后台切换、断点续播与长时间播放。播放预加载、授权续期及本地缓存策略见下文。

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

`POST /mobile/v1/client/transport/encryption/config`、`POST /mobile/v1/client/service/notice`、`POST /mobile/v1/client/app/config`、`POST /mobile/v1/client/app/update/check` 四个接口始终使用 JSON 明文请求和响应，不依赖加密开关查询。免加密路径统一定义在 `APITransportEncryption.swift`，其中加密配置接口不携带鉴权令牌。

应用共享网络客户端在首个需要检查加密开关的请求（包括游客登录）前，先以明文 `POST /mobile/v1/client/transport/encryption/config` 获取 `data.enabled`。开启时使用 AES-256-GCM，关闭时使用 JSON 明文。配置在客户端实例生命周期内缓存，并发调用合并为一次请求；获取失败或开关字段缺失时阻止需检查开关的请求，下次调用可重试，四个免加密接口仍可直接请求。需要重新读取时调用 `reloadTransportEncryptionConfiguration()`，在途请求保留发送时的传输方式，避免切换开关导致响应解密错误。加密配置接口尚未包含在当前 OpenAPI 文件中，端点及必填 Bool 模型独立定义在 `APITransportEncryption.swift`。

`AppContainer` 注入 `APIPayloadCipher`，对约定 password 的 UTF-8 字节计算 SHA-256 得到 32 字节密钥。启用加密时，每次请求生成随机 12 字节 nonce，将 `nonce + 密文 + 16 字节认证标签` 二进制数据编码为 Base64，直接作为 HTTP Body 发送，设置 `Content-Type: text/plain; charset=utf-8`、`Accept: text/plain`，不发送 `X-Payload-Encryption` 请求头；成功 HTTP 响应必须先解码 Base64，再通过 GCM 解密及完整性校验，最后按原来的 JSON、业务码及模型规则解析，校验失败不会降级接收明文。Debug 日志使用加密前、解密后的脱敏 JSON。`APIPayloadCipherTests`、`EncryptedNetworkTests` 和 `TransportEncryptionConfigTests` 覆盖跨实现向量、防篡改、Base64 传输、开关配置、并发合并、刷新、重试与取消；本地 JSON stub 可不注入 cipher，且不启用服务端配置读取。

所有 API 请求的 `appVersion` 读取 App 的 `CFBundleShortVersionString`，游客登录及版本检查使用同一版本；`modelName` 在模拟器上为 `Simulator`，真机按硬件标识映射为设备名称，未收录型号保留硬件标识；`platform` 读取系统名称，`systemVersion` 为系统名称和版本号（如 `iOS 26.5`）。这些字段在 Debug/Release 中统一由运行时提供，不接受调试配置覆盖。

`deviceId` 为首次生成并写入 Keychain 的 UUID，游客登录 Body 的 `deviceIdentifier` 使用同一个值，写入成功后才发起登录及其加密配置请求。已有 `guest.deviceIdentifier.v1` 会优先迁移，以保留后台识别的原身份；Keychain 已有 ID 时以 Keychain 为准。迁移成功后移除旧 UserDefaults 副本，新 ID 不再写入 UserDefaults，也不从 Debug 配置或 IDFV 取值。账号注销重登及缓存清理不会轮换设备 ID；Keychain 读取/写入失败时显示错误并允许重试，不使用临时 ID。Keychain 使用 `AfterFirstUnlockThisDeviceOnly`、不启用 iCloud 同步，避免将新 ID 带到另一台设备。

普通卸载重装通常会保留 Keychain 中的 ID，但这不是 Apple 保证永久不变的系统契约；抹掉设备、改变签名访问组或 Keychain 数据丢失后无法恢复原 ID。[Apple 官方说明](https://developer.apple.com/forums/thread/36442)。若后台要求在这些情形下仍恢复同一用户，需要可恢复的账号绑定。

`ip` 和 `countryCode` 由公网查询取得，使用同一次响应中的公网 IPv4/IPv6 地址及对应的大写双字母国家/地区码，不使用设备地区设置。默认通过独立的 HTTPS GET 请求访问 [Country](https://country.is/)；可修改 `Config/Info.Debug.plist`、`Config/Info.plist` 的 `IPGeolocationURL` 替换为兼容接口（返回 `{"ip":"公网 IP","country":"国家简码"}`）。查询不携带 App 鉴权或设备 Headers。首次请求先查询，成功结果在内存缓存 5 分钟，并发查询合并；网络路径变化时清除缓存和旧网络的在途结果。查询最多等待 3 秒，失败时业务请求继续且省略这两个字段，30 秒后允许重试；国家未知时只发送已查到的 IP。静态 Debug 配置中的旧 IP/国家码不再生效。

其余 Debug 专用请求头从本机 `Config/Debug.local.xcconfig` 注入（可参考 `Config/Debug.local.example.xcconfig`）；本地配置的令牌转换为 `Authorization: Bearer <token>`，启动游客登录后由返回的会话令牌覆盖。所有请求均不发送 `accessToken` 请求头，游客登录与加密配置请求不携带鉴权头。登录完成后再加载业务页面，失败可重试。本机配置文件已忽略提交。Xcode 控制台会脱敏显示令牌、deviceId 和 IP。

首页顶部搜索进入独立搜索页，隐藏底部 Tab。最近搜索使用 `AppAPI.v1TheaterSearchHistory`，清空成功后移除记录；输入联想以 250ms 防抖调用 `AppAPI.v1TheaterSearchGuess`，点击搜索或历史词条调用 `AppAPI.v1TheaterSearch` 并支持分页，旧输入响应不会覆盖新结果。热播推荐复用首页热播数据，剧集点击进入播放器。搜索图标使用提供的 2x/3x 切图，海报与文案取接口数据。`SearchStoreTests` 覆盖接口契约、分页去重、取消与过期响应；`SearchUITests` 覆盖入口、历史复搜/清空、输入联想、结果与播放跳转。

剧场首集已接入点赞、收藏、观看进度和分享接口。分享弹窗使用接口文案生成二维码，封面、标题和标签合成同一海报，可保存相册或调起系统图片分享。详见 [网络模块接入](接口文档/网络模块接入.md#剧场互动与分享)。

启动默认进入首页，按“首页聚合 → 首页热播首屏 → 剧场首屏列表 → 第一条剧目的第 1 集”分步加载；首页各区块收到数据即展示，不等待剧场请求。停留首页时仅静音缓冲并预解码首集，不推进播放或记录观看。切换剧场复用同一个 AVPlayer/AVPlayerItem；提前切入时合并正在进行的列表请求。离开首页或进入后台暂停尚未完成的预热，保留已就绪缓冲，返回首页不重置已经进入过的剧场选中页。`StartupContentLoaderTests`、`TheaterStartupPlaybackTests` 和 `TheaterFeedTests` 覆盖请求顺序、首页独立展示、并发合并、取消和播放器复用。

剧场首集剩余 10 秒时提前请求播放详情的剧集列表，当前视频缓冲充足时静默准备第 2 集并停止竞争带宽的首页邻页预加载。首集结束后直接移交已获取的数据和同一个 AVPlayer/AVPlayerItem，跳过切页动画；返回首页从头重播首集。切换剧目、退出首页或拖回较早进度会取消预加载。已有播放地址的锁定集也会静默缓冲并预解码，预热不推进观看进度；自动或手动解锁后直接复用同一个 AVPlayer/AVPlayerItem，缺失播放地址时才补取剧集列表。`PlaybackPreparationTests` 覆盖请求合并、播放器移交、静默预加载、取消及锁定集。

首页和排行榜按实际可见位置预取播放详情：卡片至少露出 55%，停留 400 毫秒后按距屏幕中心排序选择最多 3 部剧，依次请求 `/mobile/v1/client/drama/episode/list`；跨停留批次同时最多 2 个预取请求。横向裁剪、隐藏分类、顶部遮挡均参与可见性计算，滚动、切分类、离开根页或进入后台会取消尚未开始的预取。排行榜点击直接进入播放页；播放页、剧场续播及选集使用同一份接口缓存，在途请求合并，命中后无需重复请求即可准备视频。

播放详情采用内存和磁盘缓存，最多 60 部：30 分钟内直接复用；30 分钟至 24 小时先显示缓存，再合并后台刷新；超过 24 小时重新请求。刷新失败保留旧资料，30 秒后允许重试，手动重试可强制刷新。缓存按 API 环境、账号、设备和语言隔离；登录返回 `userNo` 时同账号令牌更新仍可复用。失败、空或无效剧集列表不覆盖旧缓存；收藏、点赞、解锁和购买后失效相关缓存。设置页的缓存大小和清理包含这些接口数据。

播放权限与资料缓存独立：超过 5 分钟的权限在播放前通过解锁状态接口只读校验，服务端给出的更早到期时间优先。未知权限可静默预热，但不能播放；旧权限被拒绝时重新获取真实价格，必须手动确认才能扣费。页面停留到期、切集及回前台均检查权限。地址续签不延长资料或权限有效期。`PlaybackDetailCacheTests`、`PlaybackCacheIntegrationTests`、`CachedPlaybackAccessTests`、`CachedRepositoryAccessTests` 和 `BrowsePlaybackPrefetchTests` 覆盖缓存分层、并发、身份隔离、权限和停留取消。

图片与分享封面共用 Kingfisher 的内存、磁盘缓存，缓存键仅移除 `x-media-token`，保留其他内容参数。签名图片缓存未命中且返回 401/403 时，根据来源重新请求剧集详情、首页 Banner 或个人资料，取得新地址后仅重试一次；并发续签合并，失败退避 60 秒。普通网络错误不触发续签，新内容地址使用自己的缓存键。`RemoteImageRenewalTests` 和 `RemoteImageCacheTests` 覆盖这些恢复路径及缓存首帧。

视频授权失效时通过 `POST /mobile/v1/client/XMToken` 续期：剧场首页只刷新当前剧首集，播放详情页批量刷新当前剧所有已有播放地址的集，不改变未解锁集的权限。续期复用播放器并恢复进度和暂停状态，合并并发请求且限制自动重试次数。预加载按当前缓冲与实测带宽放行，缓冲不足时暂停邻页加载；持续缓冲超过 8 秒会用当前地址重新加载一次，普通网络卡顿不调用授权刷新。HLS 清单和分片遇到短暂连接中断、超时或临时 HTTP 错误时最多额外尝试两次；已传输的定长分片通过 Range 续传，并校验剩余区间。播放失败通知保留原始错误；明确网络错误、AVPlayer 最近 30 秒的分片超时日志或网关近期断流证据允许播放器用原地址重建一次，保留进度与暂停状态，持续失败后仍显示重试入口。网络或长卡顿恢复后将期望峰值码率暂设为 800 kbps，连续健康播放 15 秒且缓冲至少 8 秒后恢复自动码率；该 AVPlayer 偏好是软限制，低码率流因网络错误被系统排除时仍可能选择更高档。暂停、拖动或切页会重置健康计时，保留用户的分辨率设置。取消、权限拒绝及无网络证据的格式错误不触发该恢复。诊断日志记录错误域、错误码和 HTTP 状态，不输出签名地址。`PlaybackRenewalTests`、`DramaPlaybackTests`、`HLSPlaybackKeyTests` 覆盖刷新范围、锁定集、并发合并、关闭取消、恢复上限、连续断流的字节完整性、临时 HTTP 错误、真实加密 HLS 及进度恢复。

上下滑动保留当前页及相邻两页的播放器与缓冲，快速回滑复用仍在窗口内的加载；前台缓冲安全后，优先预热最近滑动方向的邻页。续播预热保留已经准备好的邻页。启动和静默预热先准备约 2 秒的播放余量，已有至少 0.5 秒播放余量时立即起播，开始播放后再扩大前台缓冲；实际时长按倍速调整，弱网保留自动等待和卡顿恢复。HLS 网关按视频隔离网络回调队列，避免暂停邻页的背压阻塞当前视频。`PlaybackSwipeTests` 验证播放器复用、快速来回滑、旧页静音和三播放器上限；`HLSPlaybackKeyTests` 用真实本地慢消费者验证跨视频传输隔离。首帧与线上 CDN 延迟仍需在真机和实际网络下测量。

播放详情页连续播放 5 秒后淡出顶部按钮、剧名简介、侧边操作、进度条及遮罩，只保留视频和底部选集、清晰度、倍速入口。点击视频唤出控件，使用中央按钮暂停或继续；暂停、缓冲、拖动进度及打开弹层时不计时。隐藏状态在自动续播、滑动切集和选集后保持。VoiceOver 开启时保持控件可见。`PlayerControlsUITests` 覆盖控件隐藏、唤出后继续播放及切集状态保持。

本地化资源通过 `L10n.tr`（可观察的 UI 文案）或 `L10n.text`（非主线程错误信息）读取；参数化文案使用格式占位符，新增文案需同时维护两套 Localizable 文件。选择语言后自动关闭弹窗，保留当前设置页；实际语言变化时统一替换各业务页的数据缓存、重建页面，清除旧语言的导航内容，当前页面立即重新请求，其他页面进入时加载新语言。旧请求只会写入已替换的 Store，不会覆盖新页面；会员商品和版本检查使用代次校验。登录会话、本地收藏/观看进度、会员权益及交易监听保持不变。`LocalizationTests` 和 `LocalizationUITests` 覆盖缓存失效、旧响应隔离、接口语言和页面切换。相册权限说明由两套 `InfoPlist.strings` 提供，系统权限弹窗遵循 iOS 应用语言。离线接口生成源与脚本位于本项目已忽略的 `接口文档/` 和 `Scripts/`，本地已同步标记语言列表接口废弃。
