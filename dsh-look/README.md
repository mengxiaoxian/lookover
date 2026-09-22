# dsh-look — M0 + M3 + M2-lite + M4 + P2-lite(多窗口/pick) 场景感知探针

拉模型（零感知）：只在 agent 调用 `look` 工具时读一次「最前面的非自身窗口」。
无轮询、无跟踪、无注入。两档保真度，无权限时优雅降级：

- **app 档（零 TCC 权限）**：app / bundleId / pid / windowId / bounds / layer
- **ax 档（辅助功能权限）**：+ 窗口标题、文档 URL、**选中文本**、焦点元素文本

## M2-lite：全局召唤热键（Ctrl+Alt+L）

在任何 app 里按下热键：

1. watcher helper（Carbon 全局热键，常驻，host 崩溃自动重启）通知 host
2. host **立刻**跑一次 look 快照——此刻目标 app 仍在前台，焦点未丢、选区最完整
3. helper activate-self 把 DSH 唤到前台，输入框就绪
4. 下一条消息发出时，快照作为隐藏上下文注入（`agent/pre-step`，TTL 5 分钟）

热键参数在 `lib/index.js` 顶部 `HOTKEY_ARGS`（key code 37 = L，modifiers 0x1800 = Ctrl+Alt）。
留痕日志以 `source: "hotkey"` 区分热键快照与 agent 主动调用。

## P1-lite：语音路径定案（2026-09-21）

**买不造**：ASR 是商品化能力，本地离线模型（sherpa zipformer）中文准确率不如云端。定案：

- **主力**：豆包输入法语音（系统级，任何输入框可用）——`⌥⌘Z`（召唤+快照）→ 豆包语音键说话 → 文字落 DSH 输入框 → 发送时快照自动注入；
- **兜底**：dsh-voice 本地引擎（`engine: native`，离线隐私）保持不动，断网/不便切输入法时用 ctrl+alt+v。

## P2-lite：召唤体验补全（2026-09-21，focus-input + ⌃⌥⌘N）

- **focus-input**：⌥⌘Z 召唤后 ~400ms，helper 在 DSH 窗口 AX 树里 BFS 找输入框并聚焦（重试 2.5s），
  免手动点选；气泡收起时静默无操作。
- **⌃⌥⌘N 新会话**：app UI 没有新会话快捷键；helper `new-session` AXPress 侧边栏「新建会话」按钮
  （`--dry` 只探测不按）。加 Control 是因为 tap 只听不拦，⌥⌘N 会与浏览器无痕窗口双触发。
- 现状限制：气泡收起时输入框/侧栏按钮都不在 AX 树里，两者静默无操作；「自动展开后再操作」留待后续。

## P2-lite：多窗口与 pick（2026-09-21 交付）

微信等应用点开聊天是**独立窗口**，最前窗口可能不是用户所指。现在：

- 存在 ≥2 个可见候选窗时，结果附 `windows` 列表（app / 窗口名 / bounds / selected 标记）；
- `look({pick:"微信"})` 按应用名或窗口名子串（不区分大小写）选窗，匹配不到返回
  `pick_no_match` + 候选列表；缺省仍是「最前窗口」（M0 语义不变）；
- 常见用法：`look({ocr:true, pick:"微信"})` 直接对聊天窗口 OCR；
- 窗口名来自 `kCGWindowName`（依赖屏幕录制权限；无权限时仅应用名匹配可用）。
- 实测：6 候选窗枚举 + pick 选 ChatGPT + `--pick 微信 --ocr` 读出微信主窗口会话列表。

## M4：截图 + 本地 OCR + gated 多模态（2026-09-21 交付，同日真实使用验证 ✅）

`look({ocr:true})` 对同一窗口补一层 OCR：

> **验收实录**：微信主窗口（win 497），纯文本模型读出左栏列表+右栏文字气泡；
> 读图模型走 `imagePath` 描述出照片内容（「一张女性微笑的照片」——OCR 只能给「［图片］」）；
> 诚实边界生效（未读消息不在视野则明说不猜）。图文双通道 + 门控 + 边界全部按设计工作。

1. **截图**：`screencapture -x -l<winId>`（CGWindowListCreateImage 在 macOS 15 SDK 已废弃）。
   **需要屏幕录制权限**（系统设置 → 隐私与安全性 → 屏幕录制 → DSH）；缺失时返回
   `ocr.error=capture_failed` 与引导文案，AX 档结果不受影响。
2. **本地 OCR**：macOS Vision（accurate + 语言校正，zh-Hans + en-US），零 token。
   覆盖 AX 盲区：微信/QQ 聊天气泡、图片文字、扫描 PDF、视频画面。
3. **gated 多模态**：PNG 落在 `$TMPDIR/dsh-look/`（10 分钟 TTL，调用时自动清理过期文件），
   路径随 `ocr.imagePath` 返回。默认只用 OCR 文本；只有问题确实是视觉语义类
   （图表趋势/颜色/布局）时，agent 才用 `read_image` 读图——按需付费，不是每次都喂图。
4. 系统提示已更新门控规则：OCR 结果引用时注明「据 OCR 识别」，capture_failed 时如实告知。

## M3 要点（选中文本读取）

1. **焦点元素路径**：目标 app 的 `kAXSelectedText`（原生编辑器，失焦后多数仍可读）
2. **窗口扫描路径**：失焦导致焦点元素为空时，对窗口元素树做有界 BFS
   （≤1500 元素 / 2s 墙钟，失败停 0.6s 重扫一次）
3. **Chromium 特殊处理**：
   - 渲染进程 AX 树默认不构建——设 `AXManualAccessibility` / `AXEnhancedUserInterface` 唤醒（报错也无妨，探测本身就能触发）
   - 网页正文选区不走 `AXSelectedText`，走 `AXSelectedTextMarkerRange` → `AXStringForTextMarkerRange` 参数化取值
   - 滤除 marker 文本中的 `￼`/私用区占位符
4. **能力边界（实测）**：TextEdit 等原生编辑器 ✅、Chrome 正文 ✅、微信聊天气泡 ❌（app 不暴露，留待截图/OCR）

- `native/look.swift` — Swift helper：`CGWindowListCopyWindowInfo(.optionOnScreenOnly)`
  天然前到后排序，按 bundleId/pid 跳过 DSH 自己的窗口，取第一个 layer 0 窗口。
- `lib/index.js` — host 半：spawn helper、解析 JSON、注册 `look` 工具、
  写入系统提示指引、留痕到 `~/.dsh/look/log.jsonl`。
- 编译：`npm run build:native`（注意 `-module-cache-path`，沙箱下必须）。

## 安装（已完成的步骤）

profile `~/.dsh/profiles/desktop`：
1. `package.json` dependencies 加 `"dsh-look": "file:~/lookover/dsh-look"`
2. `cordis.patch.yml` 末尾 insert `dsh-look` 插件声明
3. `pnpm install`
4. **重启 DSH Host**（否则 `look` 工具不出现）

## 留痕日志

每次 agent 调用 `look` 追加一行 JSON 到 `~/.dsh/look/log.jsonl`
（含 error 结果）。日志无新增 = 没有调用，即 A3 的判据。

## 验收

见 `../ACCEPTANCE-M0.md`。
