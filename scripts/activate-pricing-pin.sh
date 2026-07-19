#!/usr/bin/env bash
# 将已发布的 sublb-config commit SHA 写入 SubLB 受控 pricing pin，并做完整 readback。
# admin key 默认仅从本机 ~/.codex/secrets 的权限 0600 env 文件读取；脚本不会打印密钥。

set -euo pipefail

readonly PRICING_RAW_BASE="https://raw.githubusercontent.com/mason0510/sublb-config"
readonly PRICING_JSON_PATH="pricing/model_prices_and_context_window.json"
readonly PRICING_HASH_PATH="pricing/model_prices_and_context_window.sha256"
readonly ADMIN_PIN_PATH="/api/v1/admin/settings/pricing-config-commit"
readonly PUBLIC_PRICING_PATH="/api/v1/status/models/pricing"

BASE_URL=""
ENV_FILE="${HOME}/.codex/secrets/sub2api-admin-keys.env"
KEY_VAR=""
COMMIT_SHA=""
MODEL="grok-4.5"
EVIDENCE_DIR=""
DRY_RUN=false
TMP_DIR=""
REQUEST_SEQ=0

usage() {
  cat <<'EOF'
用法：
  activate-pricing-pin.sh \
    --base-url https://sub-lb.tap365.org \
    --commit <40位小写commit SHA> \
    --evidence-dir <目录> \
    [--env-file ~/.codex/secrets/sub2api-admin-keys.env] \
    [--key-var SUB2API_ADMIN_KEY_SUB_LB] [--model grok-4.5] [--dry-run]

流程：
  1. 校验指定 commit 的 GitHub raw JSON、SHA256 与目标模型；
  2. 从本机 ~/.codex/secrets/sub2api-admin-keys.env 读取站点对应 key，并做 GET 鉴权预检；
  3. PUT commit SHA（后端再次下载、校验 SHA256 并立即激活）；
  4. GET 回读 active pin，并从公开 pricing 快照确认目标模型已加载；
  5. 在 --evidence-dir 写入证据；远程 pricing 原文为公开数据，管理员响应只写脱敏摘要。

--dry-run 只执行第 1、2 步，不会发送 PUT。
默认仅适用于 https://sub-lb.tap365.org；其他站点必须显式传 --key-var，禁止跨站复用 key。
EOF
}

die() {
  printf '错误：%s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "缺少依赖命令：$1"
}

file_mode() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    stat -f '%Lp' "$1"
    return
  fi
  stat -c '%a' "$1"
}

load_env_value() {
  local env_file="$1"
  local key="$2"
  local line value="" found=false

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in
      "$key="*)
        [[ "$found" == false ]] || die "$env_file 中重复定义了 $key"
        value="${line#*=}"
        found=true
        ;;
      "export $key="*)
        [[ "$found" == false ]] || die "$env_file 中重复定义了 $key"
        value="${line#*=}"
        found=true
        ;;
    esac
  done <"$env_file"

  [[ "$found" == true ]] || die "$env_file 未定义 $key"
  if [[ "$value" == \"*\" && "$value" == *\" ]]; then
    value="${value:1:${#value}-2}"
  elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
    value="${value:1:${#value}-2}"
  fi
  [[ -n "$value" && "$value" != *$'\n'* && "$value" != *$'\r'* && "$value" != *'"'* && "$value" != *"'"* && "$value" != *' '* ]] || die "$env_file 中的 $key 格式非法"
  printf '%s' "$value"
}

save_evidence() {
  local name="$1"
  local source="$2"
  jq -S . "$source" >"$EVIDENCE_DIR/$name"
}

response_error_summary() {
  local response_file="$1"
  jq -r 'if type == "object" then (.code // "") as $code | (.message // "unknown error") as $message | (.reason // "") as $reason | "code=\($code) message=\($message) reason=\($reason)" else "non-JSON response" end' "$response_file" 2>/dev/null || printf 'non-JSON response'
}

api_request() {
  local method="$1"
  local path="$2"
  local body_file="${3:-}"
  local response_file case_file
  REQUEST_SEQ=$((REQUEST_SEQ + 1))
  response_file="$TMP_DIR/response-$REQUEST_SEQ.json"
  case_file="$TMP_DIR/request-$REQUEST_SEQ.hurl"
  {
    printf '%s %s\n' "$method" "$BASE_URL$path"
    printf 'Authorization: Bearer {{api_key}}\n'
    if [[ "$method" != "GET" ]]; then
      printf 'Content-Type: application/json\n\n'
      cat "$body_file"
      printf '\n'
    else
      printf '\n'
    fi
    printf 'HTTP *\n'
  } >"$case_file"
  hurl --secret "api_key=$API_KEY" -o "$response_file" "$case_file" >/dev/null || die "请求 $method $path 失败：$(response_error_summary "$response_file")"
  jq -e '.code == 0 and (.data | type == "object")' "$response_file" >/dev/null || die "请求 $method $path 返回业务失败：$(response_error_summary "$response_file")"
  printf '%s\n' "$response_file"
}

fetch_raw_source() {
  local json_file="$TMP_DIR/pricing.json"
  local hash_file="$TMP_DIR/pricing.sha256"
  local expected_hash actual_hash model_file

  cat >"$TMP_DIR/raw-json.hurl" <<EOF
GET $PRICING_RAW_BASE/$COMMIT_SHA/$PRICING_JSON_PATH
HTTP 200
EOF
  cat >"$TMP_DIR/raw-hash.hurl" <<EOF
GET $PRICING_RAW_BASE/$COMMIT_SHA/$PRICING_HASH_PATH
HTTP 200
EOF
  hurl -o "$json_file" "$TMP_DIR/raw-json.hurl" >/dev/null || die "无法下载 pricing raw JSON"
  hurl -o "$hash_file" "$TMP_DIR/raw-hash.hurl" >/dev/null || die "无法下载 pricing raw SHA256"

  expected_hash="$(tr -d '[:space:]' <"$hash_file" | tr '[:upper:]' '[:lower:]')"
  [[ "$expected_hash" =~ ^[0-9a-fA-F]{64}$ ]] || die "pricing raw SHA256 格式非法"
  actual_hash="$(shasum -a 256 "$json_file" | awk '{print $1}')"
  [[ "$expected_hash" == "$actual_hash" ]] || die "pricing raw SHA256 不一致"
  jq -e --arg model "$MODEL" '.[$model] | objects | select(has("input_cost_per_token") and has("output_cost_per_token"))' "$json_file" >/dev/null || die "pricing raw JSON 中不存在可计费模型：$MODEL"

  model_file="$TMP_DIR/raw-model.json"
  jq -S --arg model "$MODEL" --arg commit "$COMMIT_SHA" --arg sha "$actual_hash" \
    '{commit_sha: $commit, sha256: $sha, model: $model, pricing: .[$model]}' "$json_file" >"$model_file"
  save_evidence raw-source.json "$model_file"
}

verify_admin_response() {
  local response_file="$1"
  local phase="$2"
  jq -e --arg commit "$COMMIT_SHA" '
    .data.commit_sha == $commit and
    .data.pricing_status.config_commit_sha == $commit and
    (.data.pricing_status.model_count | type == "number" and . > 0)
  ' "$response_file" >/dev/null || die "$phase 管理员回读与目标 pin 不一致"
}

verify_public_model() {
  local response_file="$TMP_DIR/public-pricing.json"
  local model_file
  cat >"$TMP_DIR/public-pricing.hurl" <<EOF
GET $BASE_URL$PUBLIC_PRICING_PATH
HTTP 200
EOF
  hurl -o "$response_file" "$TMP_DIR/public-pricing.hurl" >/dev/null || die "读取公开 pricing 快照失败"
  jq -e --arg model "$MODEL" '.code == 0 and ([.. | objects | select(.name? == $model and (.tiers? | type == "array") and (.tiers | length > 0))] | length > 0)' "$response_file" >/dev/null || die "公开 pricing 快照未发现已加载模型：$MODEL"

  model_file="$TMP_DIR/public-model.json"
  jq -S --arg model "$MODEL" '{model: $model, entries: [.. | objects | select(.name? == $model and (.tiers? | type == "array")) | {name, description, depths, tiers}]}' "$response_file" >"$model_file"
  save_evidence public-model-pricing.json "$model_file"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-url) BASE_URL="${2:-}"; shift 2 ;;
    --env-file) ENV_FILE="${2:-}"; shift 2 ;;
    --key-var) KEY_VAR="${2:-}"; shift 2 ;;
    --commit) COMMIT_SHA="${2:-}"; shift 2 ;;
    --model) MODEL="${2:-}"; shift 2 ;;
    --evidence-dir) EVIDENCE_DIR="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done

require_command hurl
require_command jq
require_command shasum
[[ "$BASE_URL" =~ ^https://[^/?#]+$ ]] || die "--base-url 必须是无路径的 HTTPS 地址"
BASE_URL="${BASE_URL%/}"
if [[ -z "$KEY_VAR" ]]; then
  case "$BASE_URL" in
    https://sub-lb.tap365.org) KEY_VAR="SUB2API_ADMIN_KEY_SUB_LB" ;;
    *) die "非默认站点必须显式传 --key-var，禁止跨站复用管理员 key" ;;
  esac
fi
[[ "$KEY_VAR" =~ ^[A-Z_][A-Z0-9_]*$ ]] || die "--key-var 格式非法"
[[ "$COMMIT_SHA" =~ ^[0-9a-f]{40}$ ]] || die "--commit 必须是 40 位小写十六进制 commit SHA"
[[ -n "$MODEL" ]] || die "--model 不能为空"
[[ -n "$EVIDENCE_DIR" ]] || die "--evidence-dir 不能为空"
[[ -f "$ENV_FILE" ]] || die "--env-file 不存在或不是普通文件"
[[ "$(file_mode "$ENV_FILE")" == "600" ]] || die "--env-file 权限必须为 0600"
if git -C "$(dirname "$0")/.." ls-files --error-unmatch -- "$ENV_FILE" >/dev/null 2>&1; then
  die "--env-file 已被 Git 跟踪，禁止使用"
fi
if [[ "$ENV_FILE" == ./* || "$ENV_FILE" == .env ]]; then
  git -C "$(dirname "$0")/.." check-ignore -q -- "$ENV_FILE" || die "仓库内 --env-file 必须被 Git 忽略"
fi

API_KEY="$(load_env_value "$ENV_FILE" "$KEY_VAR")"

if [[ -e "$EVIDENCE_DIR" ]]; then
  [[ -d "$EVIDENCE_DIR" ]] || die "--evidence-dir 已存在但不是目录"
  [[ -z "$(find "$EVIDENCE_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]] || die "--evidence-dir 必须为空目录"
else
  mkdir -p "$EVIDENCE_DIR"
fi
chmod 700 "$EVIDENCE_DIR"

TMP_DIR="$EVIDENCE_DIR/.work"
mkdir -p "$TMP_DIR"
chmod 700 "$TMP_DIR"
umask 077

fetch_raw_source
preflight_response="$(api_request GET "$ADMIN_PIN_PATH")"
jq -S '{phase: "preflight", configured: (.data.configured // false), commit_sha: (.data.commit_sha // ""), pricing_status: (.data.pricing_status // {})}' "$preflight_response" >"$TMP_DIR/preflight.json"
save_evidence preflight.json "$TMP_DIR/preflight.json"

if [[ "$DRY_RUN" == true ]]; then
  printf 'dry_run_ok=true commit_sha=%s model=%s evidence_dir=%s\n' "$COMMIT_SHA" "$MODEL" "$EVIDENCE_DIR"
  exit 0
fi

jq -n --arg commit "$COMMIT_SHA" '{commit_sha: $commit}' >"$TMP_DIR/update.json"
update_response="$(api_request PUT "$ADMIN_PIN_PATH" "$TMP_DIR/update.json")"
jq -e --arg commit "$COMMIT_SHA" '
  .data.commit_sha == $commit and
  .data.activated == true and
  (.data.verified_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
  .data.pricing_status.config_commit_sha == $commit and
  (.data.pricing_status.model_count | type == "number" and . > 0)
' "$update_response" >/dev/null || die "PUT 已返回但未证明 pricing pin 已激活"
jq -S '{phase: "update", commit_sha: .data.commit_sha, activated: .data.activated, verified_sha256: .data.verified_sha256, model_count: .data.pricing_status.model_count, pricing_status: .data.pricing_status}' "$update_response" >"$TMP_DIR/update-result.json"
save_evidence update-result.json "$TMP_DIR/update-result.json"

readback_response="$(api_request GET "$ADMIN_PIN_PATH")"
verify_admin_response "$readback_response" "PUT 后"
jq -S '{phase: "readback", configured: (.data.configured // false), commit_sha: .data.commit_sha, pricing_status: .data.pricing_status}' "$readback_response" >"$TMP_DIR/readback.json"
save_evidence readback.json "$TMP_DIR/readback.json"
verify_public_model

printf 'activated=true commit_sha=%s model=%s evidence_dir=%s\n' "$COMMIT_SHA" "$MODEL" "$EVIDENCE_DIR"
