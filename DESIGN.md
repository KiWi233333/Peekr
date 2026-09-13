---
name: Peekr
version: "1.0"
platform:
  os: [macOS]
  minimumDeployment: "14.0"
  toolkit: [SwiftUI, AppKit, WKWebView, CEF]
  appearance: [light, dark]
  toolchain: "Swift tools 5.10; macOS 26 APIs require compiler 6.2+"
---

# Peekr Design System

这份文档是 Peekr 的项目级视觉与交互契约。它面向实现 UI 的工程师和代码代理，回答“这个 macOS 应用应该怎样呈现和响应”，而 `AGENTS.md` / `CLAUDE.md` 回答“代码应该怎样组织和验证”。

## 设计立场

Peekr 是菜单栏 macOS 应用，不是套着原生窗口的网页。系统行为优先于自定义视觉：使用原生窗口、菜单、快捷键、焦点、文本输入、拖放、材质和可访问性；只有在产品交互确实需要时才自定义。

- 面板是边缘滑出的非激活窗口：可以成为 key window 以便网页输入，但不成为 main window，也不抢走当前应用的前台焦点。
- SwiftUI 负责声明式界面和状态表达，AppKit 只在窗口、指针、拖放、菜单或其他纯 SwiftUI 无法正确表达的边界使用。
- 所有玻璃效果走 `View.liquidGlass(...)` 或 `GlassGroup`; 不在业务视图中直接调用 `glassEffect`、`NSVisualEffectView` 或 `NSGlassEffectView`。
- 所有视觉令牌集中在 `Sources/Peekr/Util/GlassStyle.swift` 的 `Theme`，所有动画令牌集中在 `Sources/Peekr/Util/Motion.swift` 的 `Motion`。
- 所有用户可见文案集中在 `Sources/Peekr/Util/Localization.swift` 的 `Localized`，不得在视图中新增散落的硬编码文案。

Apple Human Interface Guidelines 是平台行为基线；本文件是 Peekr 对它的具体化。若两者冲突，优先采用 macOS 的可用性和可访问性要求，并在本文件记录有意的产品差异。

## 视觉令牌

令牌的实际实现以 `Theme` 和 `Motion` 为准。修改下表中的视觉决策时，同时更新实现和本文件。

### 颜色与材质

| 令牌 | 当前值 / 原语 | 用途 |
| --- | --- | --- |
| `accent` | `Color.primary` | 单色强调；跟随浅色/深色外观 |
| `accentGradient` | `Color.primary` → `primary.opacity(0.62)` | 需要轻微层次的强调表面 |
| `hairline` | `primary.opacity(0.12)` | 细分隔线和 fallback 玻璃边缘 |
| panel material | macOS 26 `glassEffect`；旧系统 `.ultraThinMaterial` / `.sidebar` | 面板、导航和卡片表面 |
| reduced transparency | `controlBackgroundColor` 等不透明系统色 | 用户开启“减少透明度”时的替代材质 |

不要硬编码品牌蓝、纯黑背景或网页阴影。颜色应使用语义系统色，玻璃和窗口阴影由系统材质负责。

### 几何

| 令牌 | 值 | 用途 |
| --- | ---: | --- |
| `railWidth` | 64 pt | 图标栏 |
| `sidebarWidth` | 220 pt | 展开的应用/空间列表 |
| `tile` | 44 pt | 主要图标操作的基础尺寸 |
| `iconCorner` | 10 pt | 图标容器 |
| `tileCorner` | 12 pt | 应用 tile |
| `webCardCorner` | 14 pt | 内嵌网页卡片 |
| `panelCorner` | 18 pt | 面板外轮廓 |

使用连续圆角（`RoundedRectangle(..., style: .continuous)`）并保持从外到内逐级减小的圆角层次。面板吸附改变位置和滑入方向，不改变用户设置的尺寸。

### 动效

动效必须使用 `Motion` 中的令牌，并读取 `accessibilityReduceMotion` 或 `Motion.reduceMotion`。面板滑入、关闭、吸附、侧栏折叠和控件反馈使用短、受控的曲线；简单状态变化不使用夸张弹跳。拖动过程实时跟手，释放后的吸附才使用动画。

## 原生控件与布局

- 优先使用 `Button`、`Menu`、`Toggle`、`Picker`、`Slider`、`TextField` 和系统菜单命令；不要用透明视图重做点击、焦点或键盘行为。
- 普通按钮、列表行和菜单项保留系统箭头指针；手型只表示真正的链接。拖动和缩放使用抓取或 resize 指针，规则见下方指针规范。
- 使用 SF Pro、SF Mono 和 SwiftUI 的语义文本样式；文字必须能随系统文本大小和外观变化保持可读。
- 交互控件提供明确的 hover、pressed、focused、disabled 状态。图标按钮必须有 `help` 和无障碍标签，不能只依靠图标形状传达动作。
- 不为 macOS 窗口手绘网页式标题栏、圆角和阴影；窗口、Popover、Sheet、菜单和交通灯遵循系统行为。
- 需要自定义布局时，先复用 `PanelAnchor`、`PanelGeometry`、`Theme` 等已有单一入口，避免在视图中重复方位判断和魔法数字。

## 状态、焦点与命令

- `@Observable` 的领域模型是状态真相源；视图表达状态，不在 `body` 中放业务逻辑或非平凡副作用。
- 大型 SwiftUI 屏幕拆成有明确输入的子视图，保持稳定的视图树；共享依赖通过环境或显式初始化注入。
- 重要动作必须能从菜单栏、上下文菜单或键盘快捷键触达。Escape 关闭当前弹层或取消当前动作，⌘L、⌘W、⌘1–9 等快捷键保持 macOS 语义。
- 面板显示期间不重复安装边缘触发；拖动、缩放和弹层期间暂停自动隐藏，结束后恢复。
- 地址栏、重命名和偏好设置使用原生文本输入、选区、IME 和焦点行为。网页内容的焦点由 WebView 自己管理。

## 可访问性与本地化

- 支持浅色、深色、增加对比度、减少透明度和减少动态效果；fallback 材质必须提供等价的可读性。
- VoiceOver 能读出每个可操作元素的名称、角色和状态；拖动区和缩放区说明具体动作。
- 不以颜色作为唯一状态信号，不能以固定像素高度截断可缩放文本。
- 中英文文案均通过 `Localized` 提供；新增文案同时补齐两种语言，并考虑较长中文或英文文本对布局的影响。

## AppKit 边界与可用性

- `makePanelBackdrop`、`PointerCursorRegion`、窗口事件和菜单命令是明确的 AppKit 边界；不要把 AppKit 对象泄漏到普通 SwiftUI 子视图的状态层。
- macOS 26 / Xcode 26 专用 API 必须同时具备编译期和运行时保护；macOS 14+ 在旧 SDK 上仍应构建，并回退到系统材质。
- WebKit/CEF 是内容渲染面。浏览器会话、导航状态和窗口生命周期由对应服务管理，视觉视图不直接承担持久化或导航业务逻辑。

## 验收清单

- [ ] 浅色、深色、增加对比度、减少透明度和减少动态效果下均可读、可操作。
- [ ] 普通按钮没有网页式手型；真实拖动、缩放和链接的指针语义正确。
- [ ] 键盘可以到达所有操作，菜单和快捷键与 macOS 预期一致，Escape 有明确行为。
- [ ] VoiceOver 能识别导航、面板、输入框、拖动区和禁用状态。
- [ ] 面板滑入/关闭/吸附不冻结 WebView，拖动时尺寸实时跟手，释放后才吸附。
- [ ] macOS 14 fallback 与 macOS 26 Liquid Glass 均能构建并保持相同的层次和对比度。
- [ ] 新增视觉值已归入 `Theme` / `Motion`，新增文案已归入 `Localized`。
- [ ] UI 修改至少通过 `make build`；窗口、焦点、菜单、外观和辅助功能在 macOS 上进行手动验证。

## 指针规范

版本：2026-09-13  
适用范围：`Sources/Peekr/UI`、`Sources/Peekr/Panel` 中的 SwiftUI / AppKit 控件。

## 目标

指针必须表达当前控件的操作语义。优先使用 macOS 原生指针和控件行为，不用统一的网页式 `pointer` 手势去覆盖所有按钮。指针是辅助提示，不能替代可见状态、`help`、无障碍标签或键盘操作。

## 语义映射

| 控件或区域 | 指针 | 规则 |
| --- | --- | --- |
| 普通按钮、图标按钮、菜单、菜单项、Toggle、Picker、Slider、Stepper、列表行、标签页 | 系统箭头 | 保留 AppKit / SwiftUI 默认行为，不额外显示手型 |
| `TextField`、安全输入框、omnibox、重命名输入框、快捷键录入 | 文本插入符（I-beam） | 使用原生输入控件，不在外层覆盖箭头 |
| 可拖动的导航栏 grip、标签页组、标签页 | 悬停 `openHand`，按住 `closedHand` | 拖动开始前提示“可抓取”，拖动中提示“正在抓取”；拖放由系统拖动反馈继续接管 |
| 侧栏水平分隔条 | `resizeLeftRight` | 命中区贴着浏览器内容边缘，实际布局只预留 1 px；静止时仅保留低对比度细线，悬停时显示短胶囊提示 |
| 面板边缘 | 对应水平或垂直 resize 指针 | 边缘和角落分别使用系统方向指针，拖动实时跟手，释放后再吸附 |
| 面板角落 | `resizeNorthWest`、`resizeNorthEast`、`resizeSouthWest`、`resizeSouthEast` | 只在真实可调整大小的角落生效 |
| 可打开的外部链接或网页链接 | `pointingHand` | 只用于链接语义；应用内普通按钮不使用手型 |
| 禁止拖放、无效操作、禁用控件 | `notAllowed` 或系统禁用反馈 | 仅在用户确实处于无效操作状态时显示，不能用作常态装饰 |

## 实现约束

### Padding

- 默认使用四边一致的 `.padding(value)`，优先使用 4 / 6 / 8 / 12 / 16 的间距级别。
- 同一层级的内容保持相同的上、下、左、右内边距；不要为了补偿单边视觉偏移写出 `leading: 8`、`trailing: 7` 这类不对称值。
- 只有边缘贴合、横向滚动条、固定高度控件或明确的轴向布局，才允许单独使用 `.padding(.horizontal, …)` / `.padding(.vertical, …)`；需要在代码旁说明原因。
- 标签栏使用 12 px 外层留白、4 px 分组内容留白、6 px 标签行内留白；紧凑图标模式也沿用同一间距级别。
- Padding 不能承担点击命中区职责；拖拽和缩放命中区用独立的透明交互层实现，避免视觉占位跟着变宽。

### 自定义指针

- SwiftUI 自定义交互区通过 `PointerCursorRegion`（`Sources/Peekr/UI/PointerCursor.swift`）安装 AppKit cursor rect。
- 使用 cursor rect，不用 `onHover` 中成对调用 `NSCursor.push()` / `pop()`；这样可以让 AppKit 在离开区域、窗口失焦时自动恢复光标。
- 指针层必须不拦截原控件事件；不要在光标层添加第二套点击或拖拽逻辑。
- 拖拽状态变化时更新光标：准备拖拽为 `openHand`，拖动中为 `closedHand`。系统拖放区域仍由 `.draggable` / `.dropDestination` 提供反馈。

### 拖拽与缩放

- 真实拖动区域才显示抓取指针；普通可点击标签页、列表行和按钮保留系统箭头。
- 侧栏分隔条的命中区目标为不超过 8 px，布局占位尽量接近 0；静止时只保留低对比度细线，悬停时显示 3 px 左右、短距离的提示胶囊。
- 连续调整大小使用 AppKit 鼠标事件循环，宽度更新保持 1:1，不给实时值添加隐式动画；释放后才进行阶段吸附或弹性回弹。
- 拖动区域必须提供 `help` 和无障碍标签，说明“移动”“调整大小”或具体方向。

### 原生控件

- Button、Menu、Toggle、Picker、Slider、Stepper 不设置网页式 `cursor: pointer`。
- TextField 和快捷键录入保持原生 I-beam、选区、插入和键盘焦点行为。
- AppKit 原生 context menu 保持系统箭头和菜单反馈，不在菜单容器上叠加自定义手型。
- 禁用状态由控件自身的 disabled 样式和系统指针表达，不用额外的透明覆盖层吞掉事件。
- 自定义 focus 使用黑色、2 px、连续圆角描边，关闭系统蓝色矩形 focus effect；输入框、标签行和重命名控件必须保持圆角一致。

## 当前控件审计

| 区域 | 文件 | 结论 |
| --- | --- | --- |
| 面板边缘和角落缩放 | `UI/PanelRootView.swift` | 已使用 AppKit 缩放指针；静止时不显示宽条 |
| 侧栏分隔条 | `UI/PanelRootView.swift` | 已贴着浏览器内容边缘，命中 8 px、布局占位 1 px，静止细线 / 悬停胶囊 |
| 面板空白区域移动窗口 | `UI/PanelRootView.swift` | 已补充 `openHand` / `closedHand`；控件自身优先接收点击 |
| 导航栏移动 grip | `UI/NavigationBar.swift` | 已补充 `openHand` / `closedHand` |
| 标签页组、标签页拖动 | `UI/AppRail.swift` | 已补充悬停 `openHand`；系统拖放负责按住后的拖动反馈 |
| 标签栏 spacing / padding | `UI/AppRail.swift` | 外层 12 px、分组 4 px、行内 6–8 px；固定高度控件的轴向 padding 保留明确例外 |
| 标签行、输入框和候选项 focus | `UI/AppRail.swift`、`UI/NavigationBar.swift`、`UI/TabGroupContextMenu.swift` | 使用黑色连续圆角 focus ring，去除默认蓝色矩形效果 |
| 侧栏折叠、空间、刷新、书签等操作 | `UI/AppRail.swift`、`UI/NavigationBar.swift` | 保留原生箭头，不伪装为链接 |
| omnibox、重命名、偏好设置和导入表单 | `UI/NavigationBar.swift`、`UI/PreferencesView.swift`、`UI/*Sheet.swift` | 保留原生文本插入符和表单控件行为 |
| 空间概览、菜单和上下文菜单 | `UI/SpacesOverview.swift`、`UI/AppRail.swift` | 使用原生菜单 / 按钮指针语义 |

## 新控件验收清单

- [ ] 先判断控件是点击、输入、拖动、缩放、链接还是无效状态，再选择对应指针。
- [ ] 普通按钮和菜单没有为了“更像网页”而强制手型。
- [ ] 自定义拖动 / 缩放区域拥有窄命中区、可见的悬停反馈、`help` 和无障碍名称。
- [ ] 光标层不拦截点击、拖放、键盘焦点或 context menu。
- [ ] 默认 padding 四边一致；任何单轴 padding 都有明确布局原因。
- [ ] focus ring 使用黑色圆角描边，不出现默认蓝色矩形框或直角边。
- [ ] 拖动时实时状态不使用会造成滞后的隐式动画；释放后的吸附动画单独验证。
- [ ] 同时用鼠标、触控板和键盘检查；指针不应成为唯一的操作提示。
