#!/bin/bash
# =============================================================================
# Beachcam Frame Capture Script - Fixed & Optimized
# =============================================================================

set -euo pipefail

PLAYLIST="playlist.m3u"
URL="https://raw.githubusercontent.com/LITUATUI/M3UPT/refs/heads/main/M3U/M3UPT.m3u"
MAX_PARALLEL=3
MAX_AGE=$((24 * 60 * 60))   # 24 hours in seconds

# ----------------------------- Functions -------------------------------------

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

error() {
    echo "ERROR: $*" >&2
    exit 1
}

# ----------------------------- Main Logic ------------------------------------

log "Starting beachcam frame capture script..."

# Check if playlist needs refreshing
if [[ ! -f "$PLAYLIST" ]] || \
   [[ $(($(date +%s) - $(stat -c %Y "$PLAYLIST" 2>/dev/null || echo 0))) -gt $MAX_AGE ]]; then
    
    log "Downloading fresh playlist from $URL..."
    if ! curl -L -f -s --connect-timeout 10 --max-time 30 "$URL" -o "$PLAYLIST"; then
        error "Failed to download playlist from $URL"
    fi
    log "Playlist downloaded successfully."
else
    log "Playlist is up to date (less than 24h old). Processing Beachcams..."
fi

# Verify playlist exists and is not empty
[[ -s "$PLAYLIST" ]] || error "Playlist file is empty or missing: $PLAYLIST"

# ----------------------------- Extract & Process Beachcams -------------------

log "Extracting and processing Beachcam streams..."

# Robust M3U parsing for group-title="Beachcam"
grep -A1 'group-title="Beachcam"' "$PLAYLIST" | \
awk '
    /^#EXTINF/ {
        metadata = $0
        next
    }
    /^http/ && metadata != "" {
        gsub(/"/, "\\\"", metadata)
        print metadata "|" $0
        metadata = ""
    }
' | \
xargs -I {} -P "$MAX_PARALLEL" -r bash -c '
    line="{}"
    IFS="|" read -r metadata stream_url <<< "$line"

    # Clean filename prefix
    prefix=$(echo "$metadata" | sed -E "s/.*,//; s/[^a-zA-Z0-9_-]/_/g; s/__+/_/g; s/^_|_$//g")
    [[ -z "$prefix" ]] && prefix="beachcam_unknown"

    echo "Capturing frames for: $prefix"

    TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
    output_pattern="captures/${prefix}-${TIMESTAMP}_%03d.jpg"

    if ffmpeg -nostdin -y -i "$stream_url" \
              -frames:v 4 \
              -vf "fps=1/8" \
              -loglevel error \
              "$output_pattern"; then
        echo "✓ Successfully captured 4 frames for $prefix"
    else
        echo "✗ Failed to capture frames for $prefix (stream may be offline)"
    fi
'

# log "All beachcam processing completed."


