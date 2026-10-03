# Goal：peekr-cli + 浏览器语义化结构化 Snapshot

> 本文档保留最初的开发目标和设计假设，不能作为当前功能清单或直接执行的实施指令。
> 状态：部分实现、后续工作仍在进行 · 分支基线：`kiwi/feat/browser-use` · 参考：同类 Agent 浏览器实现。
> 当前可用 API 以 [peekr-cli Skill](../skills/peekr-cli/SKILL.md) 为准；已验证范围与未覆盖项见
> [基础闭环](agent-browser-progress-2026-09-27.md)、
> [交互与生命周期增量](agent-browser-progress-2026-09-27-interactions.md) 和
> [实施计划](plan-agent-browser-replica.md)。下文的里程碑与验收标准是原始目标，并不表示全部已完成。

## 1. 一句话目标

给 Peekr 造一个对 AI Agent 友好的命令行接入层 **`peekr-cli`**，核心能力是 **语义化结构化页面 Snapshot**——按照参考实现的交互形态，任何 agent CLI 都可以通过一条 heredoc 驱动 Peekr 的 Chromium 页面：观察（snapshot）→ 定位（@N / loc=）→ 行动（click/fill/js/cdp）→ 回报，全程复用用户登录态、不打扰用户。

## 2. 已有地基（不要重做）

| 已落地 | 位置 | 说明 |
|---|---|---|
| CDP 端口开关 | `PeekrApp.makeCefConfiguration` | 偏好设置 opt-in，`CefConfiguration.remoteDebuggingPort`（默认 9223，重启生效） |
| 发现文件 | `Util/AgentDiscovery.swift` | `~/Library/Application Support/Peekr/agent.json` = `{schemaVersion, port, pid}` |
| 任务空间所有权 | `Model/Workspace.swift` + `AppModel` | 三态 `user/agent/agentDelegatedToUser`、`agentOwner`、`takeOverWorkspace`（单向接管） |
| rail 接管 UI | `UI/AppRail.swift` | ✨ 徽标、新建 Agent 工作区、接管菜单 |
| Chromium-first 决策 | 早期路线图（历史） | Agent 接入只走 Chromium/CDP；共享全局 Profile 的登录态继承是有意设计 |

## 3. 参考行为拆解（本地调研结论，写码时直接引用）

### 3.1 参考实现的分层（重要：我们能复用什么、不能复用什么）

- **内核层**：snapshot 由定制 Chromium 在引擎内生成，这是 iframe/shadow DOM 质量的重要来源。**Peekr 使用 CEF 二进制分发，无法修改内核，因此 snapshot 落在 harness 层由 CDP 生成。**
- **开源 harness 层**（本地参考源码快照，MIT）：
  - snapshot 接口就一行：`snapshot({scope, includeActionMarks, includeStableLocator}) → {content, refs}`；`refs` 基于 **CDP backendNodeId**（跨调用稳定）。
  - TS 单文件打包（esbuild+rollup → `dist/out/index.js`），通过 Node heredoc 执行，"一次 heredoc 一轮"。
  - driver 分层：`nav / observe / pointer / keyboard / locator / waits / screencast / downloads / files / element-ops`；`ref-map.ts`/`ref-state.ts` 管 ref 生命周期（每次 snapshot 重建，@N 只在最近一次 snapshot 有效）。
  - 错误契约 `error-contract.ts`：稳定错误码 + **hard-stop 语义**（被 agent 的 try/catch 吞掉也留痕到 output-sink；替换文案为固定话术：禁重试、只可询问用户）。
- **格式与定位子句**（本地 API 资料 + `locator-query.ts`）：
  - 行语法：`@N [role] "accessible name"`；快照含页面标题与 URL、可见文本结构、可交互元素；整页 200–400 tokens。
  - `scope`: `full_page`（默认）/ `only_within_viewport`。
  - 稳定定位 `loc=` 前缀：`css:`、`xpath=`、`href:`、`role:<role>[name=<name>]`、`internal:<kind>:<url-encoded-json>`。
  - ref 临时性：导航/刷新/弹窗/tab 切换/重渲染后失效，要求 agent「每次变更后重新 snapshot」。
  - 已知弱项（文档自述）：离屏内容、图片内文字、复杂 canvas、跨域 sandbox iframe 可能不全 → 回退截图/文本抽取。
- **分发**：app bundle `Resources/agent-skills/`（SKILL.md + references + scripts）+ onboarding 把 CLI 注册到 `~/.local/bin`；安装脚本 `scripts/install.sh` 负责安装和验活。

### 3.2 Peekr 与参考实现的差异（写进设计的）

| 维度 | 参考实现 | Peekr 方案 |
|---|---|---|
| snapshot 生成 | 内核内（闭源） | harness 层：CDP `Accessibility.getFullAXTree`（或 `DOMSnapshot.captureSnapshot` 补可见性/坐标）逐帧采集 + **OOPIF 子 target 合并**（跨域 iframe 在 Chromium 是独立 target，枚举 frame targets 后归并输出） |
| 空间隔离 | 同浏览器内分区（原生） | Workspace（已有）+ app 侧桥接（见 M3） |
| 登录态 | 继承用户 | 继承用户（共享全局 Profile，已有） |
| 发现 | 安装即知 | `agent.json`（已有）；app 未开 Agent 接口时 CLI 报稳定错误码 |

## 4. 交付物与里程碑

### M1 — CLI 骨架 + snapshot（核心，先做）
1. 新仓库目录 `cli/`（TS，Node ≥22，esbuild 单文件 → `dist/peekr.js`，bin: `peekr`）。结构参考 agent-browser-harness：`src/state.ts`、`src/cdp.ts`（WebSocket 连 `agent.json` 的 port，`/json` 枚举 target）、`src/driver/{nav,observe,pointer,keyboard,locator,waits}.ts`、`src/errors.ts`。
2. `peekr nodejs <<'EOF' … EOF` heredoc 运行时，首批 helper：`openOrReuseTab / listTabs / switchTab / gotoAndWait / snapshotText / snapshotRaw / click / fillInput / pressKey / scrollBy / js / cdp / screenshot / wait / waitForLoad / cliLog`。
3. **`snapshotText()`**：默认 `full_page`；实现 = 每 frame target 的 AX 树 → 压缩为参考格式：
   - 首行块：`Page: <title>\nURL: <url>`；
   - 元素行：`@N [role] "name" [loc=… ] [url=… ]`，按树缩进；可交互元素（link/button/input/select/textarea/contenteditable）必须带 `@N`；
   - `loc=` 生成优先级 `role:name` → `css:`（稳定 id/name/data-testid 优先）→ `href:`；
   - `refs` 用 backendNodeId，重建策略采用每次 snapshot 重建 refMap；
   - 选项：`scope`、`includeActionMarks`、`includeStableLocator`（默认全 true）。
4. OOPIF：通过 `Target.getTargets`/`Target.autoAttach` 枚举 `type=iframe` 子 target，同规则生成子树并以 `[iframe src=…]` 分组缩进；单帧失败降级为该帧 `[iframe: unavailable]` 占位，不炸整页。

### M2 — 空间（Space）操作 + 所有权 hard-stop
1. helper：`useOrCreateSpace(nameOrId) / listSpaces / claimSpace(id) / handOffSpace([id]) / takeOverSpace([id]) / completeSpace(id,{keep}) / waitForAgentControl([id])`，语义逐条对齐本地镜像 `~/.agents/skills/agent-browser-harness/SKILL.md` 的生命周期规则（同目标复用同空间、complete 独占末轮、keep 默认 false）。
2. **app 侧桥接**：Peekr 进程内起 127.0.0.1 本地 HTTP（第二个端口，写入 `agent.json` 新字段 `controlPort`），路由映射 `AppModel`：`GET /spaces`、`POST /spaces`、`POST /spaces/:id/takeover`、`POST /spaces/:id/handoff`、`DELETE /spaces/:id`。鉴权 v1：绑定 localhost + `agent.json` 里的一次性 token。
3. 错误契约 `errors.ts`：`PEEKR_SPACE_USER_IN_CONTROL` / `PEEKR_SPACE_NOT_FOUND` / `PEEKR_SPACE_INACTIVE` / `PEEKR_AGENT_ACCESS_DISABLED` / `PEEKR_CDP_UNAVAILABLE`。hard-stop 语义为写 output-sink 留痕 + 固定恢复话术（停手、问用户、等「继续」后 `takeOverSpace`）。
4. 所有权映射：`WorkspaceOwnership.user → 拒绝 agent 操作`；`agentDelegatedToUser → 仍属 agent（isAgentOwned）`；接管单向（AppModel 已有）。

### M3 — 分发与 skill
1. `peekr` CLI 打进 `Peekr.app/Contents/Resources/peekr-cli/`；bundling 脚本参考 `scripts/bundle.sh` 既有流程。
2. `skills/peekr-cli/`：SKILL.md（照 agent-browser-harness 的结构改写：task space 规则、ownership 表、heredoc 规范、三条 workflow——语义/视觉/CDP）+ `references/install.md` + `scripts/install.sh`（读 `agent.json` 验活 + `~/.local/bin` 注册）。
3. 偏好设置「Agent 接入」区加一行发现文件路径展示 + 「安装命令行工具」按钮（调用 onboarding）。

### M4 — 质量对齐（可选增强）
- 视口过滤（`only_within_viewport` 用 `DOMSnapshot` 布局坐标裁剪）、`includeActionMarks`（动作高亮动画）、体验累积（`learnings` 目录）。

## 5. 验收标准（全部可执行）

1. `swift build && swift test` 全绿；每轮改动后按「隔离实例冒烟」流程回归（见记忆 peekr-test-after-changes）。
2. 冒烟脚本：Peekr 开 Agent 接口 → `peekr nodejs` heredoc 完成 `useOrCreateSpace('demo') → openOrReuseTab('https://example.com') → snapshotText() → click` 全链路；`agent.json` 不存在/`agentAccessEnabled=false` 时返回 `PEEKR_AGENT_ACCESS_DISABLED` 而非挂起。
3. snapshot 质量基准页：含嵌套同域 iframe + 一个跨域 iframe + shadow DOM 控件 + Stripe 式嵌入的本地测试页——三者在 snapshot 中可见且可 `@N` 定位（跨域至少不炸、有占位）；example.com 整页 ≤ 400 tokens。
4. 所有权：agent 空间被用户接管后，agent 任何浏览器操作返回 `PEEKR_SPACE_USER_IN_CONTROL`（hard-stop 文案），且 Peekr UI rail 徽标同步变化。
5. 文档：skill 的 SKILL.md 能让一个未接触过的 agent 首轮 heredoc 就跑通（用自身 agent 实测）。

## 6. 风险与依赖

- CefSwift pinned 0.1.0：CDP 端口能力已在 `CefConfiguration` 验证；若 AX 树在 CEF 下不完整，备选注入式 ARIA walker，在 M1 内做 A/B 取优。
- 端口安全：两个端口都只绑 127.0.0.1；文档明示「本机任意进程可连接」；保持 opt-in 默认关。
- 版权：参考 harness 为 MIT——结构可参考；若直接搬运代码需在 `cli/NOTICE` 保留对应版权声明。

## 7. 参考资料

- 参考实现的本地资料只用于行为核对，不作为 Peekr 的运行时依赖。
- 本地参考包应放在 `.reference/agent-browser-baseline/`，并保持在 `.gitignore` 中；提交时只保留经过 Peekr 自己验证的契约、测试和实现。
- Peekr 侧接缝：`Sources/Peekr/{App/PeekrApp.swift, Util/AgentDiscovery.swift, Model/Workspace.swift, App/AppModel.swift, UI/AppRail.swift}`
