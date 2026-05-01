#!/usr/bin/env zsh
set -euo pipefail

usage() {
  cat <<'EOF'
Batch-repair timestamp-corrupted recordings by regenerating video timestamps.

Usage:
  ./scripts/batch-retime-repair.sh [input-selector] [options]

Input selectors (choose one):
  --report <tsv>          Audit TSV from audit-retime-candidates.sh
  --list <txt>            Newline-separated file list
  --input <file|dir>      Direct file or recursive directory scan

Options:
  --class <name>          For --report, class filter (default: retime_required)
  --include-review        For --report, include retime_review in addition to class
  --output-dir <dir>      Output root for repaired files (default: alongside source)
  --limit <n>             Process only the first N selected files
  --suffix <text>         Output suffix before extension (default: _retimed)
  --workers <n>           Parallel ffmpeg jobs (default: 1)
  --fps <n>               Force output fps (default: source avg_frame_rate or 30)
  --crf <n>               x264 CRF quality (default: 20)
  --preset <name>         x264 preset (default: veryfast)
  --verify-max-gap <sec>  Fail verification if output max PTS gap exceeds this (default: 0.5)
  --overwrite             Overwrite existing output files
  --replace-source        Replace source with repaired output after verification
  --dry-run               Print planned actions only
  --help                  Show this help

Outputs:
  - A per-run TSV status report is written next to output files (or input root).
  - By default, repaired files are written as <name>_retimed.mp4.

Notes:
  - Requires: ffmpeg, ffprobe
  - Audio is preserved when present (-map 0:a? -c:a copy).
EOF
}

REPORT_FILE=""
LIST_FILE=""
INPUT_PATH=""
CLASS_FILTER="retime_required"
INCLUDE_REVIEW=0
OUTPUT_DIR=""
LIMIT=""
SUFFIX="_retimed"
WORKERS=1
FORCE_FPS=""
CRF=20
PRESET="veryfast"
VERIFY_MAX_GAP="0.5"
OVERWRITE=0
REPLACE_SOURCE=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --report)
      REPORT_FILE="${2:-}"
      shift 2
      ;;
    --list)
      LIST_FILE="${2:-}"
      shift 2
      ;;
    --input)
      INPUT_PATH="${2:-}"
      shift 2
      ;;
    --class)
      CLASS_FILTER="${2:-}"
      shift 2
      ;;
    --include-review)
      INCLUDE_REVIEW=1
      shift
      ;;
    --output-dir)
      OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    --limit)
      LIMIT="${2:-}"
      shift 2
      ;;
    --suffix)
      SUFFIX="${2:-}"
      shift 2
      ;;
    --workers)
      WORKERS="${2:-}"
      shift 2
      ;;
    --fps)
      FORCE_FPS="${2:-}"
      shift 2
      ;;
    --crf)
      CRF="${2:-}"
      shift 2
      ;;
    --preset)
      PRESET="${2:-}"
      shift 2
      ;;
    --verify-max-gap)
      VERIFY_MAX_GAP="${2:-}"
      shift 2
      ;;
    --overwrite)
      OVERWRITE=1
      shift
      ;;
    --replace-source)
      REPLACE_SOURCE=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
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

selector_count=0
[[ -n "$REPORT_FILE" ]] && selector_count=$(( selector_count + 1 ))
[[ -n "$LIST_FILE" ]] && selector_count=$(( selector_count + 1 ))
[[ -n "$INPUT_PATH" ]] && selector_count=$(( selector_count + 1 ))

if (( selector_count != 1 )); then
  echo "Error: choose exactly one of --report, --list, or --input" >&2
  usage
  exit 1
fi

if ! [[ "$WORKERS" =~ '^[0-9]+$' ]] || (( WORKERS < 1 )); then
  echo "Error: --workers must be a positive integer" >&2
  exit 1
fi

if ! [[ "$CRF" =~ '^[0-9]+([.][0-9]+)?$' ]]; then
  echo "Error: --crf must be numeric" >&2
  exit 1
fi

if [[ -n "$FORCE_FPS" ]] && ! [[ "$FORCE_FPS" =~ '^[0-9]+([.][0-9]+)?$' ]]; then
  echo "Error: --fps must be numeric" >&2
  exit 1
fi

if ! [[ "$VERIFY_MAX_GAP" =~ '^[0-9]+([.][0-9]+)?$' ]]; then
  echo "Error: --verify-max-gap must be numeric" >&2
  exit 1
fi

if [[ -n "$LIMIT" ]] && { ! [[ "$LIMIT" =~ '^[0-9]+$' ]] || (( LIMIT < 1 )); }; then
  echo "Error: --limit must be a positive integer" >&2
  exit 1
fi

if (( REPLACE_SOURCE == 1 )) && [[ -n "$OUTPUT_DIR" ]]; then
  echo "Error: --replace-source cannot be combined with --output-dir" >&2
  exit 1
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "Error: ffmpeg is required" >&2
  exit 1
fi

if ! command -v ffprobe >/dev/null 2>&1; then
  echo "Error: ffprobe is required" >&2
  exit 1
fi

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
FILE_LIST="$TMP_DIR/files.txt"
: > "$FILE_LIST"

if [[ -n "$REPORT_FILE" ]]; then
  REPORT_FILE="${REPORT_FILE:A}"
  if [[ ! -f "$REPORT_FILE" ]]; then
    echo "Error: report not found: $REPORT_FILE" >&2
    exit 1
  fi

  awk -F '\t' -v klass="$CLASS_FILTER" -v includeReview="$INCLUDE_REVIEW" '
    NR == 1 { next }
    {
      c = $1
      p = $16
      if (p == "") next
      if (c == klass || (includeReview == 1 && c == "retime_review")) {
        print p
      }
    }
  ' "$REPORT_FILE" > "$FILE_LIST"
elif [[ -n "$LIST_FILE" ]]; then
  LIST_FILE="${LIST_FILE:A}"
  if [[ ! -f "$LIST_FILE" ]]; then
    echo "Error: list file not found: $LIST_FILE" >&2
    exit 1
  fi
  grep -v '^[[:space:]]*$' "$LIST_FILE" > "$FILE_LIST"
else
  INPUT_PATH="${INPUT_PATH:A}"
  if [[ ! -e "$INPUT_PATH" ]]; then
    echo "Error: input not found: $INPUT_PATH" >&2
    exit 1
  fi

  if [[ -f "$INPUT_PATH" ]]; then
    print -r -- "$INPUT_PATH" > "$FILE_LIST"
  else
    find "$INPUT_PATH" -type f \( -iname '*.mp4' -o -iname '*.m4v' -o -iname '*.mov' \) -print > "$FILE_LIST"
  fi
fi

sort -u "$FILE_LIST" -o "$FILE_LIST"

if [[ -n "$LIMIT" ]]; then
  TMP_LIMITED="$TMP_DIR/files.limited.txt"
  head -n "$LIMIT" "$FILE_LIST" > "$TMP_LIMITED"
  mv "$TMP_LIMITED" "$FILE_LIST"
fi

TOTAL=$(wc -l < "$FILE_LIST" | tr -d ' ')
if (( TOTAL == 0 )); then
  echo "No input files selected."
  exit 0
fi

RUN_TIMESTAMP=$(date '+%Y%m%d-%H%M%S')

if [[ -n "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="${OUTPUT_DIR:A}"
  mkdir -p -- "$OUTPUT_DIR"
  RUN_DIR="$OUTPUT_DIR"
elif [[ -n "$REPORT_FILE" ]]; then
  RUN_DIR="${REPORT_FILE:h}"
elif [[ -n "$LIST_FILE" ]]; then
  RUN_DIR="${LIST_FILE:h}"
elif [[ -n "$INPUT_PATH" && -d "$INPUT_PATH" ]]; then
  RUN_DIR="$INPUT_PATH"
elif [[ -n "$INPUT_PATH" && -f "$INPUT_PATH" ]]; then
  RUN_DIR="${INPUT_PATH:h}"
else
  first_file=$(head -n 1 "$FILE_LIST")
  RUN_DIR="${first_file:h}"
fi

STATUS_FILE="$RUN_DIR/retime-repair-$RUN_TIMESTAMP.tsv"
printf 'status\tsource\toutput\tfps\tin_duration\tout_duration\tout_max_gap\tnote\n' > "$STATUS_FILE"

echo "Starting batch retime repair"
echo "  Files selected: $TOTAL"
if [[ -n "$LIMIT" ]]; then
  echo "  Limit: $LIMIT"
fi
echo "  Workers: $WORKERS"
echo "  Mode: $([[ $REPLACE_SOURCE -eq 1 ]] && echo replace-source || echo write-new-files)"
echo "  Status TSV: $STATUS_FILE"

fraction_to_decimal_fps() {
  local ratio="$1"
  awk -v r="$ratio" 'BEGIN {
    if (r == "" || r == "0/0") { print "30"; exit }
    if (index(r, "/") == 0) { print r; exit }
    split(r, p, "/")
    n = p[1] + 0
    d = p[2] + 0
    if (d <= 0) { print "30"; exit }
    printf "%.6f", (n / d)
  }'
}

get_video_duration() {
  local f="$1"
  ffprobe -v error -select_streams v:0 -show_entries stream=duration -of default=nokey=1:noprint_wrappers=1 -- "$f" 2>/dev/null | head -n 1
}

get_max_gap() {
  local f="$1"
  ffprobe -v error -select_streams v:0 -show_entries packet=pts_time -of csv=p=0 -- "$f" 2>/dev/null \
    | awk 'BEGIN{prev="";max=0} {t=$1+0; if(prev!=""){d=t-prev; if(d>max)max=d} prev=t} END{printf "%.6f", max}'
}

detect_source_fps() {
  local f="$1"
  local ratio
  ratio=$(ffprobe -v error -select_streams v:0 -show_entries stream=avg_frame_rate -of default=nokey=1:noprint_wrappers=1 -- "$f" 2>/dev/null | head -n 1)
  fraction_to_decimal_fps "$ratio"
}

build_output_path() {
  local source="$1"
  local out
  local stem="${source:t:r}"

  if (( REPLACE_SOURCE == 1 )); then
    out="${source:h}/.${stem}.retime_work.mp4"
  elif [[ -n "$OUTPUT_DIR" ]]; then
    out="$OUTPUT_DIR/${stem}${SUFFIX}.mp4"
  else
    out="${source:h}/${stem}${SUFFIX}.mp4"
  fi

  print -r -- "$out"
}

run_repair() {
  local source="$1"

  if [[ ! -f "$source" ]]; then
    printf 'missing\t%s\t\t\t\t\t\tfile_not_found\n' "$source" >> "$STATUS_FILE"
    return 0
  fi

  local fps
  if [[ -n "$FORCE_FPS" ]]; then
    fps="$FORCE_FPS"
  else
    fps=$(detect_source_fps "$source")
  fi

  local out
  out=$(build_output_path "$source")

  if (( OVERWRITE == 0 )) && [[ -f "$out" ]]; then
    printf 'skipped_exists\t%s\t%s\t%s\t\t\t\toutput_exists\n' "$source" "$out" "$fps" >> "$STATUS_FILE"
    return 0
  fi

  if (( DRY_RUN == 1 )); then
    printf 'dry_run\t%s\t%s\t%s\t\t\t\tplanned\n' "$source" "$out" "$fps" >> "$STATUS_FILE"
    return 0
  fi

  local in_duration
  in_duration=$(get_video_duration "$source")
  [[ -n "$in_duration" ]] || in_duration="0"

  local ff_args=(
    -nostdin
    -hide_banner
    -loglevel error
    -y
    -i "$source"
    -map 0:v:0
    -map "0:a?"
    -analyzeduration 100M
    -probesize 100M
    -vf "setpts=N/(${fps}*TB),fps=${fps},format=yuv420p"
    -c:v libx264
    -preset "$PRESET"
    -crf "$CRF"
    -c:a copy
    -movflags +faststart
    "$out"
  )

  if ! ffmpeg "${ff_args[@]}"; then
    printf 'failed_encode\t%s\t%s\t%s\t%s\t\t\tffmpeg_failed\n' "$source" "$out" "$fps" "$in_duration" >> "$STATUS_FILE"
    return 0
  fi

  local out_duration out_gap
  out_duration=$(get_video_duration "$out")
  out_gap=$(get_max_gap "$out")
  [[ -n "$out_duration" ]] || out_duration="0"
  [[ -n "$out_gap" ]] || out_gap="999999"

  if awk -v g="$out_gap" -v lim="$VERIFY_MAX_GAP" 'BEGIN { exit !(g > lim) }'; then
    printf 'failed_verify\t%s\t%s\t%s\t%s\t%s\t%s\tout_gap_exceeds_limit\n' "$source" "$out" "$fps" "$in_duration" "$out_duration" "$out_gap" >> "$STATUS_FILE"
    return 0
  fi

  if awk -v d="$out_duration" 'BEGIN { exit !(d <= 1.0) }'; then
    printf 'failed_verify\t%s\t%s\t%s\t%s\t%s\t%s\tout_duration_too_short\n' "$source" "$out" "$fps" "$in_duration" "$out_duration" "$out_gap" >> "$STATUS_FILE"
    return 0
  fi

  if (( REPLACE_SOURCE == 1 )); then
    local backup="${source}.pre_retime_backup"
    mv -f -- "$source" "$backup"
    mv -f -- "$out" "$source"
    printf 'replaced\t%s\t%s\t%s\t%s\t%s\t%s\tbackup=%s\n' "$source" "$source" "$fps" "$in_duration" "$out_duration" "$out_gap" "$backup" >> "$STATUS_FILE"
  else
    printf 'repaired\t%s\t%s\t%s\t%s\t%s\t%s\tok\n' "$source" "$out" "$fps" "$in_duration" "$out_duration" "$out_gap" >> "$STATUS_FILE"
  fi
}

typeset -a pids=()
STARTED=0

while IFS= read -r source; do
  [[ -n "$source" ]] || continue

  run_repair "$source" &
  pids+=("$!")
  STARTED=$(( STARTED + 1 ))

  while (( ${#pids[@]} >= WORKERS )); do
    wait "${pids[1]}" || true
    pids=("${pids[@]:1}")
  done
done < "$FILE_LIST"

for pid in "${pids[@]:-}"; do
  [[ -n "$pid" ]] || continue
  wait "$pid" || true
done

echo "Batch retime complete"
echo "  Status TSV: $STATUS_FILE"
echo "  Summary:"
awk -F '\t' 'NR>1{c[$1]++} END{for(k in c) printf "    %s: %d\n", k, c[k]}' "$STATUS_FILE" | sort
