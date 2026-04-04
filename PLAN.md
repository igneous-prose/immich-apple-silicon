# PLAN — Immich Accelerator

## Status: Library processing (309k assets)
Running on M4 Mac Mini. ML stable with gpu_lock fix. All queues active.

## Track 1: ML upstream (sebastianfredette/immich-ml-metal)

- [x] Pull upstream commit `f879301` (invalid face model packs)
- [x] Address Sebastian's PR #4 feedback (error propagation, lock safety, config cleanup)
- [x] Push fixes, reply to PR
- [x] Metal concurrency fix — gpu_lock with forced eval (on metal-concurrency-fix branch)
- [ ] Merge metal-concurrency-fix to main (after PR #4 is resolved)
- [ ] Track MLX thread safety bug (ml-explore/mlx#3078, #2133) — remove gpu_lock when fixed

## Track 2: Accelerator

- [x] Container extract approach (no source build)
- [x] Sharp darwin binary + libvips for HEIF support
- [x] IMMICH_MEDIA_LOCATION for path mapping
- [x] Auto-update on version change
- [x] Atomic config, PID reuse detection
- [x] Auto-install @img/sharp-libvips-darwin-arm64 during setup
- [ ] Handle VideoToolbox ffmpeg (Immich doesn't support it as accel option)

## Track 3: Documentation

- [x] README rewrite
- [x] CHANGELOG v1.0.0
- [x] Migration section
- [ ] Document concurrency tuning recommendations
- [ ] Document known limitations (VideoToolbox, corePlugin)

## Track 4: Validation

- [x] Fresh DB from clean state
- [x] Worker + ML stable under load
- [x] HEIF/HEIC support working
- [ ] Full library processing complete
- [ ] Search working (CLIP embeddings)
- [ ] Face recognition grouping working
- [ ] Video playback working

## Processing rates (M4 24GB, 309k library)

| Task | Rate/min | Hardware | Lock |
|------|----------|----------|------|
| Thumbnails | ~300 | CPU (Sharp/system libvips NEON) | none |
| CLIP | ~430 | Metal GPU (MLX) | gpu_lock |
| Face detect | ~94 | ANE (Vision) | none |
| Face embed | ~94 | CPU (ONNX CoreML) | none |
| OCR | ~430 | ANE (Vision) | none |

Optimal concurrency: thumbnails=4, smartSearch=2, faceDetection=3, ocr=3, metadata=4, video=1

## Remaining issues

1. **corePlugin WASM error** — non-fatal, container extract hardcodes /build path
2. **MLX not thread-safe** — CLIP serialized via gpu_lock (ml-explore/mlx#3078). Track for fix.
3. **Watchdog needs health check** — PID check misses hung workers (process alive but not processing). Should check queue progress over time.
4. **ML queues don't auto-refill** — failed jobs from earlier crashes sit in failed queue. Nightly task catches up, but gap during import. Consider periodic "Run All Missing" in watch loop.
5. **Auto-detect Docker runtime hostname** — setup should test `host.internal` (OrbStack) and `host.docker.internal` (Docker Desktop) from inside a container to auto-fill ML_URL. For NAS+Mac setups, use the Mac's LAN IP instead.
6. **Upstream Immich: tonemapx fallback** — Immich hardcodes `tonemapx` with no fallback to standard `tonemap`. Need to request they check filter availability at startup. See PR #13785.
7. **Dashboard auth** — binds on 0.0.0.0 with no auth. Re-queue endpoint has write access. Add optional token or localhost-only binding.

## Resolved issues

- **Sharp HEIF crash** — prebuilt darwin binaries crashed on truncated HEIC (32 bytes short of EOF). Fix: `brew install vips` + `npm rebuild` against system libvips. Matches Docker's error handling exactly.
- **Worker hangs instead of crashing** — Sharp native crash left Node.js alive but non-functional. System libvips prevents the crash entirely.
- **VideoToolbox** — solved with ffmpeg wrapper script + FFMPEG_PATH env var. No Immich changes needed.
- **Concurrency thrashing** — load 85 on 10 cores. Reduced concurrency, load dropped to 25, ML throughput up 4-6x.
- **Metal concurrency crash** — MLX lazy eval left Metal work in flight after lock release. Fix: force np.array() inside lock. Vision framework safe without lock.

## Lessons learned

1. **Less concurrency = more throughput** on a loaded system. CPU oversubscription causes thrashing.
2. **Prebuilt binaries ≠ source builds.** Different error handling for edge cases (corrupt HEIF). System libvips matches Docker's behavior.
3. **MLX is not thread-safe.** Known bug (ml-explore/mlx#3078). All MLX eval must complete inside a lock.
4. **Vision framework IS thread-safe.** Separate VNImageRequestHandler per call, isolated Metal contexts.
5. **Core Image is NOT faster than Sharp for thumbnails.** Bottleneck is decode/encode (CPU), not resize (GPU). libvips shrink-on-load has no GPU equivalent.
6. **The ffmpeg wrapper approach works.** FFMPEG_PATH env var + shell script that remaps encoders to VideoToolbox. Simpler than an HTTP proxy.

## For Immich discussion (mertalev)

Follow up on immich-app/immich#27419 with v1.1.0 experience. Show what works, what's fragile, and what would benefit from upstream support. Even small changes (like VideoToolbox accel) would help.

**What we've proven:**
- Their code runs bare metal on macOS — microservices replica, no patches, version-matched
- 309k library processing stable with watchdog, all asset types working
- VideoToolbox HW encoding via ffmpeg wrapper (h264/hevc)
- Metal GPU (CLIP), Neural Engine (faces/OCR), CPU NEON (thumbnails) all utilized
- NAS+Mac split deployment works (Docker on NAS, compute on Mac)

**What's fragile without upstream help:**
- `tonemapx` filter: hardcoded with no fallback (PR #13785). Our wrapper remaps to upstream `tonemap` but drops color space params. If Immich checked filter availability and fell back to standard `tonemap` chain, this just works everywhere.
- `videotoolbox` not in accel enum: we use a wrapper script to remap encoders. Adding `videotoolbox` as an accel option would eliminate the wrapper entirely for encoding.
- Per-queue exclusion: `IMMICH_WORKERS_INCLUDE` only takes worker types, not individual queues. For NAS+Mac, you want metadata extraction on the NAS (local I/O) but thumbnails/ML/transcode on the Mac. Currently all-or-nothing.
- "Run All Missing" doesn't re-queue previously-failed assets. Failed jobs are considered "done." Only `force: true` retries. This means any transient failure (crash, missing encoder) requires a full re-process of all assets to catch the ones that failed.

**Minimum useful change:** Add `videotoolbox` to the accel enum. That alone eliminates our encoding wrapper and makes HW transcoding first-class. The tonemapx fallback would be the next biggest win.
