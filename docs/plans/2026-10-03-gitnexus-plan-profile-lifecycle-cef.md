# GitNexus 工程计划——Profile、页面生命周期与 arm64 CEF 供应链

> 任务：生产化 Chrome 风格 Profile 隔离、后台页面生命周期与崩溃恢复，以及仅支持 Apple Silicon 的 CEF 更新供应链。本文件仅是计划，当前不实施。
> 证据固定于提交 `6a17afe63a2f8a745a6b25ea955c902d3e3a17a4`；本次使用 `node .gitnexus/run.cjs analyze --index-only --pdg` 刷新 GitNexus 索引，但随后 CLI 在分支并发变化后报告索引包落后 24 个提交。因此图谱结论仅作为辅助风险信号，当前源码优先。
> Evidence provenance schema 2；全局脏工作树摘要 `0a9c85780067d9afcd0764f307b60891e3cee927ee11eaeb5ec7826d10fd82cd`；引用路径清单 `31` 项，按路径排序；生成计划路径本身已排除。

## 1. 目标

在不改变当前源码工作树的前提下，为以下三条相互关联的改造建立可执行的生产化方案：

1. **Profile：** 引入类似 Chrome 的默认 Profile 与多个持久化命名 Profile；每个 Workspace 绑定一个 Profile；现有数据继续保留在默认 Profile；新建 Workspace 默认使用默认 Profile。
2. **生命周期：** 参考 Chrome 的后台页面休眠/丢弃策略，在空闲和内存压力下回收后台页面资源，同时保护当前页面、可听媒体、用户明确保持唤醒的页面和自动化控制中的页面。
3. **恢复与供应链：** 对 Renderer 崩溃执行可控恢复；为应用重启保留足够的导航事实；将自定义 Chrome-codec CEF 更新链路收敛到 arm64、来源可追溯、需要审核且实际从 Peekr 根仓库运行的流程。

[assumed] Profile 是存储与会话隔离边界，不是针对本地 Peekr 进程或进程级 CDP 客户端的安全边界。除非产品另有要求，应在 UI/文档中明确这一点。

## 2. 当前行为

- [verified] `Workspace` 当前持久化标签、分组、选择状态、所有权和置顶状态，但没有 Profile 身份；容错解码会为缺失字段补默认值，`WorkspacesData.currentSchemaVersion` 当前为 2（`Sources/Peekr/Model/Workspace.swift:86-154,237-265`）。
- [verified] `AppStore` 会把旧版扁平标签数组迁移为一个 Workspace；没有数据时会创建一个默认 Workspace（`Sources/Peekr/Store/AppStore.swift:3-44`；`Sources/Peekr/App/AppModel.swift:42-60`）。
- [verified] `AppModel.addWorkspace()` 与 `addAgentWorkspace()` 都会创建一个初始标签并激活新 Workspace，但目前不接受 Profile 参数（`Sources/Peekr/App/AppModel.swift:568-589,642-665`）。
- [verified] `CefSwiftEngineFactory` 为所有引擎传入 `CefProfile.default`，而 vendored API 已经提供 `CefProfile.persistent(name:)`（`Sources/Peekr/Web/CefSwiftEngine.swift:591-612`；`Vendor/CefSwift/Sources/CefKit/CefProfile.swift:48-79`）。
- [verified] `WebViewManager` 为每个标签维护一个 live engine；后台新标签采用延迟创建；只有显式丢弃或退出时才关闭引擎。现有导航回调尚未接入休眠调度（`Sources/Peekr/Web/WebViewManager.swift:3-20,53-115,252-315,364-377`）。
- [verified] `HibernationPolicy` 已经实现纯函数选择逻辑，排除当前页、保持唤醒、可听媒体和已休眠页面，并有单元测试；但尚未由 Manager 调度或应用（`Sources/Peekr/Web/HibernationPolicy.swift:3-45`；`Tests/PeekrTests/HibernationPolicyTests.swift:4-80`）。
- [verified] CEF Renderer 终止会转换为 `NavState.rendererFailure`；当前 Retry 只是 reload，而 `CefSwiftEngine.close()` 与 `browserDidClose` 会让当前实例不可再创建浏览器（`Sources/Peekr/Web/CefSwiftEngine.swift:136-146,239-276,459-471,579-588`；`Tests/PeekrTests/CefSwiftEngineTests.swift:50-83`）。
- [verified] 根目录自定义清单目前只有一个 Chrome-codec `macosarm64` 包，带有 SHA-1、SHA-256 和大小；但 `prepare-cef.sh` 与 `bundle.sh` 仍然包含 `macosx64` 分支，CEF 更新自动化位于 vendored 包内且会选择两个 macOS 架构（`CEF_VERSION.json:1-15`；`scripts/prepare-cef.sh:17-29`；`scripts/bundle.sh:62-75`；`Vendor/CefSwift/Scripts/cef-update.sh:80-155`；`Vendor/CefSwift/.github/workflows/cef-update.yml:20-69`）。

## 3. 相关架构

### 3.1 现有边界

- [verified] `AppModel`/`AppStore` 管理 Workspace、标签和持久化事实；`WebViewManager` 管理 live engines；组合根在 `AppDelegate` 中连接二者（`Sources/Peekr/App/AppDelegate.swift:34-59`）。
- [verified] `WebEngine` 是后端无关的边界；`CefSwiftEngine` 负责 CEF 浏览器对象、宿主 view、委托事件转换和 Profile 选择（`Sources/Peekr/Web/WebEngine.swift:60-126`；`Sources/Peekr/Web/CefSwiftEngine.swift:50-94`）。
- [verified] `AppRail` 负责 Workspace 的创建、重命名和删除，并已有 `onWorkspaceSwitched` 回调；`PanelController` 已提供面板显示/隐藏回调（`Sources/Peekr/UI/AppRail.swift:5-20,120-149,298-400`；`Sources/Peekr/Panel/PanelController.swift:86-127`）。
- [verified] CEF 只初始化一次，使用规范化后的 Chromium 根目录和 `Default` cache path；Profile 对象在 runtime 初始化成功后创建（`Sources/Peekr/App/PeekrApp.swift:18-44`；`Vendor/CefSwift/Sources/CefKit/CefProfile.swift:20-35`）。

### 3.2 目标契约

- [inferred] 增加 `BrowserProfile`/`ProfileStore` 领域契约：稳定 UUID、展示名、不可变 storage key、默认 Profile 标记和生命周期元数据。展示名不能作为文件系统身份；传给 CEF 前必须校验并清理 storage key。
- [inferred] 为 `Workspace` 增加 `profileID`；解码缺失值和所有创建路径都回退到稳定的 `BrowserProfile.defaultID`。迁移时不复制或移动既有 `Chromium/Default` 数据。
- [inferred] 每个 Profile ID 只缓存一个后端 Profile 对象。相同 Profile 的标签共享 cookie/storage，不同 Profile 的标签使用不同 CEF request context。
- [inferred] Profile 重新绑定是资源边界：先关闭并移除 Workspace 关联的 live engines，再在新 Profile 下延迟重建；禁止原地修改 live CEF browser 的 Profile。
- [inferred] 将页面运行时状态与持久化标签事实分开：`active`、`background`、`hibernating`、`asleep`、`restoring`、`crashed`、`closed`。URL/title 等恢复事实写入标签模型，timer、generation 和 native 对象只由 `WebViewManager` 持有。
- [inferred] 休眠必须保守：当前页、保持唤醒、可听或音频状态未知、自动化控制中的页面不得自动丢弃。若 CEF 无法证明音频已停止，应保持页面唤醒。
- [inferred] CEF 更新元数据必须包含自定义 Chrome-codec 的来源 revision、artifact URL/origin、SHA-1/SHA-256、字节大小、arm64 架构、构建参数和审核/许可证状态。根仓库 workflow 才是发布权威，不能依赖嵌套 vendored workflow。

## 4. GitNexus 发现

- [graph] CLI `impact --repo Peekr --direction upstream --depth 3 --summary-only --file Sources/Peekr/Web/WebViewManager.swift WebViewManager` 返回 `risk=CRITICAL`、68 个直接依赖、237 个受影响符号、129 个受影响流程和 20 个模块。CLI 同时报告索引包落后 24 个提交，因此这里只把它作为风险提示，不把它当作当前完整调用方清单。
- [graph] 对 `CefSwiftEngine` 的 impact 返回 `risk=CRITICAL`、68 个直接依赖、238 个受影响符号，并提示由于 `WebEngine` 有两个实现且存在接口分发，结果是 lower-bound。实现必须继续维护已由源码确认的 `WebEngine` 边界。
- [graph] 对 `Workspace` 的 impact 返回 `risk=CRITICAL`、57 个直接依赖、203 个受影响符号、43 个受影响流程和 9 个模块。迁移必须容错，并保持现有 `Workspace` 初始化和解码默认值。
- [graph] 对 `HibernationPolicy` 的 impact 没有解析到调用方并返回 `risk=UNKNOWN`；源码搜索确认它目前主要由自身测试/文档引用，`WebViewManager` 尚未接入。这说明集成路径缺失，不代表修改它是安全的。
- [verified] 直接依赖主要分布在 App/Model 持久化、Panel/UI 选择、Agent 同步、Web 后端适配器和 CEF wrapper/test。`AppDelegate` 负责 Manager、Agent 标签准备/加载/激活以及模型删除回调（`Sources/Peekr/App/AppDelegate.swift:43-59,115-128`）。所有这些边界都必须通过编译和测试门禁。
- [verified] 已有测试提供了适合扩展的 seam：Manager 生命周期使用 fake engine/factory，CefSwift 有纯 Profile 路径测试，Renderer 状态转换、Workspace 所有权迁移和休眠边界也已有测试（`Tests/PeekrTests/WebViewManagerLifecycleTests.swift:7-47`；`Vendor/CefSwift/Tests/CefKitTests/HandlerLogicTests.swift:90-123`；`Tests/PeekrTests/CefSwiftEngineTests.swift:7-83`；`Tests/PeekrTests/AgentWorkspaceTests.swift:44-76`；`Tests/PeekrTests/HibernationPolicyTests.swift:29-80`）。

## 5. 语句级 PDG 发现

- [inferred] 本次已完成带 PDG 的索引刷新，但 GitNexus MCP 在并发查询期间退出；CLI PDG impact 只返回 statement-precise/callgraph-bridge 信息，没有可独立审计的局部控制/数据切片。因此下述结论只使用源码已确认的控制条件，不虚构 PDG 边。
- [verified] 浏览器创建受 `!isClosed`、`browser == nil` 和宿主 view 已挂载三个条件控制，并消费 `pendingURL`、目标 Profile 和宿主 view（`Sources/Peekr/Web/CefSwiftEngine.swift:170-198`）。休眠/恢复必须遵守这一单次创建边界。
- [verified] `close()` 会先设置 `isClosed`，再关闭 native browser 并清理 pending/native 状态；`browserDidClose` 也会将实例标记为 closed（`Sources/Peekr/Web/CefSwiftEngine.swift:136-146,579-588`）。恢复必须创建新 engine，不能复活旧实例。
- [verified] Renderer 终止会把 `NavState` 改为非 loading 的失败状态并清除导航错误；后续 loading 会清除 Renderer failure（`Sources/Peekr/Web/CefSwiftEngine.swift:239-276,459-471`）。自动恢复必须用 generation 防止旧回调修改新 engine。
- [verified] `WebViewManager.engine(for:)` 在缓存 engine 前安装导航/下载回调；回调负责 title、host、favicon、history 和 active state 副作用（`Sources/Peekr/Web/WebViewManager.swift:252-315`）。休眠和崩溃恢复必须保留这套回调语义，并清理每个 engine 的映射。
- [verified] `HibernationPolicy.shouldHibernate` 统一处理所有豁免条件，idle threshold 是包含边界（`Sources/Peekr/Web/HibernationPolicy.swift:35-45`）。Manager 侧的候选构造是缺失的控制点；活动/音频未知时必须 fail closed。

## 6. 建议改动

### 6.1 Profile 领域模型、持久化与迁移

1. **新增 `Sources/Peekr/Model/BrowserProfile.swift` 和 `Sources/Peekr/Store/ProfileStore.swift`。** 定义稳定 ID、默认 Profile 常量、展示名、不可变 storage key、创建/更新时间、容错解码和 Application Support 下的注册表。
2. **修改 `Workspace` 与 `WorkspacesData`**（`Sources/Peekr/Model/Workspace.swift`）。增加 `profileID`，缺失时回退默认 ID；递增 advisory schema version；旧 JSON 必须继续可读。不得移动既有标签或重写 Profile 存储。
3. **修改 `AppStore` 与 `AppModel`**（`Sources/Peekr/Store/AppStore.swift`、`Sources/Peekr/App/AppModel.swift`）。首次启动创建默认 Profile；注册表缺失或失效时安全修复到默认 Profile。增加 Profile 创建、重命名、归档、Workspace 绑定和删除保护。`addWorkspace()` 与 `addAgentWorkspace()` 默认使用默认 Profile。
4. **修改 Workspace UI**（`Sources/Peekr/UI/AppRail.swift` 及既有 Preferences surface）。增加 Profile 选择和管理入口；切换前说明 live pages 会被重建；保留现有 Workspace 所有权操作。
5. **测试：** 增加注册表、路径和迁移测试；扩展 `AgentWorkspaceTests`/Workspace 测试，覆盖缺失 `profileID`、默认分配、非法 Profile 修复、重新绑定和删除保护。

### 6.2 CEF Profile 解析与 Engine Factory

1. **扩展 `WebEngineFactory` 与 `WebViewManager`**（`Sources/Peekr/Web/WebEngine.swift`、`Sources/Peekr/Web/WebViewManager.swift`），让 engine 创建显式接收 Workspace 的 `BrowserProfile`，不再隐藏使用全局 default。
2. **重构 `CefSwiftEngineFactory`**（`Sources/Peekr/Web/CefSwiftEngine.swift`），按领域 Profile ID 缓存一个 `CefProfile`。默认 Profile 使用 `.default`，命名 Profile 使用 `.persistent(name: storageKey)`。所有 engine 关闭后才能释放缓存的 CEF Profile。
3. **先验证 vendored CEF 路径契约再发布。** 当前 `CefProfile.cachePath` 生成 `root/Profiles/<name>`，并已有纯路径测试（`Vendor/CefSwift/Sources/CefKit/CefProfile.swift:60-90`；`Vendor/CefSwift/Tests/CefKitTests/HandlerLogicTests.swift:104-123`），但引擎注释记录了历史上的 direct-child 限制（`Sources/Peekr/Web/CefSwiftEngine.swift:591-597`）。增加真实 arm64 Profile smoke；若 CEF 拒绝嵌套路径，再修改 vendored adapter 和测试为直接子目录 + UUID key。
4. **隔离测试：** 创建两个命名 Profile，分别写入 cookie/local-storage sentinel，验证互不可读；再验证同一 Profile 的两个标签能够共享；覆盖重启持久化和路径穿越输入。

### 6.3 生命周期、休眠与恢复

1. **扩展后端无关生命周期 seam**（`Sources/Peekr/Web/WebEngine.swift`、`Sources/Peekr/Web/BrowserState.swift`），增加活动/生命周期事件或快照：最后导航 URL、Renderer/browser 终止、音频状态可靠性和恢复状态。协议中不能泄漏 CefKit 类型。
2. **让标签事实可恢复**（`Sources/Peekr/Model/WebApp.swift`、`Sources/Peekr/App/AppModel.swift`）。通过既有节流持久化路径保存 settled navigation URL/title；若提供 UI 豁免，增加持久化 `keepAwake`。不得把 native view、CEF pointer 或 transient task 写入 Codable 模型。
3. **把 `HibernationPolicy` 接入 `WebViewManager`**（`Sources/Peekr/Web/HibernationPolicy.swift`、`Sources/Peekr/Web/WebViewManager.swift`）。跟踪最后一次前台激活、live/asleep 状态、Agent/automation 所有权、音频状态可靠性和 per-tab generation。idle threshold、面板隐藏空闲和 memory pressure 触发 sweep，避免高频轮询。
4. **安全休眠：** 保存最后导航快照，detach/close engine，移除 host view/agent host，清理下载和 per-engine 回调，保留模型/Profile/标题/icon/badge/URL/选择状态，只把标签标为 asleep。
5. **延迟恢复：** `activate(_:)` 发现 asleep/restoring 状态后，用绑定的 Profile 创建 engine，按需挂载，加载持久化 URL；收到第一条有效导航事件后清除 asleep。旧 generation 的恢复回调必须被忽略。
6. **接入可见性与自动化豁免：** 使用 `PanelController.onVisibilityChange` 通知生命周期调度器；有 active Agent/CDP 控制或 live hidden agent host 的标签不得自动休眠，除非用户显式手动休眠。
7. **保持策略纯函数：** 保留 `HibernationPolicy` 的可测试性，补充 active、recent、边界、keep-awake、pinned（若选定）、audible、unknown-audio、automation、asleep 和混合列表场景。

### 6.4 Renderer 崩溃与重启恢复

1. **在 `WebViewManager` 中增加恢复协调器**：每个标签维护 recovery generation，自动重试预算为 1 次，使用有界 backoff；超过预算后进入 `crashed`，保留现有 Retry UI。禁止无限重建循环。
2. **保留 CEF engine 语义**（`Sources/Peekr/Web/CefSwiftEngine.swift`）：`browserDidClose` 对该实例仍是终态；由后端无关事件传出终止 reason/code；不要在 CEF delegate 内自行创建新 engine。
3. **恢复当前页面：** Renderer 终止时保存最后安全 URL/Profile/Workspace 快照，关闭并移除失败 engine，用同一 Profile 创建替代 engine 并只 reload 一次。成功后清除恢复状态；再次失败则显示诊断并等待显式 Retry。测试旧 engine 的延迟回调不能影响替代 engine。
4. **应用重启恢复：** 依靠原子持久化的 Workspace/tab/Profile 事实，首次激活时延迟创建 engine；上一次进程异常退出时显示可恢复状态，不得静默丢失标签。若单元测试无法触发真实 CEF delegate，可增加 debug-only Renderer failure 注入路径。

### 6.5 arm64-only CEF 更新与发布供应链

1. **使根清单成为权威来源**（`CEF_VERSION.json`）。自定义 Chrome-codec 只保留 `macosarm64.minimal`；增加不可变来源/构建元数据，保留 SHA-1、SHA-256 和字节大小，并记录 CEF source commit、`automate-git.py` URL/hash、GN defines、codec/license 审核状态。
2. **架构 fail closed**（`scripts/prepare-cef.sh`、`scripts/bundle.sh`、`scripts/build-cef-chrome-codecs.sh`）。下载/构建前拒绝非 Darwin-arm64；移除 custom-artifact 路径的 x86_64 分支；CI/release 在执行 CEF 命令前断言 `uname -m`。
3. **加固 artifact 获取**（`scripts/prepare-cef.sh`）。要求 HTTPS/批准的不可变来源，校验 manifest、artifact name、version、architecture 一致性，提取前验证 size/SHA-1/SHA-256，记录来源和摘要，摘要变化时失效 extracted cache；项目清单存在时不得回退到 CefSwift 公共包。
4. **消除版本漂移**（`scripts/build-cef-chrome-codecs.sh`）。从受版本控制的 source manifest 派生 CEF version/commit/artifact name 和 `automate-git.py` hash；产出包必须再次按同一清单验证；继续显式保留 proprietary-codec GN flags 和许可证门禁。
5. **新增根 workflow**（`.github/workflows/cef-update.yml`）。在 arm64 macOS runner/批准的 arm64 build host 上运行，监控 stable CEF arm64 可用性，并针对 custom codec artifact 创建审核 PR/issue，不直接自动合并。根 workflow 必须调用根脚本；vendored workflow 不是 Peekr 的事实来源。
6. **拆分 check/build/promote 阶段。** 轻量 check 只比较上游元数据；人工/批准的 arm64 build 产出 custom artifact 和 manifest；validation 运行真实 framework 的 `check-symbols.sh`、`swift test`、arm64 bundle/smoke、签名/公证校验，并生成含 old/new digest 的审核内容。升级必须人工确认 CEF API、codec licensing 和 rollback。
7. **更新 CI/release/docs**（`.github/workflows/ci.yml`、`.github/workflows/release.yml`、`docs/cef-chrome-codecs.md`），加入架构断言、manifest/provenance 校验、已验证回滚步骤和明确的发布证据。保持 arm64-only，不为让通用矩阵变绿而加入 x86 CEF 包。

## 7. 实施顺序

1. **冻结契约与基线。** 记录现有 `apps.json`/`Chromium/Default` 迁移样例、manifest digest 和当前测试/smoke 命令。并发工作树发生变化时，实施前必须重新生成 provenance。
2. **实施 Profile 数据与迁移。** 增加注册表、`Workspace.profileID`、容错 schema migration、默认创建、绑定/删除规则和纯测试；缺失 Profile 始终回退默认值。
3. **实施 Profile-aware engine 创建。** 修改 factory seam 和 fake factory，缓存后端 Profile；先通过真实 arm64 CEF 路径 smoke，再开放 UI 切换。
4. **增加 Profile UI 和 Workspace 切换。** 增加选择/管理入口，关闭受影响 engine，失效 generation，延迟重建；验证选择状态、标签归属和 Agent Workspace。
5. **持久化 live navigation snapshot。** 沿用模型已有原子/节流持久化路径保存 URL/title；补充 redirect 和 relaunch 数据测试。
6. **接入生命周期策略。** 增加 runtime record、调度器、memory/visibility 触发、keep-awake/audio/automation 豁免、安全休眠和延迟恢复。所有 AppKit/CEF close/create 必须留在 MainActor。
7. **增加崩溃恢复。** 增加 generation-guarded 单次重建/reload、终态诊断和旧回调测试；不要与 CEF 版本升级混在同一步。
8. **闭合 CEF 供应链。** 实现 arm64 fail-closed、manifest/script 去漂移、根 workflow 阶段、attestation/review gate 和发布文档。
9. **执行集成与发布门禁。** 运行纯测试、真实 CEF Profile/lifecycle/recovery smoke、symbol 校验、debug bundle smoke、release 签名/公证和回滚演练。

## 8. 测试策略

### 单元与模型测试

- 新增 `ProfileStoreTests`：缺失 registry → 生成默认 Profile；坏数据 → 安全修复；改名不改变 ID；绑定中的 Profile 不可删除；路径穿越不出 root。
- Workspace migration：旧 v2 JSON 与 legacy `[WebApp]` JSON → 所有 Workspace 使用默认 Profile；新建 Workspace/Agent Workspace 默认正确；active selection 和 tab IDs 不变。
- 扩展 `WebViewManagerLifecycleTests.swift`：factory 收到 Workspace Profile；重新绑定关闭旧 fake engine；新 engine 延迟创建并接收新 Profile；asleep 标签按需恢复；旧 generation 回调被忽略。
- 扩展 `CefSwiftEngineTests.swift`：Profile 映射、Renderer termination event、close/browserDidClose 终态、恢复快照清理，以及宿主挂载前不创建 browser。
- 扩展 `HibernationPolicyTests.swift`：threshold 边界、active、keep-awake、audible、unknown、automation、asleep 和混合集合。

### 真实 CEF 集成

- 在 arm64 临时 app root 中创建两个持久化命名 Profile，分别写入 cookie/local-storage 值，重启后验证持久化和隔离。
- 在同一 Profile 打开多个标签验证共享 session；把 Workspace 切到另一 Profile，验证旧 engine 先关闭、新 context 后创建。
- 触发或注入 Renderer termination，验证只自动恢复一次、没有 retry storm、旧回调被忽略、第二次失败后显式 Retry 仍可用。
- 隐藏面板并施加 idle/memory-pressure 信号，验证只有符合条件的页面被丢弃；媒体/automation 页面保持 live；激活后恢复正确 URL/Profile。
- 保留现有 CEF capability/media/permission smoke（`docs/cef-chrome-codecs.md:62-83`），并使用 custom arm64 artifact 执行。

### 供应链与发布检查

- 覆盖坏 manifest、错误架构、错误 artifact name、size/SHA-1/SHA-256 不匹配、未批准来源、stale cache、缺失 provenance 和缺失 bridge symbol。
- 对真实 framework 运行 `Vendor/CefSwift/Scripts/check-symbols.sh`，再运行 `swift build`、`swift test`、`./scripts/bundle.sh debug` 和三个 CEF smoke。Release 运行 `./scripts/bundle.sh release`、`codesign --verify`，有凭据时运行公证/装订。
- 现有可运行命令由 `Package.swift:15-32`、`Makefile:3-37`、`.github/workflows/ci.yml:45-49`、`.github/workflows/release.yml:65-125`、`docs/cef-chrome-codecs.md:62-69` 佐证。

## 9. 风险与影响分析

- [graph] `WebViewManager`、`CefSwiftEngine` 和 `Workspace` 都是 CRITICAL 风险中心。必须拆成小步，每个 seam 改动后立即编译/测试。
- [graph] WebViewManager 的 impact 报告 68 个直接 d=1 依赖，覆盖 Agent（`AgentCDPClient`、`AgentControlServer`、`AgentTargetSync`）、App/组合根、Model/Store、Panel、Preferences、UI（`AppRail`、`PanelRootView`、`WebContainer`、`NavigationBar`、`OmniboxTextField`、`DownloadCenter`）、Util、Web 和 vendored CEF/CefSwiftUI imports。它们都是编译/测试消费者；实现只修改本计划列出的职责，并保持 `WebEngine` 后端无关。
- [graph] `CefSwiftEngine` 的 impact 是 lower-bound，因为接口分发可能隐藏调用方。任何空结果都必须视为未解决，并由源码和编译测试确认。
- [verified] Profile 切换和休眠是资源/并发边界：CEF/AppKit 创建、关闭、挂载以及回调状态修改都留在 `@MainActor`；generation token 防止异步 DOM/favicon/download 任务修改替代 engine。
- [inferred] 休眠可能停止媒体、下载、Service Worker、WebSocket 和 Agent automation。必须使用保守豁免；活动/音频未知页面不得自动丢弃。
- [inferred] Profile 不是本地进程安全边界。CDP 授权和 Agent target 可见性仍需独立治理；没有单独协议设计时不能承诺 Profile 级 CDP 隔离。
- [verified] 当前 custom artifact 无法由根 workflow 自动重建：根脚本支持 custom staging，但更新 workflow 位于 vendored 包内且假定公共双架构 CEF 元数据。这是发布阻断项，不是单纯文档问题。
- [inferred] CEF major 更新可能破坏 C API symbol、Chromium storage、sandbox/signing 或 codec licensing。API symbol、来源、架构、许可证或 smoke 证据不完整时必须禁止自动合并。
- [inferred] 运行监控应记录 Profile ID（不记录 cookie/path 内容）、tab ID、生命周期转换、原因、generation、恢复次数、Renderer termination code、artifact digest、CEF version 和 arm64 校验结果；URL/token 默认脱敏。

## 10. 预期改动文件

| 文件 | 符号/区域 | 原因 |
| --- | --- | --- |
| `Sources/Peekr/Model/BrowserProfile.swift` | 新增 Profile 类型 | 稳定 Profile 身份和默认契约。 |
| `Sources/Peekr/Store/ProfileStore.swift` | 新增 registry store | 独立持久化和修复 Profile registry。 |
| `Sources/Peekr/Model/Workspace.swift` | `Workspace`, `WorkspacesData` | 增加 `profileID` 和容错迁移。 |
| `Sources/Peekr/Model/WebApp.swift` | `WebApp` | 保存 keep-awake 和 settled recovery facts。 |
| `Sources/Peekr/Store/AppStore.swift` | load/default migration | 不丢标签地协调默认 Profile。 |
| `Sources/Peekr/App/AppModel.swift` | Workspace/Profile 操作 | 绑定/重绑定 Profile，保存恢复事实。 |
| `Sources/Peekr/App/AppDelegate.swift` | composition root | 注入 Profile store/resolver 和生命周期 hook。 |
| `Sources/Peekr/UI/AppRail.swift` | Workspace header/actions | Profile 选择和管理入口。 |
| `Sources/Peekr/Panel/PanelController.swift` | visibility callback | 生命周期调度的可见性信号。 |
| `Sources/Peekr/Web/WebEngine.swift` | backend-neutral protocol | Profile/activity/recovery seam。 |
| `Sources/Peekr/Web/BrowserState.swift` | observable state | UI 可见的 asleep/restoring/crashed 状态。 |
| `Sources/Peekr/Web/WebViewManager.swift` | engine cache/scheduler/recovery | Profile-aware 生命周期核心。 |
| `Sources/Peekr/Web/CefSwiftEngine.swift` | factory/delegate/termination | 映射领域 Profile 与 CEF failure。 |
| `Sources/Peekr/Web/HibernationPolicy.swift` | candidate rules | 保持纯函数并增加保守豁免。 |
| `Vendor/CefSwift/Sources/CefKit/CefProfile.swift` | 条件性路径修复 | 仅当真实 arm64 smoke 证明当前路径无效时修改。 |
| `Vendor/CefSwift/Tests/CefKitTests/HandlerLogicTests.swift` | Profile path tests | 锁定已验证的 CEF 路径。 |
| `Tests/PeekrTests/ProfileStoreTests.swift` | 新增 | registry/migration/isolation 测试。 |
| `Tests/PeekrTests/WebViewManagerLifecycleTests.swift` | fake engine/factory | Profile 切换、休眠、恢复、旧回调。 |
| `Tests/PeekrTests/CefSwiftEngineTests.swift` | state/factory/recovery | CEF adapter 契约。 |
| `Tests/PeekrTests/HibernationPolicyTests.swift` | candidate scenarios | 策略边界。 |
| `Tests/PeekrTests/AgentWorkspaceTests.swift` | migration/default | Agent Workspace 兼容性。 |
| `CEF_VERSION.json` | root custom artifact metadata | arm64-only、来源和摘要。 |
| `scripts/prepare-cef.sh` | stage/record | arm64 fail-closed 与 digest/provenance。 |
| `scripts/build-cef-chrome-codecs.sh` | source/build pins | 消除版本漂移并证明产物来源。 |
| `scripts/bundle.sh` | bundle entrypoint | 架构和 provenance 门禁。 |
| `.github/workflows/cef-update.yml` | 新 root workflow | 根仓库实际使用的 check/build/validate/review 流程。 |
| `.github/workflows/ci.yml` | architecture/manifest gates | 验证支持的 CEF 环境。 |
| `.github/workflows/release.yml` | release gates | 阻止发布未验证产物。 |
| `docs/cef-chrome-codecs.md` | operational runbook | 构建、审核、回滚、许可证和证据。 |

`Vendor/CefSwift/Scripts/cef-update.sh` 和 vendored 嵌套 workflow 只是 vendor/reference automation，不是 Peekr custom Chrome-codec artifact 的权威来源；除非实现明确需要上游兼容修复，否则不要修改。

## 11. 可复用实施上下文

```yaml
implementation_context:
  task_summary: >-
    实现绑定 Workspace 的 Chrome 风格持久化 Profile，接入保守的后台页面休眠和
    generation-guarded Renderer 恢复，并闭合 arm64-only CEF 更新/发布供应链缺口。
    本次计划任务没有实施任何上述改动。
  acceptance_criteria:
    - 既有标签和 Chromium/Default 数据无损迁移到稳定默认 Profile。
    - 新 Workspace 默认使用默认 Profile；命名 Profile 存储隔离且可安全绑定/重绑定。
    - Profile 重绑定先关闭旧 engine，再在新 Profile 下延迟创建。
    - 符合条件的后台页面可休眠并延迟恢复；active、unknown-audio、keep-awake、automation 页面受保护。
    - Renderer failure 最多执行一次 generation-guarded 自动恢复，并保留显式 Retry。
    - CEF 更新/构建/发布只支持 arm64，且有 digest/provenance、审核和回滚证据。
    - 单元、集成、CEF smoke、symbol、bundle、签名、公证和发布门禁均通过。
  evidence_provenance: {"schema_version":2,"head_commit":"6a17afe63a2f8a745a6b25ea955c902d3e3a17a4","generated_plan_path":"docs/plans/2026-10-03-gitnexus-plan-profile-lifecycle-cef.md","global_dirty_digest":{"algorithm":"sha256","canonicalization":"gitnexus-evidence-provenance-v2 NUL-framed UTF-8 records","value":"0a9c85780067d9afcd0764f307b60891e3cee927ee11eaeb5ec7826d10fd82cd"},"cited_path_manifest":[{"path":".github/workflows/ci.yml","object_kind":{"head":"regular","index":"regular","worktree":"regular","untracked":"absent"},"state":"clean","rename_from":null,"rename_to":null,"head_digest":"sha256:970f80b1551e091068270e0463fc6e5e121588fbba959dd8371ea92e091c8f70","index_digest":"sha256:970f80b1551e091068270e0463fc6e5e121588fbba959dd8371ea92e091c8f70","worktree_digest":"sha256:970f80b1551e091068270e0463fc6e5e121588fbba959dd8371ea92e091c8f70","untracked_digest":"absent"},{"path":".github/workflows/release.yml","object_kind":{"head":"regular","index":"regular","worktree":"regular","untracked":"absent"},"state":"clean","rename_from":null,"rename_to":null,"head_digest":"sha256:0de184ee2c0ddd3e8ad8f510ed6e89fd0fa230276cd84d436cf5a54d2d760cb5","index_digest":"sha256:0de184ee2c0ddd3e8ad8f510ed6e89fd0fa230276cd84d436cf5a54d2d760cb5","worktree_digest":"sha256:0de184ee2c0ddd3e8ad8f510ed6e89fd0fa230276cd84d436cf5a54d2d760cb5","untracked_digest":"absent"},{"path":"CEF_VERSION.json","object_kind":{"head":"regular","index":"regular","worktree":"regular","untracked":"absent"},"state":"clean","rename_from":null,"rename_to":null,"head_digest":"sha256:7e75206d72384aefbffb85660ef4329c23a3da22612c63f9da31af0bece0f514","index_digest":"sha256:7e75206d72384aefbffb85660ef4329c23a3da22612c63f9da31af0bece0f514","worktree_digest":"sha256:7e75206d72384aefbffb85660ef4329c23a3da22612c63f9da31af0bece0f514","untracked_digest":"absent"},{"path":"Makefile","object_kind":{"head":"regular","index":"regular","worktree":"regular","untracked":"absent"},"state":"clean","rename_from":null,"rename_to":null,"head_digest":"sha256:4c8a9612dc08ded17b88d0c7f67de938608ec1264710bdafa38b785f43e052fe","index_digest":"sha256:4c8a9612dc08ded17b88d0c7f67de938608ec1264710bdafa38b785f43e052fe","worktree_digest":"sha256:4c8a9612dc08ded17b88d0c7f67de938608ec1264710bdafa38b785f43e052fe","untracked_digest":"absent"},{"path":"Package.swift","object_kind":{"head":"regular","index":"regular","worktree":"regular","untracked":"absent"},"state":"clean","rename_from":null,"rename_to":null,"head_digest":"sha256:23109c7822b8410cc5c50fe039c41a67c1bc14bc0efff94810a61a8b126f01df","index_digest":"sha256:23109c7822b8410cc5c50fe039c41a67c1bc14bc0efff94810a61a8b126f01df","worktree_digest":"sha256:23109c7822b8410cc5c50fe039c41a67c1bc14bc0efff94810a61a8b126f01df","untracked_digest":"absent"},{"path":"Sources/Peekr/App/AppDelegate.swift","object_kind":{"head":"regular","index":"regular","worktree":"regular","untracked":"absent"},"state":"clean","rename_from":null,"rename_to":null,"head_digest":"sha256:4cbfbd2cd2924c6c43131d6b6131d1e3effba7f5a23746f2a034a12b9eb49482","index_digest":"sha256:4cbfbd2cd2924c6c43131d6b6131d1e3effba7f5a23746f2a034a12b9eb49482","worktree_digest":"sha256:4cbfbd2cd2924c6c43131d6b6131d1e3effba7f5a23746f2a034a12b9eb49482","untracked_digest":"absent"},{"path":"Sources/Peekr/App/AppModel.swift","object_kind":{"head":"regular","index":"regular","worktree":"regular","untracked":"absent"},"state":"clean","rename_from":null,"rename_to":null,"head_digest":"sha256:098fcc1f28e08d62ee1d0f27e69f5aaf59649731d9f17d2429889ac877492e86","index_digest":"sha256:098fcc1f28e08d62ee1d0f27e69f5aaf59649731d9f17d2429889ac877492e86","worktree_digest":"sha256:098fcc1f28e08d62ee1d0f27e69f5aaf59649731d9f17d2429889ac877492e86","untracked_digest":"absent"},{"path":"Sources/Peekr/App/PeekrApp.swift","object_kind":{"head":"regular","index":"regular","worktree":"regular","untracked":"absent"},"state":"clean","rename_from":null,"rename_to":null,"head_digest":"sha256:af0aff0feb44f8a1a9b1c740929fdb23fb0a5455eee12f5587cb38d96b63c04d","index_digest":"sha256:af0aff0feb44f8a1a9b1c740929fdb23fb0a5455eee12f5587cb38d96b63c04d","worktree_digest":"sha256:af0aff0feb44f8a1a9b1c740929fdb23fb0a5455eee12f5587cb38d96b63c04d","untracked_digest":"absent"},{"path":"Sources/Peekr/Model/WebApp.swift","object_kind":{"head":"regular","index":"regular","worktree":"regular","untracked":"absent"},"state":"clean","rename_from":null,"rename_to":null,"head_digest":"sha256:8aeff0e97af1d01035035a5252aff504567f6eadec39b15b217231cb5fee33a5","index_digest":"sha256:8aeff0e97af1d01035035a5252aff504567f6eadec39b15b217231cb5fee33a5","worktree_digest":"sha256:8aeff0e97af1d01035035a5252aff504567f6eadec39b15b217231cb5fee33a5","untracked_digest":"absent"},{"path":"Sources/Peekr/Model/Workspace.swift","object_kind":{"head":"regular","index":"regular","worktree":"regular","untracked":"absent"},"state":"clean","rename_from":null,"rename_to":null,"head_digest":"sha256:f7f76438bd4ee5bc1a7153fe11eb0b418e8eef4b839b419d20318aa17434c647","index_digest":"sha256:f7f76438bd4ee5bc1a7153fe11eb0b418e8eef4b839b419d20318aa17434c647","worktree_digest":"sha256:f7f76438bd4ee5bc1a7153fe11eb0b418e8eef4b839b419d20318aa17434c647","untracked_digest":"absent"},{"path":"Sources/Peekr/Panel/PanelController.swift","object_kind":{"head":"regular","index":"regular","worktree":"regular","untracked":"absent"},"state":"clean","rename_from":null,"rename_to":null,"head_digest":"sha256:f19632725cb5051af2ceb9890081036cbd932a394a6a816bd8b5fa8a7ba8e4b1","index_digest":"sha256:f19632725cb5051af2ceb9890081036cbd932a394a6a816bd8b5fa8a7ba8e4b1","worktree_digest":"sha256:f19632725cb5051af2ceb9890081036cbd932a394a6a816bd8b5fa8a7ba8e4b1","untracked_digest":"absent"},{"path":"Sources/Peekr/Store/AppStore.swift","object_kind":{"head":"regular","index":"regular","worktree":"regular","untracked":"absent"},"state":"clean","rename_from":null,"rename_to":null,"head_digest":"sha256:030f8c46f5d7a240822530d9b24ca1a691d801ebb607f7777e74f9789443cf4b","index_digest":"sha256:030f8c46f5d7a240822530d9b24ca1a691d801ebb607f7777e74f9789443cf4b","worktree_digest":"sha256:030f8c46f5d7a240822530d9b24ca1a691d801ebb607f7777e74f9789443cf4b","untracked_digest":"absent"},{"path":"Sources/Peekr/UI/AppRail.swift","object_kind":{"head":"regular","index":"regular","worktree":"regular","untracked":"absent"},"state":"clean","rename_from":null,"rename_to":null,"head_digest":"sha256:b6067e7b9162f5ab6b27b173fcf1bbaab5c5a63299b07b792bff7e26761a0021","index_digest":"sha256:b6067e7b9162f5ab6b27b173fcf1bbaab5c5a63299b07b792bff7e26761a0021","worktree_digest":"sha256:b6067e7b9162f5ab6b27b173fcf1bbaab5c5a63299b07b792bff7e26761a0021","untracked_digest":"absent"},{"path":"Sources/Peekr/Web/BrowserState.swift","object_kind":{"head":"regular","index":"regular","worktree":"regular","untracked":"absent"},"state":"clean","rename_from":null,"rename_to":null,"head_digest":"sha256:f7758a9ba7bdedc75f03624b2b26fc1595c2b8b5671217e11ba4ae81106b6453","index_digest":"sha256:f7758a9ba7bdedc75f03624b2b26fc1595c2b8b5671217e11ba4ae81106b6453","worktree_digest":"sha256:f7758a9ba7bdedc75f03624b2b26fc1595c2b8b5671217e11ba4ae81106b6453","untracked_digest":"absent"},{"path":"Sources/Peekr/Web/CefSwiftEngine.swift","object_kind":{"head":"regular","index":"regular","worktree":"regular","untracked":"absent"},"state":"clean","rename_from":null,"rename_to":null,"head_digest":"sha256:d09bf06ff09da158f38e65229880ba815f7dd54aa8f4ccd955a642a7b4b29448","index_digest":"sha256:d09bf06ff09da158f38e65229880ba815f7dd54aa8f4ccd955a642a7b4b29448","worktree_digest":"sha256:d09bf06ff09da158f38e65229880ba815f7dd54aa8f4ccd955a642a7b4b29448","untracked_digest":"absent"},{"path":"Sources/Peekr/Web/HibernationPolicy.swift","object_kind":{"head":"regular","index":"regular","worktree":"regular","untracked":"absent"},"state":"clean","rename_from":null,"rename_to":null,"head_digest":"sha256:d6e5f67bf55c622502438644d79fba190936238381e8000dc4ebacd9b48d4d2e","index_digest":"sha256:d6e5f67bf55c622502438644d79fba190936238381e8000dc4ebacd9b48d4d2e","worktree_digest":"sha256:d6e5f67bf55c622502438644d79fba190936238381e8000dc4ebacd9b48d4d2e","untracked_digest":"absent"},{"path":"Sources/Peekr/Web/WebEngine.swift","object_kind":{"head":"regular","index":"regular","worktree":"regular","untracked":"absent"},"state":"clean","rename_from":null,"rename_to":null,"head_digest":"sha256:c4fe38f55fc0c94e70cf425989b6608f1aff41312659ff65fd3ba748130cbe9a","index_digest":"sha256:c4fe38f55fc0c94e70cf425989b6608f1aff41312659ff65fd3ba748130cbe9a","worktree_digest":"sha256:c4fe38f55fc0c94e70cf425989b6608f1aff41312659ff65fd3ba748130cbe9a","untracked_digest":"absent"},{"path":"Sources/Peekr/Web/WebViewManager.swift","object_kind":{"head":"regular","index":"regular","worktree":"regular","untracked":"absent"},"state":"clean","rename_from":null,"rename_to":null,"head_digest":"sha256:27e6ff45488ab53ad5e0642b5e2062d4c6a9d35c2b6bde66386e66a23a8a856a","index_digest":"sha256:27e6ff45488ab53ad5e0642b5e2062d4c6a9d35c2b6bde66386e66a23a8a856a","worktree_digest":"sha256:27e6ff45488ab53ad5e0642b5e2062d4c6a9d35c2b6bde66386e66a23a8a856a","untracked_digest":"absent"},{"path":"Tests/PeekrTests/AgentWorkspaceTests.swift","object_kind":{"head":"regular","index":"regular","worktree":"regular","untracked":"absent"},"state":"clean","rename_from":null,"rename_to":null,"head_digest":"sha256:362b06d44a23c10f73c1a96de31c596eafed32548f62070171884a7207906de0","index_digest":"sha256:362b06d44a23c10f73c1a96de31c596eafed32548f62070171884a7207906de0","worktree_digest":"sha256:362b06d44a23c10f73c1a96de31c596eafed32548f62070171884a7207906de0","untracked_digest":"absent"},{"path":"Tests/PeekrTests/CefSwiftEngineTests.swift","object_kind":{"head":"regular","index":"regular","worktree":"regular","untracked":"absent"},"state":"clean","rename_from":null,"rename_to":null,"head_digest":"sha256:d1f810cc02846e217038e65fa6afde0a8d3a64cee2d9c24d51be9e45a407630e","index_digest":"sha256:d1f810cc02846e217038e65fa6afde0a8d3a64cee2d9c24d51be9e45a407630e","worktree_digest":"sha256:d1f810cc02846e217038e65fa6afde0a8d3a64cee2d9c24d51be9e45a407630e","untracked_digest":"absent"},{"path":"Tests/PeekrTests/HibernationPolicyTests.swift","object_kind":{"head":"regular","index":"regular","worktree":"regular","untracked":"absent"},"state":"clean","rename_from":null,"rename_to":null,"head_digest":"sha256:d6e1deeb330c6c1837c6a577202829248b1cf309904d74b6f944435dbe87c27e","index_digest":"sha256:d6e1deeb330c6c1837c6a577202829248b1cf309904d74b6f944435dbe87c27e","worktree_digest":"sha256:d6e1deeb330c6c1837c6a577202829248b1cf309904d74b6f944435dbe87c27e","untracked_digest":"absent"},{"path":"Tests/PeekrTests/WebViewManagerLifecycleTests.swift","object_kind":{"head":"regular","index":"regular","worktree":"regular","untracked":"absent"},"state":"clean","rename_from":null,"rename_to":null,"head_digest":"sha256:69860fe158d7eb25b1f7a7095efedcd798ac837928be3a3f272c6ced02728533","index_digest":"sha256:69860fe158d7eb25b1f7a7095efedcd798ac837928be3a3f272c6ced02728533","worktree_digest":"sha256:69860fe158d7eb25b1f7a7095efedcd798ac837928be3a3f272c6ced02728533","untracked_digest":"absent"},{"path":"Vendor/CefSwift/.github/workflows/cef-update.yml","object_kind":{"head":"regular","index":"regular","worktree":"regular","untracked":"absent"},"state":"clean","rename_from":null,"rename_to":null,"head_digest":"sha256:a1651059af4a943611733e1c8000e5ad2e8c32d3fa6b7912a7f07b004af7ed0d","index_digest":"sha256:a1651059af4a943611733e1c8000e5ad2e8c32d3fa6b7912a7f07b004af7ed0d","worktree_digest":"sha256:a1651059af4a943611733e1c8000e5ad2e8c32d3fa6b7912a7f07b004af7ed0d","untracked_digest":"absent"},{"path":"Vendor/CefSwift/Scripts/cef-update.sh","object_kind":{"head":"regular","index":"regular","worktree":"regular","untracked":"absent"},"state":"clean","rename_from":null,"rename_to":null,"head_digest":"sha256:fc648263848677587c72546e420122bc1b5da788f71b04d551f5630a27b1adad","index_digest":"sha256:fc648263848677587c72546e420122bc1b5da788f71b04d551f5630a27b1adad","worktree_digest":"sha256:fc648263848677587c72546e420122bc1b5da788f71b04d551f5630a27b1adad","untracked_digest":"absent"},{"path":"Vendor/CefSwift/Scripts/check-symbols.sh","object_kind":{"head":"regular","index":"regular","worktree":"regular","untracked":"absent"},"state":"clean","rename_from":null,"rename_to":null,"head_digest":"sha256:1a7485efd4bc4cc145b2dd65f9c3c7bc692c6d99fd267844099be3804e900537","index_digest":"sha256:1a7485efd4bc4cc145b2dd65f9c3c7bc692c6d99fd267844099be3804e900537","worktree_digest":"sha256:1a7485efd4bc4cc145b2dd65f9c3c7bc692c6d99fd267844099be3804e900537","untracked_digest":"absent"},{"path":"Vendor/CefSwift/Sources/CefKit/CefProfile.swift","object_kind":{"head":"regular","index":"regular","worktree":"regular","untracked":"absent"},"state":"clean","rename_from":null,"rename_to":null,"head_digest":"sha256:cd5b6de41ec6dafc41f90d32a5be26e7a2bf31419c7c0770b8c9b552d80414bb","index_digest":"sha256:cd5b6de41ec6dafc41f90d32a5be26e7a2bf31419c7c0770b8c9b552d80414bb","worktree_digest":"sha256:cd5b6de41ec6dafc41f90d32a5be26e7a2bf31419c7c0770b8c9b552d80414bb","untracked_digest":"absent"},{"path":"Vendor/CefSwift/Tests/CefKitTests/HandlerLogicTests.swift","object_kind":{"head":"regular","index":"regular","worktree":"regular","untracked":"absent"},"state":"clean","rename_from":null,"rename_to":null,"head_digest":"sha256:89fa70ae678bc30cdfee8ebdab0efbf5e6853bf9e795236e78e44a82d5472805","index_digest":"sha256:89fa70ae678bc30cdfee8ebdab0efbf5e6853bf9e795236e78e44a82d5472805","worktree_digest":"sha256:89fa70ae678bc30cdfee8ebdab0efbf5e6853bf9e795236e78e44a82d5472805","untracked_digest":"absent"},{"path":"docs/cef-chrome-codecs.md","object_kind":{"head":"regular","index":"regular","worktree":"regular","untracked":"absent"},"state":"clean","rename_from":null,"rename_to":null,"head_digest":"sha256:0ca3bc5d55f1b9f7750218553e34a4b1156529dd58df4cc2ee23b6ada996c25e","index_digest":"sha256:0ca3bc5d55f1b9f7750218553e34a4b1156529dd58df4cc2ee23b6ada996c25e","worktree_digest":"sha256:0ca3bc5d55f1b9f7750218553e34a4b1156529dd58df4cc2ee23b6ada996c25e","untracked_digest":"absent"},{"path":"scripts/build-cef-chrome-codecs.sh","object_kind":{"head":"regular","index":"regular","worktree":"regular","untracked":"absent"},"state":"clean","rename_from":null,"rename_to":null,"head_digest":"sha256:966e42735130db18febef4f740fddb3108b0c0768542fdaed026546a4dc5ddd4","index_digest":"sha256:966e42735130db18febef4f740fddb3108b0c0768542fdaed026546a4dc5ddd4","worktree_digest":"sha256:966e42735130db18febef4f740fddb3108b0c0768542fdaed026546a4dc5ddd4","untracked_digest":"absent"},{"path":"scripts/bundle.sh","object_kind":{"head":"regular","index":"regular","worktree":"regular","untracked":"absent"},"state":"clean","rename_from":null,"rename_to":null,"head_digest":"sha256:6e8c942be59dc7ce51cbd5d256e65250cab972046e9012b0710f48eafa9ad8c2","index_digest":"sha256:6e8c942be59dc7ce51cbd5d256e65250cab972046e9012b0710f48eafa9ad8c2","worktree_digest":"sha256:6e8c942be59dc7ce51cbd5d256e65250cab972046e9012b0710f48eafa9ad8c2","untracked_digest":"absent"},{"path":"scripts/prepare-cef.sh","object_kind":{"head":"regular","index":"regular","worktree":"regular","untracked":"absent"},"state":"clean","rename_from":null,"rename_to":null,"head_digest":"sha256:364b42e894f4f2c85a1f594e7a196762db09bbc6a30619bee7f1aae6f115e14a","index_digest":"sha256:364b42e894f4f2c85a1f594e7a196762db09bbc6a30619bee7f1aae6f115e14a","worktree_digest":"sha256:364b42e894f4f2c85a1f594e7a196762db09bbc6a30619bee7f1aae6f115e14a","untracked_digest":"absent"}]}
  primary_symbols:
    - symbol: Workspace / WorkspacesData
      file: Sources/Peekr/Model/Workspace.swift
      lines: "86-154,237-265"
      role: 持久化 Workspace 结构和迁移边界。
    - symbol: AppModel.addWorkspace / AppModel.selectWorkspace
      file: Sources/Peekr/App/AppModel.swift
      lines: "568-589"
      role: Workspace 创建与选择。
    - symbol: WebViewManager
      file: Sources/Peekr/Web/WebViewManager.swift
      lines: "53-115,252-315,364-377"
      role: live engine 所有权、回调、生命周期和状态镜像。
    - symbol: CefSwiftEngine / CefSwiftEngineFactory
      file: Sources/Peekr/Web/CefSwiftEngine.swift
      lines: "136-198,239-276,459-471,579-612"
      role: CEF browser 生命周期、failure 转换和 Profile 映射。
    - symbol: HibernationPolicy
      file: Sources/Peekr/Web/HibernationPolicy.swift
      lines: "3-45"
      role: 当前尚未接入 Manager 的纯候选选择策略。
  related_symbols:
    - symbol: WebEngine / WebEngineFactory
      relationship: protocol seam
      relevance: 让 UI/Manager 测试保持后端无关，并承载生命周期/Profile 输入。
    - symbol: CefProfile
      relationship: backend Profile adapter
      relevance: 已有 default/incognito/persistent context API 与路径校验。
    - symbol: AppStore
      relationship: persistence boundary
      relevance: 旧扁平数组迁移和默认 Workspace 创建。
    - symbol: AppRail / PanelController
      relationship: UI and visibility consumers
      relevance: Workspace 操作与显示/隐藏生命周期信号。
    - symbol: AgentTargetSync / AppDelegate
      relationship: automation integration
      relevance: Agent 标签受控期间不能被静默休眠。
  execution_path:
    - AppDelegate 创建 AppModel、WebViewManager、CefSwiftEngineFactory 和 AgentTargetSync。
    - Workspace 选择决定 active tab 及其绑定 Profile。
    - WebViewManager 解析/创建 Profile-aware engine，并安装导航/下载回调。
    - CefSwiftEngine 只有在宿主 view 挂载后才创建 CEF browser。
    - 导航状态更新恢复事实，并镜像 active UI 状态。
    - 生命周期调度器选择符合条件的后台标签，关闭 engine 并记录 asleep。
    - 激活时用相同 Profile 创建 engine 并加载持久化 URL。
    - Renderer termination 进入有界恢复流程，旧 generation 不能修改新 engine。
    - 根 CEF workflow 校验 source revision、custom artifact digest、bridge symbol、arm64 bundle 和发布证据。
  pdg_constraints:
    - description: "MCP 退出后没有可用的局部 PDG slice；CLI PDG 输出是 callgraph bridge，因此以源码确认的 guard 为准。"
      affected_statements:
        - "Sources/Peekr/Web/CefSwiftEngine.swift:170-198"
        - "Sources/Peekr/Web/CefSwiftEngine.swift:136-146"
        - "Sources/Peekr/Web/CefSwiftEngine.swift:459-471"
        - "Sources/Peekr/Web/WebViewManager.swift:252-315"
        - "Sources/Peekr/Web/HibernationPolicy.swift:35-45"
      implementation_consequence: "保持 MainActor 顺序、单次 browser 创建、终态 close、回调清理和全部策略豁免；实施前重新执行 targeted PDG/context 检查。"
  architectural_patterns:
    - pattern: 后端无关 WebEngine protocol 与 fake factory 测试
      example_location: Sources/Peekr/Web/WebEngine.swift + Tests/PeekrTests/WebViewManagerLifecycleTests.swift
      usage_guidance: 在 seam 增加领域 lifecycle/Profile 值，把 CefKit 类型留在 CefSwiftEngine 内。
    - pattern: 容错 Codable migration 与原子 AppStore 写入
      example_location: Sources/Peekr/Model/Workspace.swift + Sources/Peekr/Store/AppStore.swift
      usage_guidance: 缺失 Profile 字段回退 default，不破坏性拒绝或重写旧标签数据。
    - pattern: MainActor CEF/AppKit 所有权
      example_location: Sources/Peekr/Web/CefSwiftEngine.swift
      usage_guidance: native object 创建/关闭/挂载都在 MainActor，用 generation guard 处理异步回调。
    - pattern: size/SHA-1/SHA-256 artifact 校验与 cache provenance
      example_location: scripts/prepare-cef.sh
      usage_guidance: 扩展现有 fail-closed 检查，项目清单存在时禁止回退到未钉住的公共 artifact。
  files_to_modify:
    - file: Sources/Peekr/Model/Workspace.swift
      symbols: [Workspace, WorkspacesData]
      intended_change: 增加 profileID 和容错 schema migration。
    - file: Sources/Peekr/Model/BrowserProfile.swift
      symbols: [new Profile types]
      intended_change: 稳定 Profile 身份和 default 契约。
    - file: Sources/Peekr/Store/ProfileStore.swift
      symbols: [new registry store]
      intended_change: 持久化并修复 Profile registry。
    - file: Sources/Peekr/App/AppModel.swift
      symbols: [Workspace/Profile operations, live navigation persistence]
      intended_change: 绑定/重绑定 Profile 并保存恢复事实。
    - file: Sources/Peekr/Web/WebEngine.swift
      symbols: [WebEngine, WebEngineFactory]
      intended_change: Profile/activity/recovery seam。
    - file: Sources/Peekr/Web/WebViewManager.swift
      symbols: [WebViewManager]
      intended_change: Profile-aware engine 所有权、休眠调度、恢复与崩溃恢复。
    - file: Sources/Peekr/Web/CefSwiftEngine.swift
      symbols: [CefSwiftEngine, CefSwiftEngineFactory]
      intended_change: 映射领域 Profile 和 CEF termination event。
    - file: Sources/Peekr/Web/HibernationPolicy.swift
      symbols: [HibernationPolicy]
      intended_change: 保守生命周期候选规则。
    - file: CEF_VERSION.json
      symbols: [manifest]
      intended_change: arm64 custom artifact provenance 和审核元数据。
    - file: scripts/prepare-cef.sh
      symbols: [stage/record]
      intended_change: arm64-only fail-closed 获取和 cache 绑定。
    - file: scripts/build-cef-chrome-codecs.sh
      symbols: [build entrypoint]
      intended_change: manifest 驱动的 source/build pinning。
    - file: scripts/bundle.sh
      symbols: [bundle entrypoint]
      intended_change: arm64/provenance 门禁。
    - file: .github/workflows/cef-update.yml
      symbols: [new root workflow]
      intended_change: 根仓库拥有 check/build/validate/review 流程。
  tests:
    - file: Tests/PeekrTests/ProfileStoreTests.swift
      scenarios:
        - "缺失 registry → 生成默认 Profile，既有 Workspace 仍可读取"
        - "改名/删除/非法 key → ID 稳定、绑定中的 Profile 拒绝删除、路径留在 root 内"
        - "两个命名 Profile → cookie/storage sentinel 隔离；同一 Profile → sentinel 共享"
    - file: Tests/PeekrTests/WebViewManagerLifecycleTests.swift
      scenarios:
        - "Profile 重绑定 → 旧 fake engine 关闭，新 engine 延迟创建并收到新 Profile"
        - "符合条件的后台标签 → 休眠；激活 → 使用相同 Profile 和 URL 恢复一次"
        - "generation 变化后的旧 engine 回调 → 被忽略"
    - file: Tests/PeekrTests/CefSwiftEngineTests.swift
      scenarios:
        - "Renderer termination → failure event；loading/recovery 清除 failure"
        - "close/browserDidClose → engine 保持终态，不能原地创建"
    - file: Tests/PeekrTests/HibernationPolicyTests.swift
      scenarios:
        - "threshold/豁免 → 只按输入顺序返回符合条件的候选"
    - file: Tests/PeekrTests/AgentWorkspaceTests.swift
      scenarios:
        - "旧版/新版 Agent Workspace → 默认 Profile 分配和所有权行为保持正确"
    - file: Vendor/CefSwift/Tests/CefKitTests/HandlerLogicTests.swift
      scenarios:
        - "已验证 CEF Profile path → default/incognito/persistent 与穿越输入安全"
  verification_commands:
    - "swift build"
    - "swift test"
    - "./scripts/bundle.sh debug"
    - "./scripts/smoke-cef-media.sh build/Peekr.app"
    - "./scripts/smoke-cef-capabilities.sh build/Peekr.app"
    - "./scripts/smoke-cef-permissions.sh build/Peekr.app"
    - "Vendor/CefSwift/Scripts/check-symbols.sh <arm64-framework-binary>"
    - "./scripts/bundle.sh release"
  risks:
    - "WebViewManager/CefSwiftEngine/Workspace 是 CRITICAL 图谱中心，必须增量改动并逐步门禁。"
    - "CEF Profile 路径和 audible-media 检测尚未由真实源码/运行验证完全证明；arm64 smoke 通过前禁止发布。"
    - "当前工作树存在与本计划无关的用户改动；实施前必须重新生成 provenance，不能覆盖它们。"
    - "自定义 Chrome-codec CEF 有许可证和 artifact 信任义务；没有审核证据不得自动 promote。"
  assumptions:
    - "用真实 arm64 context 验证当前嵌套 Profile path；若无效，修改 vendored adapter 和测试。"
    - "确认 pinned CEF 是否提供可靠 audio activity；若没有，unknown audio 必须保持唤醒。"
    - "确认产品的 Profile 安全边界；当前设计隔离存储，但不隔离进程级 CDP 可见性。"
    - "确认有不可变 custom-artifact 来源/签名和足够磁盘/RAM 的 arm64 runner。"
  open_questions:
    - "Profile 绑定是否只允许 Workspace 级别，还是也允许单个标签跨 Profile 移动？"
    - "置顶标签是否意味着 keep-awake，还是必须保留独立开关？"
    - "Profile 创建/重命名/归档由 AppRail、Preferences，还是两者共同负责？"
    - "Renderer 崩溃的恢复次数和 backoff 应采用什么产品参数？"
  avoid:
    - "本次计划任务不得实施、迁移数据、修改源码/测试/CI、构建 CEF 或提交 commit。"
    - "不得覆盖、reset 或清理工作树中与本计划无关的用户改动。"
    - "不得使用展示名作为 Profile 文件系统 key，也不得把 native CEF/AppKit 对象放入 Codable model。"
    - "不得原地复活 closed CEF engine，也不得让旧回调修改新 engine。"
    - "不得增加 x86 CEF artifact，也不得把 vendored nested workflow 当作 Peekr 发布权威。"
    - "没有 digest、bridge-symbol、smoke、许可证和 rollback 证据时，不得自动合并 custom Chrome-codec CEF 更新。"
```

## 12. 假设、开放问题与明确延期

### 实施前需要验证的假设

- [assumed] 现有 `Chromium/Default` 是默认 Profile 的持久数据，可原地保留而不做复制迁移。
- [assumed] 当前 CEF runtime 能在同一进程承载多个持久化 request context；真实 arm64 smoke 是放行条件。
- [assumed] Profile 存储隔离足以满足当前 Chrome 风格需求；本地进程/CDP 隔离是独立安全功能。
- [assumed] pinned CEF 能提供可靠页面音频活动信号，或可以在 wrapper 边界增加；在此之前 unknown audio 不自动休眠。
- [assumed] 有批准的 arm64 build host 和不可变 custom-artifact 来源；否则只能交付 check/review workflow，不能承诺自动产物升级。

### 开放问题

- [assumed] 产品是否只允许 Workspace 级 Profile 绑定，还是也需要标签级移动？
- [assumed] UI 置顶是否等同于 keep-awake？
- [assumed] Profile 删除应归档数据，还是在确认后永久删除目录？
- [assumed] Renderer recovery 的次数/backoff 具体参数是什么？
- [assumed] 专有 codec artifact 接受哪种外部签名/attestation 格式？

### 明确延期

- Chrome Sync、扩展、Widevine、Google 服务、跨设备 Profile 同步和完整 Chrome tab discard 等价实现。
- CDP 按 Profile 授权和远程 Agent 安全隔离。
- Intel/x86 CEF 构建或 universal binary。
- 除非根仓库流程明确需要，否则不重写 vendored CefSwift 的通用 updater。

## 13. 完成定义

- [ ] 存在版本化 Profile registry；旧 v1/v2/legacy 数据无损读取；所有旧/新 Workspace 缺省使用稳定默认 Profile。
- [ ] 两个命名 Profile 可持久化且存储隔离；同一 Profile 的两个标签共享状态；展示名变化不改变 Profile ID；路径穿越被阻止。
- [ ] Workspace Profile 绑定/切换可见、可逆；旧 engine 先关闭，新 context 再创建；Agent Workspace 与 CDP target sync 保持正确。
- [ ] 自动生命周期 sweep 在 MainActor 执行，具备节流、memory/visibility 触发，并保护 active、unknown-audio、keep-awake、automation 页面；手动 sleep/wake 独立可用。
- [ ] 休眠页面保留标签元数据/选择状态，按正确 Profile 和最后 URL 延迟恢复；旧回调不能污染恢复状态。
- [ ] Renderer termination 具备有界自动恢复、终态诊断、显式 Retry 和应用重启恢复。
- [ ] 根 CEF manifest/build/stage/bundle/update workflow 仅支持 arm64，并拒绝错误架构、错误来源、错误摘要、缺失 provenance、缺失 symbol 和未审核许可证/API 变化。
- [ ] Custom Chrome-codec artifact 具备可复现 source/build pins、SHA-1/SHA-256/size、批准来源/attestation、真实 arm64 bundle 验证、回滚说明，且不依赖 vendored nested workflow。
- [ ] `swift build`、`swift test`、Profile/lifecycle/recovery 集成测试、CEF capability/media/permission smoke、bridge symbol audit、debug bundle、release signing/notarization 和 rollback rehearsal 均有通过证据。
- [ ] 本次任务最终只改写计划文档；实现必须在后续执行任务中进行，并先解决开放问题和 P0 门禁。
