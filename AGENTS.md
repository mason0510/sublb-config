# Pricing 发布验证

适用：修改 `pricing/model_prices_and_context_window.json` 并准备提交或发布时。

1. 同步重算哈希：

   ```bash
   shasum -a 256 pricing/model_prices_and_context_window.json | awk '{print $1}' > pricing/model_prices_and_context_window.sha256
   ```

2. 本地提交前，至少确认 JSON 可解析、目标模型价格字段正确，并运行：

   ```bash
   bash -n scripts/verify-pricing-raw.sh
   git diff --check
   ```

3. push 后，必须用**已发布的固定 commit SHA**执行 raw readback：

   ```bash
   ./scripts/verify-pricing-raw.sh <commit-sha>
   ```

4. 验收必须同时包含：
   - raw JSON 与 `.sha256` 一致；
   - 目标模型条目存在，且输入、缓存输入、输出价格及所有上下文分档字段与预期一致；
   - raw 文件下载成功，目录 raw URL 不是 200；
   - `origin/master` 已指向该固定 commit，工作区干净。
   - 使用 `scripts/activate-pricing-pin.sh` 完成三个生产实例的集群激活；
   - 三节点运行时 `model_pricing.json/.sha256/.commit`、目标模型四类价格一致；
   - 激活后的真实 usage 记录按新价格计费。

禁止仅凭本地 JSON、GitHub 页面可打开或 HTTP 200 宣布发布完成；未通过固定 commit raw readback，不得认为 pricing 已发布。

## 固定 commit pin 更新

当前后端的 `pricing.remote_url` / `pricing.hash_url` 若以代码默认值或运行时配置固定到某个 commit，则价格源发布后必须同步更新该 **commit pin**，否则线上仍会拉取旧价格。

目标机制是将 pin 设为受控可配置项：后台或自动化入口只接受 `sublb-config` 的 40 位小写 commit SHA，后端据此固定拼接 JSON 与 SHA256 raw 地址、校验 hash 后应用新价格。价格源发布流程应自动把新 commit SHA 写入该 pin，并立即 readback 目标模型价格。

禁止把 pin 改为 `master`、branch、tag、任意 URL，或绕过 JSON/SHA256 校验。

## 生产运行缓存与集群激活

- `model_pricing.json` 是实例本地运行缓存，不是独立价格真值；唯一真值仍是本仓库固定 commit。
- 价格 pin 写入共享 settings 后，单个实例只会立即更新自己的进程内价格和运行缓存；因此
  生产激活必须使用 `scripts/activate-pricing-pin.sh` 逐实例 loopback PUT，不得只调用一次公网 PUT。
- 脚本必须从运行进程的 `PRICING_DATA_DIR` / `DATA_DIR` 确认真实路径，并逐节点回读
  `model_pricing.json`、`.sha256`、`.commit` 与目标模型四类价格。
- 三节点写同一个共享 pin，存在同一资源写冲突，固定串行；任一节点失败即按旧 commit 回滚。
- 退出码 0、单次 `activated=true`、active pin 正确均不单独代表价格已生产生效；必须有三节点
  一致性和激活后真实 usage 计费证据。

## ChainFuel 生产节点登记（2026-09-03）

- `prod-main`：生产主入口，历史运行地址 `51.79.158.64`；当前主服务器管理 SSH：`us-main-01-admin-direct`（`82.29.54.80`），服务端口 `48090`，运行价格目录 `/srv/sub2api-80/shared/data/pricing`。
- `prod-third`：`51.79.158.64`，新加坡生产节点（兼预发布/测试）；SSH 别名 `ovh-51-79-158-64-via-cn-tencent`，服务 `sublb.service`，运行价格目录 `/srv/sublb/prod-main/data/pricing`。
- `prod-forth`：`192.99.71.43`，独立负载节点；当前未登记可用 SSH 别名，直接 TCP/22 连接需先恢复后再执行生产写入。
- 定价发布必须按节点逐一执行 pin 激活与运行时 readback；不得以单节点结果代表三个实例全部生效。
