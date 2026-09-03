# Pricing 发版记录

## 2026-08-13 — ChainFuel：新增 `grok-4.6` 定价并单节点激活

- 范围：ChainFuel 当前无负载，仅激活节点 `ovh-51-79-158-64-via-cn-tencent`；未操作 `node254`、`node74`。
- 配置 commit：`a4bb6339e89447ba40ec410dc634ed5914697194`。
- pricing SHA256：`f4786e7af4ceb45b535ae38ec979b584d780558b1831793c9e1161d5857dd63c`。
- 模型：`grok-4.6`，与 `grok-4.5` 同价：输入 `$2/M`、缓存输入 `$0.50/M`、输出 `$6/M`；超过 200K tokens 的输入/缓存输入/输出分别为 `$4/M`、`$1/M`、`$12/M`。
- 发布前：固定 commit raw JSON/SHA256 校验通过；节点 `sublb.service` 的单节点 dry-run 通过。
- 发布后：`/srv/sub2api/data/pricing/model_pricing.commit` 回读为上述 commit，JSON SHA256 与目标模型全部价格字段一致；回滚备份已由激活脚本创建。
- 依赖修复：节点安装经 SHA256 校验的 Hurl `8.0.1`，用于既有激活脚本的 loopback 验收。
- 真实 usage：发布时无 `grok-4.6` 调用样本；首笔调用后需按 usage 记录补充计费核验。

## 2026-09-03 — 新增 `claude-fable-5-1` 并固定到线上

- 模型 ID：`claude-fable-5-1`（官方文档显示输入 `$10/M`、输出 `$50/M`；缓存读取为输入价的四分之一）。
- 定价配置：复用 `claude-fable-5` 条目，固定 commit `d8a4e3fd7105a410fa8c6e65f3240c1ea9e852f0`。
- pricing SHA256：`5926358e2e9ab773391d59d19fca4af29e3678cff2099b1d77ebb732bd04a2aa`。
- 发布验证：固定 commit raw JSON/SHA256 校验通过，目录 raw URL 返回非 200。
- 线上激活：ChainFuel 当前无负载，按既定单节点范围激活 `node64`（`ovh-51-79-158-64-via-cn-tencent`，`sublb.service`）；运行目录 `/srv/sublb/prod-main/data/pricing`。
- 激活回读：`model_pricing.commit`、JSON SHA256 与目标模型价格字段均与上述固定 commit 一致；API 返回 `activated=true`、`source_mode=config`。
- 真实 usage：当前尚无该模型调用样本，首笔调用后补充计费核验。
