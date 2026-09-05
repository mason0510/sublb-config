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
ARCHIVE_ROOT="${ARCHIVE_ROOT:-${TMPDIR:-/tmp}/sublb-pricing-verify-archive}"

log() { printf '[pricing raw verify] %s\n' "$*"; }
fail() { printf '[pricing raw verify][错误] %s\n' "$*" >&2; exit 1; }

cleanup() {
  if [[ "${KEEP_WORK_DIR}" != "1" && -n "${WORK_DIR:-}" && -d "$WORK_DIR" ]]; then
    mkdir -p "$ARCHIVE_ROOT"
    archive_path="${ARCHIVE_ROOT}/$(basename "$WORK_DIR").$(date +%s)"
    mv "$WORK_DIR" "$archive_path"
    log "work_dir_archived=${archive_path}"
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
cat >"$WORK_DIR/raw-dir.hurl" <<EOF
GET ${RAW_BASE}/
HTTP *
[Asserts]
status != 200
EOF
hurl -o "$WORK_DIR/raw_dir_response.txt" "$WORK_DIR/raw-dir.hurl" >/dev/null || fail "目录 raw URL 意外返回 200，请勿使用目录 URL：${RAW_BASE}/"
log "directory_url_status=non-200（预期非 200）"

cat >"$WORK_DIR/raw-json.hurl" <<EOF
GET ${JSON_URL}
HTTP 200
EOF
cat >"$WORK_DIR/raw-sha.hurl" <<EOF
GET ${SHA_URL}
HTTP 200
EOF
hurl -o "$JSON_FILE" "$WORK_DIR/raw-json.hurl" >/dev/null || fail "pricing raw JSON 下载失败"
hurl -o "$SHA_FILE" "$WORK_DIR/raw-sha.hurl" >/dev/null || fail "pricing raw SHA256 下载失败"

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
    'claude-opus-5': (5e-06, 5e-07, 6.25e-06, 1e-05, 2.5e-05),
    'claude-sonnet-5': (2e-06, 2e-07, 2.5e-06, 4e-06, 1e-05),
    'claude-fable-5': (1e-05, 1e-06, 1.25e-05, 2e-05, 5e-05),
    'claude-fable-5-1': (1e-05, 1e-06, 1.25e-05, 2e-05, 5e-05),
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

required_gpt56 = {
    'gpt-5.6-sol': (5e-06, 3e-05, 6.25e-06, 5e-07),
    'gpt-5.6-terra': (2e-06, 1.2e-05, 2.5e-06, 2e-07),
    'gpt-5.6-luna': (2e-07, 1.2e-06, 2.5e-07, 2e-08),
    'gpt-6-astra': (1e-05, 5e-05, 1.25e-05, 1e-06),
}
gpt56_keys = [
    'input_cost_per_token',
    'output_cost_per_token',
    'cache_creation_input_token_cost',
    'cache_read_input_token_cost',
]
for model, expected in required_gpt56.items():
    item = data.get(model)
    if not item:
        raise SystemExit(f'[pricing raw verify][错误] missing_model={model}')
    actual = tuple(item.get(k) for k in gpt56_keys)
    if actual != expected:
        raise SystemExit(f'[pricing raw verify][错误] price_mismatch model={model} actual={actual} expected={expected}')
    print('[pricing raw verify] model_ok=' + model + ' ' + ' '.join(f'{k}={item.get(k)}' for k in gpt56_keys))

grok_models = {
    'grok-4.3': {
        'input_cost_per_token': 1.25e-06,
        'cache_read_input_token_cost': 2e-07,
        'output_cost_per_token': 2.5e-06,
        'input_cost_per_token_above_200k_tokens': 2.5e-06,
        'cache_read_input_token_cost_above_200k_tokens': 4e-07,
        'output_cost_per_token_above_200k_tokens': 5e-06,
        'max_input_tokens': 1000000,
    },
    'grok-4.5': {
        'input_cost_per_token': 2e-06,
        'cache_read_input_token_cost': 5e-07,
        'output_cost_per_token': 6e-06,
        'input_cost_per_token_above_200k_tokens': 4e-06,
        'cache_read_input_token_cost_above_200k_tokens': 1e-06,
        'output_cost_per_token_above_200k_tokens': 1.2e-05,
        'max_input_tokens': 500000,
    },
    'grok-4.6': {
        'input_cost_per_token': 2e-06,
        'cache_read_input_token_cost': 5e-07,
        'output_cost_per_token': 6e-06,
        'input_cost_per_token_above_200k_tokens': 4e-06,
        'cache_read_input_token_cost_above_200k_tokens': 1e-06,
        'output_cost_per_token_above_200k_tokens': 1.2e-05,
        'max_input_tokens': 500000,
    },
    'grok-4.20-beta': {
        'input_cost_per_token': 1.25e-06,
        'cache_read_input_token_cost': 2e-07,
        'output_cost_per_token': 2.5e-06,
        'input_cost_per_token_above_200k_tokens': 2.5e-06,
        'cache_read_input_token_cost_above_200k_tokens': 4e-07,
        'output_cost_per_token_above_200k_tokens': 5e-06,
        'max_input_tokens': 1000000,
    },
}
for model, expected_fields in grok_models.items():
    item = data.get(model)
    if not item:
        raise SystemExit(f'[pricing raw verify][错误] missing_model={model}')
    for key, expected in expected_fields.items():
        actual = item.get(key)
        if actual != expected:
            raise SystemExit(
                f'[pricing raw verify][错误] price_mismatch model={model} key={key} '
                f'actual={actual} expected={expected}'
            )
    print('[pricing raw verify] model_ok=' + model + ' ' + ' '.join(
        f'{key}={item.get(key)}' for key in expected_fields
    ))
PY

log "验证完成：文件级 raw URL 可下载，hash 一致，关键 Claude pricing 存在。"
