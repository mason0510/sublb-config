# sublb-config

SubLB 自维护公开配置源。

这个仓库现在是 **SubLB pricing 真值源唯一主入口**。  
以后遇到模型价格、缓存价格、raw URL、固定 commit pin、hash 校验这类问题，默认先看这里，不再去上游仓库盲找。

## Pricing 相关文件

- `pricing/model_prices_and_context_window.json`
- `pricing/model_prices_and_context_window.sha256`
- `docs/pricing-raw-maintenance.md`（脚本/边界补充说明，不再重复主流程）
- `scripts/verify-pricing-raw.sh`

## 价格字段标准口径

维护模型价格时，默认按这 4 类价格拆开，不要混写：

- `input_cost_per_token`：输入价格
- `output_cost_per_token`：输出价格
- `cache_creation_input_token_cost`：缓存写入价格
- `cache_read_input_token_cost`：缓存读取价格

如果某一项价格没有官方口径，就不要猜。  
先确认来源，再写入本仓库。

## 标准设置步骤

以后新增模型、修改价格、补缓存价格，统一按下面流程：

### 1. 修改 pricing JSON

编辑：

```text
pricing/model_prices_and_context_window.json
```

按模型名补充或更新条目。  
如果业务里同时存在别名，例如 `glm-5.2` / `a/glm-5.2`，就两边一起维护，不要只改一边。

### 2. 重新生成 sha256

```bash
shasum -a 256 pricing/model_prices_and_context_window.json | awk '{print $1}' > pricing/model_prices_and_context_window.sha256
```

### 3. 提交并 push

```bash
git add pricing/model_prices_and_context_window.json pricing/model_prices_and_context_window.sha256
git commit -m "pricing: update <model-or-purpose>"
git push origin master
```

### 4. 用固定 commit 验证 raw 文件

先拿到 commit：

```bash
git rev-parse HEAD
```

再验证：

```bash
./scripts/verify-pricing-raw.sh <commit>
```

这里要求 verify 脚本通过，至少确认：

- 当前 fixed commit 对应的 raw 文件可用
- `.json` 和 `.sha256` 一致
- 关键模型条目没有丢

具体校验项见 `docs/pricing-raw-maintenance.md`。

### 5. 生产/业务仓必须 pin 到这个固定 commit

生产配置只能使用 **文件级 raw URL**，并且必须 pin 到本仓库固定 commit。

正确：

```text
https://raw.githubusercontent.com/mason0510/sublb-config/<commit>/pricing/model_prices_and_context_window.json
https://raw.githubusercontent.com/mason0510/sublb-config/<commit>/pricing/model_prices_and_context_window.sha256
```

不要使用：

- 分支 URL
- 目录 raw URL
- 第三方上游仓库固定 commit

## 维护原则

- 以后 SubLB 自己维护自己的 pricing，不再依赖第三方 pricing 仓库做最终真值。
- 价格更新后，要同时考虑：
  - pricing 源是否已更新
  - 业务仓默认 pin 是否已切到新 commit
  - 本地 fallback / 动态 pricing / 计费测试是否一致
- 遇到类似问题，先查本仓库，再查主业务仓代码，不要盲人摸象。

## 补充说明

如需查看脚本实现细节和补充边界说明，再看：

```text
docs/pricing-raw-maintenance.md
```
