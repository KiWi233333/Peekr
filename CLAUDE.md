# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> 说明：本仓库注释与文档以英文为主；本文件用中文记录架构要点，方便快速上手。代码、标识符、提交信息请沿用英文。

## 项目概览

Peekr 是一个 macOS 菜单栏 agent（`LSUIElement` / `.accessory`，无 Dock 图标、无主窗口），实现 SlidePad 式的「边缘滑出」网页浏览器。纯原生 Swift + AppKit + SwiftUI + `WKWebView`，无 Electron。把网页应用钉到屏幕任意边/角的 dock，鼠标悬停边缘或按全局热键即可滑出面板，且**不抢占当前 App 的焦点**。

约 2400 行 Swift，单一可执行 target，无第三方依赖。

## 构建与运行

```bash
make dev     # swift run —— 快速迭代，但是「裸可执行文件」模式
make run     # 打包 build/Peekr.app（ad-hoc 签名）并启动 —— 完整 .app 模式
make app     # 仅打包，不启动
make build   # swift build，仅做编译检查
make clean
```

无测试套件。`make build` 是唯一的「快速验证」手段。

**两种运行模式的关键区别（改 WebView / 登录项相关代码时务必注意）：**

| | `make dev`（`swift run`） | `make run`（`.app` bundle） |
|---|---|---|
| `Bundle.main.bundleIdentifier` | `nil` | `com.peekr.app` |
| Web 会话隔离 | `WKWebsiteDataStore.default()`（**共享**会话） | `WKWebsiteDataStore(forIdentifier:)`（**每 App 独立**持久化 cookie/登录） |
| 开机自启（`SMAppService`） | 静默 no-op | 生效 |

代码在 `WebViewManager.makeDataStore` 与 `LaunchAtLogin` 里通过 `bundleIdentifier != nil` 分支处理这两种模式。验证「会话隔离 / 自启」这类特性时**必须用 `make run`**，`swift run` 测不出来。

### 热更新（Hot Reload）

接了 [Inject](https://github.com/krzysztofzablocki/Inject)（唯一的第三方依赖，**release 下是 no-op**，`-interposable` 链接参数也只在 debug 生效）。SwiftUI 视图改 `body` 后无需重启即可看到效果，调样式很顺手。

**用法**：视图加两行——属性 `@ObserveInjection private var inject`，`body` 末尾 `.enableInjection()`。已接入 `PanelRootView` / `NavigationBar` / `AppRail`；要在别的视图上启用照抄这两行即可。

**前提**（热重载靠重新编译单个文件，编译命令只有 Xcode 会产出）：
1. 装 [InjectionIII.app](https://github.com/johnno1962/InjectionIII)（Mac App Store 或 release 下载），打开它并 `Open Project` 选本仓库目录；
2. 用 **Xcode 打开 `Package.swift` 跑**（⌘R），不要用 `swift run`——`make dev` 不会热重载，只是普通启动。

`make build` / `make run` 不受影响，CI 与发布链路照旧（Inject 静态链入、release 无副作用）。注意：启动期代码（`AppDelegate` 组合根、窗口/热键/`SlidePanel`）改了仍需重启，热重载只换 SwiftUI 视图。

**环境要求**：macOS 14+ 可运行；真正的 Liquid Glass 需要 Xcode 26 编译，低版本自动降级为 `.ultraThinMaterial`（见下文）。

**用户数据**位于 `~/Library/Application Support/Peekr/`：`apps.json`、`settings.json`、`icons/<uuid>.png`。调试持久化逻辑时清掉这里即可重置。

## 架构要点（需跨多个文件才能看清的部分）

### 组合根：`AppDelegate`
没有 DI 框架。所有对象在 `AppDelegate.applicationDidFinishLaunching` 里手动 new 出来并用闭包互相接线，顺序即依赖关系：
`Settings` → `AppModel` → `IconStore` → `WebViewManager` → `PanelController` → `EdgeTrigger` → `PreferencesWindowController` → `StatusBarController`。
组件间不持有彼此引用，而是通过回调解耦，例如：
- `panel.onVisibilityChange` → `edge.setArmed(!visible)`：面板可见时**解除**边缘触发，避免反复弹出。
- 偏好设置改动 → `PreferencesWindowController.onApply` → `AppDelegate.applyPreferences()` → 重新注册热键 + `panel.applyLayout()`。

入口 `main.swift` 用 `MainActor.assumeIsolated { … }` 包裹（顶层代码在主线程启动，需手动声明 main actor 隔离）。

### 状态：`@Observable`（注意不是 `ObservableObject`）
四个 `@MainActor @Observable` 类是各自领域的唯一真相源，UI 直接读字段：
- **`AppModel`**：dock 应用列表、`selectedID`、`isPinned`。增删改排序都在此并触发 `persist()`。
- **`Settings`**：所有偏好。`snapshot` 暴露一个 Equatable 的 `SettingsData`，供 `.onChange` 监听后保存。
- **`BrowserState`**：当前活动 WebView 的导航状态（前进/后退/加载/进度/URL/标题），由 `WebViewManager` 经 KVO 镜像而来。`focusOmniboxToken` 是个自增计数器，bump 一次即让地址栏聚焦（⌘L 用）。
- **`IconStore`**：图标缓存；本身也是 `@Observable`，所以异步 favicon 一旦加载完，SwiftUI tile 会自动刷新。

### 持久化的「容错解码」约定 ⚠️
`SettingsData` 和 `WebApp` 都手写了 `init(from decoder:)`，用 `decodeIfPresent(...) ?? fallback` 逐字段兜底，目的是**让 schema 演进时不丢用户的旧 JSON 文件**。
**新增任何持久化字段时，必须在对应的 `init(from:)` 里加一行容错解码并给默认值**，否则旧文件会解码失败被整体丢弃。`Store` 层（`AppStore`/`SettingsStore`）是极薄的 JSON 读写，原子写入，失败静默回退到默认值。

### 面板几何：位置 ≠ 尺寸
- `PanelAnchor`：6 个停靠点（左右 2 边 + 4 角；不支持上/下边，因为 rail 是竖向的）。各种 `isLeftSide`/`slidesHorizontally`/`railOnLeft` 派生属性集中在这里，**不要在视图里重复判断方位**。
- `PanelGeometry`：纯几何函数（无副作用），算 onscreen/offscreen 两个 frame、触发热区、最近 anchor。`defaultSize` 默认宽度 = 屏幕可见区宽度的 2/3。
- **核心不变量**：拖拽吸附（6 方向自动 snap）只改变停靠位置和滑入方向，**永不改变面板尺寸**；尺寸由用户通过 resize handle 决定，存在 `settings.panelWidth/Height`（0 表示「按屏幕比例自动」）。拖拽：整面板的毛玻璃背景都是 move 手柄（`PanelRootView` 的透明 drag 层），拖动时不检测边缘、**松手才 snap**。改动 `PanelController` 的拖拽/缩放/动画逻辑时请守住这条线。
- **原生体验细节**（参考 native-feel WebView 生存指南）：`PanelController.animate` 用 `allowsImplicitAnimation = true`（滑动时 WebView 持续绘制不冻结）并遵守系统「减弱动态效果」。
  - ⚠️ 踩坑记录：曾想用 `window.setValue(false, forKey: "windowOcclusionDetectionEnabled")` 关闭遮挡节流（生存指南 A.1），但该私有 KVC key 在本机 macOS 上**不存在**，`setValue:forKey:` 抛 `NSUnknownKeyException`。它发生在 `applicationDidFinishLaunching` 内、被 NSApp 运行循环吞掉 → 进程不崩但启动半途夭折（菜单栏状态项再没创建）。**教训：在 `applicationDidFinishLaunching` 里调私有 KVC / 可能抛 ObjC 异常的 API 前要确认 key 存在；"进程还活着"≠"启动成功"，要验证 `NSStatusItem` 真的出现（`osascript … count of menu bars`）。**
- `SlidePanel` 是 borderless `.nonactivatingPanel`：`canBecomeKey = true` 但 `canBecomeMain = false` —— 这是「能在网页里打字、却不抢前台 App 焦点」的关键，别改。

### 滑出触发链路
`EdgeTrigger`（全局 `mouseMoved` 监听）→ 光标在 `PanelGeometry.triggerRegion` 内停留 `hoverDelay` → `onTrigger` → `panel.show()`。面板打开期间由 `onVisibilityChange` 解除触发。`PanelController` 自身在可见时再装一组监听做**自动隐藏**（光标离开 + 未 pin + 未 `autoHideSuspended` 才隐藏；拖拽/缩放/弹 sheet 时会临时挂起）。

### WebView 生命周期
`WebViewManager` 按 App UUID **缓存一个 `WKWebView`** 并跨显隐保活（会话/滚动位置/播放不丢）。`bindObservers` 用 KVO 把活动 view 的属性镜像进 `BrowserState`。地址栏「是 URL 就打开、否则 Google 搜索」的解析逻辑在 `WebViewManager.url(fromOmnibox:)`，是单一入口。

### Liquid Glass 抽象
**所有玻璃效果只走两个入口**，不要在视图里直接写 `glassEffect`：
- `View.liquidGlass(in:tint:interactive:)`：macOS 26 用真 `glassEffect`，否则 `.ultraThinMaterial` + hairline。
- `GlassGroup { … }`：macOS 26 是 `GlassEffectContainer`，否则透明容器。
设计语言（圆角、accent、hairline 等常量）集中在 `Theme`。当前是单色 / shadcn 风格——`accent` 就是 `Color.primary`。

### 本地化
没有 `.strings` 文件。`Localized` 结构体用 `t(en, zh)` 二选一，由 `Settings.language`（`AppLanguage.resolved` 把 `.system` 解析成具体语言）驱动。**新增任何用户可见文案都加在 `Localized` 里**，并通过 `settings.strings.xxx` 读取，菜单栏标题在 `menuNeedsUpdate` 里实时刷新。

### 全局热键
`GlobalHotKeyCenter`（单例）用 Carbon `RegisterEventHotKey` 注册。`HotKeyConfig` 存 keyCode + Carbon 修饰键掩码，`PreferencesView` 的录制器用 `carbonModifiers(from:)` 做 Cocoa→Carbon 转换。面板为 key 窗口时的浏览器快捷键（⌘L/R/[/]/W、⌘1–9、Esc）在 `PanelController.handleCommand`，与全局热键是两套机制。

## 约定

- **提交信息**用 Conventional Commits（`feat:` / `fix:` …）。
- 遵循 `~/.claude/rules/code-reuse-and-altitude.md`：抽取共享逻辑后迁移所有旧调用点、把校验下沉到共同边界、收敛魔法值。本仓库里方位判断收敛在 `PanelAnchor`、几何在 `PanelGeometry`、玻璃在 `liquidGlass`、文案在 `Localized`、URL 解析在 `WebViewManager` —— 新代码应复用这些单一入口，而非另起炉灶。

<!-- gitnexus:start -->
# GitNexus — Code Intelligence

This project is indexed by GitNexus as **Peekr** (1759 symbols, 6952 relationships, 136 execution flows). Use the GitNexus MCP tools to understand code, assess impact, and navigate safely.

> If any GitNexus tool warns the index is stale, run `npx gitnexus analyze` in terminal first.

## Always Do

- **MUST run impact analysis before editing any symbol.** Before modifying a function, class, or method, run `gitnexus_impact({target: "symbolName", direction: "upstream"})` and report the blast radius (direct callers, affected processes, risk level) to the user.
- **MUST run `gitnexus_detect_changes()` before committing** to verify your changes only affect expected symbols and execution flows.
- **MUST warn the user** if impact analysis returns HIGH or CRITICAL risk before proceeding with edits.
- When exploring unfamiliar code, use `gitnexus_query({query: "concept"})` to find execution flows instead of grepping. It returns process-grouped results ranked by relevance.
- When you need full context on a specific symbol — callers, callees, which execution flows it participates in — use `gitnexus_context({name: "symbolName"})`.

## Never Do

- NEVER edit a function, class, or method without first running `gitnexus_impact` on it.
- NEVER ignore HIGH or CRITICAL risk warnings from impact analysis.
- NEVER rename symbols with find-and-replace — use `gitnexus_rename` which understands the call graph.
- NEVER commit changes without running `gitnexus_detect_changes()` to check affected scope.

## Resources

| Resource | Use for |
|----------|---------|
| `gitnexus://repo/Peekr/context` | Codebase overview, check index freshness |
| `gitnexus://repo/Peekr/clusters` | All functional areas |
| `gitnexus://repo/Peekr/processes` | All execution flows |
| `gitnexus://repo/Peekr/process/{name}` | Step-by-step execution trace |

## CLI

| Task | Read this skill file |
|------|---------------------|
| Understand architecture / "How does X work?" | `.claude/skills/gitnexus/gitnexus-exploring/SKILL.md` |
| Blast radius / "What breaks if I change X?" | `.claude/skills/gitnexus/gitnexus-impact-analysis/SKILL.md` |
| Trace bugs / "Why is X failing?" | `.claude/skills/gitnexus/gitnexus-debugging/SKILL.md` |
| Rename / extract / split / refactor | `.claude/skills/gitnexus/gitnexus-refactoring/SKILL.md` |
| Tools, resources, schema reference | `.claude/skills/gitnexus/gitnexus-guide/SKILL.md` |
| Index, status, clean, wiki CLI commands | `.claude/skills/gitnexus/gitnexus-cli/SKILL.md` |

<!-- gitnexus:end -->
