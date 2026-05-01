#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Compare ledger-recorded duration to finalized media duration.

Usage:
  ./scripts/audit-ledger-vs-finalized.sh [options]

Options:
  --hours <n>         Time window in hours (default: 24)
  --db <path>         Path to recordings.sqlite
                      (default: ~/Library/Application Support/ChaturbateDVR/recordings.sqlite)
  --out-dir <dir>     Output directory for TSV report (default: /tmp)
  --loss-threshold <s>
                      Mark as loss when ffprobe_duration + threshold < ledger_duration
                      (default: 2)
  --help              Show this help

Output:
  - Prints summary and top deltas to stdout.
  - Writes a TSV report path as AUDIT_FILE:<path>
EOF
}

HOURS=24
DB_PATH="$HOME/Library/Application Support/ChaturbateDVR/recordings.sqlite"
OUT_DIR="/tmp"
LOSS_THRESHOLD=2

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hours)
      HOURS="${2:-}"
      shift 2
      ;;
    --db)
      DB_PATH="${2:-}"
      shift 2
      ;;
    --out-dir)
      OUT_DIR="${2:-}"
      shift 2
      ;;
    --loss-threshold)
      LOSS_THRESHOLD="${2:-}"
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

if ! [[ "$HOURS" =~ ^[0-9]+$ ]] || (( HOURS < 1 )); then
  echo "Error: --hours must be a positive integer" >&2
  exit 1
fi

if ! [[ "$LOSS_THRESHOLD" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "Error: --loss-threshold must be numeric" >&2
  exit 1
fi

if [[ ! -f "$DB_PATH" ]]; then
  echo "Error: DB not found: $DB_PATH" >&2
  exit 1
fi

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "Error: sqlite3 is required" >&2
  exit 1
fi

if ! command -v ffprobe >/dev/null 2>&1; then
  echo "Error: ffprobe is required" >&2
  exit 1
fi

mkdir -p -- "$OUT_DIR"

SINCE_UNIX=$(date -v-"${HOURS}"H +%s)
REPORT="$OUT_DIR/ledger-vs-finalized-$(date +%Y%m%d-%H%M%S).tsv"
ROWS_FILE=$(mktemp)
trap 'rm -f "$ROWS_FILE"' EXIT

sqlite3 -readonly -tabs "$DB_PATH" "
SELECT r.id,
       COALESCE(c.username, ''),
       COALESCE(r.ended_at, 0),
       COALESCE(r.status, ''),
       COALESCE(r.is_remuxed, 0),
       COALESCE(r.duration_seconds, 0),
       r.file_path
FROM recordings r
LEFT JOIN channels c ON c.id = r.channel_id
WHERE r.ended_at IS NOT NULL
  AND COALESCE(r.ended_at, r.updated_at, r.started_at, 0) >= $SINCE_UNIX
ORDER BY r.ended_at DESC;
" > "$ROWS_FILE"

echo -e "id\tchannel\tended_at\tstatus\tis_remuxed\tledger_duration_s\tffprobe_duration_s\tdelta_s\tloss_flag\tfile_state\tfile_path" > "$REPORT"

total=0
loss_cases=0
big_loss_cases=0
missing_or_unprobeable=0
abs_delta_over_2s=0

while IFS=$'\t' read -r rec_id channel ended_at rec_status is_remuxed ledger_duration file_path; do
  [[ -n "${rec_id:-}" ]] || continue
  total=$((total + 1))

  ff_duration=""
  delta=""
  loss_flag="no"
  file_state="ok"

  if [[ -z "${file_path:-}" || ! -f "$file_path" ]]; then
    file_state="missing"
    loss_flag="unknown"
    missing_or_unprobeable=$((missing_or_unprobeable + 1))
    echo -e "${rec_id}\t${channel}\t${ended_at}\t${rec_status}\t${is_remuxed}\t${ledger_duration}\t\t\t${loss_flag}\t${file_state}\t${file_path}" >> "$REPORT"
    continue
  fi

  ff_duration=$(ffprobe -v error -show_entries format=duration -of default=nokey=1:noprint_wrappers=1 -- "$file_path" | head -n 1 || true)
  if [[ -z "$ff_duration" ]]; then
    file_state="unprobeable"
    loss_flag="unknown"
    missing_or_unprobeable=$((missing_or_unprobeable + 1))
    echo -e "${rec_id}\t${channel}\t${ended_at}\t${rec_status}\t${is_remuxed}\t${ledger_duration}\t\t\t${loss_flag}\t${file_state}\t${file_path}" >> "$REPORT"
    continue
  fi

  delta=$(awk -v ff="$ff_duration" -v led="$ledger_duration" 'BEGIN { printf "%.3f", (ff - led) }')
  abs_delta=$(awk -v d="$delta" 'BEGIN { if (d < 0) d = -d; printf "%.3f", d }')

  if awk -v ff="$ff_duration" -v led="$ledger_duration" -v th="$LOSS_THRESHOLD" 'BEGIN { exit !((ff + th) < led) }'; then
    loss_flag="yes"
    loss_cases=$((loss_cases + 1))
    if awk -v ff="$ff_duration" -v led="$ledger_duration" 'BEGIN { exit !((ff + 30.0) < led) }'; then
      big_loss_cases=$((big_loss_cases + 1))
    fi
  fi

  if awk -v ad="$abs_delta" 'BEGIN { exit !(ad > 2.0) }'; then
    abs_delta_over_2s=$((abs_delta_over_2s + 1))
  fi

  echo -e "${rec_id}\t${channel}\t${ended_at}\t${rec_status}\t${is_remuxed}\t${ledger_duration}\t${ff_duration}\t${delta}\t${loss_flag}\t${file_state}\t${file_path}" >> "$REPORT"
done < "$ROWS_FILE"

echo "AUDIT_FILE:$REPORT"
echo "WINDOW_HOURS:$HOURS"
echo "TOTAL_FINALIZED:$total"
echo "LOSS_CASES:$loss_cases"
echo "BIG_LOSS_OVER_30S:$big_loss_cases"
echo "MISSING_OR_UNPROBEABLE:$missing_or_unprobeable"
echo "ABS_DELTA_OVER_2S:$abs_delta_over_2s"

echo "TOP_LOSS_CASES:"
awk -F '\t' 'NR==1{next} $9=="yes" {print}' "$REPORT" | sort -t$'\t' -k8,8n | head -n 10

echo "TOP_NEGATIVE_DELTAS:"
awk -F '\t' 'NR==1{next} $8!="" {print}' "$REPORT" | sort -t$'\t' -k8,8n | head -n 10
