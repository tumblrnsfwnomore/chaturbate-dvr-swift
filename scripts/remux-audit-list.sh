#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Remux video files listed in a newline-delimited text file.

Usage:
  ./scripts/remux-audit-list.sh --list <file> [options]

Options:
  --list <file>        Text file containing one absolute video path per line (required)
  --output-dir <dir>   Directory for remuxed files (default: <list_dir>/remux-test-<timestamp>)
  --overwrite          Overwrite outputs if they already exist
  --help               Show this help

Notes:
  - Originals are never modified.
  - Output filenames are preserved inside the output directory.
  - Uses ffmpeg stream copy with +faststart for a quick remux/finalization pass.
EOF
}

LIST_FILE=""
OUTPUT_DIR=""
OVERWRITE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list)
      LIST_FILE="${2:-}"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    --overwrite)
      OVERWRITE=1
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

if [[ -z "$LIST_FILE" ]]; then
  echo "Error: --list is required" >&2
  usage
  exit 1
fi

if [[ ! -f "$LIST_FILE" ]]; then
  echo "Error: list file not found: $LIST_FILE" >&2
  exit 1
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "Error: ffmpeg is required" >&2
  exit 1
fi

if [[ -z "$OUTPUT_DIR" ]]; then
  list_dir=$(cd "$(dirname "$LIST_FILE")" && pwd)
  run_timestamp=$(date '+%Y%m%d-%H%M%S')
  OUTPUT_DIR="$list_dir/remux-test-$run_timestamp"
fi

mkdir -p -- "$OUTPUT_DIR"

count=0
while IFS= read -r source_path || [[ -n "$source_path" ]]; do
  [[ -n "$source_path" ]] || continue

  if [[ ! -f "$source_path" ]]; then
    echo "Skipping missing file: $source_path" >&2
    continue
  fi

  base_name=$(basename "$source_path")
  output_path="$OUTPUT_DIR/$base_name"
  ffmpeg_overwrite=(-n)
  if (( OVERWRITE == 1 )); then
    ffmpeg_overwrite=(-y)
  fi

  echo "Remuxing: $base_name"
  ffmpeg "${ffmpeg_overwrite[@]}" -nostdin -v error -i "$source_path" -map 0 -c copy -movflags +faststart "$output_path" < /dev/null
  count=$(( count + 1 ))
done < "$LIST_FILE"

echo "Remuxed $count file(s) to: $OUTPUT_DIR"