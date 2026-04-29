#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Audit recorded video files and classify remux candidates.

Usage:
  ./scripts/audit-remux-candidates.sh --input <dir> [options]

Options:
  --input <dir>         Root directory to scan recursively (required)
  --output-dir <dir>    Directory for reports (default: <input>)
  --head-mb <n>         Bytes from head to probe for box markers (default: 12 MB)
  --progress-every <n>  Print progress every N files when non-interactive (default: 10)
  --help                Show this help

Classification:
  - must_remux: suspicious duration metadata for file size
  - optional_remux: fragmented MP4 marker detected near file start (may be slow in players)
  - likely_ok: no obvious metadata/container issues from this audit

Outputs:
  <output-dir>/remux-audit-<timestamp>.tsv
  <output-dir>/remux-audit-<timestamp>.must_remux.txt
  <output-dir>/remux-audit-<timestamp>.optional_remux.txt
  <output-dir>/remux-audit-<timestamp>.likely_ok.txt
EOF
}

INPUT_DIR=""
OUTPUT_DIR=""
HEAD_MB=12
PROGRESS_EVERY=10

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
    --head-mb)
      HEAD_MB="${2:-}"
      shift 2
      ;;
    --progress-every)
      PROGRESS_EVERY="${2:-}"
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

INPUT_DIR="${INPUT_DIR%/}"
if [[ ! -d "$INPUT_DIR" ]]; then
  echo "Error: input directory not found: $INPUT_DIR" >&2
  exit 1
fi

if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="$INPUT_DIR"
fi

if [[ ! -d "$OUTPUT_DIR" ]]; then
  mkdir -p -- "$OUTPUT_DIR"
fi

if ! [[ "$HEAD_MB" =~ ^[0-9]+$ ]] || (( HEAD_MB < 1 )); then
  echo "Error: --head-mb must be a positive integer" >&2
  exit 1
fi

if ! [[ "$PROGRESS_EVERY" =~ ^[0-9]+$ ]] || (( PROGRESS_EVERY < 1 )); then
  echo "Error: --progress-every must be a positive integer" >&2
  exit 1
fi

if ! command -v ffprobe >/dev/null 2>&1; then
  echo "Error: ffprobe is required for this audit" >&2
  exit 1
fi

RUN_TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
REPORT="$OUTPUT_DIR/remux-audit-$RUN_TIMESTAMP.tsv"
MUST_FILE="$OUTPUT_DIR/remux-audit-$RUN_TIMESTAMP.must_remux.txt"
OPTIONAL_FILE="$OUTPUT_DIR/remux-audit-$RUN_TIMESTAMP.optional_remux.txt"
OK_FILE="$OUTPUT_DIR/remux-audit-$RUN_TIMESTAMP.likely_ok.txt"

printf 'class\treasons\tsize_bytes\tformat_duration\tvideo_duration\tmoov_in_head\tmoof_in_head\tpath\n' > "$REPORT"
: > "$MUST_FILE"
: > "$OPTIONAL_FILE"
: > "$OK_FILE"

TOTAL=0
MUST_COUNT=0
OPTIONAL_COUNT=0
OK_COUNT=0
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

  local short_name
  short_name="${current_file##*/}"

  if [[ -t 1 ]]; then
    printf '\rScanned %d/%d (%d%%) | elapsed %s | eta %s | must=%d optional=%d ok=%d | %s\033[K' \
      "$scanned" "$total" "$percent" "$(format_seconds "$elapsed")" "$(format_seconds "$eta")" "$MUST_COUNT" "$OPTIONAL_COUNT" "$OK_COUNT" "$short_name"
  else
    printf 'Progress %d/%d (%d%%) | elapsed %s | eta %s | must=%d optional=%d ok=%d | %s\n' \
      "$scanned" "$total" "$percent" "$(format_seconds "$elapsed")" "$(format_seconds "$eta")" "$MUST_COUNT" "$OPTIONAL_COUNT" "$OK_COUNT" "$current_file"
  fi
}

FILE_LIST=$(mktemp)
trap 'rm -f "$FILE_LIST"' EXIT
find "$INPUT_DIR" -type f \( -iname '*.mp4' -o -iname '*.m4v' -o -iname '*.mov' \) -print > "$FILE_LIST"
FILE_TOTAL=$(wc -l < "$FILE_LIST" | tr -d ' ')

echo "Starting audit"
echo "  Input: $INPUT_DIR"
echo "  Files to scan: $FILE_TOTAL"
echo "  Head probe: ${HEAD_MB} MB"
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

  # Probe the head only to keep runtime predictable on large files.
  head_probe=$(dd if="$file" bs=1m count="$HEAD_MB" 2>/dev/null | LC_ALL=C tr -cd '[:print:]\n' || true)
  moov_in_head=0
  moof_in_head=0
  [[ "$head_probe" == *moov* ]] && moov_in_head=1
  [[ "$head_probe" == *moof* ]] && moof_in_head=1

  reasons=""

  bad_metadata=$(awk -v fd="$format_duration" -v vd="$video_duration" -v sz="$size_bytes" 'BEGIN {
    if (fd <= 0.1 && sz > 100*1024*1024) { print 1; exit }
    if (vd <= 0.1 && sz > 100*1024*1024) { print 1; exit }
    if (fd > 0 && vd > 0 && ((fd > vd ? fd-vd : vd-fd) > 15)) { print 1; exit }
    print 0
  }')
  if [[ "$bad_metadata" == "1" ]]; then
    reasons="${reasons:+$reasons,}duration_metadata"
  fi

  short_for_size=$(awk -v fd="$format_duration" -v sz="$size_bytes" 'BEGIN {
    print (fd > 0 && fd < 180 && sz > 800*1024*1024) ? 1 : 0
  }')
  if [[ "$short_for_size" == "1" ]]; then
    reasons="${reasons:+$reasons,}short_for_size"
  fi

  if (( moof_in_head == 1 )); then
    reasons="${reasons:+$reasons,}fragmented_head"
  fi

  class="likely_ok"
  if [[ "$reasons" == *duration_metadata* || "$reasons" == *short_for_size* ]]; then
    class="must_remux"
    MUST_COUNT=$(( MUST_COUNT + 1 ))
    printf '%s\n' "$file" >> "$MUST_FILE"
  elif [[ "$reasons" == *fragmented_head* ]]; then
    class="optional_remux"
    OPTIONAL_COUNT=$(( OPTIONAL_COUNT + 1 ))
    printf '%s\n' "$file" >> "$OPTIONAL_FILE"
  else
    OK_COUNT=$(( OK_COUNT + 1 ))
    printf '%s\n' "$file" >> "$OK_FILE"
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$class" "${reasons:-none}" "$size_bytes" "$format_duration" "$video_duration" "$moov_in_head" "$moof_in_head" "$file" >> "$REPORT"

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
echo "  Input: $INPUT_DIR"
echo "  Files scanned: $TOTAL"
echo "  must_remux: $MUST_COUNT"
echo "  optional_remux: $OPTIONAL_COUNT"
echo "  likely_ok: $OK_COUNT"
echo "  Report TSV: $REPORT"
echo "  must_remux list: $MUST_FILE"
echo "  optional_remux list: $OPTIONAL_FILE"
echo "  likely_ok list: $OK_FILE"
