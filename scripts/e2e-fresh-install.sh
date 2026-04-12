#!/bin/bash
# scripts/e2e-fresh-install.sh
#
# Runs INSIDE a fresh macOS VM. Performs the full fresh-install flow:
# tap → install → setup → start → dashboard → teardown, then reports
# pass/fail. Designed to catch the #17/#18 class of bug end-to-end.
#
# Inputs (via env vars):
#   IMMICH_URL          e.g. http://192.168.64.1:12283
#   IMMICH_API_KEY
#   DB_HOST             e.g. 192.168.64.1
#   DB_PORT             e.g. 15432
#   DB_PASSWORD
#   REDIS_HOST          e.g. 192.168.64.1
#   REDIS_PORT          e.g. 16379
#   TAP_REPO            e.g. epheterson/immich-accelerator (default)
#   UPLOAD_MOUNT        e.g. /Users/admin/test-upload
#
# Exit codes: 0=pass, 1=general failure, 2-9=specific failures

set -euo pipefail

: "${IMMICH_URL:?set IMMICH_URL}"
: "${IMMICH_API_KEY:?set IMMICH_API_KEY}"
: "${DB_HOST:=192.168.64.1}"
: "${DB_PORT:=15432}"
: "${DB_PASSWORD:?set DB_PASSWORD}"
: "${REDIS_HOST:=192.168.64.1}"
: "${REDIS_PORT:=16379}"
: "${TAP_REPO:=epheterson/immich-accelerator}"
: "${UPLOAD_MOUNT:=/tmp/e2e-upload}"

eval "$(/opt/homebrew/bin/brew shellenv)"

log() { printf '[e2e] %s\n' "$*"; }
fail() { printf '[e2e FAIL] %s\n' "$*" >&2; exit "${2:-1}"; }

mkdir -p "$UPLOAD_MOUNT"

# -------------------------------------------------------------------
# 1. Tap + install (tests formula post_install, ml venv build, wrapper)
# -------------------------------------------------------------------
log "step 1: brew tap + install immich-accelerator"
brew tap "$TAP_REPO" 2>&1 | tail -3
brew install --quiet immich-accelerator 2>&1 | tail -10 \
    || fail "brew install failed" 2

log "step 2: immich-accelerator --version (tests wrapper + ml venv python)"
VER=$(immich-accelerator --version 2>&1) \
    || fail "--version failed: $VER" 3
log "  version: $VER"

# -------------------------------------------------------------------
# 3. Dashboard-imports smoke test
#    Directly exercises the regression from issue #17.
# -------------------------------------------------------------------
log "step 3: dashboard imports resolve under the formula's python"
LIBEXEC="$(brew --prefix immich-accelerator)/libexec"
"$LIBEXEC/ml/venv/bin/python3.11" -c "
import sys
sys.path.insert(0, '$LIBEXEC')
from immich_accelerator.dashboard import create_app
app = create_app({'version':'t','immich_url':'http://x','api_key':'','db_hostname':'','db_port':'5432','redis_hostname':'','redis_port':'6379','server_dir':'/tmp','ml_port':3003})
assert type(app).__name__ == 'FastAPI', f'expected FastAPI, got {type(app).__name__}'
print('dashboard.create_app OK')
" || fail "dashboard imports do not resolve (issue #17 class)" 4

# -------------------------------------------------------------------
# 4. Setup against remote Immich (tests corePlugin extraction, #18)
#    We don't drive the interactive prompts — we write the config
#    directly and then invoke the server-extraction code path.
# -------------------------------------------------------------------
log "step 4: download_immich_server for v2.7.4 (tests corePlugin fix)"
"$LIBEXEC/ml/venv/bin/python3.11" -c "
import sys, os, logging
sys.path.insert(0, '$LIBEXEC')
logging.basicConfig(level=logging.INFO)
from pathlib import Path
import immich_accelerator.__main__ as acc
acc.DATA_DIR = Path('/tmp/e2e-data')
acc.DATA_DIR.mkdir(parents=True, exist_ok=True)
server_dir = acc.download_immich_server('2.7.4')
manifest = acc.DATA_DIR / 'build-data' / 'corePlugin' / 'manifest.json'
assert manifest.exists(), f'corePlugin/manifest.json NOT extracted: {manifest}'
assert manifest.stat().st_size > 0, 'manifest.json is empty'
print(f'corePlugin manifest extracted: {manifest.stat().st_size} bytes')
" || fail "corePlugin extraction failed (issue #18 class)" 5

# -------------------------------------------------------------------
# 5. Dashboard HTTP serve + status check
# -------------------------------------------------------------------
log "step 5: write config and start dashboard"
CONFIG_DIR="$HOME/.immich-accelerator"
mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_DIR/config.json" <<JSON
{
  "version": "2.7.4",
  "server_dir": "/tmp/e2e-data/server/2.7.4",
  "node": "$(which node)",
  "immich_url": "$IMMICH_URL",
  "db_hostname": "$DB_HOST",
  "db_port": "$DB_PORT",
  "db_username": "postgres",
  "db_password": "$DB_PASSWORD",
  "db_name": "immich",
  "redis_hostname": "$REDIS_HOST",
  "redis_port": "$REDIS_PORT",
  "upload_mount": "$UPLOAD_MOUNT",
  "ffmpeg_path": "$(which ffmpeg 2>/dev/null || echo /opt/homebrew/bin/ffmpeg)",
  "ml_port": 3003,
  "api_key": "$IMMICH_API_KEY"
}
JSON
chmod 600 "$CONFIG_DIR/config.json"

immich-accelerator dashboard --port 28420 >/tmp/dashboard.log 2>&1 &
DASH_PID=$!
trap 'kill $DASH_PID 2>/dev/null || true' EXIT

# Wait for dashboard to bind
for _ in $(seq 1 15); do
    if curl -sf http://localhost:28420/ >/dev/null 2>&1; then break; fi
    sleep 1
done

if ! curl -sf http://localhost:28420/ >/dev/null; then
    cat /tmp/dashboard.log
    fail "dashboard did not serve / within 15s" 6
fi
log "step 5: dashboard serving HTTP 200 at /"

# -------------------------------------------------------------------
# 6. /api/status returns JSON with version field populated
# -------------------------------------------------------------------
log "step 6: /api/status returns populated JSON"
STATUS=$(curl -sf http://localhost:28420/api/status) \
    || fail "/api/status did not return 200" 7
if ! echo "$STATUS" | grep -q '"version"'; then
    echo "status body: $STATUS" >&2
    fail "/api/status missing version field" 7
fi
log "  status: $(echo "$STATUS" | head -c 200)..."

# -------------------------------------------------------------------
# Cleanup
# -------------------------------------------------------------------
kill "$DASH_PID" 2>/dev/null || true
trap - EXIT

log "ALL CHECKS PASSED"
