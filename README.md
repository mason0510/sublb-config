# sublb-config

SubLB 自维护公开配置源。

这个仓库现在是 **SubLB pricing 真值源唯一主入口**。  
以后遇到模型价格、缓存价格、raw URL、固定 commit pin、hash 校验这类问题，默认先看这里，不再去上游仓库盲找。

## Pricing 相关文件

- `pricing/model_prices_and_context_window.json`
- `pricing/model_prices_and_context_window.sha256`
- `docs/pricing-raw-maintenance.md`（脚本/边界补充说明，不再重复主流程）
- `scripts/verify-pricing-raw.sh`
- `scripts/activate-pricing-pin.sh`（生产集群激活、逐节点回读与失败回滚的唯一入口）

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

### 5. 用唯一入口激活生产集群

先执行 dry-run：

```bash
./scripts/activate-pricing-pin.sh \
  --base-url https://sub-lb.tap365.org \
  --commit <40位小写commit SHA> \
  --model <本次修改的目标模型> \
  --evidence-dir <空目录> \
  --dry-run
```

dry-run 通过后，去掉 `--dry-run` 执行唯一写操作。脚本会逐个调用三个生产实例的
loopback 管理接口，使每个实例立即完成以下动作：

1. 下载同一个固定 commit；
2. 校验 SHA256；
3. 更新进程内价格；
4. 更新该实例真实 `PRICING_DATA_DIR` 下的 `model_pricing.json`、
   `model_pricing.sha256`、`model_pricing.commit`；
5. 回读目标模型输入、输出、缓存写入、缓存读取价格；
6. 任一实例失败时，按 preflight 的旧 commit 对集群执行回滚。

三个节点因为写入同一个共享 pin，必须串行执行；这属于同一资源写冲突，不做并发 PUT。
不要手工猜测 `model_pricing.json` 路径，脚本优先从服务进程环境读取 `PRICING_DATA_DIR`，
再使用登记的节点默认目录做受限回退。

生产默认节点：

| 节点 | 服务 | 运行时价格目录 |
|---|---|---|
| `ovh-51-79-158-64-via-cn-tencent` | `sublb.service` | `/srv/sub2api/data/pricing` |
| `82.29.54.254` | `sub2api-254.service` | `/srv/sub2api-254/shared/data/pricing` |
| `74.48.114.71` | `sublb.service` | `/srv/sublb/shared/data/pricing` |

`model_pricing.json` 是各实例运行缓存，不是第二份价格真值。禁止脱离固定 commit 和激活
入口长期手工维护它；紧急恢复也必须保留备份、同步 `.sha256/.commit` 并回读进程内价格。

### 6. 验证真实调用计费

集群文件一致仍不足以证明业务完成。激活后必须产生或等待一条目标模型真实调用，再用
Hurl 查询 `/api/v1/admin/usage`，核对：

- 调用时间晚于集群激活完成时间；
- `billing_model` 是目标模型；
- `input_cost/input_tokens` 等于新输入单价；
- `output_cost/output_tokens` 等于新输出单价；
- 缓存 token 非零时，缓存成本反算等于新缓存单价；
- `total_cost` 与四类成本之和一致。

没有激活后的真实调用样本时，状态只能写“集群配置已收敛，真实计费待样本复核”。

### 7. 固定 commit URL 边界

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

## 生产收口检查

把 pricing 仓改完并 pin 到固定 commit 后，业务仓至少再确认这 3 件事：

1. `origin/master`、raw JSON 和 raw SHA256 固定在同一个 commit；
2. active pin 等于该 commit；
3. 三节点 `model_pricing.commit`、文件 SHA256 和目标模型四类价格完全一致；
4. 三节点服务进程内价格通过各自 loopback PUT 响应证明已加载；
5. 激活后的真实 usage 调用按新价计费；
6. evidence 目录存在，仓库工作区干净。

如果这里只改了 pricing 仓，没有完成业务仓 pin/readback，就不要算完成。

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
