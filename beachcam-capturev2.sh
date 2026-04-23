#!/bin/bash
# =============================================================================
# Beachcam Frame/Video Capture Script - OPTIMIZED + LIVE PROGRESS BAR
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
  $0                    # Default: 4 frames from all Beachcams
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

# Live progress bar (updates on same line)
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

# Per-stream processing (called in parallel)
process_stream() {
    local line="$1"
    local PROGRESS_FILE="$2"
    local TOTAL="$3"

    local metadata stream_url
    IFS="|" read -r metadata stream_url <<< "$line"

    # Clean filename prefix
    local prefix
    prefix=$(echo "$metadata" | sed -E 's/.*,//; s/[^a-zA-Z0-9_-]/_/g; s/__+/_/g; s/^_|_$//g')
    [[ -z "$prefix" ]] && prefix="beachcam_unknown"

    echo -e "\nProcessing: $prefix"

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
            echo "✗ Failed: $prefix"
        fi
    else
        local output_pattern="captures/${prefix}-${TIMESTAMP}_%03d.jpg"
        echo "→ Capturing ${FRAME_COUNT} frames"

        if ffmpeg -nostdin -y -i "$stream_url" \
                  -frames:v "$FRAME_COUNT" \
                  -vf "fps=${FPS}" \
                  -loglevel error \
                  "$output_pattern"; then
            echo "✓ Success: $prefix (${FRAME_COUNT} frames)"
        else
            echo "✗ Failed: $prefix"
        fi
    fi

    # Atomic progress update + redraw bar
    local current
    current=$(flock -x "$PROGRESS_FILE" bash -c '
        curr=$(cat "$1" 2>/dev/null || echo 0)
        echo $((curr + 1)) > "$1"
        echo $((curr + 1))
    ' _ "$PROGRESS_FILE")

    show_progress "$current" "$TOTAL"
}
export -f process_stream show_progress

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

# ----------------------------- Extract streams -------------------
log "Extracting Beachcam streams${FILTER:+ (filtered by \"$FILTER\")}..."

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
    {
        if [[ -n "$FILTER" ]]; then
            grep -i "$FILTER"
        else
            cat
        fi
    }
)

TOTAL=${#STREAM_LINES[@]}

if [[ $TOTAL -eq 0 ]]; then
    log "No beachcams found${FILTER:+ matching filter \"$FILTER\"}."
    exit 0
fi

log "Found $TOTAL beachcam(s) to process. Starting parallel capture..."

# Progress tracking
PROGRESS_FILE=$(mktemp /tmp/beachcam_progress_$$.XXXXXX)
echo 0 > "$PROGRESS_FILE"
trap 'rm -f "$PROGRESS_FILE" 2>/dev/null || true' EXIT

# Process in parallel with live progress bar
printf '%s\n' "${STREAM_LINES[@]}" | \
xargs -I {} -P "$MAX_PARALLEL" -r bash -c 'process_stream "$1" "$2" "$3"' _ {} "$PROGRESS_FILE" "$TOTAL"

# Final progress (100%)
show_progress "$TOTAL" "$TOTAL"
echo -e "\n"

log "All beachcam processing completed."
