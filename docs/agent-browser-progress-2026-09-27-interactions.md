# Agent 浏览器能力对齐：交互与生命周期增量（2026-09-27）

本轮在 [TaskSpace / Page 基础闭环](agent-browser-progress-2026-09-27.md) 上补齐常用交互和 Swift 生命周期边界。对照仓库内固定的参考版本 0.5.0.32 API 资料，不宣称完整兼容或全部完成。

## 新增与修正

| 能力 | 可用行为 | 主要代码 |
|---|---|---|
| 历史导航 | `goBack/goForward` 支持文档与 pushState 历史；边界返回 null，不进入创建时的内部 marker 页 | `cli/src/driver/history.ts` |
| 表单 | `clear/check/uncheck/setChecked/selectOption/setInputFiles`；勾选幂等，选择支持 value/label/index 与 multiple | `cli/src/driver/forms.ts`、`keyboard.ts` |
| 文件输入 | 可对隐藏 file input 设置实际文件或用空数组清空；缺失、目录、单选输入传多文件均拒绝 | `forms.ts` |
| 键盘 | portable ControlOrMeta、Cmd/Ctrl/Alt/Shift 组合键、大小写无关的命名键、逐字输入与 delay | `key-chords.ts`、`keyboard.ts` |
| 严格定位 | CSS/role/href/XPath 匹配多个元素时拒绝；修复 loc= 前缀；CSS/role 可穿透 open shadow root | `locator.ts` |
| 操作前检查 | click/fill 自动滚动，拒绝隐藏、禁用、遮挡、脱离 DOM；fill 拒绝只读和非文本控件 | `element-scripts.ts`、`keyboard.ts` |
| 同源 iframe | 嵌套坐标累加；修正无 ID 元素的 CSS 路径；refs 记录子文档 URL/timeOrigin，导航后拒绝旧引用 | `frames.ts`、`observe.ts`、`locator.ts` |
| TaskSpace API | claimTaskSpace/takeOverTaskSpace 返回可调用 page() 的 handle；ownership 快照；finish 支持 keep: 'all' | `page-model.ts` |
| 原生预算 | 每空间最多 8 个 managed page，超额在创建前返回 PEEKR_TAB_LIMIT；关闭页面恢复额度 | `AgentTargetSync.swift` |
| 原生生命周期 | finish 全程互斥；每次 await 后重验归属；转移到别处的 tab 不再属于旧空间；停止或取消创建不能注册新 target | `AgentTargetSync.swift` |
| 失败清理 | 原生 socket 取消处理、键盘失败释放已按下键、底层 hard stop 立即锁住本轮 | `AgentCDPClient.swift`、`keyboard.ts`、`nav.ts` |

真实 CEF 验证发现：`DOM.setFileInputFiles(files: [])` 返回成功但不清空。现在空数组使用文件输入允许的 value 清空并派发 input/change，随后回读 files 数量；设置非空文件仍走 CDP。

## 验证记录

| 检查 | 结果 |
|---|---|
| `cd cli && npm run typecheck` | PASS |
| `cd cli && npm test` | PASS：43 项 |
| `swift test` | PASS：129 项 XCTest + 5 项 Swift Testing |
| 真实 CEF 隔离自测 | PASS：16 组场景，含原有 8 组和本轮交互、页数预算、keep all |
| Swift 格式检查 | PASS：本轮 Agent 生产文件与新增原生测试；使用 `scripts/agent-swift-format.json` |
| `swift build -Xswiftc -strict-concurrency=complete` | 构建成功；Agent 文件无警告，原有 GlobalHotKey.shared 与 SpacesMorphModifier.Animatable 两项 Swift 6 迁移警告仍在 |
| `git diff --check` | PASS |
| GitNexus | 已重建索引、执行编辑前 upstream impact 和收尾 detect_changes(scope: 'all')；公共 guard/locator 为 CRITICAL 范围，结合专项测试核验 |

收尾变更分析包含此前已有 WIP，共涉及 38 个已跟踪变更文件，整体风险为 CRITICAL；该计数不是本轮独立改动量，也不包含未跟踪新文件。索引提示跨语言引用和执行流截断限制，因此图分析仅辅助定位，结论仍以源码核对和上述测试为依据。基线指纹核对确认此前已有的 Makefile、浏览器 UI 等无关 WIP 保持不变。

Swift 并发治理遵循指定的 swift-development：保留 MainActor 上的 UI/model 状态，不引入 unchecked Sendable；考虑 await 重入，原生收尾持有整个操作的互斥状态；显式检查取消并关闭在途 socket。AgentTargetSync 与 AgentCDPClient 都保持在 300 行以内，新功能分离到独立模块。

移除已无生产调用的 URL 相等猜测辅助代码和旧 frame 坐标/聚焦路径。本轮未改动用户已有 Makefile 与浏览器 UI WIP，未提交、推送或覆盖已安装应用。

复现命令：

```sh
cd cli && npm run typecheck && npm test
cd .. && swift test
xcrun swift-format lint --strict --configuration scripts/agent-swift-format.json \
  Sources/Peekr/Agent/AgentTargetSync.swift \
  Sources/Peekr/Agent/AgentCDPClient.swift \
  Tests/PeekrTests/AgentTargetSyncTests.swift
node scripts/smoke-agent-browser.mjs /absolute/path/to/Debug/Peekr.app
```

最后一次真实运行目录：`/var/folders/wb/nf4mv4ks7bb5bmmd3hh6zx0c0000gn/T/peekr-agent-smoke-1GDpSM`。其中 result.json 保存断言场景，page.png/interactions.png 是测试页面截图。脚本只启动与关闭自己的应用进程，使用独立 profile 和 loopback fixture。

## 尚未覆盖

- 完整跨域 frame/OOPIF、target 重建迁移、userPage/adopt/release 和任务错误状态。
- networkidle、完整网络/弹窗/dialog/download/filechooser 事件；已有文件输入操作不等于文件选择器拦截或下载支持。
- 浏览器自动化风格的 locator 对象、动画稳定性、自动等待重试、拖拽、keyboard down/up、剪贴板。当前 actionability 为派发前检查，不能消除网页在检查后立即变化的竞态。
- TaskSpace.pages 仍返回现有页面元数据，finish 仍返回 done/closed 元数据；未对齐外部参考的全部返回类型。
- 验证覆盖固定本地场景和现有单元测试，未进行外网站点、真实账号、全部 UI 视觉验收或发布验证。
