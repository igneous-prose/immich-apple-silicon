#!/bin/bash
# scripts/tart-cleanup.sh
#
# Eric's cleanup rule: spin it down and free the disk. This script
# kills every tart VM in the `immich-*` namespace and optionally the
# cached OCI base image. Safe to run anytime — anything in progress
# is force-stopped.
#
# Usage:
#   scripts/tart-cleanup.sh            # kill+delete immich-* VMs
#   scripts/tart-cleanup.sh --all      # also delete the cached base image (frees ~30GB)
#   scripts/tart-cleanup.sh --dry-run  # list what would be deleted

set -euo pipefail

export PATH="/opt/homebrew/bin:$PATH"

DRY_RUN=0
DELETE_BASE=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --all) DELETE_BASE=1 ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[dry-run] $*"
    else
        "$@"
    fi
}

log() { printf '[tart-cleanup] %s\n' "$*"; }

# 1. Every immich-* VM (JSON-safe: tart's text columns are fragile).
vms=$(tart list --format json 2>/dev/null | python3 -c '
import sys, json
for vm in json.load(sys.stdin):
    if vm.get("Source") == "local" and vm["Name"].startswith("immich-"):
        print(vm["Name"])
' 2>/dev/null || true)
if [ -z "$vms" ]; then
    log "no immich-* VMs found"
else
    log "found VMs:"
    echo "$vms" | sed 's/^/  /'
    for vm in $vms; do
        run tart stop --timeout 5 "$vm" 2>/dev/null || true
        run tart delete "$vm"
    done
fi

# 2. Cached OCI base image (only with --all)
if [ "$DELETE_BASE" -eq 1 ]; then
    oci_images=$(tart list --format json 2>/dev/null | python3 -c '
import sys, json
for vm in json.load(sys.stdin):
    if vm.get("Source") == "OCI" and "macos-sonoma-base" in vm["Name"]:
        print(vm["Name"])
' 2>/dev/null || true)
    for img in $oci_images; do
        log "deleting base OCI image $img (~30GB)"
        run tart delete "$img"
    done
fi

# 3. Disk report
log "~/.tart disk usage after cleanup:"
du -sh ~/.tart 2>/dev/null || echo "  (no ~/.tart directory)"

log "done."
