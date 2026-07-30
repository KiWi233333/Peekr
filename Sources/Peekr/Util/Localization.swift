import Foundation

/// UI language. `.system` follows the OS; otherwise an explicit override.
enum AppLanguage: String, Codable, CaseIterable, Identifiable {
    case system, english, chinese
    var id: String { rawValue }

    /// CEF locale shipped by Peekr. Keep this mapping in sync with the locale
    /// allowlist in `scripts/bundle.sh`.
    var cefLocaleIdentifier: String {
        cefLocaleIdentifier(preferredLanguages: Locale.preferredLanguages)
    }

    func cefLocaleIdentifier(preferredLanguages: [String]) -> String {
        let preferred = preferredLanguages.first?.lowercased() ?? "en"
        switch self {
        case .english:
            return "en"
        case .chinese:
            return Self.usesTraditionalChinese(preferred) ? "zh-TW" : "zh-CN"
        case .system:
            guard preferred.hasPrefix("zh") else { return "en" }
            return Self.usesTraditionalChinese(preferred) ? "zh-TW" : "zh-CN"
        }
    }

    private static func usesTraditionalChinese(_ identifier: String) -> Bool {
        identifier.hasPrefix("zh-hant")
            || identifier.hasPrefix("zh-tw")
            || identifier.hasPrefix("zh-hk")
            || identifier.hasPrefix("zh-mo")
    }

    /// Resolve `.system` to a concrete language using the OS preference.
    var resolved: AppLanguage {
        guard self == .system else { return self }
        let pref = Locale.preferredLanguages.first?.lowercased() ?? "en"
        return pref.hasPrefix("zh") ? .chinese : .english
    }

    var nativeName: String {
        switch self {
        case .system: return "System"
        case .english: return "English"
        case .chinese: return "中文"
        }
    }
}

/// Central string table. One place, two languages — `t(en, zh)` picks one.
struct Localized {
    let isChinese: Bool

    private func t(_ en: String, _ zh: String) -> String { isChinese ? zh : en }

    // Menu bar
    var toggle: String { t("Toggle Peekr", "显示 / 隐藏") }
    var showPeekr: String { t("Show Peekr", "显示 Peekr") }
    var hidePeekr: String { t("Hide Peekr", "隐藏 Peekr") }
    var pinOpen: String { t("Keep Open", "保持打开") }
    var autoHideMenu: String { t("Hide Automatically", "自动隐藏") }
    var importFromChrome: String { t("Import from Chrome", "从 Chrome 导入") }
    var importChromeBookmarks: String { t("Import Bookmarks", "导入书签") }
    var importAction: String { t("Import…", "导入…") }
    var preferences: String { t("Preferences…", "偏好设置…") }
    var quit: String { t("Quit Peekr", "退出 Peekr") }
    var quitConfirmTitle: String { t("Quit Peekr?", "退出 Peekr？") }
    var quitConfirmMessage: String {
        t("Peekr and all open web pages will close.",
          "将关闭 Peekr 和所有打开的网页。")
    }

    // Main menu — editing (drives the ⌘X/C/V/A/Z key equivalents)
    var editMenu: String { t("Edit", "编辑") }
    var undo: String { t("Undo", "撤销") }
    var redo: String { t("Redo", "重做") }
    var cut: String { t("Cut", "剪切") }
    var copy: String { t("Copy", "拷贝") }
    var paste: String { t("Paste", "粘贴") }
    var selectAll: String { t("Select All", "全选") }

    // Rail / tiles
    var addWebApp: String { t("Add Web App", "添加网页应用") }
    var importOpenTabs: String { t("Import Browser Data…", "导入浏览器数据…") }
    var importTitle: String { t("Import Browser Data", "导入浏览器数据") }
    var importTabsMode: String { t("Open Tabs", "标签页") }
    var importCookiesMode: String { t("Chrome Cookies", "Chrome Cookie") }
    var importEmpty: String {
        t("No open tabs found. Make sure Safari, Chrome, or Edge is running, and allow automation access when prompted.",
          "未发现打开的标签。请确认 Safari、Chrome 或 Edge 正在运行，并在提示时允许自动化访问。")
    }
    func importAdd(_ n: Int) -> String { isChinese ? "添加 \(n) 个" : "Add \(n)" }
    var importScan: String { t("Scan Browsers", "扫描浏览器") }
    var importScanHint: String {
        t("Scan the tabs open in Safari, Chrome, Edge or Brave. You'll be asked to allow automation the first time.",
          "扫描 Safari、Chrome、Edge 或 Brave 当前打开的标签。首次会请求允许自动化访问。")
    }
    var importRescan: String { t("Rescan", "重新扫描") }
    var importScanning: String { t("Scanning browsers…", "正在扫描浏览器…") }
    var openAutomationSettings: String { t("Open Automation Settings", "打开自动化设置") }
    var chromeProfile: String { t("Chrome Profile", "Chrome Profile") }
    var chromeProfilesEmpty: String {
        t("No Chrome profiles were found. Open Chrome once to create a profile, then try again.",
          "未发现 Chrome Profile。请先打开一次 Chrome 创建 Profile，然后重试。")
    }
    var reloadChromeProfiles: String { t("Reload Profiles", "重新读取 Profile") }
    var chromeCookieDatabaseMissing: String {
        t("This profile does not have a cookie database.", "这个 Profile 没有 Cookie 数据库。")
    }
    var chromeCookieDatabaseReady: String {
        t("The cookie database is ready to import.", "Cookie 数据库可以导入。")
    }
    var cookiePrivacyHint: String {
        t("Peekr reads an access-restricted local snapshot and asks macOS for Chrome Safe Storage access. Decrypted values stay in memory and are written only to Peekr's local Chromium profile; the snapshot is deleted and partitioned cookies are skipped.",
          "Peekr 会读取仅当前用户可访问的本地快照，并向 macOS 请求 Chrome Safe Storage 访问。解密后的值只保留在内存中，并仅写入 Peekr 本机 Chromium Profile；快照随后删除，分区 Cookie 会跳过。")
    }
    var importChromeCookies: String { t("Import Cookies", "导入 Cookie") }
    var importingChromeCookies: String { t("Importing Chrome cookies…", "正在导入 Chrome Cookie…") }
    var cookieConfirmTitle: String { t("Import Chrome cookies?", "导入 Chrome Cookie？") }
    func cookieConfirmMessage(_ profile: String) -> String {
        t("Cookies from “\(profile)” will be copied into Peekr's persistent Chromium profile. macOS may ask for keychain access.",
          "将把“\(profile)”中的 Cookie 复制到 Peekr 的持久 Chromium Profile。macOS 可能会请求钥匙串访问。")
    }
    func cookieImportResult(imported: Int, skipped: Int) -> String {
        if isChinese {
            return "已提交 \(imported) 个 Cookie，跳过 \(skipped) 个。刷新已打开的网页后生效。"
        }
        return "\(imported) cookies submitted; \(skipped) skipped. Reload open pages to use them."
    }
    func cookieImportFailed(_ message: String) -> String {
        t("Import failed: \(message)", "导入失败：\(message)")
    }
    var open: String { t("Open", "打开") }
    var edit: String { t("Edit…", "编辑…") }
    var refreshIconAndTitle: String { t("Refresh Icon & Title", "刷新图标和标题") }
    var delete: String { t("Delete", "删除") }
    var dragHint: String { t("Drag to move • release near an edge or corner to snap", "拖动移动 • 在边缘或角落松开自动吸附") }
    var newTab: String { t("New Tab", "新建标签") }
    var rename: String { t("Rename", "重命名") }
    var newWorkspace: String { t("New Workspace", "新建工作区") }
    var defaultWorkspace: String { t("Workspace", "工作区") }
    var resizeHint: String { t("Drag to resize", "拖动调整大小") }

    // Omnibox
    var omniboxPlaceholder: String { t("Search or enter address", "搜索或输入网址") }
    var googleSearch: String { t("Google Search", "Google 搜索") }

    // Bookmarks
    var bookmarks: String { t("Bookmarks", "书签") }
    var importBookmarks: String { t("Import Bookmarks", "导入书签") }
    var done: String { t("Done", "完成") }
    var bookmarksEmpty: String {
        t("No bookmarks yet. Import from a browser to get started.", "还没有书签。从浏览器导入开始吧。")
    }

    // Edit sheet
    var editWebApp: String { t("Edit Web App", "编辑网页应用") }
    var title: String { t("Title", "名称") }
    var alias: String { t("Alias", "别名") }
    var aliasHint: String { t("Optional — shown instead of the title", "可选——替代标题显示") }
    var address: String { t("Address", "网址") }
    var cancel: String { t("Cancel", "取消") }
    var save: String { t("Save", "保存") }
    var add: String { t("Add", "添加") }
    var chooseIcon: String { t("Choose…", "选择…") }
    var useFavicon: String { t("Use favicon", "使用网站图标") }
    var iconLibrary: String { t("Icon library", "图标库") }
    var iconLibraryHint: String { t("Brand name (e.g. github)", "品牌名（如 github）") }

    // Preferences
    var preferencesWindowTitle: String { t("Peekr Preferences", "Peekr 偏好设置") }
    var general: String { t("General", "通用") }
    var browser: String { t("Browser", "浏览器") }
    var apps: String { t("Apps", "应用") }
    var about: String { t("About", "关于") }
    var docking: String { t("Docking", "停靠") }
    var panel: String { t("Panel", "面板") }
    var panelBehavior: String { t("Panel Behavior", "面板行为") }
    var shortcutStartup: String { t("Shortcut & Startup", "快捷键与启动") }
    var width: String { t("Width", "宽度") }
    var height: String { t("Height", "高度") }
    var defaultWidth: String { t("Default width", "默认宽度") }
    var defaultHeight: String { t("Default height", "默认高度") }
    var panelSizeHint: String {
        t("The panel size, shared across every app. Drag a bottom corner of the panel to change it.",
          "面板尺寸，所有应用共用一个。拖动面板的底部边角即可调整。")
    }
    var hoverDelay: String { t("Hover delay", "悬停延迟") }
    var edgeSensitivity: String { t("Edge trigger width", "边缘触发区域") }
    var autoHide: String { t("Auto-hide the panel", "自动隐藏面板") }
    var autoHideMethod: String { t("Hide when", "隐藏时机") }
    func autoHideModeName(_ mode: AutoHideMode) -> String {
        switch mode {
        case .focusLoss: return t("Focus is lost", "失去焦点时")
        case .mouseLeave: return t("Cursor leaves the panel", "光标离开面板时")
        }
    }
    func autoHidePolicyName(_ policy: AutoHidePolicy) -> String {
        switch policy {
        case .off: return t("Off", "关闭")
        case .focusLoss: return t("When focus is lost", "失去焦点时")
        case .mouseLeave: return t("When the cursor leaves", "光标移出时")
        }
    }
    var followCursor: String { t("Follow cursor across displays", "跨显示器跟随光标") }
    var toggleShortcut: String { t("Toggle shortcut", "切换快捷键") }
    var launchAtLogin: String { t("Launch Peekr at login", "开机时启动 Peekr") }
    var language: String { t("Language", "语言") }
    var bookmarkSync: String { t("Auto-sync bookmarks", "定时同步书签") }
    func syncIntervalName(_ interval: BookmarkSyncInterval) -> String {
        switch interval {
        case .off: return t("Off", "关闭")
        case .hourly: return t("Hourly", "每小时")
        case .daily: return t("Daily", "每天")
        }
    }
    var pressKeys: String { t("Press keys…", "按下按键…") }

    // Web engine
    var webEngineSection: String { t("Web Engine", "浏览器内核") }
    var chromeDataSection: String { t("Chrome Data", "Chrome 数据") }
    var chromeDataHint: String {
        t("Import cookies into Peekr's Chromium profile or copy Chrome bookmarks into Peekr.",
          "将 Cookie 导入 Peekr 的 Chromium Profile，或把 Chrome 书签复制到 Peekr。")
    }
    var webEngineHint: String {
        t("Both engines are bundled. Switching recreates open pages. WebKit isolates site data per app; Chromium uses one persistent profile.",
          "两种内核均已内置。切换时会重建已打开页面。WebKit 按应用隔离站点数据；Chromium 使用一个持久 Profile。")
    }
    var switchEngineTitle: String { t("Switch web engine?", "切换浏览器内核？") }
    func switchEngineMessage(_ engine: String) -> String {
        t("Switch to \(engine)? Open pages will be recreated and unsaved page state may be lost.",
          "切换到 \(engine)？已打开页面将被重建，页面中未保存的状态可能丢失。")
    }
    var switchEngine: String { t("Switch Engine", "切换内核") }
    func engineName(_ kind: WebEngineKind) -> String {
        switch kind {
        case .system: return t("System · WebKit", "系统内核 · WebKit")
        case .chromium: return t("Chromium", "Chromium 内核")
        }
    }
    func engineDetail(_ kind: WebEngineKind) -> String {
        switch kind {
        case .system:
            return t("Apple's built-in engine — fast, light, no download.",
                     "Apple 内置引擎——快、轻、无需下载。")
        case .chromium:
            return t("Bundled Chromium via CefSwift/CEF for maximum site compatibility.",
                     "通过 CefSwift/CEF 内置 Chromium，提供更完整的网站兼容性。")
        }
    }

    var defaultSize: String { t("Default (screen ratio)", "默认（屏幕比例）") }
    func anchorName(_ anchor: PanelAnchor) -> String {
        switch anchor {
        case .left: return t("Left edge", "左侧")
        case .right: return t("Right edge", "右侧")
        case .topLeft: return t("Top-left", "左上角")
        case .topRight: return t("Top-right", "右上角")
        case .bottomLeft: return t("Bottom-left", "左下角")
        case .bottomRight: return t("Bottom-right", "右下角")
        }
    }
    var dockingHint: String {
        t("Hover this edge/corner, or drag the panel by its grip and release near any edge/corner. Snapping changes the slide direction — not the size.",
          "悬停此边缘/角落，或拖动面板抓手并在任意边缘/角落松开。吸附只改变滑出方向，不改变尺寸。")
    }
    var chromeBookmarksUnavailableTitle: String {
        t("Chrome bookmarks not found", "未找到 Chrome 书签")
    }
    var chromeBookmarksUnavailableMessage: String {
        t("Open Chrome once and make sure its Default profile contains bookmarks, then try again.",
          "请先打开一次 Chrome，并确认默认 Profile 中已有书签，然后重试。")
    }
    var chromeBookmarksEmptyTitle: String {
        t("No bookmarks to import", "没有可导入的书签")
    }
    var chromeBookmarksEmptyMessage: String {
        t("Peekr found Chrome's bookmark file but it did not contain importable bookmarks.",
          "Peekr 找到了 Chrome 书签文件，但其中没有可导入的书签。")
    }
    var chromeBookmarksConfirmTitle: String {
        t("Import Chrome bookmarks?", "导入 Chrome 书签？")
    }
    func chromeBookmarksConfirmMessage(_ profile: String) -> String {
        t("Import bookmarks from “\(profile)”? Peekr will add or refresh that Chrome profile's imported folder.",
          "从“\(profile)”导入书签？Peekr 将新增或刷新这个 Chrome Profile 的导入文件夹。")
    }
    var chromeBookmarksImportedTitle: String {
        t("Chrome bookmarks imported", "Chrome 书签已导入")
    }
    var chromeBookmarksImportedMessage: String {
        t("The imported bookmarks are available from Peekr's bookmark panel.",
          "导入的书签现在可以在 Peekr 的书签面板中使用。")
    }
    func appsCount(_ n: Int) -> String { isChinese ? "\(n) 个应用" : "\(n) apps" }

    // About
    var tagline: String { t("A liquid-glass slide-over browser for macOS.", "macOS 上的液态玻璃侧滑浏览器。") }
}
