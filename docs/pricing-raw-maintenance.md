# SubLB pricing raw 维护说明

本仓库维护 SubLB 生产 pricing 远程源，不再依赖 sub2api 上游仓库的固定 commit。

## 生产配置只能使用文件级 raw URL

正确：

```text
https://raw.githubusercontent.com/mason0510/sublb-config/<commit>/pricing/model_prices_and_context_window.json
https://raw.githubusercontent.com/mason0510/sublb-config/<commit>/pricing/model_prices_and_context_window.sha256
```

错误：

```text
https://raw.githubusercontent.com/mason0510/sublb-config/<commit>/pricing/
```

目录 raw URL 会返回 400/非 200，不能作为 `PRICING_REMOTE_URL`。

## 每次更新流程

1. 修改 `pricing/model_prices_and_context_window.json`。
2. 重新生成 hash：

   ```bash
   shasum -a 256 pricing/model_prices_and_context_window.json | awk '{print $1}' > pricing/model_prices_and_context_window.sha256
   ```

3. 提交并 push。
4. 用固定 commit 验证：

   ```bash
   ./scripts/verify-pricing-raw.sh <commit>
   ```

5. 验证通过后，生产节点才能把 `PRICING_REMOTE_URL` / `PRICING_HASH_URL` 指向该 commit 的两个文件级 raw URL。
