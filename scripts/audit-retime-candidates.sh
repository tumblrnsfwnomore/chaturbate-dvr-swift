#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Audit recorded MP4/MOV files for timeline corruption and missing audio.

Usage:
  ./scripts/audit-retime-candidates.sh --input <dir> [options]

Options:
  --input <dir>           Root directory to scan recursively (required)
  --output-dir <dir>      Directory for reports (default: <input>)
  --large-gap-sec <n>     Mark as retime_required if max PTS gap >= n (default: 5)
  --huge-gap-sec <n>      Always retime_required if max PTS gap >= n (default: 30)
  --tiny-step-sec <n>     Threshold for near-zero PTS deltas (default: 0.002)
  --progress-every <n>    Print progress every N files when non-interactive (default: 5)
  --max-files <n>         Optional cap for quick sampling
  --help                  Show this help

Classification:
  - retime_required: clear timestamp corruption pattern detected
  - retime_review: mild anomalies detected; inspect manually
  - likely_ok: no strong timeline anomalies from this audit

Outputs:
  <output-dir>/retime-audit-<timestamp>.tsv
  <output-dir>/retime-audit-<timestamp>.retime_required.txt
  <output-dir>/retime-audit-<timestamp>.retime_review.txt
  <output-dir>/retime-audit-<timestamp>.likely_ok.txt
  <output-dir>/retime-audit-<timestamp>.no_audio.txt
EOF
}

INPUT_DIR=""
OUTPUT_DIR=""
LARGE_GAP_SEC="5"
HUGE_GAP_SEC="30"
TINY_STEP_SEC="0.002"
PROGRESS_EVERY=5
MAX_FILES=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input)
      INPUT_DIR="${2:-}"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    --large-gap-sec)
      LARGE_GAP_SEC="${2:-}"
      shift 2
      ;;
    --huge-gap-sec)
      HUGE_GAP_SEC="${2:-}"
      shift 2
      ;;
    --tiny-step-sec)
      TINY_STEP_SEC="${2:-}"
      shift 2
      ;;
    --progress-every)
      PROGRESS_EVERY="${2:-}"
      shift 2
      ;;
    --max-files)
      MAX_FILES="${2:-}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$INPUT_DIR" ]]; then
  echo "Error: --input is required" >&2
  usage
  exit 1
fi

if ! [[ "$LARGE_GAP_SEC" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "Error: --large-gap-sec must be numeric" >&2
  exit 1
fi

if ! [[ "$HUGE_GAP_SEC" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "Error: --huge-gap-sec must be numeric" >&2
  exit 1
fi

if ! [[ "$TINY_STEP_SEC" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "Error: --tiny-step-sec must be numeric" >&2
  exit 1
fi

if ! [[ "$PROGRESS_EVERY" =~ ^[0-9]+$ ]] || (( PROGRESS_EVERY < 1 )); then
  echo "Error: --progress-every must be a positive integer" >&2
  exit 1
fi

if [[ -n "$MAX_FILES" ]] && { ! [[ "$MAX_FILES" =~ ^[0-9]+$ ]] || (( MAX_FILES < 1 )); }; then
  echo "Error: --max-files must be a positive integer" >&2
  exit 1
fi

INPUT_DIR="${INPUT_DIR%/}"
if [[ ! -d "$INPUT_DIR" ]]; then
  echo "Error: input directory not found: $INPUT_DIR" >&2
  exit 1
fi

if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="$INPUT_DIR"
fi
mkdir -p -- "$OUTPUT_DIR"

if ! command -v ffprobe >/dev/null 2>&1; then
  echo "Error: ffprobe is required" >&2
  exit 1
fi

RUN_TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
REPORT="$OUTPUT_DIR/retime-audit-$RUN_TIMESTAMP.tsv"
RETIME_REQUIRED_FILE="$OUTPUT_DIR/retime-audit-$RUN_TIMESTAMP.retime_required.txt"
RETIME_REVIEW_FILE="$OUTPUT_DIR/retime-audit-$RUN_TIMESTAMP.retime_review.txt"
LIKELY_OK_FILE="$OUTPUT_DIR/retime-audit-$RUN_TIMESTAMP.likely_ok.txt"
NO_AUDIO_FILE="$OUTPUT_DIR/retime-audit-$RUN_TIMESTAMP.no_audio.txt"

printf 'class\treasons\tsize_bytes\tformat_duration\tvideo_duration\thas_audio\taudio_streams\tmax_gap_s\tgaps_gt_0_5s\tgaps_gt_1s\tgaps_gt_large\tgaps_gt_huge\ttiny_ratio\tjumps_0_6_to_1_2\tnegative_gaps\tpath\n' > "$REPORT"
: > "$RETIME_REQUIRED_FILE"
: > "$RETIME_REVIEW_FILE"
: > "$LIKELY_OK_FILE"
: > "$NO_AUDIO_FILE"

TOTAL=0
RETIME_REQUIRED_COUNT=0
RETIME_REVIEW_COUNT=0
LIKELY_OK_COUNT=0
NO_AUDIO_COUNT=0
START_EPOCH=$(date +%s)

format_seconds() {
  local total="${1:-0}"
  if (( total < 0 )); then
    total=0
  fi
  local hours=$(( total / 3600 ))
  local minutes=$(( (total % 3600) / 60 ))
  local seconds=$(( total % 60 ))
  if (( hours > 0 )); then
    printf '%d:%02d:%02d' "$hours" "$minutes" "$seconds"
  else
    printf '%02d:%02d' "$minutes" "$seconds"
  fi
}

print_progress() {
  local scanned="$1"
  local total="$2"
  local current_file="$3"
  local now elapsed eta percent
  now=$(date +%s)
  elapsed=$(( now - START_EPOCH ))

  if (( scanned > 0 && total > 0 && scanned < total )); then
    eta=$(( elapsed * (total - scanned) / scanned ))
  else
    eta=0
  fi

  if (( total > 0 )); then
    percent=$(( scanned * 100 / total ))
  else
    percent=100
  fi

  if [[ -t 1 ]]; then
    printf '\rScanned %d/%d (%d%%) | elapsed %s | eta %s | required=%d review=%d ok=%d no_audio=%d | %s\033[K' \
      "$scanned" "$total" "$percent" "$(format_seconds "$elapsed")" "$(format_seconds "$eta")" \
      "$RETIME_REQUIRED_COUNT" "$RETIME_REVIEW_COUNT" "$LIKELY_OK_COUNT" "$NO_AUDIO_COUNT" "${current_file##*/}"
  else
    printf 'Progress %d/%d (%d%%) | elapsed %s | eta %s | required=%d review=%d ok=%d no_audio=%d | %s\n' \
      "$scanned" "$total" "$percent" "$(format_seconds "$elapsed")" "$(format_seconds "$eta")" \
      "$RETIME_REQUIRED_COUNT" "$RETIME_REVIEW_COUNT" "$LIKELY_OK_COUNT" "$NO_AUDIO_COUNT" "$current_file"
  fi
}

FILE_LIST=$(mktemp)
trap 'rm -f "$FILE_LIST"' EXIT
find "$INPUT_DIR" -type f \( -iname '*.mp4' -o -iname '*.m4v' -o -iname '*.mov' \) -print > "$FILE_LIST"

if [[ -n "$MAX_FILES" ]]; then
  TMP_LIST=$(mktemp)
  head -n "$MAX_FILES" "$FILE_LIST" > "$TMP_LIST"
  mv "$TMP_LIST" "$FILE_LIST"
fi

FILE_TOTAL=$(wc -l < "$FILE_LIST" | tr -d ' ')

echo "Starting retime/audio audit"
echo "  Input: $INPUT_DIR"
echo "  Files to scan: $FILE_TOTAL"
echo "  large-gap-sec: $LARGE_GAP_SEC"
echo "  huge-gap-sec: $HUGE_GAP_SEC"
echo "  tiny-step-sec: $TINY_STEP_SEC"
echo "  Report TSV: $REPORT"

if (( FILE_TOTAL == 0 )); then
  echo "No matching files found (.mp4/.m4v/.mov)."
  exit 0
fi

while IFS= read -r file; do
  TOTAL=$(( TOTAL + 1 ))

  size_bytes=$(stat -f '%z' -- "$file" 2>/dev/null || echo 0)
  format_duration=$(ffprobe -v error -show_entries format=duration -of default=nokey=1:noprint_wrappers=1 -- "$file" 2>/dev/null | head -n 1)
  video_duration=$(ffprobe -v error -select_streams v:0 -show_entries stream=duration -of default=nokey=1:noprint_wrappers=1 -- "$file" 2>/dev/null | head -n 1)

  [[ -n "$format_duration" ]] || format_duration="0"
  [[ -n "$video_duration" ]] || video_duration="0"

  audio_streams=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 -- "$file" 2>/dev/null | wc -l | tr -d ' ')
  has_audio=1
  if [[ "$audio_streams" == "0" ]]; then
    has_audio=0
    NO_AUDIO_COUNT=$(( NO_AUDIO_COUNT + 1 ))
    printf '%s\n' "$file" >> "$NO_AUDIO_FILE"
  fi

  pts_stats=$(ffprobe -v error -select_streams v:0 -show_entries packet=pts_time -of csv=p=0 -- "$file" 2>/dev/null \
    | awk -v tiny="$TINY_STEP_SEC" -v large="$LARGE_GAP_SEC" -v huge="$HUGE_GAP_SEC" '
      BEGIN {
        prev=""; n=0; max=0; g05=0; g1=0; gl=0; gh=0; tinyc=0; band=0; neg=0;
      }
      {
        t=$1+0;
        if (prev != "") {
          d=t-prev;
          n++;
          if (d < 0) neg++;
          if (d > max) max=d;
          if (d > 0.5) g05++;
          if (d > 1.0) g1++;
          if (d > large) gl++;
          if (d > huge) gh++;
          if (d > 0 && d <= tiny) tinyc++;
          if (d >= 0.6 && d <= 1.2) band++;
        }
        prev=t;
      }
      END {
        tiny_ratio = (n > 0) ? (tinyc / n) : 0;
        printf "%.6f,%d,%d,%d,%d,%d,%.6f,%d,%d,%d", max, g05, g1, gl, gh, tinyc, tiny_ratio, band, neg, n;
      }
    ')

  IFS=',' read -r max_gap gaps_gt_0_5 gaps_gt_1 gaps_gt_large gaps_gt_huge tiny_count tiny_ratio jumps_0_6_to_1_2 negative_gaps interval_count <<< "$pts_stats"

  class="likely_ok"
  reasons=""

  if (( has_audio == 0 )); then
    reasons="${reasons:+$reasons,}no_audio_track"
  fi

  if awk -v mg="$max_gap" -v huge="$HUGE_GAP_SEC" 'BEGIN { exit !(mg >= huge) }'; then
    class="retime_required"
    reasons="${reasons:+$reasons,}huge_pts_gap"
  fi

  if awk -v mg="$max_gap" -v large="$LARGE_GAP_SEC" 'BEGIN { exit !(mg >= large) }'; then
    class="retime_required"
    reasons="${reasons:+$reasons,}large_pts_gap"
  fi

  if (( gaps_gt_1 >= 5 )); then
    class="retime_required"
    reasons="${reasons:+$reasons,}repeated_gt1s_gaps"
  fi

  if awk -v tr="$tiny_ratio" 'BEGIN { exit !(tr >= 0.05) }' && (( jumps_0_6_to_1_2 >= 20 )); then
    class="retime_required"
    reasons="${reasons:+$reasons,}oscillating_pts_pattern"
  fi

  if [[ "$class" == "likely_ok" ]]; then
    if awk -v mg="$max_gap" 'BEGIN { exit !(mg >= 1.0) }'; then
      class="retime_review"
      reasons="${reasons:+$reasons,}gt1s_gap"
    elif awk -v tr="$tiny_ratio" 'BEGIN { exit !(tr >= 0.02) }' && (( jumps_0_6_to_1_2 >= 5 )); then
      class="retime_review"
      reasons="${reasons:+$reasons,}mild_oscillation"
    fi
  fi

  if [[ -z "$reasons" ]]; then
    reasons="none"
  fi

  case "$class" in
    retime_required)
      RETIME_REQUIRED_COUNT=$(( RETIME_REQUIRED_COUNT + 1 ))
      printf '%s\n' "$file" >> "$RETIME_REQUIRED_FILE"
      ;;
    retime_review)
      RETIME_REVIEW_COUNT=$(( RETIME_REVIEW_COUNT + 1 ))
      printf '%s\n' "$file" >> "$RETIME_REVIEW_FILE"
      ;;
    *)
      LIKELY_OK_COUNT=$(( LIKELY_OK_COUNT + 1 ))
      printf '%s\n' "$file" >> "$LIKELY_OK_FILE"
      ;;
  esac

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$class" "$reasons" "$size_bytes" "$format_duration" "$video_duration" "$has_audio" "$audio_streams" \
    "$max_gap" "$gaps_gt_0_5" "$gaps_gt_1" "$gaps_gt_large" "$gaps_gt_huge" "$tiny_ratio" "$jumps_0_6_to_1_2" "$negative_gaps" "$file" >> "$REPORT"

  if [[ -t 1 ]]; then
    print_progress "$TOTAL" "$FILE_TOTAL" "$file"
  elif (( TOTAL % PROGRESS_EVERY == 0 || TOTAL == FILE_TOTAL )); then
    print_progress "$TOTAL" "$FILE_TOTAL" "$file"
  fi
done < "$FILE_LIST"

if [[ -t 1 ]]; then
  printf '\n'
fi

echo "Audit complete"
echo "  Files scanned: $TOTAL"
echo "  retime_required: $RETIME_REQUIRED_COUNT"
echo "  retime_review: $RETIME_REVIEW_COUNT"
echo "  likely_ok: $LIKELY_OK_COUNT"
echo "  no_audio: $NO_AUDIO_COUNT"
echo "  Report TSV: $REPORT"
echo "  retime_required list: $RETIME_REQUIRED_FILE"
echo "  retime_review list: $RETIME_REVIEW_FILE"
echo "  likely_ok list: $LIKELY_OK_FILE"
echo "  no_audio list: $NO_AUDIO_FILE"