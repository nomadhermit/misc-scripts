#!/bin/bash
# =============================================================================
# Beachcam Frame/Video Capture Script - Parameterized Version
# =============================================================================

set -euo pipefail

PLAYLIST="playlist.m3u"
URL="https://raw.githubusercontent.com/LITUATUI/M3UPT/refs/heads/main/M3U/M3UPT.m3u"
MAX_PARALLEL=3
MAX_AGE=$((24 * 60 * 60))   # 24 hours in seconds

# ----------------------------- Defaults -------------------------------------
MODE="frames"          # "frames" or "video"
FRAME_COUNT=4
VIDEO_SECONDS=20
FPS=1/8                # Default for frame mode

# ----------------------------- Argument Parsing -----------------------------
usage() {
    echo "Usage: $0 [-v <seconds>] [-i <frames>]"
    echo "  -v <seconds>   Capture video for specified seconds (default: 20 if -v used without value)"
    echo "  -i <frames>    Capture specified number of frames (default: 4)"
    echo "  No arguments   Uses default frame capture (4 frames)"
    exit 1
}

while getopts ":v:i:h" opt; do
    case $opt in
        v)
            MODE="video"
            if [[ -n "$OPTARG" && "$OPTARG" =~ ^[0-9]+$ ]]; then
                VIDEO_SECONDS="$OPTARG"
            else
                VIDEO_SECONDS=20  # default if -v given without number
            fi
            ;;
        i)
            MODE="frames"
            if [[ -n "$OPTARG" && "$OPTARG" =~ ^[0-9]+$ ]]; then
                FRAME_COUNT="$OPTARG"
            else
                FRAME_COUNT=4
            fi
            ;;
        h)
            usage
            ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
            usage
            ;;
        :)
            # -v or -i without value is allowed (uses defaults)
            if [[ "$OPTARG" == "v" ]]; then
                MODE="video"
                VIDEO_SECONDS=20
            elif [[ "$OPTARG" == "i" ]]; then
                MODE="frames"
                FRAME_COUNT=4
            fi
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

# ----------------------------- Main Logic ------------------------------------
log "Starting beachcam capture script (Mode: $MODE)..."

# Check if playlist needs refreshing
if [[ ! -f "$PLAYLIST" ]] || \
   [[ $(($(date +%s) - $(stat -c %Y "$PLAYLIST" 2>/dev/null || echo 0))) -gt $MAX_AGE ]]; then
    
    log "Downloading fresh playlist from $URL..."
    if ! curl -L -f -s --connect-timeout 10 --max-time 30 "$URL" -o "$PLAYLIST"; then
        error "Failed to download playlist from $URL"
    fi
    log "Playlist downloaded successfully."
else
    log "Playlist is up to date (less than 24h old)."
fi

# Verify playlist exists and is not empty
[[ -s "$PLAYLIST" ]] || error "Playlist file is empty or missing: $PLAYLIST"

# ----------------------------- Extract & Process Beachcams -------------------
log "Extracting and processing Beachcam streams..."

mkdir -p captures

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

    echo "Processing: $prefix"

    TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")

    if [[ "'"$MODE"'" == "video" ]]; then
        output_file="captures/${prefix}-${TIMESTAMP}.mp4"
        echo "Capturing ${'"'"$VIDEO_SECONDS"'"'} seconds of video for $prefix → $output_file"
        
        if ffmpeg -nostdin -y -i "$stream_url" \
                  -t '"$VIDEO_SECONDS"' \
                  -c copy \
                  -loglevel error \
                  "$output_file"; then
            echo "✓ Successfully captured video for $prefix"
        else
            echo "✗ Failed to capture video for $prefix (stream may be offline)"
        fi
    else
        # Frame capture mode
        output_pattern="captures/${prefix}-${TIMESTAMP}_%03d.jpg"
        echo "Capturing ${'"'"$FRAME_COUNT"'"'} frames for $prefix"
        
        if ffmpeg -nostdin -y -i "$stream_url" \
                  -frames:v '"$FRAME_COUNT"' \
                  -vf "fps='"$FPS"'" \
                  -loglevel error \
                  "$output_pattern"; then
            echo "✓ Successfully captured $FRAME_COUNT frames for $prefix"
        else
            echo "✗ Failed to capture frames for $prefix (stream may be offline)"
        fi
    fi
'

log "All beachcam processing completed."
