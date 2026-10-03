# Agent 浏览器能力进度与验证（2026-09-27）

后续增量见 [交互与生命周期完善](agent-browser-progress-2026-09-27-interactions.md)。以下是上一轮基础闭环的历史记录。

本轮完成 **TaskSpace / Page 基础操作与归属闭环**。源码构建已在独立 CEF 应用副本验证，尚未覆盖全部规划功能，也未替换用户安装的应用。执行清单见 [实施计划](plan-agent-browser-replica.md)。

## 已实现的行为

| 能力 | 当前行为 | 主要实现 |
|---|---|---|
| 原生页面归属 | 仅原生桥接显式创建并绑定的 target 属于 agent；不按 URL、全局 target 顺序或当前空间猜测 | `AgentTargetSync.swift`、`AgentControlServer.swift` |
| 原生视图复用 | 后台创建使用 WebViewManager 缓存引擎，bringToFront 展示同一页面；支持 create/list/close/activate | `WebViewManager.swift`、`AppDelegate.swift` |
| TaskSpace / Page | `taskSpace(nameOrId).page(label)` 绑定空间和标签，支持导航、观察、基础输入、等待、evaluate/CDP | `cli/src/page-model.ts` |
| 标签生命周期 | 按浏览器 generation 对账；跨 CLI 进程稳定；关闭/失效标签不自动重用；重启明确报 stale | `cli/src/page-ledger.ts` |
| 跨轮元素引用 | Page 方法按空间、target、generation、URL/timeOrigin 恢复最近 snapshot refs；导航和 reload 清理 | `cli/src/page-refs.ts` |
| 轮次互斥 | 每浏览器一个 CLI 进程持锁，完整 helper FIFO；忙时明确拒绝；进程崩溃后回收死锁文件 | `cli/src/round.ts` |
| 用户接管 | 每次 CDP 派发前检查 native ownership/target；handoff 后本轮不能继续操作其他空间；catch 不吞掉 hard stop | `driver/spaces.ts`、`driver/nav.ts` |
| 任务完成 | finish 关闭 managed scratch，按 label 保留结果页并交给用户；始终保留 unmanaged/user tabs | 原生 `finish`、`completeSpace` |
| 传输失败 | 断线拒绝 pending 请求/事件；初始化失败关闭 socket；不重放写操作；SIGINT 退出 130 并释放租约 | `cli/src/cdp.ts`、`index.ts` |
| 导航竞态 | goto 等待对应 loader；reload 等待新 loader 后再验证完成，避免返回旧文档 | `page-model.ts`、`driver/nav.ts` |

原生桥接是支持的 API 的归属事实源。CLI 不再提供 CDP-only 降级或浏览器级 Target 生命周期旁路。Node 脚本仍是可信代码；该设计不是沙箱，空间也共享浏览器 profile/cookie。

## 自测结果

| 检查 | 结果 | 覆盖与边界 |
|---|---|---|
| TypeScript typecheck | PASS | `cd cli && npm run typecheck` |
| CLI 测试 | PASS：38 项 | 原有入口/ledger，加上跨空间隔离、hard stop、标签失效、串行队列、断线取消、进程租约、SIGINT、初始化期间接管清理 |
| Swift 测试 | PASS：124 XCTest + 5 Swift Testing | 含新增的原生归属、接管及 finish 保留测试 |
| 真实 CEF | PASS：8 组场景 | 独立应用、临时数据目录、loopback fixture；无真实账号登录或外网站点验收 |
| 截图检查 | PASS | fixture 标题、输入值和点击后的结果文本可见；不代表完整 UI 视觉验收 |
| Git 差异检查 | PASS | `git diff --check`；未提交、未推送 |
| GitNexus 影响检查 | 已执行，CRITICAL | 公共守卫/传输影响大，结果含用户既有 UI WIP；不等于仅本轮改动的风险评级。新文件另行检查 |

Swift 全量回归曾在两项 `IconStoreTests` 失败：图标解析器已注入，但页面 HTML 仍走公网且测试只等一秒。本轮用 URLProtocol 拦截专用 `.peekr-icon.test` 域名，保留真实 load、并发合并和落盘路径；不修改生产图标代码。修复后全量通过。

真实 CEF 脚本：`scripts/smoke-agent-browser.mjs`。传入包含 CEF Framework 的 Debug `.app` 路径：

```sh
node scripts/smoke-agent-browser.mjs /absolute/path/to/Debug/Peekr.app
```

脚本输出 `artifacts` 目录，包含 `result.json`、`page.png` 和隔离应用日志。它验证：

1. 原生创建 → 导航 → 填写 → 点击 → 条件等待 → snapshot → screenshot。
2. 新 CLI 进程复用相同 label/target 与页面状态。
3. 跨轮 refs，以及 bringToFront 后仍操作同一页面。
4. 同 URL 的两个空间保持独立，原生拒绝跨空间关闭。
5. handoff 后原生和 CLI 都停止，捕获异常也不能输出成功。
6. 显式 resume、reload 切换文档、finish 仅清理 managed pages。
7. finish keep 只保留指定结果页并移交用户。
8. 重启同一隔离 profile 后旧标签明确失效，不认领恢复的用户 tab。

## 仍未对齐

- W2：完整 frame/OOPIF session 映射、target 重建迁移、markError、tab budget；当前跨进程执行按整个浏览器串行，未提供 page 并行。
- W3：goBack/goForward、networkidle、完整导航/事件 epoch、popup/dialog/download/filechooser/network 事件 API。
- W4：完整 locator/actionability、组合键、dragAndDrop、check/select/files 等高级交互。
- W5–W7：完整高级 CDP/fetch、站点能力、安全与发布验收。支持域内 raw CDP 不等于这些功能已形成稳定契约。
- 同轮断线自动重连未提供；应检查结果后新开轮次。Page 的 refs 可跨进程恢复，旧 flat helpers 仍需每轮重新 snapshot。
- `takeOverTaskSpace` 等旧别名返回 space 元数据；需再用 `taskSpace(id)` 获取 Page 外观。未宣称完整外部 API 类型兼容。

后续先补 W2 剩余生命周期与 frame 身份，再扩展 W3–W4 的可靠等待和交互覆盖。已通过的隔离自测脚本作为后续回归入口。
