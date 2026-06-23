# SubLB pricing raw 补充说明

README.md 才是本仓库的 pricing 维护唯一主流程入口。  
本页只保留补充边界和脚本说明，避免与 README 重复。

## 本页用途

- 补充说明 `scripts/verify-pricing-raw.sh` 的校验目标
- 记录 raw URL 使用边界
- 避免把目录 raw URL 误当成 remote_url

## raw URL 边界

这里不重复 README 的 pin 主流程，只补充一个最容易踩坑的技术边界：

错误示例：

```text
https://raw.githubusercontent.com/mason0510/sublb-config/<commit>/pricing/
```

目录 raw URL 会返回 400/非 200，不能作为 `PRICING_REMOTE_URL`。

## verify 脚本负责什么

`scripts/verify-pricing-raw.sh <commit>` 默认会检查：

1. 目录 raw URL 不是 200
   （即确认目录 raw 返回非 200，避免误配成 remote_url）
2. JSON raw 文件可下载
3. SHA raw 文件可下载
4. 下载后的 JSON 与 SHA256 一致
5. 关键模型条目仍然存在

如果需要修改主流程，请改 README；  
如果只是补充脚本校验边界，再改本页。
