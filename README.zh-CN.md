<div align="center">

<img src="assets/icon.png" alt="Peekr" width="128" height="128" />

# Peekr

**一款极速的 SlidePad 式「边缘滑出」网页浏览器，专为 macOS 打造，披着 Liquid Glass 外衣。**

把网页应用钉在屏幕任意边/角的 dock 上，鼠标滑过去（或按全局热键），面板就会*探*出来——而且**不抢占当前 App 的焦点**。

[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-black?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.10-F05138?logo=swift&logoColor=white)](https://swift.org)
[![Native](https://img.shields.io/badge/AppKit%20%2B%20SwiftUI-no%20Electron-1E90FF)](#为什么选-peekr)
[![License](https://img.shields.io/github/license/KiWi233333/Peekr?color=blue)](LICENSE)
[![Release](https://img.shields.io/github/v/release/KiWi233333/Peekr?include_prereleases&sort=semver)](https://github.com/KiWi233333/Peekr/releases)
[![Stars](https://img.shields.io/github/stars/KiWi233333/Peekr?style=social)](https://github.com/KiWi233333/Peekr/stargazers)

[English](README.md) · 简体中文

<img src="assets/hero.png" alt="Peekr 从屏幕边缘探出" width="820" />

</div>

---

## 亮点

- ⚡️ **极小体积** —— 纯原生 Swift + AppKit + SwiftUI + `WKWebView`，无 Electron、无 Web 运行时。空闲约 58 MB、0% CPU，WebView 首次探出时才惰性创建。
- 🪟 **Liquid Glass** —— 在 macOS 26 上使用真正的 `glassEffect` / `GlassEffectContainer`；旧系统自动降级为 `.ultraThinMaterial`。
- 🎯 **从不抢焦点** —— 无边框的 non-activating 面板：能在网页里打字，却不会让你掉出当前 App。
- 🧲 **6 向停靠** —— 吸附到左右两边或四个角；拖拽即可重新停靠。
- 🔒 **隔离且持久的会话** —— 每个网页应用拥有独立 cookie 存储，保持登录态。

## 为什么选 Peekr？

市面上大多数「滑出式浏览器」都是 Electron 套壳，动辄几百 MB、卡顿明显。Peekr 是一个约 2400 行、单一 target、**零第三方依赖**的 Swift 应用——秒启动、空闲 0% CPU，用起来就像 macOS 原生的一部分。它以 `LSUIElement` agent 形式驻留菜单栏：无 Dock 图标、无主窗口，只在你需要时探出面板。

## 功能

| | |
|---|---|
| **边缘探出 + 悬停延迟** | 悬停停靠的边/角即滑出；停留延迟可配置。 |
| **6 向停靠** | 停靠到左右两边或任意角。拖拽面板的玻璃背景，在边/角附近松手即可**自动吸附**到最近的锚点——且**永不改变尺寸**。 |
| **可缩放面板** | 拖动缩放手柄；默认宽度为屏幕可见区的 ⅔。 |
| **全局热键** | 可重绑定（默认 `⌃⌥Space`）；在偏好设置里录制任意快捷键。 |
| **浏览器快捷键** | `⌘L` 聚焦地址栏、`⌘R` 刷新、`⌘[` / `⌘]` 前进后退、`⌘W` 关闭、`⌘1`–`⌘9` 切换应用、`Esc` 隐藏。 |
| **每应用导航栏** | 玻璃地址栏：前进 / 后退 / 刷新-停止、可加载或搜索的地址输入框、进度条、在 Safari 中打开。 |
| **图标 dock** | 真实 favicon（自动抓取并缓存），无则回退为字母图标；拖拽排序；右键 编辑 / 重载 / 删除；可设置**自定义图标**。 |
| **浏览器数据导入** | 在「偏好设置 → 应用 → 导入浏览器数据…」中，把当前标签页导入为 Peekr 应用，或把指定 Chrome Profile 的 Cookie 复制到 Peekr Chromium Profile。临时数据库快照仅当前用户可访问并在导入后删除；解密值只在本机内存中处理，不支持的分区 Cookie 会跳过。 |
| **持久会话** | WebKit 为每个应用保留独立 `WKWebsiteDataStore`；Chromium 使用一个持久共享 Profile，让导入的 Chrome 登录态可供 Peekr 应用使用。 |
| **多显示器** | 跟随光标所在屏幕，并记住最后一块屏。 |
| **固定与自动隐藏** | 可固定常开，也可在离开时自动滑走。 |
| **双语** | 中英文，跟随系统语言自动切换。 |
| **开机自启** | 一个开关，基于 `SMAppService`。 |

## 截图

<div align="center">
<img src="assets/screenshot.png" alt="Peekr 滑出面板：图标 rail、导航栏与加载中的网页应用" width="720" />
</div>

## 安装

### 从源码构建

需要 **Xcode 26** 才能用上真正的 Liquid Glass（低版本也能构建运行，自动降级为材质效果）。macOS 14+。

```bash
git clone https://github.com/KiWi233333/Peekr.git
cd Peekr

make run     # 构建并启动 Release .app（WebKit + 内置 Chromium）
make dev     # 构建并启动 Debug .app
make app     # 仅构建 Release build/Peekr.app
make build   # swift build —— 快速编译检查
make clean
```

> [!NOTE]
> Chromium 依赖 CefSwift Framework 和五个 Helper Bundle，因此 Peekr
> 不再支持用裸 `swift run` 启动。`make dev` 和 `make run` 都会生成完整
> `.app`；首次构建会把固定版本的 CEF 构建依赖下载到 `.cef/`，产物自身
> 则完整内置运行时。WebKit 按应用隔离数据；Chromium 当前使用 CefSwift
> 提供的单一持久全局 Profile。

### 使用

- 悬停停靠的边/角，或按全局热键（`⌃⌥Space`）触发面板。
- 从菜单栏图标打开 **偏好设置…**（`⌘,`）或 **退出**。
- 用户数据位于 `~/Library/Application Support/Peekr/`（`apps.json`、`settings.json`、`icons/`）。删除即可重置。

## 架构

Peekr 没有依赖注入框架——所有对象都在 `AppDelegate.applicationDidFinishLaunching` 里手动接线，构造顺序*即*依赖关系。状态由四个 `@MainActor @Observable` 真相源持有，SwiftUI 直接读取。

```
Sources/Peekr/
  App/          PeekrApp（CefSwift 启动入口）、AppDelegate、AppModel、
                BookmarksModel、MainMenu
  Model/        WebApp、Workspace、BookmarkNode、Settings、PanelAnchor、HotKeyConfig
  Store/        AppStore、SettingsStore、BookmarkStore（JSON 持久化）
  Web/          WebEngine、WebKitEngine、CefSwiftEngine、WebViewManager、
                BrowserState、BookmarkImporter、OpenTabsImporter
  Panel/        SlidePanel、PanelController、PanelGeometry、EdgeTrigger
  UI/           PanelRootView、AppRail、NavigationBar、EditAppSheet、
                BookmarkSheet、ImportTabsSheet
  Preferences/  PreferencesWindowController、PreferencesView
  Input/        GlobalHotKey（Carbon）
  StatusBar/    StatusBarController
  Util/         GlassStyle（liquidGlass + theme）、IconStore、LaunchAtLogin、
                Localization、AppPaths
```

几条承重约定（完整说明见 [`CLAUDE.md`](CLAUDE.md)）：

- **位置 ≠ 尺寸。** 方位判断收敛在 `PanelAnchor`，几何收敛在 `PanelGeometry`。拖拽吸附只改停靠位置和滑入方向，**永不**改变面板尺寸。
- **每个关注点只有一扇门。** 玻璃走 `liquidGlass()`，文案走 `Localized`，地址栏 URL 解析走 `WebViewManager.url(fromOmnibox:)`。复用这些单一入口，而非另起炉灶。
- **容错解码。** 持久化模型手写 `init(from:)`，用 `decodeIfPresent(...) ?? fallback` 逐字段兜底，schema 演进时永不丢弃用户旧 JSON。

## 路线图

完整路线图（基于用户需求洞察）见 **[ROADMAP.md](ROADMAP.md)**。重点：

- [x] 浏览器快捷键、书签与打开标签导入
- [ ] 每应用面板尺寸记忆 + 真休眠（含睡眠/唤醒热键）
- [ ] 应用辨识度：别名、活动应用强调、未读 / 通知角标
- [ ] 按 URL 模式注入自定义 CSS / JS
- [ ] 内置内容拦截、应用快速切换器

## 贡献

欢迎提交 Issue 和 PR！请先阅读 [CONTRIBUTING.md](CONTRIBUTING.md) 和 [行为准则](CODE_OF_CONDUCT.md)。提交信息遵循 [Conventional Commits](https://www.conventionalcommits.org/)。

## 许可证

[MIT](LICENSE) © KiWi233333
