---
id: c_muc5l3gcsbtr
projectId: p_muc5l3gbldmv
status: open
outcome: unknown
occurredAt: 2026-09-18T10:00:00+08:00
version: 1
---
# 本地记忆存储选型：结构化状态 + 可读内容怎么存

**约束：** 单机单人，macOS，数据量小（百级案例），索引必须可重建
**尝试：** 考虑过 SQLite、JSONL、图数据库
**选择：** JSONL 存状态 + Markdown 存正文 + 内存重建索引
**理由：** 索引是派生物可重建；可读性优先；规模小无需图数据库
**结果：** unknown

## 来源
- [ax-selection] SQLite vs JSONL for local-first apps · 讨论「单机单人场景下 JSONL 足够，索引可以重建」 @2026-09-18T10:00:00+08:00

## 经验（Claim）
- (pending/candidate) 小规模个人记忆用 JSONL+Markdown 优于图数据库｜适用条件：单机单人、百级记录、索引可重建的前提下
