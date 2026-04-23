#!/bin/bash
# =============================================================================
# Beachcam Frame/Video Capture Script - With Name Filter (-f)
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
FILTER=""                  # New: name filter
FPS=1/8

# ----------------------------- Argument Parsing -----------------------------
usage() {
    echo "Usage: $0 [-v <seconds>] [-i <frames>] [-f <filter>]"
    echo "  -v <seconds>   Capture video for specified seconds"
    echo "  -i <frames>    Capture specified number of frames"
    echo "  -f <text>      Filter beachcams by name (e.g. -f Barra)"
    echo "  No arguments   Default: 4 frames, all Beachcams"
    exit 1
}

while getopts ":v:i:f:h" opt; do
    case $opt in
        v)
            MODE="video"
            if [[ -n "$OPTARG" && "$OPTARG" =~ ^[0-9]+$ ]]; then
                VIDEO_SECONDS="$OPTARG"
            else
                VIDEO_SECONDS=20
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
        f)
            FILTER="$OPTARG"
            ;;
        h)
            usage
            ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
            usage
            ;;
        :)
            # Handle -v / -i without value
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
log "Starting beachcam capture script (Mode: $MODE${FILTER:+ | Filter: \"$FILTER\"})..."

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

[[ -s "$PLAYLIST" ]] || error "Playlist file is empty or missing: $PLAYLIST"

mkdir -p captures

# ----------------------------- Extract & Process Beachcams -------------------
log "Extracting Beachcam streams${FILTER:+ (filtered by \"$FILTER\")}..."

# Robust M3U parsing + optional filter
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
{
    if [[ -n "$FILTER" ]]; then
        grep -i "$FILTER"   # Case-insensitive filter on the metadata|url line
    else
        cat
    fi
} | \
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
        echo "Capturing ${'"'"$VIDEO_SECONDS"'"'} seconds of video → $output_file"
        
        if ffmpeg -nostdin -y -i "$stream_url" \
                  -t '"$VIDEO_SECONDS"' \
                  -c copy \
                  -loglevel error \
                  "$output_file"; then
            echo "✓ Success: $prefix"
        else
            echo "✗ Failed: $prefix"
        fi
    else
        # Frame mode
        output_pattern="captures/${prefix}-${TIMESTAMP}_%03d.jpg"
        echo "Capturing ${'"'"$FRAME_COUNT"'"'} frames"
        
        if ffmpeg -nostdin -y -i "$stream_url" \
                  -frames:v '"$FRAME_COUNT"' \
                  -vf "fps='"$FPS"'" \
                  -loglevel error \
                  "$output_pattern"; then
            echo "✓ Success: $prefix ($FRAME_COUNT frames)"
        else
            echo "✗ Failed: $prefix"
        fi
    fi
'

log "All beachcam processing completed."
