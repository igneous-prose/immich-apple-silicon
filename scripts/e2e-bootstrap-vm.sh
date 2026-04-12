#!/bin/bash
# scripts/e2e-bootstrap-vm.sh
#
# One-time setup: clone the macOS Sonoma base image into a reusable VM
# with Homebrew + python@3.11 + git installed, then snapshot it as the
# baseline every per-PR test clones from. Saves ~10 minutes per run.
#
# Run on macmini. Idempotent — skips work that's already done.
#
# Peak disk cost: ~60GB (base image + bootstrap VM clone).
# Cleanup: scripts/tart-cleanup.sh --all

set -euo pipefail

BASE_IMAGE="ghcr.io/cirruslabs/macos-sonoma-base:latest"
BOOTSTRAP_VM="immich-test-base"
VM_USER="admin"
VM_PASSWORD="admin"

export PATH="/opt/homebrew/bin:$PATH"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

if ! command -v tart >/dev/null; then
    log "tart not installed. Run: brew install cirruslabs/cli/tart"
    exit 1
fi

# 1. Pull base image if missing
if ! tart list | awk 'NR>1 {print $2}' | grep -qx "macos-sonoma-base"; then
    log "Pulling base image $BASE_IMAGE (~30GB, one-time)..."
    tart pull "$BASE_IMAGE"
else
    log "Base image already pulled."
fi

# 2. Clone to bootstrap VM if missing
if ! tart list | awk 'NR>1 {print $2}' | grep -qx "$BOOTSTRAP_VM"; then
    log "Cloning base image into $BOOTSTRAP_VM..."
    tart clone macos-sonoma-base "$BOOTSTRAP_VM"
fi

# 3. Check if already bootstrapped (bootstrap marker file inside VM)
if tart get "$BOOTSTRAP_VM" 2>&1 | grep -q "State: running"; then
    log "$BOOTSTRAP_VM is already running. Assuming someone else is working on it; exiting."
    exit 2
fi

log "Starting $BOOTSTRAP_VM (headless)..."
tart run --no-graphics "$BOOTSTRAP_VM" &
TART_PID=$!
trap 'tart stop --force "$BOOTSTRAP_VM" 2>/dev/null || true; kill $TART_PID 2>/dev/null || true' EXIT

# Wait for VM IP
log "Waiting for VM to boot and acquire IP..."
VM_IP=""
for _ in $(seq 1 60); do
    VM_IP=$(tart ip "$BOOTSTRAP_VM" 2>/dev/null || true)
    if [ -n "$VM_IP" ]; then break; fi
    sleep 2
done
if [ -z "$VM_IP" ]; then
    log "VM did not acquire IP within 2 minutes. Aborting."
    exit 3
fi
log "VM IP: $VM_IP"

# Wait for SSH
log "Waiting for SSH..."
for _ in $(seq 1 30); do
    if sshpass -p "$VM_PASSWORD" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=3 "$VM_USER@$VM_IP" "echo ok" 2>/dev/null; then
        break
    fi
    sleep 2
done

# Check for bootstrap marker — if present, we're already done
if sshpass -p "$VM_PASSWORD" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "$VM_USER@$VM_IP" "test -f /Users/$VM_USER/.bootstrapped" 2>/dev/null; then
    log "VM is already bootstrapped. Stopping and exiting."
    tart stop "$BOOTSTRAP_VM"
    trap - EXIT
    exit 0
fi

log "Installing Homebrew + python@3.11 + git inside VM..."
sshpass -p "$VM_PASSWORD" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "$VM_USER@$VM_IP" 'bash -s' <<'INNER'
set -euo pipefail
if ! command -v brew >/dev/null; then
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
fi
eval "$(/opt/homebrew/bin/brew shellenv)"
brew install --quiet python@3.11 git vips node libpq
touch ~/.bootstrapped
INNER

log "Stopping VM and saving snapshot..."
sshpass -p "$VM_PASSWORD" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "$VM_USER@$VM_IP" "sudo shutdown -h now" 2>/dev/null || true
sleep 5
tart stop --force "$BOOTSTRAP_VM" 2>/dev/null || true
trap - EXIT

log "Bootstrap complete. $BOOTSTRAP_VM is ready to be cloned by per-run E2E tests."
