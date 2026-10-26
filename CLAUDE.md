# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> 说明：本仓库注释与文档以英文为主；本文件用中文记录架构要点，方便快速上手。代码、标识符、提交信息请沿用英文。

## 项目概览

Peekr 是一个 macOS 菜单栏 agent（`LSUIElement` / `.accessory`，无 Dock 图标、无主窗口），实现边缘滑出的网页浏览器。界面使用 Swift + AppKit + SwiftUI，网页只使用内置 CefSwift/CEF/Chromium，没有 WebKit 运行时后端。鼠标悬停边缘或按全局热键即可滑出面板，且**不抢占当前 App 的焦点**。当前分支另有 Spaces、标签组、按需页面预览，以及默认关闭的 Agent Access 和 Node.js CLI。

当前源码分支的功能可能尚未进入下载版；版本事实见 `CHANGELOG.md` 和 GitHub Releases。

## 构建与运行

```bash
make dev     # 构建并启动 InjectionIII 热更新 Debug .app，持续跟踪日志
make inject  # 重新构建并启动注入用 Debug .app
make run     # 打包并打开 Release .app
make app     # 仅打包 Release .app
make dmg     # 构建 Release DMG
make build   # swift build，仅做编译检查
swift test
cd cli && npm run typecheck && npm test  # CLI 改动时
make clean
```

`make dev` 构建完整的 CEF Debug `.app`，然后通过 Xcode 和 InjectionIII 启动可注入版本；终端继续执行 `tail -F` 跟踪 Chromium 日志，`Ctrl+C` 会停止日志输出并关闭开发中的 Peekr 进程。`make run` 构建 Release `.app`，不启用热更新。所有页面共享 `CefProfile.default` 的持久 Chromium Profile，Spaces 仅隔离标签组织和 Agent 归属，不隔离 Cookie 或登录态。

### 热更新（Hot Reload）

接了 [Inject](https://github.com/krzysztofzablocki/Inject)（热更新依赖；**release 下是 no-op**，`-interposable` 链接参数也只在 debug 生效）。另有 CefSwift/CEF 浏览器依赖。SwiftUI 视图改 `body` 后无需重启即可看到效果，调样式很顺手。

**用法**：视图加两行——属性 `@ObserveInjection private var inject`，`body` 末尾 `.enableInjection()`。已接入 `PanelRootView` / `NavigationBar` / `AppRail` / `SpacesOverview`；要在别的视图上启用照抄这两行即可。

**前提**：装 [InjectionIII.app](https://github.com/johnno1962/InjectionIII)，打开它并 `Open Project` 选本仓库目录（一次即可，之后自动恢复）。

**启动**：运行 `make dev`。脚本先准备 CEF Debug Bundle，再用 xcodebuild 生成 Xcode Debug 产物，打开 InjectionIII 和当前仓库，最后把 Xcode binary 装进带 CEF Framework/Helper 的 `.app` 并启动。之后修改已注入的 SwiftUI 视图并保存，InjectionIII 会在几秒到几十秒内注入更新。`make inject` 用于不重新打包 CEF 时重新构建并重启注入用 App。

注意：新增/删除源文件、改 `Package.swift` 或隔了太久，重跑一次 `make inject` 刷新编译产物与日志；启动期代码（`AppDelegate` 组合根、窗口/热键/`SlidePanel`）改了需重启 app。`make build` / `make run` / `make dev` 不受影响，CI 与发布链路照旧（Inject 静态链入、release 无副作用）。

**环境要求**：macOS 14+ 可运行；真正的 Liquid Glass 需要 Xcode 26 编译，低版本自动降级为 `.ultraThinMaterial`（见下文）。

**用户数据**位于 `~/Library/Application Support/Peekr/`：`apps.json`（Spaces、标签与分组）、`bookmarks.json`、`history.json`、`settings.json`、`profiles.json`、`downloads.json`、`permissions.json`、`zoom.json`、`recently-closed.json`、图标缓存及 `Chromium/`。Agent Access 开启时还有 `agent.json` 和 CLI 页签记录。调试时使用隔离数据目录，避免误删真实登录态。

## 架构要点（需跨多个文件才能看清的部分）

### 组合根：`AppDelegate`
没有 DI 框架。所有对象在 `AppDelegate.applicationDidFinishLaunching` 里手动 new 出来并用闭包互相接线，顺序即依赖关系：
`Settings` → `AppModel` / `BookmarksModel` → `IconStore` / `BadgeStore` → `WebViewManager`（`CefSwiftEngineFactory`）→ `PanelController` → `EdgeTrigger` → `PreferencesWindowController` → `StatusBarController`；Agent Access 开启后才启动本地控制桥接。
组件间不持有彼此引用，而是通过回调解耦，例如：
- `panel.onVisibilityChange` → `edge.setArmed(!visible)`：面板可见时**解除**边缘触发，避免反复弹出。
- 偏好设置改动 → `PreferencesWindowController.onApply` → `AppDelegate.applyPreference(_:)` → 按变更类型更新热键、布局或相关服务。

入口是 `App/PeekrApp.swift` 的 `CefSwiftApp`；它在 SwiftUI/AppKit 接触 `NSApp` 前初始化 CEF，`AppDelegate` 再完成组件接线。

### 状态：`@Observable`（注意不是 `ObservableObject`）
各领域的 `@MainActor @Observable` 模型是 UI 状态入口：
- **`AppModel`**：Spaces、标签、标签组、当前空间和选择、`isPinned`。增删改排序在此并触发 `persist()`。
- **`Settings`**：所有偏好。`snapshot` 暴露一个 Equatable 的 `SettingsData`，供 `.onChange` 监听后保存。
- **`BrowserState`**：当前活动 CEF 页面的导航状态（前进/后退/加载/进度/URL/标题），由 `WebViewManager` 镜像。`focusOmniboxToken` 是个自增计数器，bump 一次即让地址栏聚焦（⌘L 用）。
- **`IconStore`**：图标缓存；本身也是 `@Observable`，所以异步 favicon 一旦加载完，SwiftUI tile 会自动刷新。
- **`BookmarksModel` / `BadgeStore`**：书签树和从网页标题解析的未读数。空间概览的 `WorkspacePreviewService` 仅在打开时捕获当前页，后台缩略并过滤空白帧。

### 持久化的「容错解码」约定 ⚠️
`SettingsData`、`WebApp`、`Workspace` 和 `WorkspacesData` 都手写了容错解码，目的是**让 schema 演进时不丢用户的旧 JSON 文件**。
**新增任何持久化字段时，必须在对应的 `init(from:)` 里加一行容错解码并给默认值**，否则旧文件会解码失败被整体丢弃。`Store` 层（`AppStore`/`SettingsStore`）是极薄的 JSON 读写，原子写入，失败静默回退到默认值。

### 面板几何：位置 ≠ 尺寸
- `PanelAnchor`：6 个停靠点（左右 2 边 + 4 角；不支持上/下边，因为 rail 是竖向的）。各种 `isLeftSide`/`slidesHorizontally`/`railOnLeft` 派生属性集中在这里，**不要在视图里重复判断方位**。
- `PanelGeometry`：纯几何函数（无副作用），算 onscreen/offscreen 两个 frame、触发热区、最近 anchor。`defaultSize` 默认宽度 = 屏幕可见区宽度的 2/3。
- **核心不变量**：拖拽吸附（6 方向自动 snap）只改变停靠位置和滑入方向，**永不改变面板尺寸**；尺寸由用户通过 resize handle 决定，存在 `settings.panelWidth/Height`（0 表示「按屏幕比例自动」）。拖拽：整面板的毛玻璃背景都是 move 手柄（`PanelRootView` 的透明 drag 层），拖动时不检测边缘、**松手才 snap**。改动 `PanelController` 的拖拽/缩放/动画逻辑时请守住这条线。
- **原生体验细节**（参考 native-feel WebView 生存指南）：`PanelController.animate` 用 `allowsImplicitAnimation = true`（滑动时 WebView 持续绘制不冻结）并遵守系统「减弱动态效果」。
  - ⚠️ 踩坑记录：曾想用 `window.setValue(false, forKey: "windowOcclusionDetectionEnabled")` 关闭遮挡节流（生存指南 A.1），但该私有 KVC key 在本机 macOS 上**不存在**，`setValue:forKey:` 抛 `NSUnknownKeyException`。它发生在 `applicationDidFinishLaunching` 内、被 NSApp 运行循环吞掉 → 进程不崩但启动半途夭折（菜单栏状态项再没创建）。**教训：在 `applicationDidFinishLaunching` 里调私有 KVC / 可能抛 ObjC 异常的 API 前要确认 key 存在；"进程还活着"≠"启动成功"，要验证 `NSStatusItem` 真的出现（`osascript … count of menu bars`）。**
- `SlidePanel` 是 borderless `.nonactivatingPanel`：`canBecomeKey = true` 但 `canBecomeMain = false` —— 这是「能在网页里打字、却不抢前台 App 焦点」的关键，别改。

### 滑出触发链路
`EdgeTrigger`（全局 `mouseMoved` 监听）→ 光标在 `PanelGeometry.triggerRegion` 内停留 `hoverDelay` → `onTrigger` → `panel.show()`。面板打开期间由 `onVisibilityChange` 解除触发。`PanelController` 按偏好选择失焦或鼠标离开时自动隐藏；pin、拖拽/缩放和弹层会阻止或暂停自动隐藏。

### WebView 生命周期
`WebViewManager` 按标签 UUID 缓存一个 `WebEngine`，生产工厂只创建 `CefSwiftEngine`；跨面板显隐复用同一个原生 CEF 页面。当前页面导航状态映射到 `BrowserState`。地址栏 URL 与所选搜索引擎的解析集中在 `WebViewManager.url(fromOmnibox:searchEngine:)`。Agent 后台页面由同一个 manager 缓存并在展示时复用；所有页面共用持久 `CefProfile.default`。

### 内部页面（`peekr://`）
浏览器级页面（新标签、历史、下载、书签、站点设置、清除数据、快捷键）不是 CEF 的 `chrome://` 页面，而是 `InternalPage` + SwiftUI 视图。`WebViewManager.openInternalPage/closeInternalPage` 在 `BrowserState.internalPage` 上切面；`PanelRootView` 让 CEF 视图保持挂载但隐藏，并把 `InternalPageHost` 覆盖在同一区域。内部页期间 `mirror` 不覆盖地址/标题，`goBack` 先关闭内部页。`WebApp.urlString` 为 `peekr://…` 的标签不创建 CEF 引擎；`⌘T` 新建的就是这种标签。所有内部页路由必须能由 `InternalPage.from(url)` 往返解析。

### 隐私 Space、音频与清除数据
- `Workspace.isPrivate` 的 Space 使用 `CefProfile.incognito()`，只存在于本次会话；`AppModel.persist()` 过滤私有 Space，`WebViewManager.recordHistory`/下载写入也按私有标签跳过。
- 音频检测没有 CEF JS 返回值 API，靠页面注入的 media probe 通过 `console.log("__PEEKR_AUDIO__:1|0")` 单向上报；`WebViewManager` 更新 `AppModel.audibleTabIDs`，rail 显示扬声器，`HibernationPolicy` 不再休眠可听页面。iframe/Shadow DOM/WebRTC 音频检测不到。
- 清除数据由 `BrowsingDataCleaner`（历史/下载/权限/缩放）与 CefKit `CefBrowsingData`（Cookies/HTTP cache）组成；CEF 只能整库删除，时间范围仅适用于 Peekr 自有数据。入口是 `peekr://clear-data` 和 `⇧⌘⌫`。
- 启动行为在 `AppDelegate.applyStartupBehavior()`；最近关闭栈落在 `recently-closed.json`，私有标签不入栈。

### Liquid Glass 抽象
**所有玻璃效果只走两个入口**，不要在视图里直接写 `glassEffect`：
- `View.liquidGlass(in:tint:interactive:)`：macOS 26 用真 `glassEffect`，否则 `.ultraThinMaterial` + hairline。
- `GlassGroup { … }`：macOS 26 是 `GlassEffectContainer`，否则透明容器。
设计语言（圆角、accent、hairline 等常量）集中在 `Theme`。当前是单色 / shadcn 风格——`accent` 就是 `Color.primary`。

### 本地化
没有 `.strings` 文件。`Localized` 结构体用 `t(en, zh)` 二选一，由 `Settings.language`（`AppLanguage.resolved` 把 `.system` 解析成具体语言）驱动。**新增任何用户可见文案都加在 `Localized` 里**，并通过 `settings.strings.xxx` 读取，菜单栏标题在 `menuNeedsUpdate` 里实时刷新。

### 全局热键
`GlobalHotKeyCenter`（单例）用 Carbon `RegisterEventHotKey` 注册。`HotKeyConfig` 存 keyCode + Carbon 修饰键掩码，`PreferencesView` 的录制器用 `carbonModifiers(from:)` 做 Cocoa→Carbon 转换。面板为 key 窗口时的浏览器快捷键（⌘L/R/⇧R/[/]/←/→、⌘D/F/W/T/⇧T、⌘=/−/0、⌘1–9、⌘⌥←/→、Ctrl+Tab、Esc）在 `PanelController.handleCommand`（local keyDown monitor，仅 `event.window === panel` 时生效；Esc 优先级：查找栏 > 文本编辑 > 隐藏面板），与全局热键是两套机制。页内查找栏状态在 `WebViewManager.findBar`（`FindBarState`），UI 在 `PanelRootView.FindBar`；右键菜单定制在 `CefSwiftEngine` 的 `configureContextMenu`/`contextMenuCommand`；新标签打开语义（⌘-click/中键/target=_blank 前后台分流）在 `decideWindowOpenFor` → `WebViewManager.openInNewTab`。

## 约定

- **提交信息**用 Conventional Commits（`feat:` / `fix:` …）。
- **外部参考命名**：主线或其他共享分支的提交标题，以及规范、规划和验收文档，不写外部对标产品、参考项目或用于设计参考的第三方软件名称。需要说明参考关系时使用“参考实现”“同类产品”“外部自动化套件”等中性表述；构建、运行、测试、打包和安全操作所必需的依赖名称可以保留。
- 遵循 `~/.claude/rules/code-reuse-and-altitude.md`：抽取共享逻辑后迁移所有旧调用点、把校验下沉到共同边界、收敛魔法值。本仓库里方位判断收敛在 `PanelAnchor`、几何在 `PanelGeometry`、玻璃在 `liquidGlass`、文案在 `Localized`、URL 解析在 `WebViewManager` —— 新代码应复用这些单一入口，而非另起炉灶。

<!-- gitnexus:start -->
# GitNexus — Code Intelligence

This project is indexed by GitNexus as **Peekr** (32304 symbols, 66712 relationships, 505 execution flows).

> Index stale? Run `node .gitnexus/run.cjs analyze --index-only` from the project root — it auto-selects an available runner. No `.gitnexus/run.cjs` yet? Bootstrap with `npx`, `bunx`, or `pnpm dlx` — e.g. `bunx gitnexus@latest analyze` (npm 11 npx crash; #1939).

## Always Do

- **MUST run impact before editing.** Use `impact({target: "symbolName", direction: "upstream"})` or `node .gitnexus/run.cjs impact "symbolName" --direction upstream --repo .`; report callers, processes, and risk. Never substitute grep for graph analysis. For unified PDG impact, add `mode: "pdg"` with optional `line: <N>` — it returns statement-level `affectedStatements` over CDG + REACHING_DEF and inter-procedural symbols in `interproceduralByDepth`/`byDepth`; no-layer/degraded PDG results are UNKNOWN-risk notes (`--pdg` layer). CLI equivalent: `node .gitnexus/run.cjs impact "symbolName" --direction upstream --mode pdg --line <N> --repo .`.
- **MUST analyze graph changes before committing.** Use `detect_changes({scope: "all"})` (MCP) or `node .gitnexus/run.cjs detect-changes --scope all --repo .` (CLI fallback). `partial: true` or `truncated: true` is not a clean check — a zero means unseen, not unaffected; re-run it. For regression review: `detect_changes({scope: "compare", base_ref: "main"})` or `node .gitnexus/run.cjs detect-changes --scope compare --base-ref "main" --repo .`.
- MUST warn on HIGH/CRITICAL `risk` pre-edit; never use `riskSharedAxes` to waive a HIGH/CRITICAL `risk` warning. Compare File/symbol: MCP File omits axes; Graph-RAG expands File.
- **MUST treat `risk: UNKNOWN` as unresolved, not as low.** An empty caller set is not evidence the symbol is unused — it can also mean the callers are not resolvable by the index (plain-object property access, dynamic dispatch, cross-language calls). `impact` pairs `UNKNOWN` with a `riskNote` saying so. Confirm with a text search before treating the symbol as safe to change or delete; do not proceed on the strength of a zero.
- **MUST use `query({search_query: "concept"})` for concepts/flows, `context({name: "symbolName"})` for a named symbol, or `impact` for blast radius, on read-only callers, dependencies, imports, or execution flow.** Graph first; text search only for empty/`UNKNOWN`/literals.
- For security review, `explain({target: "fileOrSymbol"})` lists taint findings (source→sink flows; needs `analyze --pdg`).
- For control/data dependence, `pdg_query({mode: "controls", target: "fileOrSymbol"})` answers "under what condition does X run?" (CDG, incl. guard clauses) and `pdg_query({mode: "flows", target, variable})` traces "where does variable Y flow?" (REACHING_DEF). `--pdg` layer.

## Never Do

- NEVER edit a function, class, or method before MCP/CLI impact analysis.
- NEVER ignore HIGH or CRITICAL risk warnings from impact analysis, and never read `UNKNOWN` as an all-clear — it means the walk could not answer, which is the one verdict that requires confirming by other means.
- NEVER rename symbols with find-and-replace — use `rename` which understands the call graph.
- NEVER commit before MCP/CLI graph change analysis.

## Resources

| Resource | Use for |
| --- | --- |
| `gitnexus://repo/Peekr/context` | Codebase overview, check index freshness |
| `gitnexus://repo/Peekr/clusters` | All functional areas |
| `gitnexus://repo/Peekr/processes` | All execution flows |
| `gitnexus://repo/Peekr/process/{name}` | Step-by-step execution trace |

## CLI

| Task | Read this skill file |
| --- | --- |
| Understand architecture / "How does X work?" | `.claude/skills/gitnexus-exploring/SKILL.md` |
| Blast radius / "What breaks if I change X?" | `.claude/skills/gitnexus-impact-analysis/SKILL.md` |
| Trace bugs / "Why is X failing?" | `.claude/skills/gitnexus-debugging/SKILL.md` |
| Rename / extract / split / refactor | `.claude/skills/gitnexus-refactoring/SKILL.md` |
| Tools, resources, schema reference | `.claude/skills/gitnexus-guide/SKILL.md` |
| Index, status, clean, wiki CLI commands | `.claude/skills/gitnexus-cli/SKILL.md` |

<!-- gitnexus:end -->
