#!/bin/bash
# VideoToolbox ffmpeg wrapper for Immich Accelerator
#
# Placed earlier in PATH than the real ffmpeg. Intercepts encoding calls
# and adds VideoToolbox hardware acceleration flags. Non-encoding calls
# (probing, frame extraction) pass through unchanged.
#
# Also remaps Immich's custom tonemapx filter (only in jellyfin-ffmpeg)
# to upstream-compatible tonemap + colorspace filters.

REAL_FFMPEG="/opt/homebrew/bin/ffmpeg"

# Debug logging — always append (cheap), only truncate when ACCELERATOR_DEBUG is set
DEBUG_LOG="$HOME/.immich-accelerator/logs/ffmpeg-wrapper.log"
_debug_log() {
    echo "[$(date '+%H:%M:%S')] $*" >> "$DEBUG_LOG"
    [[ -n "$ACCELERATOR_DEBUG" ]] && tail -50 "$DEBUG_LOG" > "$DEBUG_LOG.tmp" 2>/dev/null && mv "$DEBUG_LOG.tmp" "$DEBUG_LOG"
}

# Remap tonemapx to upstream tonemap + format filters.
# tonemapx is an all-in-one filter in jellyfin-ffmpeg (Immich's Docker build).
# Upstream ffmpeg only has 'tonemap'. We keep algorithm, desat, peak; drop the
# color space params (p/t/m/r) since upstream tonemap handles the transfer
# internally. Not bit-identical to Docker, but visually close for thumbnails.
#
# Input:  tonemapx=tonemap=hable:desat=0:p=bt709:t=bt709:m=bt709:r=pc:peak=100:format=yuv420p
# Output: tonemap=hable:desat=0:peak=100,format=yuv420p
remap_tonemapx() {
    local vf="$1"
    [[ "$vf" != *tonemapx* ]] && echo "$vf" && return

    # Extract the tonemapx=... segment and parse its options
    local before="${vf%%tonemapx=*}"
    local rest="${vf#*tonemapx=}"
    # rest = "tonemap=hable:desat=0:p=bt709:...:format=yuv420p,scale=..."
    local tmx_opts="${rest%%,*}"
    local after=""
    [[ "$rest" == *,* ]] && after="${rest#*,}"

    # Parse tonemapx options
    local algo="" desat="" peak="" fmt=""
    IFS=':' read -ra OPTS <<< "$tmx_opts"
    for opt in "${OPTS[@]}"; do
        case "$opt" in
            tonemap=*) algo="${opt#tonemap=}" ;;
            desat=*)   desat="$opt" ;;
            peak=*)    peak="$opt" ;;
            format=*)  fmt="${opt#format=}" ;;
        esac
    done

    # Build upstream filter chain
    local tm="tonemap=${algo:-hable}"
    [[ -n "$desat" ]] && tm="$tm:$desat"
    [[ -n "$peak" ]] && tm="$tm:$peak"

    # Colorspace conversion: BT.2020 HDR input → BT.709 SDR output
    # tonemap handles HDR→SDR. The colorspace filter can't handle all HDR
    # transfer types (e.g. HLG/arib-std-b67), so we skip it and let
    # tonemap + format do the work. This is a best-effort approximation
    # of Immich's tonemapx — proper support needs an upstream Immich change.
    local result="${before}${tm}"
    [[ -n "$fmt" ]] && result="$result,format=$fmt"
    [[ -n "$after" ]] && result="$result,$after"

    echo "$result"
}

# Two-pass approach: first pass detects HW encode and builds args,
# second pass strips -preset if HW encode is active (handles any arg order).
ARGS=("$@")
USE_HW=false
PASS1_ARGS=()
PRESET_INDICES=()

for ((i=0; i<${#ARGS[@]}; i++)); do
    arg="${ARGS[$i]}"

    # Remap software encoders to VideoToolbox hardware encoders
    if [[ "$arg" == "-c:v" || "$arg" == "-vcodec" ]]; then
        next="${ARGS[$((i+1))]:-}"
        case "$next" in
            h264|libx264|libx264rgb)
                PASS1_ARGS+=("$arg" "h264_videotoolbox")
                ((i++))
                USE_HW=true
                continue
                ;;
            hevc|libx265)
                PASS1_ARGS+=("$arg" "hevc_videotoolbox")
                ((i++))
                USE_HW=true
                continue
                ;;
        esac
    fi

    # Mark -preset positions for potential removal (don't decide yet)
    if [[ "$arg" == "-preset" ]]; then
        PRESET_INDICES+=("${#PASS1_ARGS[@]}")
        PASS1_ARGS+=("$arg")
        ((i++))
        PASS1_ARGS+=("${ARGS[$i]}")
        continue
    fi

    # Remap tonemapx in filter arguments
    if [[ "$arg" == "-vf" || "$arg" == "-filter_complex" ]]; then
        PASS1_ARGS+=("$arg")
        ((i++))
        PASS1_ARGS+=("$(remap_tonemapx "${ARGS[$i]}")")
        continue
    fi

    PASS1_ARGS+=("$arg")
done

# Second pass: strip -preset args if using HW encode
if [[ "$USE_HW" == true && ${#PRESET_INDICES[@]} -gt 0 ]]; then
    NEW_ARGS=()
    SKIP_SET=()
    for idx in "${PRESET_INDICES[@]}"; do
        SKIP_SET+=("$idx" "$((idx+1))")
    done
    for ((i=0; i<${#PASS1_ARGS[@]}; i++)); do
        skip=false
        for s in "${SKIP_SET[@]}"; do
            [[ "$i" == "$s" ]] && skip=true && break
        done
        $skip || NEW_ARGS+=("${PASS1_ARGS[$i]}")
    done
else
    NEW_ARGS=("${PASS1_ARGS[@]}")
fi

# Add hardware decode if we're doing hardware encode
if [[ "$USE_HW" == true ]]; then
    _debug_log "HW: $REAL_FFMPEG -hwaccel videotoolbox ${NEW_ARGS[*]}"
    exec "$REAL_FFMPEG" -hwaccel videotoolbox "${NEW_ARGS[@]}"
else
    _debug_log "SW: $REAL_FFMPEG ${NEW_ARGS[*]}"
    exec "$REAL_FFMPEG" "${NEW_ARGS[@]}"
fi
