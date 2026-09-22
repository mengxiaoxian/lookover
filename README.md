# lookover

> **不离场、随叫随到、和你看着同一块屏幕的通用桌面助手。**

名字来自它的核心交互：你按一下、说一句，它就**凑过来看一眼**你在看什么——而不是把你拽到它那里去。

基于 [DeepSeek Harness](https://github.com/deepseek-ai)（DSH）插件体系构建的 macOS 桌面 Agent 助手，由两个可独立使用的插件组成：

| 模块 | 是什么 | 一句话 |
|---|---|---|
| [`dsh-look/`](dsh-look/) | 场景感知探针 | 让 Agent 在被问到「这个/这个报错/这个页面」时，能真实读到你的屏幕上下文 |
| [`dsh-mem/`](dsh-mem/) | 个人经验记忆 | 把解决过的问题存为带来源、可纠正的案例，下次相似任务直接召回 |

---

## 解决什么问题

用 AI 助手时最大的摩擦不是「问不出答案」，而是**每换一个任务就要重新解释一遍背景**：

- 你在浏览器看一份英文合同，想问第 7 条的风险——得先复制粘贴给 AI；
- 终端弹了个报错——得截图上传；
- 微信里对方说了句话——得手动转述。

用户指代屏幕内容（「这个」「他刚说的」）时，AI 是盲的。**lookover 让 Agent 获得一次诚实、克制、留痕的「看」。**

## 产品原则

1. **拉模型，零轮询**——只在 agent 调用 `look` 工具那一刻读一次最前面的非自身窗口。无轮询、无跟踪、无注入，每次读取落盘留痕（`~/.dsh/look/log.jsonl`）。
2. **优雅降级**——零权限也能用（app/bundleId/bounds），授予权限获得更多（窗口标题、文档 URL、选中文本、焦点元素），OCR 是最后一层兜底。
3. **答案出现在注意力所在处**——召唤即捕获：按下热键的瞬间快照（此刻焦点未丢、选区最完整），答案就地交付，全程不离开当前工作页面。
4. **诚实边界**——读不到就说读不到，禁止翻历史/读标签页/猜 URL 变相编造屏幕内容；这条边界是验收用例喂出来的（见下）。

## 架构

```
任何 App（Chrome / 微信 / 终端 / WPS / IDE …）
   │  ⌥⌘Z 召唤（listen-only CGEventTap，不拦截）
   ▼
dsh-look 探针 ── 按下瞬间抓一次快照（热快照 39ms）
   ├─ app 档（零 TCC 权限）: app / bundleId / pid / windowId / bounds
   ├─ ax 档（辅助功能权限）: + 窗口标题 / 文档 URL / 选中文本 / 焦点元素
   └─ ocr 档（录屏权限）:   + 截图 → macOS Vision 本地 OCR（零 token）
   ▼  agent/pre-step 隐藏注入（TTL 5min，防噪）
DSH 宿主 Agent ── 基于共享快照回答 / 召回 dsh-mem 经验案例
   ▼
答案交付在气泡（锚定注意力位置，不改前台 App）
```

多窗口场景：≥2 个可见候选窗时返回 `windows` 列表，`look({pick:"微信"})` 按名称选窗——你指哪个它看哪个。

## 验收数据（真实测试，非宣称）

- **A2「该看就看」命中率 11/11 = 100%**：微信×2、Chrome×4、终端、WPS×2、ima.copilot×3，含 1 例「识别命中、执行越权」坏样本，加边界约束后复测通过
- **A3「不该看就不看」0/5 次调用**：无关问题期间留痕日志零增长
- 热快照 **39ms**；冷 Chrome ~1s（延迟被「展开+打字」掩盖）；空闲开销 ≈ 0
- 完整记录见 [`docs/acceptance-M0.md`](docs/acceptance-M0.md)

## 关键工程决策（为什么不好抄）

| 决策 | 被否掉的备选 | 理由 |
|---|---|---|
| 全局热键用 CGEventTap | Carbon RegisterEventHotKey | Carbon 在现代 macOS 后台 CLI 注册成功但**永不派发**（成品二进制同样踩坑）；listen-only 不拦截，与 App 自有热键搭便车共存 |
| 快照在「按下瞬间」抓 | 唤起后再读 | 唤起 App 瞬间焦点即丢、选区被破坏——时序设计是「召唤即捕获」的根基 |
| Chromium AX 树手动唤醒 | 直接读 | Chromium 默认不构建无障碍树；`AXManualAccessibility` 唤醒 + 失败歇 0.6s 重扫；Blink 选区需 `AXSelectedTextMarkerRange` 参数化取值并滤 `￼` 占位符 |
| OCR 用 macOS Vision 本地跑 | 云端多模态 | 零 token、零上传；gated——仅视觉语义问题才把图喂多模态模型 |
| 记忆插件不另起 LLM 管线 | 独立抽取服务 | **agent 本身就是抽取器**：只提供工具+系统提示+注入，结构化质量随宿主模型免费升级 |

完整踩坑记录：[`docs/engineering-handoff-2026-09-20.md`](docs/engineering-handoff-2026-09-20.md)

## 当前边界（诚实清单）

- v1 聚焦**只读辅助**：读你所读、答你所问；动作执行（代点、代发）后置
- 记忆召回是词元打分（CJK 二元组），同义改写会漏；向量索引在路线图上
- 副屏 / 跨 Space 窗口未覆盖；气泡收起时 AX 树不可达（自动展开后操作在做）
- 依赖 DSH 宿主运行环境，不是独立 App

## 路线图

- [x] M0 零权限 look 工具（验收 11/11）
- [x] M3 辅助功能层（选中文本三级读取）
- [x] M2-lite 召唤热键快照（39ms）
- [x] M4 截图 + 本地 OCR + gated 多模态
- [x] P2-lite 多窗口 pick / focus-input / 新会话热键
- [x] dsh-mem MVP（案例存取/召回/纠正，13 项断言全绿）
- [ ] 召唤带宽阶梯：按住说话 → 拖拽即问
- [ ] 异步任务的「进行中形态」（长任务的进度呈现是真空地带）
- [ ] 收获周报：被动信号度量「真实解决问题」，替代人工验收

## 长期愿景：从「看见」到「记住」

lookover 的终局不是「看得见屏幕的助手」，而是**个人经验型桌面助手**：把共同解决问题的经历沉淀为**带来源、可纠正、有适用条件**的问题案例，让下一次相似任务——少解释一次背景，少重做一次研究，少踩一次已经踩过的坑。

三层产品承诺：**当下**（理解授权上下文、就地帮助）→ **跨任务**（带回旧经验并核对适用条件）→ **长期**（可查看、可修订的个人经验空间）。最有辨识度的瞬间：助手在新任务里提出「上次用过这个方法，但它依赖一个这次不成立的条件，建议调整」，并展示可核查的依据。

dsh-mem 是这条路线的第一步。完整的产品方向评估（双向论证、对象模型、竞品对比、验证方案、信任风险）见 [`docs/product-direction-evaluation.md`](docs/product-direction-evaluation.md)。

## 文档

- [`docs/product-direction-evaluation.md`](docs/product-direction-evaluation.md) — 个人经验型桌面 AI 助手：产品方向评估（长期愿景）
- [`docs/product-design-mvp.md`](docs/product-design-mvp.md) — dsh-mem MVP 产品需求与设计方案（PRD）
- [`docs/acceptance-M0.md`](docs/acceptance-M0.md) — M0 验收记录（含坏样本迭代过程）
- [`docs/engineering-handoff-2026-09-20.md`](docs/engineering-handoff-2026-09-20.md) — 工程交接与踩坑记录

各插件的使用与安装说明见各自目录的 README：[`dsh-look/README.md`](dsh-look/README.md) ｜ [`dsh-mem/README.md`](dsh-mem/README.md)

## License

MIT

## 作者

程蒙博（[mengxiaoxian](https://github.com/mengxiaoxian)）· AI Agent 产品经理。产品设计与工程实现均为独立完成。
