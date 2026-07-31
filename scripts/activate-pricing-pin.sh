#!/usr/bin/env bash
# 将已发布的 sublb-config commit SHA 写入 SubLB 受控 pricing pin，并让所有生产实例立即收敛。
# admin key 默认仅从本机 ~/.codex/secrets 的权限 0600 env 文件读取；脚本不会打印密钥。

set -euo pipefail

readonly PRICING_RAW_BASE="https://raw.githubusercontent.com/mason0510/sublb-config"
readonly PRICING_JSON_PATH="pricing/model_prices_and_context_window.json"
readonly PRICING_HASH_PATH="pricing/model_prices_and_context_window.sha256"
readonly ADMIN_PIN_PATH="/api/v1/admin/settings/pricing-config-commit"
readonly CLAUDE_ALLOWLIST_PATH="/api/v1/admin/settings/claude-pricing-allowlist"

BASE_URL=""
ENV_FILE="${HOME}/.codex/secrets/sub2api-admin-keys.env"
KEY_VAR=""
COMMIT_SHA=""
MODEL="grok-4.5"
EVIDENCE_DIR=""
DRY_RUN=false
SINGLE_INSTANCE=false
TMP_DIR=""
REQUEST_SEQ=0
EXPECTED_HASH=""
EXPECTED_MODEL_B64=""
OLD_COMMIT_SHA=""
OLD_HASH=""
OLD_MODEL_B64=""

# 默认生产拓扑。价格更新必须逐实例触发内存安装，不能只写共享 pin 后等待定时器。
CLUSTER_NODES=(
  "node80|mason-main|sub2api-80.service|/srv/sub2api-80/shared/data/pricing"
  "node254|ny-admin|sub2api-254.service|/srv/sub2api-254/shared/data/pricing"
  "node74|74|sublb.service|/srv/sublb/shared/data/pricing"
)

usage() {
  cat <<'EOF'
用法：
  activate-pricing-pin.sh \
    --base-url https://sub-lb.tap365.org \
    --commit <40位小写commit SHA> \
    --evidence-dir <目录> \
    [--env-file ~/.codex/secrets/sub2api-admin-keys.env] \
    [--key-var SUB2API_ADMIN_KEY_SUB_LB] [--model grok-4.5] [--dry-run]
    [--single-instance]

流程：
  1. 校验指定 commit 的 GitHub raw JSON、SHA256 与目标模型；
  2. 从本机 ~/.codex/secrets/sub2api-admin-keys.env 读取站点对应 key，并做 GET 鉴权预检；
  3. 默认通过各节点 loopback 管理接口串行 PUT 同一 commit，使每个实例立即更新进程内价格及其真实 model_pricing.*；
  4. 每节点回读 service、进程实际 PRICING_DATA_DIR、commit、SHA256、目标模型四类价格；
  5. GET 公网 active pin；若目标是 Claude 系列，自动合并到 Claude billing allowlist并回读；
  6. 任一节点失败时，使用 preflight 旧 commit 对全节点回滚；所有脱敏证据写入 --evidence-dir。

--dry-run 会完成 raw、鉴权与三节点只读 preflight，不会发送 PUT。
--single-instance 仅供非集群维护；对默认生产站点使用时不会形成集群生效证明。
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
    printf 'x-api-key: {{api_key}}\n'
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
  EXPECTED_HASH="$actual_hash"
  EXPECTED_MODEL_B64="$(jq -c --arg model "$MODEL" '.[$model] | {
    input_cost_per_token,
    output_cost_per_token,
    cache_creation_input_token_cost,
    cache_read_input_token_cost
  }' "$json_file" | base64 | tr -d '\n')"
}

fetch_rollback_source() {
  local json_file="$TMP_DIR/rollback-pricing.json"
  local hash_file="$TMP_DIR/rollback-pricing.sha256"
  [[ "$OLD_COMMIT_SHA" =~ ^[0-9a-f]{40}$ ]] || return 1
  cat >"$TMP_DIR/rollback-json.hurl" <<EOF
GET $PRICING_RAW_BASE/$OLD_COMMIT_SHA/$PRICING_JSON_PATH
HTTP 200
EOF
  cat >"$TMP_DIR/rollback-hash.hurl" <<EOF
GET $PRICING_RAW_BASE/$OLD_COMMIT_SHA/$PRICING_HASH_PATH
HTTP 200
EOF
  hurl -o "$json_file" "$TMP_DIR/rollback-json.hurl" >/dev/null
  hurl -o "$hash_file" "$TMP_DIR/rollback-hash.hurl" >/dev/null
  OLD_HASH="$(tr -d '[:space:]' <"$hash_file" | tr '[:upper:]' '[:lower:]')"
  [[ "$OLD_HASH" =~ ^[0-9a-f]{64}$ ]]
  [[ "$OLD_HASH" == "$(shasum -a 256 "$json_file" | awk '{print $1}')" ]]
  OLD_MODEL_B64="$(jq -c --arg model "$MODEL" '.[$model] | {
    input_cost_per_token,
    output_cost_per_token,
    cache_creation_input_token_cost,
    cache_read_input_token_cost
  }' "$json_file" | base64 | tr -d '\n')"
}

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

node_action() {
  local spec="$1" action="$2" commit="$3" expected_hash="$4" expected_model_b64="$5" phase="$6"
  local label host service fallback_dir output_file remote_env
  IFS='|' read -r label host service fallback_dir <<EOF
$spec
EOF
  output_file="$EVIDENCE_DIR/${phase}-${label}.json"
  remote_env="LABEL=$(shell_quote "$label") SERVICE=$(shell_quote "$service") FALLBACK_DIR=$(shell_quote "$fallback_dir") COMMIT_SHA=$(shell_quote "$commit") EXPECTED_HASH=$(shell_quote "$expected_hash") MODEL=$(shell_quote "$MODEL") EXPECTED_MODEL_B64=$(shell_quote "$expected_model_b64") ACTION=$(shell_quote "$action")"
  {
    printf '%s\n' "$API_KEY"
    cat <<'REMOTE'
set -euo pipefail

die() { printf 'node_error=%s\n' "$*" >&2; exit 1; }
command -v hurl >/dev/null 2>&1 || die "missing hurl"
command -v jq >/dev/null 2>&1 || die "missing jq"
[[ "$(systemctl is-active "$SERVICE")" == "active" ]] || die "service not active: $SERVICE"
pid="$(systemctl show -p MainPID --value "$SERVICE")"
[[ "$pid" =~ ^[1-9][0-9]*$ ]] || die "invalid MainPID"

pricing_dir="$(tr '\0' '\n' <"/proc/$pid/environ" | sed -n 's/^PRICING_DATA_DIR=//p' | head -1)"
if [[ -z "$pricing_dir" ]]; then
  data_dir="$(tr '\0' '\n' <"/proc/$pid/environ" | sed -n 's/^DATA_DIR=//p' | head -1)"
  if [[ -n "$data_dir" ]]; then pricing_dir="${data_dir%/}/pricing"; fi
fi
if [[ -z "$pricing_dir" ]]; then pricing_dir="$FALLBACK_DIR"; fi
[[ "$pricing_dir" == /srv/*/shared/data/pricing ]] || die "unexpected pricing dir: $pricing_dir"
[[ -d "$pricing_dir" ]] || die "pricing dir missing: $pricing_dir"

before_commit="$(tr -d '[:space:]' <"$pricing_dir/model_pricing.commit" 2>/dev/null || true)"
before_hash="$(sha256sum "$pricing_dir/model_pricing.json" 2>/dev/null | awk '{print $1}' || true)"
backup_dir=""

if [[ "$ACTION" == "activate" ]]; then
  backup_dir="$pricing_dir/backups/${COMMIT_SHA}-$(date +%Y%m%dT%H%M%S%z)"
  install -d -m 0700 "$backup_dir"
  for name in model_pricing.json model_pricing.sha256 model_pricing.commit; do
    if [[ -f "$pricing_dir/$name" ]]; then cp -p "$pricing_dir/$name" "$backup_dir/$name"; fi
  done
  work_dir="$backup_dir/.work"
  install -d -m 0700 "$work_dir"
  trap 'find "$work_dir" -type f -exec sh -c '\''for f do : >"$f"; done'\'' sh {} + 2>/dev/null || true' EXIT
  cat >"$work_dir/update.hurl" <<EOF
PUT http://127.0.0.1:48090/api/v1/admin/settings/pricing-config-commit
x-api-key: {{api_key}}
Content-Type: application/json

{"commit_sha":"$COMMIT_SHA"}
HTTP 200
EOF
  hurl --secret "api_key=$API_KEY" -o "$work_dir/update.json" "$work_dir/update.hurl" >/dev/null || die "loopback PUT failed"
  jq -e --arg commit "$COMMIT_SHA" --arg hash "$EXPECTED_HASH" '
    .code == 0 and .data.commit_sha == $commit and .data.activated == true and
    .data.verified_sha256 == $hash and .data.pricing_status.config_commit_sha == $commit and
    .data.pricing_status.local_hash == ($hash[0:8]) and .data.pricing_status.source_mode == "config"
  ' "$work_dir/update.json" >/dev/null || die "loopback PUT did not activate expected pricing"
fi

actual_commit="$(tr -d '[:space:]' <"$pricing_dir/model_pricing.commit" 2>/dev/null || true)"
actual_hash="$(sha256sum "$pricing_dir/model_pricing.json" 2>/dev/null | awk '{print $1}' || true)"
actual_model="$(jq -c --arg model "$MODEL" '.[$model] | {
  input_cost_per_token,
  output_cost_per_token,
  cache_creation_input_token_cost,
  cache_read_input_token_cost
}' "$pricing_dir/model_pricing.json" 2>/dev/null || true)"
expected_model="$(printf '%s' "$EXPECTED_MODEL_B64" | base64 -d)"

if [[ "$ACTION" == "activate" ]]; then
  [[ "$actual_commit" == "$COMMIT_SHA" ]] || die "commit readback mismatch"
  [[ "$actual_hash" == "$EXPECTED_HASH" ]] || die "hash readback mismatch"
  [[ "$(jq -S . <<<"$actual_model")" == "$(jq -S . <<<"$expected_model")" ]] || die "model price readback mismatch"
fi

jq -n \
  --arg node "$LABEL" --arg service "$SERVICE" --arg pricing_dir "$pricing_dir" \
  --arg action "$ACTION" --arg before_commit "$before_commit" --arg before_hash "$before_hash" \
  --arg commit "$actual_commit" --arg hash "$actual_hash" --arg backup_dir "$backup_dir" \
  --argjson pricing "${actual_model:-null}" \
  '{node:$node,service:$service,service_active:true,pricing_dir:$pricing_dir,action:$action,
    before:{commit:$before_commit,sha256:$before_hash},
    after:{commit:$commit,sha256:$hash,pricing:$pricing},backup_dir:$backup_dir}'
REMOTE
  } | ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" "$remote_env bash -c 'IFS= read -r API_KEY; export API_KEY; sudo -E bash -s'" >"$output_file"
  jq -S . "$output_file" >"$output_file.tmp"
  mv "$output_file.tmp" "$output_file"
}

run_cluster_action() {
  local action="$1" commit="$2" hash="$3" model_b64="$4" phase="$5" spec
  for spec in "${CLUSTER_NODES[@]}"; do
    node_action "$spec" "$action" "$commit" "$hash" "$model_b64" "$phase" || return 1
  done
}

rollback_cluster() {
  [[ "$OLD_COMMIT_SHA" =~ ^[0-9a-f]{40}$ ]] || return 1
  fetch_rollback_source || return 1
  run_cluster_action activate "$OLD_COMMIT_SHA" "$OLD_HASH" "$OLD_MODEL_B64" rollback
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

is_claude_pricing_model() {
  local normalized
  normalized="$(printf '%s' "$MODEL" | tr '[:upper:]' '[:lower:]')"
  [[ "$normalized" == claude-* || "$normalized" == *opus* || "$normalized" == *sonnet* || "$normalized" == *haiku* || "$normalized" == *fable* ]]
}

sync_claude_pricing_allowlist() {
  local preflight_response update_response readback_response payload_file

  if ! is_claude_pricing_model; then
    return 0
  fi

  preflight_response="$(api_request GET "$CLAUDE_ALLOWLIST_PATH")"
  jq -e '.data.models | type == "array"' "$preflight_response" >/dev/null || die "Claude allowlist 预检返回缺少 models 数组"
  jq -S --arg model "$MODEL" '{phase: "preflight", target_model: $model, models: .data.models}' "$preflight_response" >"$TMP_DIR/claude-allowlist-preflight.json"
  save_evidence claude-allowlist-preflight.json "$TMP_DIR/claude-allowlist-preflight.json"

  if jq -e --arg model "$MODEL" '.data.models | index($model) != null' "$preflight_response" >/dev/null; then
    jq -S --arg model "$MODEL" '{phase: "unchanged", target_model: $model, models: .data.models}' "$preflight_response" >"$TMP_DIR/claude-allowlist-readback.json"
    save_evidence claude-allowlist-readback.json "$TMP_DIR/claude-allowlist-readback.json"
    return 0
  fi

  payload_file="$TMP_DIR/claude-allowlist-update.json"
  jq -S --arg model "$MODEL" '{models: ((.data.models + [$model]) | unique | sort)}' "$preflight_response" >"$payload_file"
  update_response="$(api_request PUT "$CLAUDE_ALLOWLIST_PATH" "$payload_file")"
  jq -e --arg model "$MODEL" '.data.models | type == "array" and index($model) != null' "$update_response" >/dev/null || die "Claude allowlist 更新后未包含目标模型：$MODEL"
  jq -S --arg model "$MODEL" '{phase: "update", target_model: $model, models: .data.models}' "$update_response" >"$TMP_DIR/claude-allowlist-update.json"
  save_evidence claude-allowlist-update.json "$TMP_DIR/claude-allowlist-update.json"

  readback_response="$(api_request GET "$CLAUDE_ALLOWLIST_PATH")"
  jq -e --arg model "$MODEL" '.data.models | type == "array" and index($model) != null' "$readback_response" >/dev/null || die "Claude allowlist 回读未包含目标模型：$MODEL"
  jq -S --arg model "$MODEL" '{phase: "readback", target_model: $model, models: .data.models}' "$readback_response" >"$TMP_DIR/claude-allowlist-readback.json"
  save_evidence claude-allowlist-readback.json "$TMP_DIR/claude-allowlist-readback.json"
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
    --single-instance) SINGLE_INSTANCE=true; shift ;;
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
OLD_COMMIT_SHA="$(jq -r '.data.commit_sha // empty' "$preflight_response")"

if [[ "$DRY_RUN" == true ]]; then
  if [[ "$SINGLE_INSTANCE" == false ]]; then
    run_cluster_action preflight "$COMMIT_SHA" "$EXPECTED_HASH" "$EXPECTED_MODEL_B64" preflight-node || die "集群节点 preflight 失败"
  fi
  printf 'dry_run_ok=true cluster=%s commit_sha=%s model=%s evidence_dir=%s\n' "$([[ "$SINGLE_INSTANCE" == false ]] && echo true || echo false)" "$COMMIT_SHA" "$MODEL" "$EVIDENCE_DIR"
  exit 0
fi

if [[ "$SINGLE_INSTANCE" == false ]]; then
  if ! run_cluster_action activate "$COMMIT_SHA" "$EXPECTED_HASH" "$EXPECTED_MODEL_B64" activate-node; then
    rollback_cluster || die "集群激活失败，且自动回滚未完整通过；立即检查 evidence"
    die "集群激活失败，已回滚到 $OLD_COMMIT_SHA"
  fi
  update_response="$EVIDENCE_DIR/activate-node-node80.json"
else
  jq -n --arg commit "$COMMIT_SHA" '{commit_sha: $commit}' >"$TMP_DIR/update.json"
  update_response="$(api_request PUT "$ADMIN_PIN_PATH" "$TMP_DIR/update.json")"
fi
jq -e --arg commit "$COMMIT_SHA" '
  if has("data") then
    .data.commit_sha == $commit and .data.activated == true
  else
    .after.commit == $commit
  end
' "$update_response" >/dev/null || die "写入已返回但未证明 pricing pin 已激活"
jq -S --arg phase "update" '{phase:$phase} + .' "$update_response" >"$TMP_DIR/update-result.json"
save_evidence update-result.json "$TMP_DIR/update-result.json"

readback_response="$(api_request GET "$ADMIN_PIN_PATH")"
verify_admin_response "$readback_response" "PUT 后"
jq -S '{phase: "readback", configured: (.data.configured // false), commit_sha: .data.commit_sha, pricing_status: .data.pricing_status}' "$readback_response" >"$TMP_DIR/readback.json"
save_evidence readback.json "$TMP_DIR/readback.json"
sync_claude_pricing_allowlist

printf 'activated=true commit_sha=%s model=%s evidence_dir=%s\n' "$COMMIT_SHA" "$MODEL" "$EVIDENCE_DIR"
