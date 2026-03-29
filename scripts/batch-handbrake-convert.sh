#!/usr/bin/env zsh
set -euo pipefail

usage() {
  cat <<'EOF'
Batch-convert recordings with HandBrakeCLI.

Usage:
  ./scripts/batch-handbrake-convert.sh --input <dir> [options]

Options:
  --input <dir>          Root directory to scan recursively (required)
  --workers <n>          Concurrent conversions (default: 1)
  --nice <n>             Process niceness for HandBrake (default: 12, lower = more CPU priority)
  --sleep-between <n>    Seconds to pause between file launches (default: 2)
  --preset <name>        HandBrake preset name (default: Fast 1080p30)
  --dry-run              Print planned actions only
  --overwrite            Re-encode even if destination already exists
  --delete-source        Delete source file after verified conversion
  --replace-source       Replace source with converted file after verification
  --extensions <list>    Comma-separated extensions (default: mp4,mkv,mov,ts,m4v)
  --help                 Show this help

Examples:
  ./scripts/batch-handbrake-convert.sh --input ~/Recordings --dry-run
  ./scripts/batch-handbrake-convert.sh --input ~/Recordings --delete-source
  ./scripts/batch-handbrake-convert.sh --input ~/Recordings --workers 2 --nice 10

Features:
  - Live overall progress bar
  - Live per-file active job progress from HandBrake JSON output
  - Overall ETA
  - Persistent text log and TSV status file in the input directory
  - Conservative defaults for long unattended runs

Notes:
  - Requires: HandBrakeCLI
  - Optional: ffprobe (used for duration verification)
  - For .mp4 sources, non-replace mode outputs <name>.hb.mp4 to avoid clobbering.
EOF
}

INPUT_DIR=""
WORKERS=""
NICE_LEVEL=12
SLEEP_BETWEEN_JOBS=2
PRESET="Fast 1080p30"
DRY_RUN=0
OVERWRITE=0
DELETE_SOURCE=0
REPLACE_SOURCE=0
EXTENSIONS="mp4,mkv,mov,ts,m4v"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input)
      INPUT_DIR="${2:-}"
      shift 2
      ;;
    --workers)
      WORKERS="${2:-}"
      shift 2
      ;;
    --nice)
      NICE_LEVEL="${2:-}"
      shift 2
      ;;
    --sleep-between)
      SLEEP_BETWEEN_JOBS="${2:-}"
      shift 2
      ;;
    --preset)
      PRESET="${2:-}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --overwrite)
      OVERWRITE=1
      shift
      ;;
    --delete-source)
      DELETE_SOURCE=1
      shift
      ;;
    --replace-source)
      REPLACE_SOURCE=1
      DELETE_SOURCE=1
      shift
      ;;
    --extensions)
      EXTENSIONS="${2:-}"
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

INPUT_DIR="${INPUT_DIR:A}"
if [[ ! -d "$INPUT_DIR" ]]; then
  echo "Error: input directory not found: $INPUT_DIR" >&2
  exit 1
fi

if ! command -v HandBrakeCLI >/dev/null 2>&1; then
  echo "Error: HandBrakeCLI not found. Install with: brew install handbrake" >&2
  exit 1
fi

HAS_FFPROBE=0
if command -v ffprobe >/dev/null 2>&1; then
  HAS_FFPROBE=1
fi

if [[ -z "$WORKERS" ]]; then
  WORKERS=1
fi

if ! [[ "$WORKERS" =~ '^[0-9]+$' ]] || (( WORKERS < 1 )); then
  echo "Error: --workers must be a positive integer" >&2
  exit 1
fi

if ! [[ "$NICE_LEVEL" =~ '^[-]?[0-9]+$' ]]; then
  echo "Error: --nice must be an integer" >&2
  exit 1
fi

if ! [[ "$SLEEP_BETWEEN_JOBS" =~ '^[0-9]+$' ]]; then
  echo "Error: --sleep-between must be a non-negative integer" >&2
  exit 1
fi

RUN_TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
RUN_LOG="$INPUT_DIR/handbrake-convert-$RUN_TIMESTAMP.log"
STATUS_FILE="$INPUT_DIR/handbrake-convert-$RUN_TIMESTAMP.tsv"
TMP_DIR="$(mktemp -d)"
JOB_STATE_DIR="$TMP_DIR/job-states"
mkdir -p "$JOB_STATE_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT

IFS=',' read -rA EXT_ARR <<< "$EXTENSIONS"
if (( ${#EXT_ARR[@]} == 0 )); then
  echo "Error: --extensions produced an empty list" >&2
  exit 1
fi

typeset -gi PREVIOUS_RENDER_LINES=0
typeset -gi RUN_START_EPOCH=$(date +%s)
typeset -ga JOB_PIDS=()

timestamp_now() {
  date '+%Y-%m-%d %H:%M:%S'
}

log_text() {
  printf '[%s] %s\n' "$(timestamp_now)" "$*" >> "$RUN_LOG"
}

human_size() {
  local bytes="${1:-0}"
  awk -v b="$bytes" 'BEGIN {
    split("B KB MB GB TB", u, " ")
    i = 1
    while (b >= 1024 && i < 5) {
      b /= 1024
      i++
    }
    printf "%.2f %s", b, u[i]
  }'
}

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

trim_number_field() {
  local value="$1"
  value="${value##*:}"
  value="${value//,/}"
  value="${value// /}"
  value="${value//\"/}"
  printf '%s' "$value"
}

short_name() {
  local path="$1"
  local name="${path:t}"
  if (( ${#name} > 42 )); then
    printf '...%s' "${name[-39,-1]}"
  else
    printf '%s' "$name"
  fi
}

build_find_expr() {
  local -a expr
  local ext
  for ext in "$@"; do
    ext="${ext:l}"
    if [[ -z "$ext" ]]; then
      continue
    fi
    expr+=( -iname "*.$ext" -o )
  done

  if (( ${#expr[@]} == 0 )); then
    return
  fi

  expr[-1]=()
  print -r -- "${(j: :)expr}"
}

get_duration_seconds() {
  local file="$1"
  ffprobe -v error -show_entries format=duration -of default=nokey=1:noprint_wrappers=1 -- "$file" 2>/dev/null | head -n 1
}

verify_conversion() {
  local src="$1"
  local out="$2"

  if [[ ! -s "$out" ]]; then
    return 1
  fi

  if (( HAS_FFPROBE == 0 )); then
    return 0
  fi

  local src_dur out_dur
  src_dur="$(get_duration_seconds "$src")"
  out_dur="$(get_duration_seconds "$out")"

  if [[ -z "$src_dur" || -z "$out_dur" ]]; then
    return 0
  fi

  local delta allowed
  delta=$(awk -v a="$src_dur" -v b="$out_dur" 'BEGIN{d=(a>b?a-b:b-a); printf "%.6f", d}')
  allowed=$(awk -v a="$src_dur" 'BEGIN{t=a*0.01; if (t < 2.0) t=2.0; printf "%.6f", t}')
  awk -v d="$delta" -v t="$allowed" 'BEGIN{exit !(d <= t)}'
}

destination_for() {
  local src="$1"
  local lower="${src:l}"

  if (( REPLACE_SOURCE == 1 )); then
    if [[ "$lower" == *.mp4 ]]; then
      printf '%s' "$src"
    else
      printf '%s.mp4' "${src:r}"
    fi
    return
  fi

  if [[ "$lower" == *.mp4 ]]; then
    printf '%s.hb.mp4' "${src:r}"
  else
    printf '%s.mp4' "${src:r}"
  fi
}

write_job_state() {
  local job_id="$1"
  local src="$2"
  local phase="$3"
  local progress="$4"
  local eta_seconds="$5"
  local rate_avg="$6"

  local state_file="$JOB_STATE_DIR/job-$job_id.state"
  printf '%s\n%s\n%s\n%s\n%s\n' "$src" "$phase" "$progress" "$eta_seconds" "$rate_avg" > "$state_file"
}

remove_job_state() {
  local job_id="$1"
  rm -f -- "$JOB_STATE_DIR/job-$job_id.state"
}

append_status() {
  printf '%s\n' "$1" >> "$STATUS_FILE"
}

render_progress_bar() {
  local completed="$1"
  local total="$2"
  local width=34
  local filled=$(( total > 0 ? completed * width / total : 0 ))
  local empty=$(( width - filled ))
  local percent=$(( total > 0 ? completed * 100 / total : 0 ))
  local bar=""

  if (( filled > 0 )); then
    bar+=$(printf '%*s' "$filled" '' | tr ' ' '#')
  fi
  if (( empty > 0 )); then
    bar+=$(printf '%*s' "$empty" '' | tr ' ' '-')
  fi

  printf '[%s] %3d%%' "$bar" "$percent"
}

read_job_lines() {
  local -a lines
  local state_file
  for state_file in "$JOB_STATE_DIR"/*.state(N); do
    local -a state
    state=("${(@f)$(<"$state_file")}")
    (( ${#state[@]} >= 5 )) || continue

    local src="$state[1]"
    local phase="$state[2]"
    local progress="$state[3]"
    local eta_seconds="$state[4]"
    local rate_avg="$state[5]"

    local phase_label="$phase"
    case "$phase" in
      scanning) phase_label="scan" ;;
      encoding) phase_label="encode" ;;
      verifying) phase_label="verify" ;;
      moving) phase_label="finalize" ;;
      queued) phase_label="queued" ;;
    esac

    local eta_label="--:--"
    if [[ -n "$eta_seconds" && "$eta_seconds" != "-" ]] && [[ "$eta_seconds" =~ '^[0-9]+$' ]]; then
      eta_label="$(format_seconds "$eta_seconds")"
    fi

    local rate_label="-"
    if [[ -n "$rate_avg" && "$rate_avg" != "-" ]]; then
      rate_label=$(awk -v r="$rate_avg" 'BEGIN{printf "%.1f fps", r}')
    fi

    lines+=("  $(short_name "$src") | ${phase_label}: ${progress}% | eta ${eta_label} | ${rate_label}")
  done
  reply=("${lines[@]}")
}

render_dashboard() {
  local completed="$1"
  local total="$2"
  local active="$3"
  local now elapsed overall_eta
  now=$(date +%s)
  elapsed=$(( now - RUN_START_EPOCH ))

  if (( completed > 0 && completed < total )); then
    overall_eta=$(( elapsed * (total - completed) / completed ))
  else
    overall_eta=0
  fi

  local -a lines
  lines+=("$(render_progress_bar "$completed" "$total")  ${completed}/${total} complete  ${active} active")
  lines+=("Elapsed: $(format_seconds "$elapsed")  Overall ETA: $( (( completed > 0 && completed < total )) && format_seconds "$overall_eta" || printf '%s' '--:--' )")

  read_job_lines
  local -a job_lines
  job_lines=("${reply[@]}")
  if (( ${#job_lines[@]} > 0 )); then
    lines+=("Active jobs:")
    lines+=("${job_lines[@]}")
  fi

  if [[ -t 1 ]]; then
    if (( PREVIOUS_RENDER_LINES > 0 )); then
      printf '\033[%dA' "$PREVIOUS_RENDER_LINES"
    fi
    printf '\r\033[J'
    local line
    for line in "${lines[@]}"; do
      printf '%s\n' "$line"
    done
    PREVIOUS_RENDER_LINES=${#lines[@]}
  fi
}

finish_dashboard() {
  local completed="$1"
  local total="$2"
  render_dashboard "$completed" "$total" 0
}

count_running_jobs() {
  local -a still_running=()
  local pid
  for pid in "${JOB_PIDS[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      still_running+=("$pid")
    fi
  done
  JOB_PIDS=("${still_running[@]}")
  printf '%d' "${#JOB_PIDS[@]}"
}

convert_one() {
  local src="$1"
  local job_id="$2"
  local dest tmp encoded_size src_size saved_bytes saved_percent
  local hb_output_file="$TMP_DIR/job-$job_id.handbrake.log"

  dest="$(destination_for "$src")"
  tmp="$dest.tmp.$RANDOM.$RANDOM"
  src_size=$(stat -f '%z' -- "$src" 2>/dev/null || echo 0)

  write_job_state "$job_id" "$src" "queued" 0 - -
  log_text "START | $(short_name "$src") -> $(short_name "$dest")"

  if [[ -e "$dest" && "$src" != "$dest" && $OVERWRITE -eq 0 ]]; then
    append_status "SKIP_EXISTS	$src	$dest	$src_size	0"
    log_text "SKIP_EXISTS | $(short_name "$src") | destination already exists"
    remove_job_state "$job_id"
    return
  fi

  if (( DRY_RUN == 1 )); then
    append_status "DRY_RUN	$src	$dest	$src_size	0"
    log_text "DRY_RUN | $(short_name "$src") -> $(short_name "$dest")"
    remove_job_state "$job_id"
    return
  fi

  local -a hb_cmd
  hb_cmd=(
    nice
    -n "$NICE_LEVEL"
    HandBrakeCLI
    --json
    -i "$src"
    -o "$tmp"
    --preset "$PRESET"
    --optimize
  )

  local current_state=""
  local progress_pct="0.0"
  local eta_seconds="-"
  local rate_avg="-"
  local fraction=""

  "${hb_cmd[@]}" 2>&1 | tee "$hb_output_file" | while IFS= read -r line; do
    case "$line" in
      *'"State": "SCANNING"'*)
        current_state="SCANNING"
        ;;
      *'"State": "WORKING"'*)
        current_state="WORKING"
        ;;
      *'"State": "WORKDONE"'*)
        current_state="WORKDONE"
        ;;
      *'"ETASeconds": '*)
        eta_seconds="$(trim_number_field "$line")"
        [[ "$current_state" == "WORKING" ]] && write_job_state "$job_id" "$src" "encoding" "$progress_pct" "$eta_seconds" "$rate_avg"
        ;;
      *'"RateAvg": '*)
        rate_avg="$(trim_number_field "$line")"
        [[ "$current_state" == "WORKING" ]] && write_job_state "$job_id" "$src" "encoding" "$progress_pct" "$eta_seconds" "$rate_avg"
        ;;
      *'"Progress": '*)
        fraction="$(trim_number_field "$line")"
        progress_pct=$(awk -v p="$fraction" 'BEGIN{printf "%.1f", p * 100}')
        if [[ "$current_state" == "SCANNING" ]]; then
          write_job_state "$job_id" "$src" "scanning" "$progress_pct" - -
        elif [[ "$current_state" == "WORKING" ]]; then
          write_job_state "$job_id" "$src" "encoding" "$progress_pct" "$eta_seconds" "$rate_avg"
        fi
        ;;
    esac
  done
  local -a pipe_status=("${pipestatus[@]}")
  local hb_exit="${pipe_status[1]:-1}"

  if [[ "$hb_exit" != "0" ]]; then
    rm -f -- "$tmp"
    append_status "FAIL_ENCODE	$src	$dest	$src_size	0"
    log_text "FAIL_ENCODE | $(short_name "$src") | HandBrake exited with status $hb_exit"
    if [[ -f "$hb_output_file" ]]; then
      tail -n 20 "$hb_output_file" | while IFS= read -r failure_line; do
        log_text "HB | $failure_line"
      done
    fi
    remove_job_state "$job_id"
    return
  fi

  write_job_state "$job_id" "$src" "verifying" 100 - "$rate_avg"
  if ! verify_conversion "$src" "$tmp"; then
    rm -f -- "$tmp"
    append_status "FAIL_VERIFY	$src	$dest	$src_size	0"
    log_text "FAIL_VERIFY | $(short_name "$src") | verification failed"
    remove_job_state "$job_id"
    return
  fi

  mkdir -p -- "${dest:h}"
  write_job_state "$job_id" "$src" "moving" 100 - "$rate_avg"

  if [[ "$dest" == "$src" ]]; then
    local backup
    backup="$src.hb-backup.$RANDOM.$RANDOM"
    mv -f -- "$src" "$backup"
    if mv -f -- "$tmp" "$dest"; then
      rm -f -- "$backup"
    else
      mv -f -- "$backup" "$src"
      rm -f -- "$tmp"
      append_status "FAIL_REPLACE	$src	$dest	$src_size	0"
      log_text "FAIL_REPLACE | $(short_name "$src") | could not replace source"
      remove_job_state "$job_id"
      return
    fi
  else
    mv -f -- "$tmp" "$dest"
    if (( DELETE_SOURCE == 1 )); then
      rm -f -- "$src"
    fi
  fi

  encoded_size=$(stat -f '%z' -- "$dest" 2>/dev/null || echo 0)
  saved_bytes=$(( src_size - encoded_size ))
  saved_percent=$(awk -v old="$src_size" -v new="$encoded_size" 'BEGIN{ if (old <= 0) { printf "0.0" } else { printf "%.1f", ((old - new) * 100.0 / old) } }')
  append_status "OK	$src	$dest	$src_size	$encoded_size"
  log_text "OK | $(short_name "$src") -> $(short_name "$dest") | before $(human_size "$src_size") | after $(human_size "$encoded_size") | saved $(human_size "$saved_bytes") (${saved_percent}%)"

  remove_job_state "$job_id"
  rm -f -- "$hb_output_file"
}

print_scan_summary() {
  local total="$1"
  echo "Input: $INPUT_DIR"
  echo "Workers: $WORKERS"
  echo "Niceness: $NICE_LEVEL"
  echo "Sleep between launches: ${SLEEP_BETWEEN_JOBS}s"
  echo "Preset: $PRESET"
  echo "Delete source: $DELETE_SOURCE"
  echo "Replace source: $REPLACE_SOURCE"
  echo "Dry run: $DRY_RUN"
  echo "Extensions: $EXTENSIONS"
  echo "ffprobe verification: $HAS_FFPROBE"
  echo "Files found: $total"
  echo "Run log: $RUN_LOG"
  echo "Run status: $STATUS_FILE"
}

FIND_EXPR="$(build_find_expr "${EXT_ARR[@]}")"
if [[ -z "$FIND_EXPR" ]]; then
  echo "Error: no valid extensions after parsing --extensions" >&2
  exit 1
fi

typeset -a FILES
while IFS= read -r -d '' f; do
  FILES+=("$f")
done < <(find "$INPUT_DIR" -type f \( ${(z)FIND_EXPR} \) -print0)

TOTAL=${#FILES[@]}
printf 'status\tsource\tdestination\tsource_bytes\toutput_bytes\n' > "$STATUS_FILE"
log_text "Run started | input=$INPUT_DIR | workers=$WORKERS | nice=$NICE_LEVEL | sleep_between=${SLEEP_BETWEEN_JOBS}s | preset=$PRESET | dry_run=$DRY_RUN | delete_source=$DELETE_SOURCE | replace_source=$REPLACE_SOURCE"
print_scan_summary "$TOTAL"

if (( TOTAL == 0 )); then
  exit 0
fi

typeset -gi started_jobs=0
typeset -gi launched_jobs=0
typeset -gi completed_jobs=0

while (( completed_jobs < TOTAL )); do
  while (( launched_jobs < TOTAL )) && (( $(count_running_jobs) < WORKERS )); do
    launched_jobs=$(( launched_jobs + 1 ))
    convert_one "${FILES[$launched_jobs]}" "$launched_jobs" &
    JOB_PIDS+=("$!")
    if (( SLEEP_BETWEEN_JOBS > 0 )); then
      sleep "$SLEEP_BETWEEN_JOBS"
    fi
  done

  completed_jobs=$(( $(wc -l < "$STATUS_FILE" | tr -d ' ') - 1 ))
  render_dashboard "$completed_jobs" "$TOTAL" "$(count_running_jobs)"

  if (( completed_jobs < TOTAL )); then
    sleep 1
  fi
done

wait || true
finish_dashboard "$completed_jobs" "$TOTAL"

ok_count=$(awk -F '\t' '$1=="OK"{c++} END{print c+0}' "$STATUS_FILE")
dry_count=$(awk -F '\t' '$1=="DRY_RUN"{c++} END{print c+0}' "$STATUS_FILE")
skip_count=$(awk -F '\t' '$1=="SKIP_EXISTS"{c++} END{print c+0}' "$STATUS_FILE")
fail_count=$(awk -F '\t' '$1 ~ /^FAIL_/{c++} END{print c+0}' "$STATUS_FILE")

echo ""
echo "Summary"
echo "  OK: $ok_count"
echo "  Dry run: $dry_count"
echo "  Skipped (exists): $skip_count"
echo "  Failed: $fail_count"
echo "  Run log: $RUN_LOG"
echo "  Run status: $STATUS_FILE"

if (( ok_count > 0 )); then
  awk -F '\t' '
    $1=="OK" {old+=$4; new+=$5}
    END {
      saved=old-new
      pct=(old>0)?(saved*100.0/old):0
      printf "  Size before: %.2f GB\n", old/1024/1024/1024
      printf "  Size after:  %.2f GB\n", new/1024/1024/1024
      printf "  Saved:       %.2f GB (%.1f%%)\n", saved/1024/1024/1024, pct
    }
  ' "$STATUS_FILE"
fi

if (( fail_count > 0 )); then
  echo ""
  echo "Failures"
  awk -F '\t' '$1 ~ /^FAIL_/{printf "  %s: %s\n", $1, $2}' "$STATUS_FILE"
  log_text "Run finished with failures | failed=$fail_count"
  exit 2
fi

log_text "Run finished successfully | ok=$ok_count | skipped=$skip_count | dry_run=$dry_count"