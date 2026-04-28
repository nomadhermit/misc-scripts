#!/bin/bash
# =============================================================================
# Beachcam Frame/Video Capture Script - FIXED (HLS + Headers + Variables)
# =============================================================================

set -euo pipefail

PLAYLIST="playlist.m3u"
URL="https://raw.githubusercontent.com/LITUATUI/M3UPT/refs/heads/main/M3U/M3UPT.m3u"
MAX_PARALLEL=3
MAX_AGE=$((24 * 60 * 60))

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
  $0 -i 10 -f Barra     # 10 frames, filtered
  $0 -v 30              # 30 seconds video from all
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
            echo "Invalid option" >&2
            usage
            ;;
    esac
done

# Export variables so they are visible inside parallel subshells
export MODE FRAME_COUNT VIDEO_SECONDS FPS

# ----------------------------- Functions -------------------------------------
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

error() {
    echo "ERROR: $*" >&2
    exit 1
}

show_progress() {
    local completed=$1
    local total=$2
    local percent=$(( completed * 100 / total ))
    local width=50
    local filled=$(( percent * width / 100 ))
    printf "\rProgress: ["
    printf "%${filled}s" | tr ' ' '█'
    printf "%$((width - filled))s" | tr ' ' '░'
    printf "] %d/%d (%d%%)" "$completed" "$total" "$percent"
}

# Per-stream processing (HLS-optimized with headers + reconnect)
process_stream() {
    local line="$1"
    local prog_file="$2"
    local total="$3"

    local metadata stream_url
    IFS="|" read -r metadata stream_url <<< "$line"

    local prefix
    prefix=$(echo "$metadata" | sed -E 's/.*,//; s/[^a-zA-Z0-9_-]/_/g; s/__+/_/g; s/^_|_$//g')
    [[ -z "$prefix" ]] && prefix="beachcam_unknown"

    echo -e "\n[$(date '+%H:%M:%S')] Processing: $prefix"

    local TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
    local success=0

    # Common HLS options (critical for iol.pt beachcams)
    local HLS_OPTS=(
        -reconnect 1
        -reconnect_streamed 1
        -reconnect_delay_max 5
        -headers $'Referer: https://www.iol.pt/\r\n'
        -user_agent "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36"
    )

    if [[ "$MODE" == "video" ]]; then
        local output_file="captures/${TIMESTAMP}/${prefix}-${TIMESTAMP}.mp4"
        echo "→ Capturing ${VIDEO_SECONDS}s video → $output_file"

        if ffmpeg -nostdin -y "${HLS_OPTS[@]}" \
                  -i "$stream_url" \
                  -t "$VIDEO_SECONDS" \
                  -c copy \
                  -loglevel error \
                  "$output_file" 2>/dev/null; then

            if [[ -s "$output_file" ]]; then
                echo "✓ Success: $prefix (video, $(du -h "$output_file" | cut -f1))"
                success=1
            else
                echo "✗ Empty file: $prefix"
            fi
        else
            echo "✗ Failed: $prefix (check stream)"
        fi

    else
        # Frame mode
        local output_pattern="captures/${TIMESTAMP}/${prefix}-${TIMESTAMP}_%03d.jpg"
        echo "→ Capturing ${FRAME_COUNT} frames"

        if ffmpeg -nostdin -y "${HLS_OPTS[@]}" \
                  -i "$stream_url" \
                  -frames:v "$FRAME_COUNT" \
                  -vf "fps=${FPS}" \
                  -loglevel error \
                  "$output_pattern" 2>/dev/null; then

            local count=$(ls "${output_pattern%_*}"_* 2>/dev/null | wc -l || echo 0)
            if [[ $count -gt 0 ]]; then
                echo "✓ Success: $prefix ($count frames)"
                success=1
            else
                echo "✗ No frames captured: $prefix"
            fi
        else
            echo "✗ Failed: $prefix (check stream)"
        fi
    fi

    # Atomic progress update
    local current
    current=$(flock -x "$prog_file" bash -c '
        curr=$(cat "$1" 2>/dev/null || echo 0)
        echo $((curr + 1)) > "$1"
        echo $((curr + 1))
    ' _ "$prog_file")

    show_progress "$current" "$total"
}
export -f process_stream show_progress

# ----------------------------- Main Logic ------------------------------------
log "Starting beachcam capture script (Mode: $MODE${FILTER:+ | Filter: \"$FILTER\"})..."

# Refresh playlist if needed
if [[ ! -f "$PLAYLIST" ]] || \
   [[ $(($(date +%s) - $(stat -c %Y "$PLAYLIST" 2>/dev/null || echo 0))) -gt $MAX_AGE ]]; then
    log "Downloading fresh playlist..."
    if ! curl -L -f -s --connect-timeout 10 --max-time 60 "$URL" -o "$PLAYLIST"; then
        error "Failed to download playlist from $URL"
    fi
    log "Playlist downloaded successfully."
else
    log "Playlist is up to date."
fi

[[ -s "$PLAYLIST" ]] || error "Playlist file is empty or missing: $PLAYLIST"

mkdir -p captures

# Extract streams
mapfile -t STREAM_LINES < <(
    grep -A1 'group-title="Beachcam"' "$PLAYLIST" | \
    awk '
        /^#EXTINF/ { metadata = $0; next }
        /^http/ && metadata != "" {
            gsub(/"/, "\\\"", metadata)
            print metadata "|" $0
            metadata = ""
        }
    ' | \
    { [[ -n "$FILTER" ]] && grep -i "$FILTER" || cat; }
)

TOTAL=${#STREAM_LINES[@]}

if [[ $TOTAL -eq 0 ]]; then
    log "No beachcams found${FILTER:+ matching filter \"$FILTER\"}."
    exit 0
fi

log "Found $TOTAL beachcam(s) → starting capture..."

# Progress tracking
PROGRESS_FILE=$(mktemp /tmp/beachcam_progress_$$.XXXXXX)
echo 0 > "$PROGRESS_FILE"
trap 'rm -f "$PROGRESS_FILE" 2>/dev/null || true' EXIT

# Run in parallel
printf '%s\n' "${STREAM_LINES[@]}" | \
xargs -I {} -P "$MAX_PARALLEL" -r bash -c 'process_stream "$1" "$2" "$3"' _ {} "$PROGRESS_FILE" "$TOTAL"

# Final progress + cleanup
show_progress "$TOTAL" "$TOTAL"
echo -e "\n"

log "All beachcam processing completed."
