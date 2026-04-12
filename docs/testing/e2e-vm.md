# Fresh-install E2E testing via tart Mac VM

## Why this exists

Two production bugs (#17, #18) shipped in v1.4.0 because every pre-release
check was run on the maintainer's machine, which had globally-installed
Python packages and leftover state that masked both regressions. The
reporter hit both within 14 minutes of first trying a fresh install.

The unit tests in `tests/test_fresh_install.py` close the specific holes,
and the `fresh-install-macos` CI job runs them on clean GitHub runners.
Neither covers the *full* install flow: `brew install` → post_install venv
build → `immich-accelerator setup` → `download_immich_server` → `dashboard`
serving real data.

This doc describes the tart-based VM pipeline on macmini that does.

## Topology

```
macmini (host)
├─ Existing prod OrbStack containers (DO NOT DISTURB)
│  ├─ immich_server      :2283   ← Eric's actual Immich, untouched
│  ├─ immich_postgres    :5432   bound 127.0.0.1
│  └─ immich_redis       :6379   bound 127.0.0.1
│
├─ tart (Apple Virtualization.framework)
│  └─ immich-test VM (macOS Sonoma)
│     ├─ Homebrew
│     ├─ python@3.11
│     └─ Our formula under test
│
└─ Host exposure for VM → macmini
   └─ socat or port-forward that lets the VM reach
      immich_postgres/immich_redis via 192.168.64.1:<port>
```

## Phases

### 1. Bootstrap (one-time, ~15 min)

- `tart pull ghcr.io/cirruslabs/macos-sonoma-base:latest` (~30 GB)
- `tart clone macos-sonoma-base immich-test-base`
- Boot VM, install Homebrew, python@3.11, git
- `tart stop immich-test-base && tart snapshot immich-test-base bootstrapped`
- Peak disk: ~60 GB (base + clone)

### 2. Test run (per-PR, ~5 min)

- `tart clone immich-test-base immich-test-run-$TIMESTAMP`
- `tart run --net-softnet immich-test-run-$TIMESTAMP &`
- `ssh admin@$(tart ip immich-test-run-$TIMESTAMP)`
- Inside VM: run `scripts/e2e-fresh-install.sh`, capture exit code
- `tart stop --force immich-test-run-$TIMESTAMP`
- `tart delete immich-test-run-$TIMESTAMP`
- Peak extra disk during run: ~5 GB

### 3. Tear-down (always, Eric's cleanup rule)

- All test-run VMs: deleted after every run (success or fail)
- `immich-test-base` (bootstrap VM): kept between runs for speed
- Cached OCI image: kept between runs
- **Nuke-all command**: `scripts/tart-cleanup.sh` — deletes every VM in
  the `immich-*` namespace AND the cached `macos-sonoma-base` image.
  Frees ~65 GB in under 30 seconds.

## What the E2E test verifies

End-to-end, inside the fresh VM:

1. `brew install epheterson/immich-accelerator/immich-accelerator` — must
   complete without errors. Tests formula install, post_install, ML venv
   creation, pip install of uvicorn[standard] + fastapi (issue #17 class).
2. `immich-accelerator --version` — wrapper preflight must pass, venv
   python must be reachable.
3. `immich-accelerator setup --url http://192.168.64.1:2283 --api-key …`
   in a scripted non-interactive form — must pull `immich-server:v2.7.4`
   from ghcr.io, extract corePlugin (issue #18 class), complete config.
4. `immich-accelerator dashboard --port 28420 &` — must start without
   ModuleNotFoundError.
5. `curl -sf http://localhost:28420/` — must return HTML 200.
6. `curl -sf http://localhost:28420/api/status` — must return JSON with
   non-error fields populated.
7. Tear down the dashboard process, return 0.

## Host-to-VM networking

Immich's postgres and redis on macmini are bound to 127.0.0.1 for
security. The VM cannot reach 127.0.0.1-bound host services directly.

Approach: bring up ephemeral socat listeners on 192.168.64.1 during the
test run, tear them down after. `scripts/e2e-host-portforward.sh` owns
this — starts socat with a known pidfile, `trap EXIT` kills them.

Bindings (ephemeral, test-scoped):
- `192.168.64.1:12283 → 127.0.0.1:2283` (Immich HTTP)
- `192.168.64.1:15432 → 127.0.0.1:5432` (Postgres)
- `192.168.64.1:16379 → 127.0.0.1:6379` (Redis)

These are only up while a test is running. They don't modify Eric's
running docker-compose or re-bind any existing ports.

## Not doing

- **Not running this on every git push.** The CI macos-14 job is the
  per-push gate (fast, ~2 min). The tart VM E2E is pre-release only,
  triggered manually before tagging: `make e2e-vm`.
- **Not running Xcode / heavy simulators** in the VM. The `macos-sonoma-base`
  image is ~30 GB. The `macos-sonoma-xcode` variant is ~90 GB — we don't
  need it.
- **Not shipping the VM image anywhere.** It's reproducible from
  `tart pull` + `scripts/e2e-bootstrap-vm.sh`. The bootstrapped VM lives
  on macmini and gets rebuilt if it ever goes stale.

## Runbook

```bash
# One-time (on macmini): bootstrap the base VM with Homebrew + python
ssh macmini 'cd ~/Repos/immich-apple-silicon && scripts/e2e-bootstrap-vm.sh'

# Per-PR: run E2E against current branch
ssh macmini 'cd ~/Repos/immich-apple-silicon && git pull && scripts/e2e-run.sh'

# After tests: free all disk (drops base VM and cached image)
ssh macmini 'cd ~/Repos/immich-apple-silicon && scripts/tart-cleanup.sh --all'
```
