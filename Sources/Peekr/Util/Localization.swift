import Foundation

/// UI language. `.system` follows the OS; otherwise an explicit override.
enum AppLanguage: String, Codable, CaseIterable, Identifiable {
    case system, english, chinese
    var id: String { rawValue }

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
    var pinOpen: String { t("Pin Open", "固定常开") }
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
    var importOpenTabs: String { t("Import Open Tabs…", "导入打开的标签…") }
    var importTitle: String { t("Import Open Tabs", "导入打开的标签") }
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
    var apps: String { t("Apps", "应用") }
    var about: String { t("About", "关于") }
    var docking: String { t("Docking", "停靠") }
    var panel: String { t("Panel", "面板") }
    var shortcutStartup: String { t("Shortcut & Startup", "快捷键与启动") }
    var width: String { t("Width", "宽度") }
    var height: String { t("Height", "高度") }
    var defaultWidth: String { t("Default width", "默认宽度") }
    var defaultHeight: String { t("Default height", "默认高度") }
    var panelSizeHint: String {
        t("Default size for apps you haven't resized yet. Drag a panel's edge to remember a size per app.",
          "尚未单独调整尺寸的应用的默认大小。拖动面板边缘即可为单个应用单独记忆尺寸。")
    }
    var hoverDelay: String { t("Hover delay", "悬停延迟") }
    var edgeSensitivity: String { t("Edge sensitivity", "边缘灵敏度") }
    var autoHide: String { t("Auto-hide when the cursor leaves", "光标离开时自动隐藏") }
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
    var defaultSize: String { t("Default (screen ratio)", "默认（屏幕比例）") }
    var dockingHint: String {
        t("Hover this edge/corner, or drag the panel by its grip and release near any edge/corner. Snapping changes the slide direction — not the size.",
          "悬停此边缘/角落，或拖动面板抓手并在任意边缘/角落松开。吸附只改变滑出方向，不改变尺寸。")
    }
    func appsCount(_ n: Int) -> String { isChinese ? "\(n) 个应用" : "\(n) apps" }

    // About
    var tagline: String { t("A liquid-glass slide-over browser for macOS.", "macOS 上的液态玻璃侧滑浏览器。") }
}
