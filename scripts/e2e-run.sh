#!/bin/bash
# scripts/e2e-run.sh
#
# Per-PR/per-release E2E runner. Clones the bootstrapped VM, runs the
# full fresh-install flow inside it against macmini's Immich, tears
# down the clone. Eric's cleanup rule: the VM is deleted on success
# AND on failure.
#
# Prereqs:
#   - scripts/e2e-bootstrap-vm.sh has been run once (creates immich-test-base)
#   - scripts/e2e-host-portforward.sh can be started (needs socat)
#   - macmini's OrbStack is running the immich_server/postgres/redis stack
#
# Usage: scripts/e2e-run.sh

set -euo pipefail

export PATH="/opt/homebrew/bin:$PATH"

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BOOTSTRAP_VM="immich-test-base"
TS=$(date +%Y%m%d-%H%M%S)
TEST_VM="immich-test-run-$TS"
VM_USER="admin"
VM_PASSWORD="admin"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5)

log() { printf '[e2e-run %s] %s\n' "$(date +%H:%M:%S)" "$*"; }

# ------------------- Pre-flight ----------------------
if ! command -v tart >/dev/null; then
    log "tart missing. Run: brew install cirruslabs/cli/tart"
    exit 1
fi
if ! tart list | awk 'NR>1 {print $2}' | grep -qx "$BOOTSTRAP_VM"; then
    log "$BOOTSTRAP_VM missing. Run: scripts/e2e-bootstrap-vm.sh first."
    exit 1
fi
if ! command -v sshpass >/dev/null; then
    log "sshpass missing. Run: brew install hudochenkov/sshpass/sshpass"
    exit 1
fi
if ! command -v socat >/dev/null; then
    log "socat missing. Run: brew install socat"
    exit 1
fi

# Check immich_server is running
if ! "$HOME/.orbstack/bin/docker" ps --format '{{.Names}}' 2>/dev/null | grep -qx immich_server; then
    log "immich_server is not running in OrbStack. Aborting."
    exit 1
fi

# Resolve DB password from env Immich
DB_PASSWORD=$("$HOME/.orbstack/bin/docker" inspect immich_server \
    --format '{{range .Config.Env}}{{println .}}{{end}}' \
    | awk -F= '/^DB_PASSWORD=/{print $2}')
if [ -z "$DB_PASSWORD" ]; then
    log "could not resolve DB_PASSWORD from immich_server env"
    exit 1
fi

# Immich API key from vault
if [ -f "$HOME/vault/secrets/services.yml" ] && command -v yq >/dev/null; then
    IMMICH_API_KEY=$(yq '.services.immich.api_key' "$HOME/vault/secrets/services.yml" 2>/dev/null)
fi
if [ -z "${IMMICH_API_KEY:-}" ] || [ "$IMMICH_API_KEY" = "null" ]; then
    log "IMMICH_API_KEY not found in vault and not set in env"
    exit 1
fi

# ------------------- Cleanup trap ----------------------
cleanup() {
    log "tearing down..."
    "$REPO_DIR/scripts/e2e-host-portforward.sh" stop 2>/dev/null || true
    tart stop --force "$TEST_VM" 2>/dev/null || true
    tart delete "$TEST_VM" 2>/dev/null || true
    log "cleanup done. (base VM and OCI image retained — run scripts/tart-cleanup.sh --all to free them)"
}
trap cleanup EXIT

# ------------------- Host port forwarders ----------------------
log "starting host port forwarders (192.168.64.1 -> 127.0.0.1)"
"$REPO_DIR/scripts/e2e-host-portforward.sh" start

# ------------------- Clone VM ----------------------
log "cloning $BOOTSTRAP_VM -> $TEST_VM"
tart clone "$BOOTSTRAP_VM" "$TEST_VM"

log "starting $TEST_VM"
tart run --no-graphics --net-softnet "$TEST_VM" &
TART_PID=$!

# Wait for IP + SSH
log "waiting for VM IP..."
VM_IP=""
for _ in $(seq 1 60); do
    VM_IP=$(tart ip "$TEST_VM" 2>/dev/null || true)
    if [ -n "$VM_IP" ]; then break; fi
    sleep 2
done
[ -z "$VM_IP" ] && { log "VM never acquired IP"; exit 3; }
log "VM IP: $VM_IP"

log "waiting for VM SSH..."
for _ in $(seq 1 30); do
    if sshpass -p "$VM_PASSWORD" ssh "${SSH_OPTS[@]}" "$VM_USER@$VM_IP" "echo ok" 2>/dev/null; then
        break
    fi
    sleep 2
done

# ------------------- Copy test script into VM ----------------------
log "copying e2e-fresh-install.sh into VM"
sshpass -p "$VM_PASSWORD" scp "${SSH_OPTS[@]}" \
    "$REPO_DIR/scripts/e2e-fresh-install.sh" \
    "$VM_USER@$VM_IP:/tmp/e2e-fresh-install.sh"

# ------------------- Run test ----------------------
log "running E2E inside VM..."
set +e
sshpass -p "$VM_PASSWORD" ssh "${SSH_OPTS[@]}" "$VM_USER@$VM_IP" \
    "IMMICH_URL=http://192.168.64.1:12283 \
     IMMICH_API_KEY='$IMMICH_API_KEY' \
     DB_HOST=192.168.64.1 DB_PORT=15432 DB_PASSWORD='$DB_PASSWORD' \
     REDIS_HOST=192.168.64.1 REDIS_PORT=16379 \
     bash /tmp/e2e-fresh-install.sh"
RC=$?
set -e

if [ $RC -eq 0 ]; then
    log "E2E PASSED"
else
    log "E2E FAILED (exit $RC)"
fi

exit $RC
