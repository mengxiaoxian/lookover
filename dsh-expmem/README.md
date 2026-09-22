# dsh-expmem — 个人经验记忆插件（Demo）

把真实解决过的问题存为**带来源、可纠正、有适用条件**的问题案例，在新任务中召回复用。
依据《MVP产品需求与设计方案_个人经验型桌面助手_2026-09-21.md》§6/§8，Demo 级实现。

**设计核心：agent 本身就是抽取器。** 插件不另起 LLM 管线，只提供工具 + 系统提示 + pre-step 注入，
由宿主 agent 在对话中完成案例结构化（省一次调用，且结构化质量随宿主模型升级）。

## 能力 ↔ PRD 验收映射

| PRD 能力 | 实现 | Demo 验证 |
|---|---|---|
| C2 带来源案例 | `mem_save_case`（outcomeStatus 强制 honest，unknown 不许写结果注记） | E2a–E2d ✓ |
| C3 经验候选 | `mem_add_claim`（必带 conditions；同文去重升版本） | E2c ✓ |
| C4 召回 | `mem_recall` 工具 + **pre-step 隐藏注入**（复用 dsh-look 快照同款注入模式，top1 词元命中 ≥3 才注入，防噪） | E3a–E3e ✓ |
| C5 纠正生效 | `mem_correct`（ignore/invalidate/delete/revive；delete 级联关联 Claim） | E4a–E4c ✓ |
| C6 书架 | `mem_list` + 每案例 Markdown 导出（`cases/<id>.md`） | E5 ✓ |
| C1 就地回答 | 由 dsh-look + 宿主气泡承担，不在本插件范围 | — |

## 运行 Demo（无需 DSH Host）

```bash
npm run demo    # 13 项断言全绿即 E2–E5 通路 OK
```

Demo 数据落在 `demo/data/`（每次运行重置），用模拟 look 快照做来源。

## 安装进 profile（与 dsh-look 同法）

`~/.dsh/profiles/desktop`：
1. `package.json` dependencies 加 `"dsh-expmem": "link:~/lookover/dsh-expmem"`
2. `cordis.patch.yml` 末尾 insert `dsh-expmem` 插件声明
3. `pnpm install` → **重启 DSH Host**

生产数据目录：`$DSH_HOME/mem`（缺省 `~/.dsh/mem`）；`MEM_DIR` 可覆盖。

## 存储（PRD §8.2）

- `projects.jsonl` / `cases.jsonl` / `claims.jsonl` / `events.jsonl`（append-only 留痕）+ `state.json`（ignore 表）
- `cases/<id>.md`：人读案例卡（frontmatter = 结构化字段）
- **索引在内存中重建**，存储文件是唯一事实源；删除级联到索引与 Markdown

## 已知限制（Demo 级，README 即欠条）

1. **召回是词元打分**（拉丁词 + CJK 二元组）：改写同义查询会漏（Demo 中「Chrome 选中文本读不到」未能召回 AX 案例，即同义改写 miss 的实例）。接宿主后可让 agent 先 `mem_recall` 自己的改写；向量索引留 M-mem-3 之后；
2. 相似 Claim 去重是同文精确匹配，语义去重未做；
3. pre-step 注入的防噪阈值（词元 ≥3）是拍的，需真实使用校准；
4. 并发写未加锁（单用户单进程假设）；
5. `reuseCount` 目前把 pre-step 注入也算复用，高估——有效复用判定（PRD §10）待埋点细化。
