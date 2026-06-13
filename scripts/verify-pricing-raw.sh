#!/usr/bin/env bash
# 校验 SubLB 自维护 pricing raw 文件：必须使用文件级 raw URL，禁止使用目录 URL。
set -euo pipefail

OWNER="${OWNER:-mason0510}"
REPO="${REPO:-sublb-config}"
REF="${1:-${REF:-$(git rev-parse HEAD 2>/dev/null || echo master)}}"
RAW_BASE="https://raw.githubusercontent.com/${OWNER}/${REPO}/${REF}/pricing"
JSON_URL="${RAW_BASE}/model_prices_and_context_window.json"
SHA_URL="${RAW_BASE}/model_prices_and_context_window.sha256"
WORK_DIR="${WORK_DIR:-$(mktemp -d)}"
KEEP_WORK_DIR="${KEEP_WORK_DIR:-0}"

log() { printf '[pricing raw verify] %s\n' "$*"; }
fail() { printf '[pricing raw verify][错误] %s\n' "$*" >&2; exit 1; }

cleanup() {
  if [[ "${KEEP_WORK_DIR}" != "1" && -n "${WORK_DIR:-}" && -d "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

mkdir -p "$WORK_DIR"
JSON_FILE="$WORK_DIR/model_prices_and_context_window.json"
SHA_FILE="$WORK_DIR/model_prices_and_context_window.sha256"

log "ref=${REF}"
log "json_url=${JSON_URL}"
log "sha_url=${SHA_URL}"
log "work_dir=${WORK_DIR}"

# 目录 raw URL 应该不可用；这一步用于防止把 /pricing/ 当成 remote_url。
DIR_STATUS="$(curl -sS -o "$WORK_DIR/raw_dir_response.txt" -w '%{http_code}' "${RAW_BASE}/" || true)"
if [[ "$DIR_STATUS" == "200" ]]; then
  fail "目录 raw URL 意外返回 200，请勿使用目录 URL：${RAW_BASE}/"
fi
log "directory_url_status=${DIR_STATUS}（预期非 200）"

curl -fsSL "$JSON_URL" -o "$JSON_FILE"
curl -fsSL "$SHA_URL" -o "$SHA_FILE"

EXPECTED_SHA="$(tr -d '[:space:]' < "$SHA_FILE")"
ACTUAL_SHA="$(shasum -a 256 "$JSON_FILE" | awk '{print $1}')"
[[ -n "$EXPECTED_SHA" ]] || fail "sha256 文件为空"
[[ "$EXPECTED_SHA" == "$ACTUAL_SHA" ]] || fail "sha256 不一致 expected=${EXPECTED_SHA} actual=${ACTUAL_SHA}"
log "sha256_ok=${ACTUAL_SHA}"

python3 - "$JSON_FILE" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, 'r', encoding='utf-8') as f:
    data = json.load(f)
required = {
    'claude-opus-4-6': (5e-06, 5e-07, 6.25e-06, 1e-05, 2.5e-05),
    'claude-opus-4-7': (5e-06, 5e-07, 6.25e-06, 1e-05, 2.5e-05),
    'claude-opus-4-8': (5e-06, 5e-07, 6.25e-06, 1e-05, 2.5e-05),
}
keys = [
    'input_cost_per_token',
    'cache_read_input_token_cost',
    'cache_creation_input_token_cost',
    'cache_creation_input_token_cost_above_1hr',
    'output_cost_per_token',
]
print(f'[pricing raw verify] models_count={len(data)}')
for model, expected in required.items():
    item = data.get(model)
    if not item:
        raise SystemExit(f'[pricing raw verify][错误] missing_model={model}')
    actual = tuple(item.get(k) for k in keys)
    if actual != expected:
        raise SystemExit(f'[pricing raw verify][错误] price_mismatch model={model} actual={actual} expected={expected}')
    print('[pricing raw verify] model_ok=' + model + ' ' + ' '.join(f'{k}={item.get(k)}' for k in keys))
PY

log "验证完成：文件级 raw URL 可下载，hash 一致，关键 Claude pricing 存在。"
