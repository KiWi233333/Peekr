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
    var customColor: String { t("Custom Color…", "自定义颜色…") }
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
    var importSessionMode: String { t("Chrome Session", "Chrome 会话") }
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
    var readChromeSession: String { t("Read Chrome Session", "读取 Chrome 会话") }
    var rereadChromeSession: String { t("Read Again", "重新读取") }
    var chromeSessionHint: String {
        t("Reads Chrome's latest session snapshot, including open tabs, tab groups, pinning and the active tab. Chrome can stay open.",
          "读取 Chrome 最近的会话快照，包括打开的标签、标签组、固定状态和活动标签。Chrome 可以保持打开。")
    }
    func chromeSessionSummary(windows: Int, tabs: Int, groups: Int) -> String {
        if isChinese {
            return "发现 \(windows) 个窗口、\(tabs) 个标签和 \(groups) 个标签组。"
        }
        return "Found \(windows) windows, \(tabs) tabs and \(groups) tab groups."
    }
    func importChromeSessionResult(windows: Int, tabs: Int, groups: Int) -> String {
        if isChinese {
            return "已导入 \(windows) 个窗口中的 \(tabs) 个标签和 \(groups) 个标签组。"
        }
        return "Imported \(tabs) tabs and \(groups) tab groups from \(windows) windows."
    }
    var importingChromeSession: String { t("Importing Chrome session…", "正在导入 Chrome 会话…") }
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

    // Unified browser-data import
    var importBrowserLabel: String { t("Browser", "浏览器") }
    var importButton: String { t("Import", "导入") }
    var importRunning: String { t("Importing…", "正在导入…") }
    var importUnsupported: String { t("Not supported", "暂不支持") }
    var importNoBrowsers: String {
        t("No importable browser was found on this Mac.",
          "未发现可导入的浏览器。")
    }
    var importOptionBookmarks: String { t("Bookmarks", "书签") }
    var importOptionOpenTabs: String { t("Open Tabs", "打开的标签页") }
    var importOptionCookies: String { t("Session Cookies", "Session Cookie") }
    var importOptionSession: String { t("Session (windows & tab groups)", "会话（窗口与标签组）") }
    var importOptionBookmarksHint: String {
        t("Read the browser's bookmark file, keeping folder structure.",
          "读取浏览器书签文件，保留文件夹结构。")
    }
    var importOptionOpenTabsHint: String {
        t("Read the tabs open right now through Automation.",
          "通过自动化读取当前打开的标签页。")
    }
    var importOptionCookiesHint: String {
        t("Decrypt Chrome cookies and write them to Peekr's local Chromium profile.",
          "解密 Chrome Cookie 并写入 Peekr 本地 Chromium Profile。")
    }
    var importOptionSessionHint: String {
        t("Read Chrome's latest session: tabs, tab groups, pinning and the active tab.",
          "读取 Chrome 最近的会话，含标签、标签组、固定状态和活动标签。")
    }
    func importBookmarksDone(count: Int, browser: String) -> String {
        t("Imported \(count) bookmarks from \(browser).",
          "已从 \(browser) 导入 \(count) 个书签。")
    }
    func importBookmarksUnavailable(_ browser: String) -> String {
        t("No \(browser) bookmark file was found.",
          "未发现 \(browser) 的书签文件。")
    }
    func importBookmarksEmpty(_ browser: String) -> String {
        t("\(browser) has no bookmarks to import.",
          "\(browser) 没有可导入的书签。")
    }
    func importOpenTabsDone(count: Int, browser: String) -> String {
        t("Imported \(count) open tabs from \(browser).",
          "已从 \(browser) 导入 \(count) 个打开的标签页。")
    }
    func importOpenTabsEmpty(_ browser: String) -> String {
        t("No open \(browser) tabs were found. Make sure \(browser) is running, and allow Automation access when prompted.",
          "未发现 \(browser) 打开的标签页。请确认 \(browser) 正在运行，并在提示时允许自动化访问。")
    }
    var importSessionEmpty: String {
        t("No Chrome session snapshot was found.",
          "未发现 Chrome 会话快照。")
    }
    var open: String { t("Open", "打开") }
    var downloads: String { t("Downloads", "下载") }
    var noDownloads: String { t("No downloads yet", "暂无下载") }
    var downloadInProgress: String { t("Downloading…", "下载中…") }
    var downloadComplete: String { t("Completed", "已完成") }
    var downloadCanceled: String { t("Canceled", "已取消") }
    var downloadFailed: String { t("Failed", "失败") }
    var cancelDownload: String { t("Cancel download", "取消下载") }
    var openDownloadedFile: String { t("Open file", "打开文件") }
    var showDownloadedFile: String { t("Show in Finder", "在 Finder 中显示") }
    var openDownloadsFolder: String { t("Open Downloads folder", "打开下载文件夹") }
    var searchDownloads: String { t("Search downloads", "搜索下载") }
    var noMatchingDownloads: String { t("No matching downloads", "没有匹配的下载") }
    var clearCompletedDownloads: String { t("Clear finished", "清除已结束") }
    var edit: String { t("Edit…", "编辑…") }
    var refreshIconAndTitle: String { t("Refresh Icon & Title", "刷新图标和标题") }
    var delete: String { t("Delete", "删除") }
    var close: String { t("Close", "关闭") }
    var dragHint: String { t("Drag to move • release near an edge or corner to snap", "拖动移动 • 在边缘或角落松开自动吸附") }
    var newTab: String { t("New Tab", "新建标签") }
    var rename: String { t("Rename", "重命名") }
    var closeTab: String { t("Close Tab", "关闭标签") }
    var pinTab: String { t("Pin Tab", "固定标签") }
    var unpinTab: String { t("Unpin Tab", "取消固定标签") }
    var muteTab: String { t("Mute Tab", "静音标签") }
    var unmuteTab: String { t("Unmute Tab", "取消标签静音") }
    var mutedTab: String { t("Muted", "已静音") }
    var closeOtherTabs: String { t("Close Other Tabs", "关闭其他标签") }
    var closeTabsToRight: String { t("Close Tabs to the Right", "关闭右侧标签") }
    var duplicateTab: String { t("Duplicate Tab", "复制标签") }
    var newTabGroup: String { t("New Tab Group", "新建标签组") }
    var tabGroup: String { t("Tab Group", "标签组") }
    var newTabInGroup: String { t("New Tab in Group", "在组中新建标签") }
    var moveToGroup: String { t("Move to Group", "移到标签组") }
    var removeFromGroup: String { t("Remove from Group", "移出标签组") }
    var duplicateGroup: String { t("Duplicate Group", "复制标签组") }
    var ungroup: String { t("Ungroup", "解散标签组") }
    var closeGroup: String { t("Close Group", "关闭标签组") }
    var groupColor: String { t("Group Color", "标签组颜色") }
    var reopenClosedTab: String { t("Reopen Closed Tab", "重新打开关闭的标签") }
    var collapseGroup: String { t("Collapse Group", "折叠标签组") }
    var expandGroup: String { t("Expand Group", "展开标签组") }
    var collapseSidebar: String { t("Collapse Sidebar", "折叠侧栏") }
    var expandSidebar: String { t("Expand Sidebar", "展开侧栏") }
    var newWorkspace: String { t("New Workspace", "新建工作区") }
    var profile: String { t("Profile", "Profile") }
    var profiles: String { t("Profiles", "Profiles") }
    var chooseProfile: String { t("Choose Profile", "选择 Profile") }
    var newProfile: String { t("New Profile", "新建 Profile") }
    var renameProfile: String { t("Rename Profile", "重命名 Profile") }
    var archiveProfile: String { t("Archive Profile", "归档 Profile") }
    var profileName: String { t("Profile name", "Profile 名称") }
    var keepAwake: String { t("Keep Awake", "保持唤醒") }
    var allowSleep: String { t("Allow Sleep", "允许休眠") }
    var sleepPage: String { t("Sleep Page", "休眠页面") }
    var wakePage: String { t("Wake Page", "唤醒页面") }
    var spaces: String { t("Spaces", "工作区") }
    var openSpaces: String { t("Open Spaces", "打开工作区") }
    var defaultWorkspace: String { t("Workspace", "工作区") }
    var newAgentWorkspace: String { t("New Agent Space", "新建 Agent 工作区") }
    var defaultAgentWorkspace: String { t("Agent Space", "Agent 工作区") }
    var agentSpaceBadge: String { t("Agent-owned space", "Agent 专属工作区") }
    var takeOverWorkspace: String { t("Take Over Space", "接管此工作区") }
    var pinWorkspace: String { t("Pin Workspace", "置顶工作区") }
    var unpinWorkspace: String { t("Unpin Workspace", "取消置顶工作区") }
    var moreActions: String { t("More Actions", "更多操作") }
    var reorderWorkspaces: String { t("Drag cards to reorder", "拖动卡片调整顺序") }
    var resizeHint: String { t("Drag to resize", "拖动调整大小") }

    // Omnibox
    var omniboxPlaceholder: String { t("Search or enter address", "搜索或输入网址") }
    var pasteAndGo: String { t("Paste and Go", "粘贴并访问") }
    var pasteAndSearch: String { t("Paste and Search", "粘贴并搜索") }
    func searchWith(_ engine: SearchEngine) -> String {
        t("Search with \(engine.displayName)", "使用 \(engine.displayName) 搜索")
    }

    // Page context menu
    var reload: String { t("Reload", "重新加载") }
    var inspect: String { t("Inspect", "检查") }
    var openLinkInNewTab: String { t("Open Link in New Tab", "在新标签页中打开链接") }
    var copyLinkAddress: String { t("Copy Link Address", "复制链接地址") }
    var openImageInNewTab: String { t("Open Image in New Tab", "在新标签页中打开图片") }
    var copyImageAddress: String { t("Copy Image Address", "复制图片地址") }
    func searchSelection(_ engine: SearchEngine, for selection: String) -> String {
        t("Search \(engine.displayName) for \"\(selection)\"", "用 \(engine.displayName) 搜索“\(selection)”")
    }

    // Find in page
    var findInPage: String { t("Find in page", "在页面中查找") }
    var findPrevious: String { t("Previous match", "上一个匹配") }
    var findNext: String { t("Next match", "下一个匹配") }

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
    var pageLoadErrorTitle: String { t("This page can’t be loaded", "此页面无法加载") }
    var rendererFailureTitle: String { t("This page stopped responding", "此页面已停止响应") }
    var rendererFailureMessage: String {
        t("The page process stopped unexpectedly. Reload the page to try again.",
          "页面进程意外停止。重新加载页面后再试一次。")
    }
    var retry: String { t("Retry", "重试") }
    var back: String { t("Back", "返回") }
    func pageLoadErrorMessage(_ error: WebLoadFailure) -> String {
        t("Peekr could not load this page.\n\(error.diagnostic)",
          "Peekr 无法加载此页面。\n\(error.diagnostic)")
    }
    var searchEngineSection: String { t("Search", "搜索") }
    var defaultSearchEngine: String { t("Default search engine", "默认搜索引擎") }
    var searchEngineHint: String {
        t("Address-bar searches and new tabs use this engine. Existing tabs are not changed.",
          "地址栏搜索和新建标签页会使用此引擎；已有标签页不会被更改。")
    }
    var chromeDataSection: String { t("Chrome Data", "Chrome 数据") }
    var chromeDataHint: String {
        t("Import cookies into Peekr's Chromium profile or copy Chrome bookmarks into Peekr.",
          "将 Cookie 导入 Peekr 的 Chromium Profile，或把 Chrome 书签复制到 Peekr。")
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

    // Agent access
    var agentAccessSection: String { t("Agent Access", "Agent 接入") }
    var agentAccessToggle: String { t("Allow AI agents to drive Chromium pages", "允许 AI Agent 驱动 Chromium 页面") }
    var agentAccessPort: String { t("Debug port", "调试端口") }
    var agentAccessHint: String {
        t("Exposes Peekr's Chromium pages to local AI agents over the DevTools protocol (localhost only). Built on the Chromium engine; takes effect after relaunch. Any local process could attach while enabled — turn it on only when an agent needs it.",
          "通过 DevTools 协议把 Peekr 的 Chromium 页面暴露给本机 AI Agent（仅 localhost）。基于 Chromium 内核，重启后生效。开启期间本机任意程序都可连接——只在需要时打开。")
    }
    var agentAccessRelaunchHint: String {
        t("Takes effect after you quit and reopen Peekr.", "退出并重新打开 Peekr 后生效。")
    }
    var agentDiscoveryPath: String { t("Discovery file", "发现文件") }
    var agentAccessInstallCLI: String { t("Command line tool for AI agents", "面向 AI Agent 的命令行工具") }
    var installAction: String { t("Install…", "安装…") }
    var cliInstallDoneTitle: String { t("Command line tool installed", "命令行工具已安装") }
    func cliInstallDoneMessage(_ path: String) -> String {
        t("The `peekr` command is now available at \(path). AI agents can run `peekr doctor` to connect.",
          "`peekr` 命令已安装到 \(path)。AI Agent 运行 `peekr doctor` 即可连接。")
    }
    var cliInstallFailedTitle: String { t("Command line tool not installed", "命令行工具未安装") }
    var cliInstallMissingBundle: String {
        t("The peekr harness was not found in the app bundle. Reinstall Peekr or build it with npm available.",
          "应用包内没有找到 peekr 工具。请重新安装 Peekr，或在装有 npm 的环境重新构建。")
    }

    // About
    var tagline: String { t("A liquid-glass slide-over browser for macOS.", "macOS 上的液态玻璃侧滑浏览器。") }
}
