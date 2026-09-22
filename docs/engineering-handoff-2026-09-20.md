# HANDOFF — 场景感知助手 2026-09-20 会话交接

> 下次会话先读这份。工作区：`~/lookover/`，插件本体：`dsh-look/`。
> 安装方式：`~/.dsh/profiles/desktop` 里 `dsh-look` 以 **pnpm `link:` 协议**指向工作区
> ——改 Swift 后重编译到 `dsh-look/bin/look` 即生效（helper 每次调用从磁盘 spawn）；
> 改 JS（lib/index.js）需重启 DSH Host。

## 一、已交付（全部实测验收）

### M0 零权限 `look` 工具 ✅
- `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` 前到后排序，按 bundleId+pid 跳过 DSH 自身（NSWorkspace 枚举同 bundle 全部进程，覆盖 Electron 多进程），取第一个 layer-0 非自身窗口
- 零 TCC 权限：app / bundleId / pid / windowId / bounds / layer
- 系统提示指引（何时看/何时别看/诚实边界/禁止翻历史猜 URL）
- 留痕：`~/.dsh/look/log.jsonl`（source: agent | hotkey）
- **验收：A2 命中率 11/11=100%（含 1 例越权坏样本，加边界约束后复测通过）；A3 0/5；A1/A5/A6 全过**
- 详见 `ACCEPTANCE-M0.md`

### M3 辅助功能层（ax 档）✅
- `fidelity: "ax"`：窗口标题、文档/URL、**选中文本**、焦点元素文本；无权限自动降级 app 档
- 选中文本三级读取：①焦点元素 `AXSelectedText`（原生 app，失焦多数仍可读）②窗口级 ③元素树有界 BFS（≤1500 元素 / 2s 墙钟 / 失败歇 0.6s 重扫）
- **实测矩阵**：TextEdit ✅（失焦仍可读）、Chrome 正文 ✅、微信聊天气泡 ❌（app 不暴露，M4 补）

### M2-lite 召唤热键快照 ✅
- **搭便车设计**：DSH 自带 ⌥⌘Z（气泡/展开切换），listen-only CGEventTap 旁路监听同组合——一个键：App 召唤 + 快照
- 按下瞬间（目标 app 仍前台、焦点未丢、选区最完整）抓一次 look 快照 → 挂到下一条消息（agent/pre-step 隐藏注入，TTL 5min，600ms 防抖）
- watcher 崩溃 2s 自动重启；不自己激活 App（尊重气泡/展开语义）
- 性能：热快照 39ms，冷 Chrome ~1s（延迟被「展开+打字」掩盖）；空闲≈0
- 端到端验收：⌥⌘Z → 问「我在看什么」→ 正确答出 Kimi 官网 + URL 参数分析

## 二、踩坑记录（重要，别重踩）

1. **Carbon RegisterEventHotKey 在现代 macOS 后台 CLI 进程上注册成功但永不派发**（appshots 成品二进制同样）。全局热键用 **CGEventTap**（需辅助功能权限，恰好 M3 已授）
2. **`~/.dsh/` 路径下执行未签名二进制会被系统安全策略 SIGKILL**（同字节文件 workspace 路径正常）。所以 profile 里必须是 **symlink 到 workspace**（已用 link: 协议实现）；下次装别的本地插件同样注意
3. **Chromium 无障碍树默认不构建**：设 `AXManualAccessibility`/`AXEnhancedUserInterface`（报错也算探测唤醒），且失败后等 0.6s 重扫
4. **Blink 网页正文选区不走 `AXSelectedText`**：要 `AXSelectedTextMarkerRange` → 参数化 `AXStringForTextMarkerRange`；文本里混 `￼`/私用区占位符要滤
5. swiftc 编译加 `-module-cache-path ./build/mc`（沙箱坑）
6. 改 JS 必须重启 host；改 Swift 二进制不用（每次 spawn）
7. **TCC 归因到 DSH 应用**（responsible process），host/bash 派生的 helper 都继承 ax 权限——调试时可直接从 bash 跑 helper 复现 agent 视角

## 三、后续排期建议

| 优先级 | 事项 | 说明 | 预估 | 状态 |
|---|---|---|---|---|
| P0 | **M4 截图 + 本地 OCR + gated 多模态** | 微信气泡等 AX 盲区的根治；`screencapture -l<winid>`（需**录屏权限**）→ macOS Vision 本地 OCR（零 token）→ 仅视觉语义问题才喂多模态 | 1 个会话 | ✅ 2026-09-21 交付（screencapture 替代已废弃的 CGWindowListCreateImage；录屏权限未授时优雅降级并引导授权） |
| P1 | 提示文案持续迭代 | 日常使用收集漏看/误看/越权样本（日志+体感），像 A2 坏样本那样闭环修文案 | 持续 | |
| P1 | 语音输入衔接 | dsh-voice 已在 profile（ctrl+alt+v），但页面级热键失焦失效；与 ⌥⌘Z 快照流打通（说而非打）| 0.5–1 会话 | ✅ 2026-09-21 定案：**买不造**——主力语音路径 = 豆包输入法（云端 ASR，准确率高于本地 sherpa），链路 ⌥⌘Z召唤+快照 → 豆包语音键 → 文字进 DSH 输入框 → 发送时快照注入（TTL 5min 覆盖）；dsh-voice 本地引擎保留为离线兜底，零代码改动 |
| P2 | 多窗口支持 | 现在 only 最前非自身窗口；「第二个窗口」「那个副屏」类指令 | 待定 | ✅ 2026-09-21 交付 windows 列表 + pick 子串选窗（pick 参数需重启 Host 生效）；副屏/跨 Space 未覆盖 |
| P2 | **召唤体验**：唤起后焦点进输入框 + 新会话快捷键 | focus-input（AX 找输入框聚焦，热键后 400ms 触发）；⌃⌥⌘N = AXPress「新建会话」按钮（app UI 无此快捷键；加 Ctrl 避开浏览器无痕窗口冲突） | 0.5 会话 | ✅ 2026-09-21 交付；气泡收起时二者静默无操作。**需重启 Host 生效** |
| P2 | 快照 UI 化 | 在气泡里显示「已捕获 XX 上下文」提示条，可手动清除 | 0.5 会话 | （并入 dsh-expmem MVP 的「采集可见」提示条） |
| P3 | 多模态 token 成本审计 | M4 落地后统计实际消耗，校准 gating 阈值 | M4 后 | 🟡 2026-09-21 首次真实多模态调用已发生（读图模型描述微信图片消息），可开始统计 |

## 四、文件清单

```
~/lookover/
├── dsh-look/                 # 插件本体（link: 进 profile）
│   ├── native/look.swift     # helper：一次性探测 / watch(⌥⌘Z) / activate-self
│   ├── bin/look              # 编译产物（必须经此路径执行，见坑 2）
│   ├── lib/index.js          # host 半：look 工具 + 热键链路 + pre-step 注入
│   ├── cordis.patch.yml      # insert 声明
│   └── README.md             # 设计文档
├── ACCEPTANCE-M0.md          # M0 验收记录（含坏样本）
└── HANDOFF-2026-09-20.md     # 本文件
```
