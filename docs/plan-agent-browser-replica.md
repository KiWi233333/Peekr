# Peekr Agent 浏览器能力实施计划

状态：实施中（W2 基础闭环已验证，完整对齐未完成）

目标分支：`kiwi/feat/browser-use`  
参考版本：0.5.0.32
参考源码快照：commit `d01be93325c7ea59d41c2ca9f4c59b58b4be4046`

当前执行状态（2026-09-27）：W0 与 W1 基础入口已完成，W2 原生归属与生命周期基础可用。本次继续补齐 8 页预算、异步收尾互斥、页面转移保护、取消清理，以及历史导航、常用表单、文件输入、组合键、严格定位和同源 iframe 引用失效。CLI 43 项、Swift 134 项与真实 CEF 16 组场景通过。完整 frame/session、事件和高级交互仍未完成。见 [基础闭环](agent-browser-progress-2026-09-27.md) 与 [本轮交互和质量验证](agent-browser-progress-2026-09-27-interactions.md)。

本文档定义 Peekr 的 Agent 浏览器能力边界、功能契约、模块拆分、实施顺序和验收方式。目标是吸收可验证的交互和自动化契约，不复制外部二进制；Peekr 使用自己的 CEF/CDP 和 Swift AppModel 提供等价能力。

## 0. 分阶段执行总清单

以下清单是本项目的唯一执行顺序。每个阶段完成后才进入下一阶段；阶段内的子任务按依赖从上到下执行。复刻工作以“先可运行、再扩展覆盖面”为原则，所有完成项都必须留下代码、测试或运行证据。

### W0 — Chromium-only 基线与 WebKit 清理

目标：应用只使用内置 CEF/Chromium，启动、设置、文档和测试中不再存在 WebKit 后端路径。

- [x] **W0.1 盘点入口**：使用 `semble search` 和精确字面量检索收集 `WebKitEngine`、`WKWebView`、`WebEngineKind.system`、`webEngine`、`replaceFactory` 的全部引用，建立清单并标注“代码 / 测试 / 文档 / 历史记录”。
- [x] **W0.2 删除实现**：移除 `Sources/Peekr/Web/WebKitEngine.swift` 及其 `WebKitEngineFactory`，确认 `Package.swift`、打包脚本和资源复制规则没有隐式依赖。
- [x] **W0.3 固化工厂**：`AppDelegate` 启动时始终注入 `CefSwiftEngineFactory`；移除基于环境变量或设置值的后端分支，同时保留 `WebEngineFactory` 作为测试替身注入点。
- [x] **W0.4 收敛设置模型**：删除 `Settings`/`SettingsData` 的 `webEngine` 字段和编码逻辑；旧 JSON 中的未知 `webEngine` 键必须被容错忽略，升级后保存文件不得再写回该键。
- [x] **W0.5 移除设置 UI**：删除 Web Engine Picker、切换确认弹窗、相关 `PreferenceEffect` 分支和本地化字符串；Browser 设置页只保留搜索、Chrome 数据、Agent 接入和书签同步。
- [x] **W0.6 清理注释与文档**：README、README.zh-CN、DESIGN、ROADMAP 和当前功能说明统一改为 Chromium/CEF-only；保留历史发行记录时必须明确其为历史版本，不得暗示当前可切换 WebKit。
- [x] **W0.7 调整测试**：删除引擎切换测试，增加“旧设置可加载且不回写 webEngine”和“启动工厂为 CEF”测试；保留 WebEngine 协议层生命周期测试。
- [x] **W0.8 验收**：`rg` 在 `Sources`、当前文档和测试中不得发现可执行 WebKit 后端引用；`swift test`、Debug 启动、CEF 页面导航、Agent CDP 连接全部通过。

W0 删除残留审计证据（2026-09-14）：

- GitNexus 已重建索引（10,459 nodes、24,838 edges、300 flows）。查询 `Show → CefSwiftBrowserHostView` 的链路为 `PanelController.show → WebViewManager.activate → CefSwiftEngineFactory.makeEngine → CefSwiftBrowserHostView`；未发现 `WebKitEngine` 符号。
- `WebEngine` 当前只有生产实现 `CefSwiftEngine` 和测试替身 `FakeEngine`；没有 WebKit 实现或 WebKit 工厂。
- 文件名、Swift import 和当前源码/文档扫描均无 `WebKitEngine`、`WKWebView`、`WebEngineKind`、`replaceFactory` 残留。扫描到的 `WebKit` 文本仅是历史版本说明、旧设置迁移测试数据和 Chromium 标准 User-Agent 标识，不构成运行时后端支持。

### W1 — CLI 启动器与公开 API 契约

目标：建立一致的命令行入口、脚本执行语义和可生成帮助。

- [x] **W1.1 命令解析骨架**：已接入 `--help`、`--version`、`help [topic]`、`onboarding`、`import list`、`import --browser`、`upgrade`、`nodejs` 的确定性路由；真实导入和自更新后端分别留给 W2/W6。
- [x] **W1.2 stdin/heredoc**：支持 `peekr < script.js` 与 `peekr nodejs -e '...'`，保证脚本只执行一次，空输入和非法参数有稳定退出码。
- [x] **W1.3 SDK 注入**：实现 `peekr` namespace、顶层 helpers 与 `兼容 namespace` 兼容别名，三者共享同一个运行时状态。
- [x] **W1.4a schema 驱动运行时**：`public-api-schema.ts` 统一提供 API help、公开方法描述和声明式 options 校验；`peekr`、`兼容 namespace` 与注入的顶层函数均经过同一校验代理。
- [ ] **W1.4b 类型生成**：从 schema 生成完整的 TypeScript API 类型，禁止 CLI 与运行时各自维护方法列表。
- [x] **W1.5a 输出基础**：脚本 stdout 采用 round 缓冲并在成功后统一 flush；脚本错误写入 stderr，退出码固定，成功输出与错误输出分流。
- [x] **W1.5b 输出格式基础**：支持默认人类可读输出与 `nodejs --json` 机器可读输出；SIGINT 返回 130 并输出结构化中断错误。
- [ ] **W1.5c 多轮输出**：补齐跨 round 输出上下文和取消后的异步任务清理/最终 flush 规则。
- [ ] **W1.6 验收**：CLI 单元测试覆盖参数矩阵、stdin、语法错误、异步异常、SIGINT 和多轮输出；安装后的 `peekr doctor` 能发现并连接本机 Peekr。

W1 当前证据：`cli/test/cli-entry.test.mjs`、`cli/test/page-ledger.test.mjs` 与既有单元测试合计 22 项通过；`npm run typecheck` 通过。`import --browser chrome` 当前明确返回 `PEEKR_IMPORT_REQUIRES_DESKTOP`，`upgrade` 当前明确返回 `PEEKR_UPGRADE_NOT_CONFIGURED`，避免把占位命令误报为已具备后端能力。

### W2 — 原生桥接、TaskSpace 与 Page 身份

目标：把 Peekr 的 AppModel/CEF 页面映射为可复用的任务空间和稳定 Page 引用。

- [x] **W2.1a CDP 基础传输**：已有端口发现、Bearer token 注入、HTTP target 列表、Node WebSocket、单请求超时和统一 `PeekrError` 映射。
- [ ] **W2.1b CDP 可靠性**：补齐断线检测、socket 重建、in-flight 请求取消/重放边界和 protocol error 结构化字段。
- [x] **W2.2a 空间控制基础**：已有 `/spaces`、create、claim、handoff、takeover、complete、DELETE 与 ownership guard；CLI 已使用 discovery token 调用。
- [x] **W2.2b 原生 tab 控制**：控制桥接列举、创建、关闭、激活原生缓存 tab；只有显式创建并绑定的 target 属于 agent，用户 tab 不自动归属。
- [x] **W2.3a Page ledger 持久化**：`cli/src/page-ledger.ts` 以 discovery 同目录 `page-ledger.json` 保存 `spaceId + label + targetId + url/title`，采用 0600 临时文件和原子 rename。
- [x] **W2.3b target 对账接入**：选中 TaskSpace 后 `listTabs` 返回稳定 `label`；新建/复用 tab 支持显式 label 或自动 `pN`，关闭 tab 会解除映射，live target 对账可识别 stale 条目。
- [ ] **W2.3c 完整 Page 身份**：补齐 page ID、frame/OOPIF session、用户 tab ID、target 重建迁移和永久关闭 label，禁止 stale target 被错误复用。
- [x] **W2.4a TaskSpace 生命周期基础**：实现 create/list/claim/use/handOff/takeOver/complete，ownership 变化会刷新本地 selected space。
- [ ] **W2.4b 生命周期边界**：增加 `markError`、空间关闭时 ledger 清理、用户 tab 保留策略和 agent tab budget。
- [ ] **W2.5 并发模型**：对同一 Page 的命令按 ID 顺序结算；事件、chunk、下载和工具调用禁止使用 latest-wins 覆盖。
- [x] **W2.6 验收**：跨进程轮次锁使第二进程明确返回 busy；SIGKILL 后可回收锁；真实 Peekr 重启后旧 label 明确返回 stale，禁止猜测迁移 target。

W2 当前证据（2026-09-27）：CLI 43 项测试、Swift 129 项 XCTest 与 5 项 Swift Testing 通过，真实 CEF 的 16 组场景通过。W2.1b 已有断线拒绝 pending 请求/事件、protocol error 原字段和禁止写操作重放，但无同轮自动重连；W2.3c 已有 generation、关闭 label 墓碑与跨轮 refs，仍缺 frame/session 及 target 迁移。W2.4b 已有 finish 清理、保留策略、8 页预算及收尾互斥，仍缺 markError。W2.5 当前按整个浏览器轮次和完整 helper FIFO 串行，事件/chunk/download 尚未完成。详见本轮验证记录。

### W3 — 导航、等待与可观察性

目标：先实现 agent 能稳定“看见页面并等待页面就绪”。

增量状态：goto/reload/goBack/goForward/stop、基本条件等待与同源 frame 文档失效已实现；networkidle、完整事件和跨域 frame 仍缺失，下列整项保持未完成。

- [ ] **W3.1 导航**：实现 `goto`、`reload`、`goBack`、`goForward`、`stop`，统一 URL、title、loading、HTTP 和 frame 状态。
- [ ] **W3.2 等待**：实现 waitForSelector、waitForURL、load/domcontentloaded/networkidle、超时和取消；等待条件必须绑定当前 navigation epoch。
- [ ] **W3.3 Snapshot**：实现 accessibility tree、文本 snapshot、raw snapshot、ref 分配、frame/OOPIF 合并和大小压缩。
- [ ] **W3.4 页面事件**：实现 console、dialog、popup、download、filechooser、request/response 的订阅与一次性等待。
- [ ] **W3.5 验收**：对 SPA、跨域 iframe、重定向、弹窗、慢网和导航竞态建立固定回归页面；输出包含可复现的 page/ref 信息。

### W4 — Locator 与交互动作

目标：覆盖 参考基线的主要元素定位与用户动作，保证动作前可解释、失败后可诊断。

增量状态：严格单元素匹配、派发前可操作性检查、组合键、clear/check/selectOption/setInputFiles 已验证；完整定位器、自动等待、拖拽及 chooser/download 仍缺失，下列整项保持未完成。

- [ ] **W4.1 locator**：支持 ref、role/name、text、label、placeholder、alt、title、CSS、XPath、href、test id、shadow DOM。
- [ ] **W4.2 actionability**：统一 visible/enabled/editable/stable/receives-events 检查、自动滚动、strict mode 和重试策略。
- [ ] **W4.3 pointer**：实现 click、dblclick、hover、dragAndDrop、wheel、坐标点击和按钮/modifier 组合。
- [ ] **W4.4 keyboard**：实现 press、type、insertText、focus、macOS 快捷键、组合键和剪贴板读写。
- [ ] **W4.5 表单与文件**：实现 fill、clear、check/uncheck、selectOption、setInputFiles、FileChooser 与 Download。
- [ ] **W4.6 验收**：每种定位器至少有成功、零结果、多结果、隐藏元素、跨 frame 和 stale ref 用例；动作失败必须返回稳定错误码与建议。

### W5 — evaluate/CDP/fetch 与站点能力

目标：开放受控的高级能力，并与安全、超时和输出限制绑定。

- [ ] **W5.1 evaluate/js**：实现 page.evaluate、序列化异常、Promise 结果、函数参数和执行上下文选择。
- [ ] **W5.2 CDP**：实现 page.cdp、session attach/detach、浏览器级命令和 frame target 路由。
- [ ] **W5.3 网络请求**：实现 page.fetch、serverFetch、browserFetch，区分页面 cookie、服务端凭据和跨域策略。
- [ ] **W5.4 截图与导出**：实现 viewport/fullPage/element screenshot、质量/格式限制、路径安全和大文件输出引用。
- [ ] **W5.5 安全边界**：限制本地文件、调试端口、任意 CDP 方法和脚本执行；记录调用来源、目标 Page 和耗时。
- [ ] **W5.6 验收**：安全测试覆盖路径穿越、非 localhost 连接、未授权 target、脚本超时、响应体上限和敏感 header 泄漏。

### W6 — Skill、安装、升级与发布

目标：让复刻能力可以被 Agent 发现、安装、升级和持续维护。

- [ ] **W6.1 Skill 目录**：建立 `skills/peekr-cli/`，参考成熟 harness 的阅读结构（SKILL、references、scripts、learnings），内容改为 Peekr 契约。
- [ ] **W6.2 安装脚本**：实现 Node 版本检测、CLI 安装/升级、PATH 选择、幂等执行、失败回滚和卸载提示。
- [ ] **W6.3 资源打包**：构建时复制 CLI、Skill、schema 和版本清单；禁止将本机 `.reference` 或调试 token 带入发布包。
- [ ] **W6.4 诊断与迁移**：`peekr doctor` 检查 CEF runtime、调试端口、发现文件、Node 和权限；旧 WebKit 设置迁移到 Chromium-only schema。
- [ ] **W6.5 发布验收**：在干净 macOS 用户目录验证首次启动、升级、卸载、权限拒绝、CEF 崩溃恢复和跨版本 ledger 迁移。

### W7 — 兼容性收口与持续回归

目标：把参考基线转化为可长期维护的兼容矩阵。

- [ ] **W7.1 API 矩阵**：为每个公开方法记录支持级别（完全、部分、明确不支持）和对应测试。
- [ ] **W7.2 运行时矩阵**：覆盖 macOS 版本、Apple Silicon、CEF 版本、Node 版本、代理/无代理网络和多显示器。
- [ ] **W7.3 性能基线**：记录启动、首个 target、snapshot、动作、下载和并发空间的 P50/P95，设回归阈值。
- [ ] **W7.4 故障演练**：模拟 CEF 子进程退出、CDP 断线、页面崩溃、磁盘只读、升级中断和重复 claim。
- [ ] **W7.5 变更门禁**：代码提交前运行 GitNexus `detect_changes()`、单元测试、CLI 测试、`git diff --check` 和文档链接检查。

## 1. 参考基准与结论

### 1.1 本地参考资料

参考资料保存在本机忽略目录中，不进入仓库提交。只记录经过核验、且对 Peekr 自己的契约有帮助的行为，不在规范文档中保留外部产品、仓库或安装路径名称。

本地 CLI 以独立进程启动 Node 脚本，并向脚本注入兼容 namespace 和 helpers。已核验的原生入口包括：

```text
createTab                 listTabs
listTaskSpaces            createTaskSpace
claimTaskSpace            closeTaskSpace
useTaskSpace              handOffTaskSpace
takeOverTaskSpace         completeTaskSpace
markTaskSpaceError        setAgentTaskState
getBrowserVersion         sendCDPMessage
```

公开 helpers 还包括：

```text
taskSpace / useOrCreateTaskSpace / listTaskSpaces / profiles
Page.goto / reload / snapshot / screenshot / evaluate / fetch
Page.click / dblclick / hover / dragAndDrop / fill / selectOption
Page.focus / press / setInputFiles / waitForSelector / waitForURL
Page.mouse / Page.keyboard / waitForEvent / FileChooser / Download
snapshotText / snapshotRaw / cdp / js / serverFetch / browserFetch
siteSkills / siteSkillsForUrl / runSiteTool / runSiteBrowserTool
learnContext / cliLog / help
```

### 1.2 harness 的分层

参考 harness 的职责边界如下；下表只保留能力类别和 Peekr 自己的落点：

| 层 | 参考能力 | Peekr 目标 |
|---|---|---|
| CLI 启动 | `run.ts`, `index.ts` | `cli/src/run.ts`, `cli/src/index.ts` |
| 原生桥接 | `browser-runtime.ts` | `cli/src/cdp.ts` + Swift Agent bridge |
| 公开契约 | `public-api-schema.ts` | 新增同名 Schema，作为唯一 API 真相源 |
| TaskSpace/Page | `page-model.ts` | `cli/src/page-model.ts` |
| Page 身份 | `page-ledger.ts`, `page-ref-registry.ts` | `cli/src/page-ledger.ts`, `cli/src/page-ref-registry.ts` |
| 元素解析 | `element-resolver.ts` | 扩展现有 `cli/src/driver/locator.ts` |
| 驱动 | `driver/*` | 现有 drivers 迁移到 Page 上下文 |
| 输出与错误 | `output-sink.ts`, `error-contract.ts` | 现有 `errors.ts` 增加 round sink 和 hard-stop |
| Skill | Skill、references、scripts、learnings | `skills/peekr-cli/`，保持目录和阅读流程一致 |

### 1.3 按功能的核对入口

下表是实施时的第一跳位置；每项都需要在 Peekr 中建立自己的 parity 测试。

| 功能 | Peekr 目标模块 | 主要函数/类型 |
|---|---|---|
| CLI 输入与执行 | `cli/src/run.ts`, `cli/src/index.ts` | `runMain`, `execute`, `executionContext` |
| SDK 注入与宿主适配 | `cli/src/index.ts` | `installPeekrSdk`, `disposePeekrSdk`, `wrapUseTaskSpace` |
| helper 聚合 | `cli/src/helpers.ts` | `helperContext`, `taskSpace`, `useOrCreateTaskSpace`, `profiles` |
| API schema/help | `cli/src/public-api-schema.ts`, `cli/src/help-runtime.ts` | 公开方法、参数校验和 `help()` |
| Space/Page 生命周期 | `cli/src/page-model.ts` | `TaskSpace`, `Page`, `Download`, `FileChooser` |
| Page 持久身份 | `cli/src/page-ledger.ts`, `cli/src/page-ref-registry.ts` | `PageLedgerStore`, `PageRefRegistry` |
| CDP/session/events | `cli/src/browser-runtime.ts` | `browserCdp`, `ensureSession`, `ensureFrameSessions` |
| 导航和等待 | `cli/src/driver/nav.ts`, `cli/src/driver/page-waits.ts` | goto/reload、URL/selector/load/network idle |
| Snapshot | `cli/src/driver/observe.ts`, `cli/src/snapshot-result.ts` | `snapshot`, `snapshotText`、压缩、frame/ref 修复 |
| 元素解析 | `cli/src/element-resolver.ts` | ref、role、CSS、href、XPath、shadow DOM、actionability |
| 鼠标动作 | `cli/src/driver/page-actions.ts`, `cli/src/driver/pointer.ts` | click、hover、drag、wheel、自动滚动 |
| 键盘和剪贴板 | `cli/src/driver/page-keyboard.ts`, `cli/src/clipboard.ts` | press/type/insertText/paste、macOS 编辑命令 |
| 文件与下载 | `cli/src/driver/files.ts`, `cli/src/driver/downloads.ts` | chooser、setInputFiles、download 生命周期 |
| JS/CDP/fetch | `cli/src/cdp-eval.ts`, `cli/src/http.ts` | `evaluate`, `js`, `cdp`, `page.fetch`, `serverFetch` |
| 错误和输出 | `cli/src/error-contract.ts`, `cli/src/output-sink.ts` | 错误码、hard-stop、buffer/flush |
| 站点知识 | `cli/src/learning/` | site manifest、notes、tools、runtime loader |
| 安装与打包 | `scripts/build.mjs`, `scripts/install.sh` | 单文件构建、Skill 复制、PATH/App 安装 |

### 1.4 不能直接复用的部分

1. 外部内核生成的原生 snapshot 不能从 App bundle 中还原成源码。
2. 外部实现的 `sendCDPMessage`、窗口/任务空间原生绑定不能直接复用。
3. 外部实现的内嵌 Node helper 属于其发行版；Peekr 第一版可要求 Node ≥22，同时保留未来替换为 App 内嵌 Node helper 的接口。
4. 外部实现的站点 learnings 内容不能整包复制；只能吸收 manifest、工具协议和目录结构，内容由 Peekr 自己验证后产生。

## 2. 总体兼容目标

### 2.1 CLI 兼容

以下命令和退出语义是第一优先级：

```text
peekr --help
peekr --version
peekr help [topic]
peekr onboarding
peekr import list
peekr import --browser <browser> [--profile <name> ...]
peekr upgrade
peekr nodejs -e <script>
peekr nodejs < script.js
peekr < script.js                 # 兼容参考行为的直接 stdin 模式
```

当前 `peekr nodejs` 入口保留，但最终 `peekr` 直接接收 heredoc 也必须工作。脚本输入只能执行一次，执行结束后统一 flush 输出；空输入、参数错误和脚本语法错误有确定退出码。

### 2.2 运行时兼容

脚本中同时支持两种入口：

```js
const task = await taskSpace("research");
const page = task.page("p1");

// Peekr 原生名称
const same = await peekr.taskSpace("research");

// 兼容 namespace
const legacy = await globalThis.legacy.taskSpace("research");
```

实现上采用三层：

1. `peekr`：Peekr 的正式 namespace。
2. 顶层 helpers：方便 heredoc，名称与参考行为保持一致。
3. `legacy`：只做兼容别名，不拥有第二份状态或实现。

### 2.3 任务空间兼容

一个用户目标只能创建一个 TaskSpace；后续 round 根据相同名称或数字 ID 复用它。新空间默认创建 `p1`，后续 Page 使用稳定标签。用户创建的、未托管的 tab 不能被 `finish({ keep: [] })` 关闭。

ownership 必须保持三态：

| 状态 | 含义 | Agent 行为 |
|---|---|---|
| `user` | 用户控制 | 浏览器动作 hard-stop；不能自行 claim |
| `agent` | Agent 控制 | 可执行全部操作 |
| `agentDelegatedToUser` | Agent 所有，但临时交给用户 | 等用户确认后 takeover，不能绕过用户 |

`finish({ keep })` 必须只调用一次，并且在完成后清理 ledger、事件订阅和 Agent 创建的页面。

## 3. 完整功能剖析与实现计划

### 3.1 CLI 启动、脚本执行和 SDK 注入

**参考行为**

- `nodejs` 子命令把 stdin 或 `-e` 内容包装进 async 函数。
- helpers 同时作为函数参数和 global 属性存在。
- `console` 被 round console 替代，避免用户日志绕过输出收集。
- 每轮结束统一处理输出；hard-stop 会丢弃前置业务输出。
- SDK 被宿主嵌入时，`installPeekrSdk()` 和直接 CLI 必须暴露同一 helper surface。
- `help()` 从 JSDoc/API Schema 生成，而不是单独维护一份手写列表。

**Peekr 实现**

- 新增 `cli/src/run.ts`，统一 `stdinText`, `stdin`, `argv`, `stdout`, `stderr` 测试注入。
- `cli/src/index.ts` 只负责命令路由；脚本执行逻辑不放在命令分支中。
- 新增 `cli/src/public-api-schema.ts` 和 `cli/src/help-runtime.ts`。
- 增加 `installPeekrSdk(target, options)`，为 App 内嵌 Node 或未来其他宿主复用。
- 为 `globalThis.peekr` 和 `globalThis.legacy` 安装同一批函数引用。
- 支持 `--sdk-path`，允许真实 E2E 使用当前 checkout 的 SDK。

**验收**

- 直接 stdin、`nodejs` stdin、`-e` 三种输入执行同一脚本，输出一致。
- `console.log`、`cliLog`、异常、hard-stop 的输出顺序稳定。
- `help()`、Skill、生成的 API 文档和 Schema 差异检查全通过。

### 3.2 原生发现、连接和生命周期

**参考行为**

- CLI 不扫描端口，读取 App 写出的发现信息。
- 原生绑定提供 CDP 传输、浏览器版本、Space 操作和状态事件。
- App 未启动、Agent access 关闭、端口陈旧、宿主断开时返回稳定错误。

**Peekr 当前基础**

- [AgentDiscovery.swift](/Users/yunge/Projects/self/Peekr/Sources/Peekr/Util/AgentDiscovery.swift) 已写入 `agent.json`。
- [AgentControlServer.swift](/Users/yunge/Projects/self/Peekr/Sources/Peekr/Agent/AgentControlServer.swift) 已提供 loopback HTTP。
- `cli/src/discovery.ts`、`cli/src/cdp.ts` 已能读取发现文件并连接 CEF。

**目标数据契约**

```json
{
  "schemaVersion": 2,
  "port": 9223,
  "controlPort": 49321,
  "token": "rotated-per-launch",
  "pid": 12345,
  "browserInstanceId": "browser-host:12345"
}
```

要求：两个端口均绑定 `127.0.0.1`；`agent.json` 只在 Agent access 开启且服务正在监听时存在；token 每次启动轮换；CLI 不打印 token 以外的敏感数据。

### 3.3 TaskSpace、Workspace 和 ownership

**参考行为**

- `taskSpace(nameOrId)`：优先复用 Agent-owned 空间，否则创建。
- `useOrCreateTaskSpace`：字符串按名称复用，数字按 ID 精确查找。
- `claimTaskSpace`：用户明确要求后转移 ownership。
- `handOffTaskSpace`：把控制权交给用户，但空间仍由 Agent 创建和持有。
- `takeOverTaskSpace`：用户确认后恢复 Agent 控制。
- `waitForControl`：只读等待，不主动抢占。
- `completeTaskSpace({ keep })`：keep 为 false 时关闭 Agent 空间，为 true 时交给用户继续查看。
- 用户接管、空间 inactive、空间不存在时不能重试或创建替代空间。

**Peekr 实现**

- Swift `Workspace` 继续使用内部 UUID。
- 对外增加稳定数字 `spaceId`，持久化 UUID ↔ 数字 ID 映射；CLI 不暴露 UUID 作为主要 locator。
- `AgentControlServer` 增加 `/spaces/:id/claim`、`/resume`、`/handoff`、`/takeover`、`/complete` 的完整语义。
- `cli/src/page-model.ts` 负责对象生命周期，`cli/src/driver/spaces.ts` 只负责控制 API 和 descriptor 解析。
- 所有 page action 在真正发 CDP 前重新确认 ownership；缓存只能降低读取次数，不能成为安全边界。

**验收**

- 同名空间不会无故重复创建；数字 ID 不会因重启改变。
- rail 徽标、Swift ownership 和 CLI descriptor 立即同步。
- 用户接管后 click、fill、evaluate、cdp、截图、下载全部返回同一个 hard-stop code。

### 3.4 Page ledger、tab 发现和 Page 生命周期

**参考行为**

- Page 标签 (`p1`, `p2`) 跨 Node round 持久化。
- ledger 记录 `targetId`、来源 (`agent`/`unknown`)、refs、已关闭和已释放标签。
- 自动发现 popup、download、iframe 子 target；用户 tab 只记录为 unmanaged。
- `adopt()` 托管已有 tab，`release()` 释放但不关闭。
- 每个 Space 有 Page budget；超过预算返回可操作错误。
- ledger 使用临时文件 + 原子 rename，避免崩溃留下半份 JSON。

**Peekr 实现**

- 新增 `cli/src/page-ledger.ts`，默认目录 `~/.peekr/state`，支持环境变量覆盖。
- ledger 加入 `browserInstanceId`，拒绝复用其他 Peekr 实例的陈旧 target。
- target 断开时 reconcile；新 target 根据 opener 归属推断 Agent 或 unknown。
- Page 的 `close()` 只关闭 Agent-created page；unknown page 必须显式 adopt 后才可关闭。
- `finish()` 先校验完整 keep 列表，再执行任何关闭动作，避免半完成状态。

### 3.5 CDP transport、session、事件和 dialog

**参考行为**

- 浏览器级命令走 Browser socket；页面命令走 Page socket。
- session 丢失时区分页面主 session、iframe session 和浏览器断开。
- 事件有上限，支持 drain 和按 Page 订阅。
- Dialog、文件选择器和下载必须先 arm，再执行触发动作。
- 原生事件回调失败不能变成未处理 Promise rejection。

**Peekr 实现**

- 保留现有 `TargetSocket` / `BrowserSocket`，扩展成 `BrowserRuntime`。
- 保持 CEF flattened session 不可用时的每 target socket 策略。
- 增加 session cache、session invalidation、frame session tree、event buffer 上限和 reconnect。
- `Target.setDiscoverTargets`、`Target.targetCreated`、`Target.targetDestroyed` 负责 popup/OOPIF 发现。
- 为每个 Page 保存 network activity、pending dialog、pending file chooser、pending download。

**验收**

- 主页面 reload、iframe reload、CEF target close 分别返回不同错误分类。
- 事件缓冲不会无限增长；`page.events()` 读取后清空。
- dialog 出现时普通操作停止，并提供 `acceptDialog` / `dismissDialog`。

### 3.6 Navigation 和等待

**公开方法**

```text
Page.goto(url, { referer, timeout, waitUntil })
Page.reload({ timeout, waitUntil })
Page.waitForURL(matcher, { timeout })
Page.waitForLoadState(state, { timeout, idleMs })
Page.waitForSelector(selector, { state, timeout })
Page.waitForFunction(fn, argument, { polling, timeout })
Page.waitForTimeout(timeout)
```

**行为要求**

- `waitUntil` 支持 `commit`、`domcontentloaded`、`load`、`networkidle`。
- timeout 错误携带是否已 commit、当前 URL、readyState。
- URL matcher 支持精确字符串、glob、RegExp、同步 predicate。
- selector 等待只对 transient resolution error 重试；不能吞掉用户接管或 session 终止。
- `waitForTimeout` 只能作为明确的固定等待，不替代可观察条件。

### 3.7 Snapshot、AX tree、OOPIF 和引用

**参考行为**

- `page.snapshot()` 返回结构化 `{ content, refs }`。
- 默认 viewport；可选 `full_page` 和 iframe `subtree`。
- refs 绑定 backend node identity；内容变化后旧 ref 失效。
- 每个可交互节点带 `@N`，并尽量提供 stable locator。
- action marks 可在截图或页面上显示当前操作。

**Peekr 实现路线**

1. 主 target 调用 `Accessibility.getFullAXTree`。
2. 使用 `DOMSnapshot.captureSnapshot` 补充可见性、坐标、属性和 DOM backendNodeId。
3. 通过 Target/frame inventory 递归发现同域 frame 和跨域 OOPIF。
4. 将每个 frame 归并成 `[iframe src=...]` 节点；单 frame 失败只输出 unavailable 占位。
5. `snapshot-result.ts` 负责裁剪、压缩、ref 重写和 locator 校验。

**文本格式**

```text
Page: Example Domain
URL: https://example.com/

  heading "Example Domain"
  paragraph "This domain is for use in illustrative examples..."
  @12 [link] "More information" [loc=role:link[name='More information']] [url=https://iana.org/domains/example]
```

**定位规则**

1. ref：`@N` / `ref=N`，只对最近一次 snapshot 有效。
2. role/name：`loc=role:button[name='Save']`。
3. 稳定属性：`css:#id`、`css:[data-testid='x']`、`css:[name='email']`。
4. 链接：`loc=href:https://...`。
5. 显式 `xpath=` 和原始 CSS 作为 escape hatch。

所有 selector 必须唯一；多个 actionable match 返回候选诊断，不静默选择第一个。

### 3.8 元素解析、actionability 和输入动作

**元素解析**

- 支持顶层 document、开放 Shadow DOM、同域 iframe 和 OOPIF frame。
- 解析后检查 attached、visible、enabled、pointer-events、covered、moving。
- 元素状态失败归类为 transient；selector 不存在、ref 过期、多个匹配归类为 permanent。
- 自动滚动只发生在 action 即将执行时；不要求 Agent 先手动滚动。

**Page actions**

```text
click(selector, { button, clickCount, delay, position, force, timeout, label })
dblclick(selector, options)
hover(selector, options)
dragAndDrop(source, target, options)
fill(selector, value, { clearFirst, timeout })
selectOption(selector, value, { timeout })
focus(selector, { timeout })
press(selector, chord, { delay, timeout })
```

动作必须优先使用真实 CDP Input 事件，不能用 `element.click()` 代替真实输入。`label` 用于同步原生鼠标高亮和 Agent 可见操作说明。

### 3.9 Mouse、Keyboard、Clipboard 和文件

**鼠标**

- `mouse.click/move/down/up/wheel` 使用 CSS pixel 坐标。
- 支持 left/middle/right、clickCount、steps、label。
- wheel 在当前鼠标位置执行，避免滚动错误容器。

**键盘**

- 支持浏览器自动化风格 chord 和 `ControlOrMeta`。
- 区分 `press`、`type`、`insertText`、`paste`。
- macOS 编辑命令映射到原生 Meta 组合键。
- 输入后验证 value/input/change 事件；无法确认时返回诊断。

**剪贴板**

- 纯文本和 `{ text, html }` 富文本粘贴。
- 临时修改系统剪贴板后必须恢复；恢复失败需要显式错误。
- 不把剪贴板内容写入日志。

**文件**

- `setInputFiles` 接受绝对路径，拒绝相对路径。
- 动态 chooser 必须先 `waitForFileChooser()` 再 click。
- Download 必须先 `waitForEvent('download')`，用 `saveAs()` 在 round 结束前保存。

### 3.10 `evaluate`、CDP、Fetch 和截图

**evaluate**

- 回调运行在 Page 内，不捕获 Node 变量，只接受 JSON 参数。
- 非 JSON 值通过明确的 unserializable 编码处理。
- 超时报告 `executionStopped`、`pageResponsive`、`mayHaveLateEffects`。
- 发生 late effect 时禁止盲目重复，先 reload 或关闭 Page。

**CDP**

- `Page.cdp()` 只允许当前 Page session 的 Page/Runtime/DOM/Input/Network 等命令。
- `TaskSpace.cdp()` 只允许 Target/Browser 域命令。
- 原始 CDP 可能使 refs 失效；每次使用后要求重新 snapshot。

**Fetch**

- `page.fetch()` 在页面上下文执行，遵守 cookies、CORS、service worker。
- `serverFetch()` 使用 Node fetch，不带页面 cookie。
- 支持 method、headers、body、credentials、redirect、timeout、saveAs。

**截图**

- `page.screenshot({ path, fullPage, clip, scale, raw })`。
- 默认 CSS pixel 输出并校正 devicePixelRatio。
- viewport 截图使用当前 scroll offset，fullPage 从 document origin 开始。
- 截图默认保存绝对路径，自动创建父目录。

### 3.11 Site learnings 和工具包

**参考 harness 结构**

```text
skills/agent-browser-harness/learnings/<site>/
  manifest.json
  notes/*.md
  tools/*.js
  browser-tools/*.js
```

**Peekr 计划**

- 复刻 `siteSkills()`、`siteSkillsForUrl()`、`learnContext()`、`runSiteTool()`、`runSiteBrowserTool()`。
- manifest 只声明站点匹配规则、工具名和输入 schema。
- notes 只保存可重复的站点行为，不保存凭据、用户数据或一次性任务历史。
- 增加 `validate-site-skills` 检查域名、工具导出、参数 schema 和安全路径。
- 先迁移三个测试站点：静态表单、GitHub-like 列表、跨域 iframe 页面。

### 3.12 错误、输出和 hard-stop

**稳定错误码**

```text
PEEKR_AGENT_ACCESS_DISABLED
PEEKR_CDP_UNAVAILABLE
PEEKR_CDP_SEND_FAILED
PEEKR_SPACE_NOT_FOUND
PEEKR_SPACE_INACTIVE
PEEKR_SPACE_USER_IN_CONTROL
PEEKR_SPACE_NOT_SELECTED
PEEKR_UNKNOWN_REF
PEEKR_SELECTOR_NOT_FOUND
PEEKR_SELECTOR_AMBIGUOUS
PEEKR_ACTION_FAILED
PEEKR_PAGE_BUDGET_REACHED
PEEKR_DIALOG_OPEN
PEEKR_DOWNLOAD_FAILED
PEEKR_INSTALL_USAGE
```

**hard-stop 规则**

- `SPACE_USER_IN_CONTROL`、`SPACE_INACTIVE` 和 Agent access 关闭属于停止信号。
- 错误对象保留稳定 `code`，文案可演进。
- 第一次 hard-stop 写入 round sink；即便脚本 catch 后继续调用，也只输出一次恢复指引。
- hard-stop 丢弃之前的业务输出，避免 Agent 把半成品当作成功结果。
- 普通 selector、网络和超时错误可以按分类决定是否重试。

### 3.13 安装、Skill 分发和 App onboarding

**参考行为**

- Skill 包跟随 App 发行。
- 安装脚本定位运行中的 App、`/Applications` 或 `~/Applications`。
- 注册 CLI 到 `~/.local/bin`，必要时提示 PATH。
- 安装后运行 doctor 验证发现文件和 CDP。

**Peekr 计划**

- 将 `cli/dist/peekr.js` 和 `skills/peekr-cli/**` 打入 `Contents/Resources/peekr-cli/`。
- `peekr install --target claude|codex|all --scope user|project --no-path` 统一处理 CLI 和 Skill。
- `install.sh` 只做 App 定位和转交，不复制第二份业务逻辑。
- Preferences 的 Agent Access 区展示发现文件路径、运行状态、安装命令和重启提示。
- 安装成功后输出 JSON summary；Agent access 未开启时安装仍成功，但 `agentAccess.ok=false`。

## 4. 目标目录结构

```text
cli/src/
  index.ts
  run.ts
  state.ts
  public-api-schema.ts
  help-runtime.ts
  output-sink.ts
  errors.ts
  discovery.ts
  cdp.ts
  browser-runtime.ts
  native-gate.ts
  page-model.ts
  page-ledger.ts
  page-ref-registry.ts
  ref-map.ts
  driver/
    nav.ts
    observe.ts
    snapshot-result.ts
    element-resolver.ts
    pointer.ts
    keyboard.ts
    page-actions.ts
    waits.ts
    files.ts
    downloads.ts
    eval.ts
    frames.ts
  learning/
    index.ts
    validate.ts

skills/peekr-cli/
  SKILL.md
  references/api.md
  references/install.md
  references/clearing-state.md
  scripts/install.sh
  learnings/<site>/...
```

Swift 侧保持职责收敛：

```text
Sources/Peekr/Agent/AgentControlServer.swift  # Space/ownership HTTP API
Sources/Peekr/Agent/AgentTargetSync.swift     # CDP target ↔ rail/tab 同步
Sources/Peekr/Util/AgentDiscovery.swift       # agent.json
Sources/Peekr/Model/Workspace.swift           # 持久 ownership 和外部 spaceId
Sources/Peekr/App/AppModel.swift              # 状态转移和 UI 真相源
Sources/Peekr/Web/CefSwiftEngine.swift        # CEF/CDP 生命周期
```

## 5. 实施波次与交付物

### W0：基准冻结和兼容清单

- 提交 `兼容接口清单.json`、本机版本、源码 commit 和 Skill 目录清单。
- 生成 API parity 表，逐项标记 `same`、`adapted`、`unsupported`。
- 添加 `cli/NOTICE`，记录 MIT 来源和未复制的闭源边界。

### W1：CLI/SDK 壳

- 完成 `run.ts`、`installPeekrSdk`、`public-api-schema.ts`、`help-runtime.ts`。
- `peekr`、`peekr nodejs`、`-e`、直接 stdin 全部工作。
- 将当前 helpers 保持为兼容层，禁止新增第二份状态。

### W2：TaskSpace/Page 模型

- 实现数字 `spaceId` 映射、TaskSpace/Page 类、page ledger、Page budget。
- 把现有 `spaces.ts` 控制 API 适配到对象模型。
- 将 `openOrReuseTab`、`listTabs`、`switchTab` 迁移为 Page 方法和 legacy wrappers。

### W3：Browser runtime 和驱动迁移

- 统一 CDP session、frame、事件、dialog、download 和 chooser。
- 迁移 nav、waits、observe、pointer、keyboard、eval 到 `withPage()`。
- 先保证主 frame，再收敛 iframe/OOPIF。

### W4：Snapshot/locator parity

- 实现 AX + DOMSnapshot 双源 snapshot。
- 完成 ref registry、稳定 locator、shadow DOM、跨域 iframe 占位和 subtree。
- 用固定基准页建立 token 数量、节点覆盖率、唯一定位成功率报告。

### W5：Skill、learnings 和安装

- 重写 `SKILL.md` 为 参考实现同等级的首轮可执行文档。
- 补齐 API/install/clearing-state references。
- 完成 `peekr install`、App bundle 资源复制、Preferences onboarding。
- 引入 site learning validator。

### W6：真实浏览器验收和发布

- CEF 隔离实例 E2E。
- Swift/CLI 双端完整测试。
- codesign、bundle resource、版本 metadata、安装升级和回滚验证。
- 输出最终 parity 报告和已知差异清单。

## 6. 验收矩阵

| 类别 | 必须验证 |
|---|---|
| CLI | help/version、stdin、`-e`、空输入、语法错误、退出码 |
| SDK | `peekr`、顶层 helpers、`参考实现` 别名引用同一状态 |
| Space | 复用、创建、数字 ID、claim、handoff、takeover、finish |
| ownership | user/agent/delegated 三态、hard-stop、rail 同步 |
| Page | p1、popup、adopt/release、关闭保护、ledger 原子写入 |
| CDP | 主 target、iframe/OOPIF、重连、事件、dialog、download |
| Snapshot | AX 角色、名称、值、ref、locator、viewport/full/subtree |
| Locator | role、css、href、xpath、shadow DOM、唯一性、ambiguity 诊断 |
| Input | click、fill、press、select、mouse、keyboard、paste、upload |
| Network | page fetch、server fetch、network idle、超时和 CORS |
| 文件 | chooser arm、download saveAs、绝对路径、失败清理 |
| Learnings | manifest、站点匹配、工具参数、路径安全、格式校验 |
| 分发 | App bundle、PATH、Claude/Codex Skill、doctor、无 Agent access |
| 质量 | `swift build`、`swift test`、CLI typecheck/test、真实 CEF E2E |

核心冒烟脚本：

```bash
peekr nodejs <<'EOF'
const task = await taskSpace("replica-smoke");
const page = task.page("p1");
await page.goto("https://example.com");
console.log(await page.snapshot({ scope: "full_page" }));
await task.finish({ keep: [] });
EOF
```

复杂基准页必须同时包含：嵌套同域 iframe、跨域 iframe、开放 Shadow DOM、表单输入、下载、JavaScript dialog 和新窗口 popup。

## 7. 风险与明确取舍

1. **Snapshot 质量风险**：CEF 的 AX 树可能比参考内核不完整。先做 AX/DOMSnapshot 双源，再准备注入式 ARIA walker 作为降级，不把降级结果伪装成完整 snapshot。
2. **Space ID 差异**：Peekr 内部 UUID 与参考实现的数字 ID 不兼容，必须增加持久外部 ID，不能让每个 helper 自己转换。
3. **全局选择状态**：native bridge 若一次只能选择一个 Space，所有操作必须经过 FIFO gate；不能用并发 Promise 绕过选择锁。
4. **用户控制边界**：ownership 检查必须在 Swift 侧最终裁决，CLI 缓存只用于性能，不能用于授权。
5. **CEF target 差异**：维持当前每 target WebSocket 方案，禁止假设 Chromium flattened session 在所有 CEF 版本可用。
6. **内嵌 Node**：第一阶段使用 Node ≥22；将 Node runtime 抽象为 `NodeHost`，以后可替换为 App 内嵌 helper，不让业务 API 依赖宿主路径。
7. **版权**：复用开源 harness 时保留 MIT notice；不提交外部内核、反编译产物或未授权站点数据。

## 8. 当前工作树之后的执行顺序

1. 收口已有 `peekr install` WIP，并先补 `install` 的单元测试。
2. 新增 `public-api-schema.ts`，冻结完整 API 名称和参数验证。
3. 实现 `TaskSpace/Page` 对象和 page ledger，把现有 helpers 作为薄兼容层。
4. 将现有 snapshot/action 迁移到 `withPage()`，补 hard-stop 输出 sink。
5. 完成主 frame → iframe/OOPIF → Shadow DOM 的 snapshot parity。
6. 最后做 Skill、learnings、App bundle、真实 CEF E2E 和发布验证。

本文档只描述复刻计划，不改变当前工作树中已有的 Swift 或 CLI WIP。

## 9. 本地参考索引

完整参考包只允许放在仓库根目录的 `.reference/agent-browser-baseline/`，并必须加入 `.gitignore`。它不会进入提交，只用于本机源码搜索、版本比对和行为复现。

本地索引至少应包含版本清单、API 资料、Skill 目录、可执行探针和源码快照；具体文件名由本机资料管理，不写入规范文档。任何核对结果都必须转化为 Peekr 自己的契约、测试或实现后再提交。

若更换参考版本，应新建版本目录，不覆盖旧目录；重新计算清单中的 hash，并在本计划文档中记录差异。

## 10. 参考资料

- 外部资料不写入本仓库的规范文档；需要核对时使用本地参考索引或独立研究记录。
- 本计划只记录 Peekr 自己验证过的行为、实现、测试和未决差异。
- Peekr 当前目标：[goal-peekr-cli.md](/Users/yunge/Projects/self/Peekr/docs/goal-peekr-cli.md)。
