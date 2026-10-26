# 浏览器功能对齐计划——数据面、页面控制面与隐私面

> 任务：以参考实现（主流桌面浏览器）为准，补齐 Peekr 在菜单栏滑出式浏览器形态内可等价实现的全部用户可感知浏览能力。
> 证据固定于当前工作树（`f237c9c` + 未提交的侧栏拖拽改造）。GitNexus 索引落后 6 个提交，图谱结论仅作风险提示，源码优先。
> 本文件是先规划后实施的执行基线；参考对象按仓库约定使用中性表述。

## 1. 目标与完成定义

“完全对齐”在本项目里定义为四层同时成立：

1. **可发现**：入口出现在用户会找的位置（工具栏、菜单、快捷键、地址栏、页面内入口）。
2. **可操作**：不是只读展示，增删改查、状态切换、取消/重试都可完成。
3. **可持久**：用户数据、设置、站点决定、下载记录跨启动保留，旧 JSON 不丢。
4. **可恢复**：页面崩溃、进程休眠、误关闭、重启后都有符合预期的恢复路径。

非目标（并说明原因，避免“功能列表对齐、产品不可用”）：

- 扩展体系、应用商店、账号同步、密码管理器、支付/地址自动填充、Cast、云端翻译：依赖账号、服务端或 Chromium 上层 UI，当前 CEF Alloy 嵌入形态不具备。
- 多浏览器窗口、标签拖出成窗：Peekr 的产品边界是单一滑出面板 + Spaces。
- Chromium 内部 `chrome://` 页面：改为 `peekr://` 原生页面，避免把 CEF 内部页面当产品 API。

## 2. 当前基线（已验证）

### 2.1 已有能力

- 导航：后退/前进/刷新/停止、软刷新、历史滑动、URL 解析、四家搜索引擎、地址栏异步补全（`WebViewManager.swift:247-381`，`NavigationBar.swift:385-446`）。
- 标签：新建/关闭/重开、固定、静音、休眠/唤醒、分组、拖拽排序、Spaces 隔离、恢复最近关闭（内存 25 条）（`AppModel.swift:194-374`，`AppRail.swift:507-1230`）。
- 页面：页内查找、按源站缩放、下载中心、权限弹窗、HTTP 认证、页面右键菜单基础项（`WebViewManager.swift:268-319`，`CefSwiftEngine.swift:528-592`）。
- 数据：Spaces/标签、书签、历史（200 条）、缩放、设置、Profile 注册表、图标缓存（`Sources/Peekr/Store/`）。
- 导入：四个浏览器的书签/打开的标签，Chromium 系 Cookies 与会话（`Sources/Peekr/Web/`，`BrowserImportSheet.swift`）。

### 2.2 关键缺口与缺陷

- **快捷键**：`⇧⌘R` / `⇧⌘T` 用 `charactersIgnoringModifiers` 与小写字母比较，实际不可达（`PanelController.swift:308-335`）。
- **地址栏**：Paste and Go/Search 菜单项存在但未接线（`OmniboxTextField.swift:132-158`）；标签建议会导航当前页而不是切换标签（`OmniboxSuggestion.swift:48-53`）。
- **历史**：只有地址栏建议，没有历史页、搜索、删除、清空；容量 200（`HistoryStore.swift:15-47`）。
- **下载**：仅内存、无暂停/继续/重试、无下载页、重启即丢（`DownloadStore.swift`，`CefSwiftEngine.swift:394-451`）。
- **书签**：只能新增/删除/导入，不能重命名、改 URL、建文件夹、移动、搜索、导出；无星标状态（`BookmarksModel.swift`，`BookmarkSheet.swift`）。
- **页面控制**：无打印、保存、查看源代码、DevTools 快捷键、全屏处理、阅读模式；查找无匹配计数/大小写/全词（`WebViewManager.swift:290-319`）。
- **安全与站点状态**：无锁标识、页面信息、证书错误页、站点权限记忆（`CefPermissionPrompt.swift:51-80`）。
- **弹窗**：所有 `window.open` 都变成标签，没有拦截与提示（`CefSwiftEngine.swift:489-512`）。
- **标签能力**：无标签搜索、无音频发声指示、关闭栈不持久、无 MRU 切换。
- **隐私**：无清除浏览数据、无隐私 Space。
- **CEF 能力**：`CefKit` 未封装 find-result、print、audio、cookie manager、cache 清理；`CefSwiftEngine` 未实现证书错误、导航策略、全屏、JS 对话框回调（`Vendor/CefSwift/Sources/CefKit/`）。

### 2.3 风险信号

- `WebViewManager`、`BrowserState`、`Settings`、`CefSwiftEngine` 的 upstream impact 均为 **CRITICAL**；`PanelRootView` / `NavigationBar` 为 LOW。
- 因此共享文件实行“单波次单所有者”，数据契约先落地，页面与引擎并行，最后统一集成。

## 3. 功能矩阵与优先级

| 域 | 能力 | 优先级 | 形态 |
| --- | --- | --- | --- |
| 地址栏 | 切换标签建议、Paste and Go、`peekr://`、更多引擎、内联补全 | P0/P1 | 现有栏 + 建议模型 |
| 标签 | 标签搜索、音频指示、MRU、关闭栈持久化 | P0/P1 | 覆盖层 + rail |
| 页面 | 查找计数/大小写/全词、缩放提示、默认缩放 | P0 | 查找栏 + 栏 |
| 页面 | DevTools、查看源代码、全屏、打印、保存 | P1/P2 | 快捷键 + CEF |
| 数据 | 历史页（搜索/删除/清空/按日分组） | P0 | `peekr://history` |
| 数据 | 下载页（持久化/暂停/继续/重试/清理） | P0 | `peekr://downloads` |
| 数据 | 书签管理器（文件夹/编辑/移动/搜索/导出/星标） | P0 | `peekr://bookmarks` |
| 数据 | 新标签页（搜索/常用/最近） | P0 | `peekr://newtab` |
| 设置 | 设置页与设置搜索、下载位置、主页、启动、默认缩放 | P1 | `peekr://settings` + 现有偏好窗 |
| 安全 | 锁标识、页面信息、证书错误、站点权限记忆 | P0/P1 | 工具栏 + `peekr://site-settings` |
| 隐私 | 清除浏览数据（历史/下载/缓存/Cookies） | P1 | `peekr://clear-data` |
| 隐私 | 隐私 Space、弹窗拦截 | P2 | Space + 提示 |
| 窗口 | 弹窗窗口、标签拖出、多窗口 | 非目标 | — |
| 生态 | 扩展、同步、密码、自动填充、Cast、翻译 | 非目标 | — |

## 4. 架构契约

### 4.1 内部页面路由

新增 `Sources/Peekr/Model/InternalPage.swift`：

```swift
enum InternalPage: Hashable, Identifiable {
    case newTab
    case history
    case downloads
    case bookmarks
    case settings
    case siteSettings(origin: String)
    case clearData
    case shortcuts

    var id: String
    var url: URL              // peekr://history …
    var titleKey: LocalizedKey // 或直接返回 Localized 字符串
    static func from(_ url: URL) -> InternalPage?
    static func isInternal(_ url: URL) -> Bool
}
```

`BrowserState` 增加 `var internalPage: InternalPage?` 与 `var tabSearchOpen = false`。内部页面显示期间：

- `NavigationBar` 用 `internalPage` 覆写地址显示与后退语义；不写回 `urlString`。
- `WebViewManager.mirror` 在内部页显示时不覆盖标题/地址/前进后退。
- `WebViewManager.goBack()` 优先关闭内部页；`activate` 切换标签时先关闭内部页。
- `WebViewManager.loadAddress` 从内部页发起导航时关闭内部页，并为尚无 engine 的标签创建 engine 后加载。
- `peekr://` URL 不写入历史、不做网络请求。

### 4.2 数据模型与迁移

- `HistoryStore` 从 struct 改为 `@MainActor @Observable final class`；`HistoryEntry` 增加 `visitCount: Int`、`firstVisited: Date`，容错解码；容量提升到 10_000；新增 `search(_:)`、`remove(urlString:)`、`removeAll()`、`topSites(limit:)`。旧数组 JSON 直接可读。
- `DownloadStore` 改为持久化：新增 `DownloadRecord`（Codable，含 `id`、`url`、`fileName`、`receivedBytes`、`totalBytes`、`state`、`location`、`startedAt`、`endedAt`、`isPaused`），保存在 `downloads.json`；启动时把未完成记录标记为 `.failed`（可重试）。
- `BookmarksModel` 增加 `contains(url:)`、`add(title:url:toFolder:)`、`update(_:)`、`move(_:to:at:)`、`createFolder(name:in:)`、`search(_:)`、`exportHTML()`；保持现有容错解码。
- 新增 `SitePermissionStore`（`sites.json`）：`origin -> [permissionKind: allow/deny]`；`CefPermissionPrompt` 先查记忆，再弹窗；弹窗提供 “Remember” 抑制按钮。
- `SettingsData` 新增（全部容错解码 + snapshot）：
  `homePage: String = ""`、`startupBehavior: .newTab`、`downloadDirectory: String = ""`、`askWhereToSave: Bool = false`、
  `defaultZoom: Double = 0`、`rememberPermissions: Bool = true`、`blockPopups: Bool = true`、`historyRetentionDays: Int = 0`（0 = 不自动清理）。
- `ZoomStore`：按源站值缺省回落到 `settings.defaultZoom`；新增 `clear()`。

### 4.3 WebEngine 协议增量

```swift
var onFindResult: ((FindResult) -> Void)? { get set }
var onAudioState: ((WebAudioActivity) -> Void)? { get set }
func toggleDevTools()
func viewSource()
func pauseDownload(_ id: UInt32)
func resumeDownload(_ id: UInt32)
func retryDownload(_ id: UInt32)
```

默认实现为空，保证测试 fake 不受影响。`FindResult` 含 `matches`、`activeMatchOrdinal`、`finalUpdate`。

### 4.4 UI 入口

- 导航栏：后退（内部页可退）、前进、刷新、地址栏（锁/不安全标识）、星标、下载、书签、侧栏开关、更多菜单。
- 快捷键（面板为 key 时）：`⌘Y` 历史、`⌘⇧J` 下载、`⌘⇧O` 书签管理器、`⌘⇧A` 标签搜索、`⌘,` 偏好、`⌘⌥I` DevTools、`⌘U` 查看源、`⌘G/⇧⌘G` 查找下一个/上一个、`⌘⇧⌫` 清除数据。
- 所有新增动效走 `Motion` 并保留 Reduce Motion 分支；所有新文案进 `Localized`，英文/简体中文双语。

## 5. 分阶段实施

### Wave 0A：数据契约（单代理）

文件：`Model/InternalPage.swift`、`Model/Settings.swift`、`Web/BrowserState.swift`、`Store/HistoryStore.swift`、`Store/DownloadStore.swift`、`Store/ZoomStore.swift`、`Store/SitePermissionStore.swift`、`App/BookmarksModel.swift`、`Util/Localization.swift`、`Tests/PeekrTests/DataSurfaceTests.swift`。

验收：`swift build` + `swift test` 通过；旧 `history.json`/`settings.json` 可读；新增单元测试覆盖历史迁移与搜索、书签 CRUD、下载记录编解码、设置容错解码、权限记忆。

### Wave 0B：引擎契约（单代理，可与 0A 并行）

文件：`Web/WebEngine.swift`、`Web/CefSwiftEngine.swift`、`Vendor/CefSwift/Sources/CefKit/BrowserClient.swift`、`CefBrowser.swift`、`CefBrowserDelegate.swift`、`CefDownloads.swift`、新增 `CefFind.swift`/`CefAudio.swift`（如需要）。

范围：find-result 回调、audio 状态、下载暂停/继续/重试、DevTools toggle、view-source、证书错误回调最小实现（先记录状态，不弹自定义页）。

验收：`swift build` 通过；`CefSwiftEngine` 单测覆盖状态映射；不改变现有导航/下载语义。

### Wave 1：页面与数据面（并行代理，仅新增文件）

- `HistoryPageView`：搜索、按日分组、单条删除、清空、点击导航。
- `NewTabPageView`：搜索框、常用站点、最近标签、书签快捷入口。
- `DownloadsPageView`：持久记录、暂停/继续/重试/删除、打开/定位、清空。
- `BookmarksPageView`：文件夹树 + 列表、搜索、新建文件夹、编辑、移动、删除、导出 HTML。
- `TabSearchView`：跨 Space 标签搜索、键盘上下、回车切换。
- `SiteSettingsPageView`：站点权限列表、删除决定、清除全部。
- `InternalPageHost`：按 `InternalPage` 分发到上述页面，统一背景/滚动/empty state。

验收：每个页面可独立预览；不修改共享文件；构建通过。

### Wave 2：壳体集成（单代理，顺序执行）

文件：`UI/PanelRootView.swift`、`UI/NavigationBar.swift`、`Panel/PanelController.swift`、`App/AppDelegate.swift`、`App/MainMenu.swift`、`StatusBar/StatusBarController.swift`、`UI/DownloadCenter.swift`、`Web/WebViewManager.swift`、`Web/OmniboxSuggestion.swift`、`UI/OmniboxTextField.swift`、`Model/SearchEngine.swift`。

范围：内部页宿主、后退语义、星标、锁标识、下载/历史/书签/标签搜索入口、快捷键修复与新增、Paste and Go、切换标签建议、下载暂停/继续接线、查找计数 UI、缩放提示、DevTools/查看源代码、更多搜索引擎。

验收：`swift build` + `swift test`；手动清单见 §7。

### Wave 3：隐私与 CEF 深水区

- 清除浏览数据：cookie manager / HTTP cache 包装，按时间范围清除。
- 证书错误 interstitial：继续访问（危险）与返回。
- 弹窗拦截：用户手势放行 + 拦截提示 + 站点允许列表。
- 隐私 Space：CEF incognito profile，退出即清，不写历史/下载记录。
- 音频指示与休眠策略修正（Wave 0B 的状态接到 rail）。

### Wave 4：剩余体验

- 打印/保存页面（先提供“打印为 PDF”与“下载页面”能力边界说明）。
- 阅读模式、翻译入口（打开外部翻译页）、书签栏、启动恢复、前进/后退历史菜单、内联地址补全、设置页搜索。
- 完整回归与 CHANGELOG。

## 6. 回归门禁

1. 每个 Wave 结束运行 `swift build` 与 `swift test`。
2. 共享文件改动前运行 `node .gitnexus/run.cjs impact "<symbol>" --direction upstream --depth 1 --summary-only --repo .`，CRITICAL 需在提交说明中记录。
3. 真实 CEF 冒烟：`make app` 后验证新标签页、历史页、下载、书签、查找、权限、DevTools、查看源代码。
4. 数据迁移：用旧版 `history.json`/`settings.json`/`apps.json` 启动一次，确认不丢数据。
5. 交互回归：面板滑动、拖拽、缩放、自动隐藏不被内部页破坏；Reduce Motion 下无动效异常。

## 7. 本次执行范围与手动验收

本次执行 Wave 0A、0B、Wave 1 与 Wave 2；Wave 3/4 在本计划中保留为后续波次。

手动验收清单：

- 新标签显示 `peekr://newtab`，搜索/常用站点可导航；初始和新工作区仍打开搜索引擎首页。
- `⌘Y` / `⌘⇧J` / `⌘⇧O` / `⌘⇧A` / `⌘,` / `⌘⌥I` / `⌘U` / `⌘G` / `⇧⌘G` / `⇧⌘R` / `⇧⌘T` 全部生效。
- 历史页搜索、删除、清空后重启仍正确；旧历史文件不丢。
- 下载开始后出现在下载页，暂停/继续/取消/重试可用，重启后记录仍在。
- 书签星标可切换，书签管理器可建文件夹、重命名、移动、删除、导出。
- 查找栏显示匹配计数，大小写开关生效。CEF 的 find handler 不提供全词选项，全词匹配留待后续自研高亮层。
- 权限弹窗勾选 Remember 后同站点不再询问，可在站点设置里撤销。
- `peekr://` 页面后退关闭内部页并回到网页；页面之间不保留独立历史栈。

## 8. 执行记录（2026-10-24）

已交付 Wave 0A、0B、Wave 1 与 Wave 2，并完成真实 CEF 冒烟：

- **数据层**：`InternalPage`、历史 v1→v2 容错迁移、下载持久化/暂停状态、书签 CRUD/移动/导出、站点权限记忆、默认缩放、隐私设置、`Localized` 双语键。
- **引擎层**：CEF find handler、下载暂停/继续、DevTools 切换、查看源代码、证书错误原生提示、弹窗拦截。
- **页面层**：`peekr://newtab`、`history`、`downloads`、`bookmarks`、`site-settings`、`shortcuts`。
- **壳体层**：内部页宿主与后退语义、星标、安全标识、溢出菜单、标签搜索、查找计数/大小写、缩放提示、下载中心“显示全部”、状态栏入口、隐私偏好。
- **验证**：`swift build` 通过；206 个 XCTest + 5 个 Swift Testing 全绿；`make app` 成功；真实 CEF 冒烟覆盖历史、新标签、下载、书签、站点设置、快捷键页、标签搜索、真实网页、查找高亮/计数、DevTools 窗口。
- **冒烟中修复**：`peekr://site-settings`（无 query）之前被当作外部 URL 送进 CEF，现可正确路由；查找首条结果的 ordinal 0 归一化为 1。
- **范围调整**：初始/新工作区保留搜索引擎首页，只有 `⌘T` 新标签进入 NTP，避免破坏既有引擎生命周期语义与测试。

### Wave 3 执行记录

- **隐私 Space**：`Workspace.isPrivate` + `BrowserProfile.incognitoProfile`；私有空间使用 `CefProfile.incognito()`，不写 `apps.json`、历史或下载记录，退出即清；rail 与 Spaces 卡片有私有标识，禁止绑定持久 Profile。
- **音频指示**：页面注入幂等 media probe，通过 `__PEEKR_AUDIO__:` console 通道回报播放状态；`WebViewManager` 更新 `AppModel.audibleTabIDs`，rail 显示扬声器，可听页面不会被自动休眠。已知限制：iframe、Shadow DOM、WebRTC/WebAudio 检测不到。
- **清除浏览数据**：新增 CefKit `CefCookieManager`/`CefCompletionCallback`/`CefDeleteCookiesCallback`/`CefBrowsingData`，`BrowsingDataCleaner` 串联历史、已结束下载、Cookies、缓存、站点权限、缩放；`peekr://clear-data` 页面与 `⇧⌘⌫` 入口恢复。CEF 只能整库删除 Cookies/缓存，时间范围仅适用于 Peekr 自有数据。
- **启动与会话**：`StartupBehavior.homePage`；启动时按 New Tab / 继续上次 / 主页处理；最近关闭栈持久化到 `recently-closed.json`（私有标签不写入）。
- **验证**：231 个 XCTest + 5 个 Swift Testing 全绿；真实 CEF 冒烟覆盖 `peekr://clear-data` 页面、私有 Space、rail 音频图标、清除数据完成回调；`make app` Release 成功。

仍未完成（后续 Wave 4）：打印/保存页面、阅读模式、翻译入口、书签栏、前进后退历史菜单、地址栏内联补全、设置页内搜索、页面内证书 interstitial（当前为原生提示）、全词查找、iframe/Shadow DOM 音频检测、清除数据的时间范围与超时兜底。
