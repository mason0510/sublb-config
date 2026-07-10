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

禁止仅凭本地 JSON、GitHub 页面可打开或 HTTP 200 宣布发布完成；未通过固定 commit raw readback，不得认为 pricing 已发布。

## 固定 commit pin 更新

当前后端的 `pricing.remote_url` / `pricing.hash_url` 若以代码默认值或运行时配置固定到某个 commit，则价格源发布后必须同步更新该 **commit pin**，否则线上仍会拉取旧价格。

目标机制是将 pin 设为受控可配置项：后台或自动化入口只接受 `sublb-config` 的 40 位小写 commit SHA，后端据此固定拼接 JSON 与 SHA256 raw 地址、校验 hash 后应用新价格。价格源发布流程应自动把新 commit SHA 写入该 pin，并立即 readback 目标模型价格。

禁止把 pin 改为 `master`、branch、tag、任意 URL，或绕过 JSON/SHA256 校验。
