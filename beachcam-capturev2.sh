#!/bin/bash
# =============================================================================
# Beachcam Frame/Video Capture Script - OPTIMIZED
# =============================================================================

set -euo pipefail

PLAYLIST="playlist.m3u"
URL="https://raw.githubusercontent.com/LITUATUI/M3UPT/refs/heads/main/M3U/M3UPT.m3u"
MAX_PARALLEL=3
MAX_AGE=$((24 * 60 * 60))   # 24 hours in seconds

# ----------------------------- Defaults -------------------------------------
MODE="frames"
FRAME_COUNT=4
VIDEO_SECONDS=20
FILTER=""
FPS=1/8

# ----------------------------- Argument Parsing -----------------------------
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  -v [seconds]   Capture video (default: 20 seconds)
  -i [frames]    Capture frames (default: 4 frames)
  -f <text>      Filter beachcams by name (case-insensitive)
  -h             Show this help

Examples:
  $0                    # 4 frames from all Beachcams
  $0 -i 10              # 10 frames from all
  $0 -v 30 -f Barra     # 30s video, filtered by "Barra"
  $0 -f Rio             # 4 frames, filtered by "Rio"
EOF
    exit 0
}

while getopts ":v:i:f:h" opt; do
    case $opt in
        v)
            MODE="video"
            [[ -n "${OPTARG:-}" && "$OPTARG" =~ ^[0-9]+$ ]] && VIDEO_SECONDS="$OPTARG"
            ;;
        i)
            MODE="frames"
            [[ -n "${OPTARG:-}" && "$OPTARG" =~ ^[0-9]+$ ]] && FRAME_COUNT="$OPTARG"
            ;;
        f)
            FILTER="$OPTARG"
            ;;
        h)
            usage
            ;;
        \?|:)
            echo "Invalid option or missing argument" >&2
            usage
            ;;
    esac
done

# ----------------------------- Functions -------------------------------------
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

error() {
    echo "ERROR: $*" >&2
    exit 1
}

# Main processing function (exported for xargs subshells)
process_stream() {
    local line="$1"
    local metadata stream_url
    IFS="|" read -r metadata stream_url <<< "$line"

    # Clean filename prefix
    local prefix
    prefix=$(echo "$metadata" | sed -E 's/.*,//; s/[^a-zA-Z0-9_-]/_/g; s/__+/_/g; s/^_|_$//g')
    [[ -z "$prefix" ]] && prefix="beachcam_unknown"

    echo "Processing: $prefix"

    local TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")

    if [[ "$MODE" == "video" ]]; then
        local output_file="captures/${prefix}-${TIMESTAMP}.mp4"
        echo "→ Capturing ${VIDEO_SECONDS}s video → $output_file"

        if ffmpeg -nostdin -y -i "$stream_url" \
                  -t "$VIDEO_SECONDS" \
                  -c copy \
                  -loglevel error \
                  "$output_file"; then
            echo "✓ Success: $prefix (video)"
        else
            echo "✗ Failed: $prefix (video)"
        fi
    else
        # Frame capture mode
        local output_pattern="captures/${prefix}-${TIMESTAMP}_%03d.jpg"
        echo "→ Capturing ${FRAME_COUNT} frames"

        if ffmpeg -nostdin -y -i "$stream_url" \
                  -frames:v "$FRAME_COUNT" \
                  -vf "fps=${FPS}" \
                  -loglevel error \
                  "$output_pattern"; then
            echo "✓ Success: $prefix (${FRAME_COUNT} frames)"
        else
            echo "✗ Failed: $prefix (frames)"
        fi
    fi
}
export -f process_stream

# ----------------------------- Main Logic ------------------------------------
log "Starting beachcam capture script (Mode: $MODE${FILTER:+ | Filter: \"$FILTER\"})..."

# Refresh playlist if needed
if [[ ! -f "$PLAYLIST" ]] || \
   [[ $(($(date +%s) - $(stat -c %Y "$PLAYLIST" 2>/dev/null || echo 0))) -gt $MAX_AGE ]]; then
    log "Downloading fresh playlist..."
    if ! curl -L -f -s --connect-timeout 10 --max-time 30 "$URL" -o "$PLAYLIST"; then
        error "Failed to download playlist from $URL"
    fi
    log "Playlist downloaded successfully."
else
    log "Playlist is up to date."
fi

[[ -s "$PLAYLIST" ]] || error "Playlist file is empty or missing: $PLAYLIST"

mkdir -p captures

# ----------------------------- Extract & Process -------------------
log "Extracting Beachcam streams${FILTER:+ (filtered by \"$FILTER\")}..."

# Optimized pipeline:
# 1. Parse M3U
# 2. Apply optional filter (early)
# 3. Run process_stream in parallel
grep -A1 'group-title="Beachcam"' "$PLAYLIST" | \
awk '
    /^#EXTINF/ { metadata = $0; next }
    /^http/ && metadata != "" {
        gsub(/"/, "\\\"", metadata)
        print metadata "|" $0
        metadata = ""
    }
' | \
{
    if [[ -n "$FILTER" ]]; then
        grep -i "$FILTER"
    else
        cat
    fi
} | \
xargs -I {} -P "$MAX_PARALLEL" -r bash -c 'process_stream "$1"' _ {}

log "All beachcam processing completed."
