#!/data/data/com.termux/files/usr/bin/bash
#
# termux-restic-backup — the scheduled backup job.
#
# Launched by Android's JobScheduler through termux-job-scheduler.
# All configuration lives in ~/.restic/env, which this script sources itself,
# so it does not depend on any interactive shell state.
#
set -uo pipefail

CONFIG_DIR="$HOME/.restic"
# shellcheck source=/dev/null
source "$CONFIG_DIR/env"

LOG_DIR="$CONFIG_DIR/logs"
LOG_FILE="$LOG_DIR/backup.log"
LOCK_FILE="$CONFIG_DIR/backup.lock"
STAMP_FILE="$CONFIG_DIR/last-success"
PATHS_FILE="$CONFIG_DIR/paths.txt"
EXCLUDES_FILE="$CONFIG_DIR/excludes.txt"

# --- Retention: how many snapshots to keep --------------------------------
# Override any of these by exporting them from ~/.restic/env
KEEP_DAILY="${KEEP_DAILY:-7}"
KEEP_WEEKLY="${KEEP_WEEKLY:-4}"
KEEP_MONTHLY="${KEEP_MONTHLY:-12}"
KEEP_YEARLY="${KEEP_YEARLY:-3}"

# Pruning rewrites data packs on the remote: slow and bandwidth-hungry.
# 1=Mon ... 7=Sun. Set to 0 to never prune from the phone and run
# `tools/maintenance.sh prune` from a desktop instead.
PRUNE_ON_WEEKDAY="${PRUNE_ON_WEEKDAY:-7}"

# Skip the run if the last successful backup is younger than this many hours.
# 0 disables the check. Useful if you register more than one trigger.
MIN_INTERVAL_HOURS="${MIN_INTERVAL_HOURS:-0}"

MAX_LOG_BYTES="${MAX_LOG_BYTES:-2000000}"

mkdir -p "$LOG_DIR"

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE"; }

notify() {
  command -v termux-notification >/dev/null 2>&1 || return 0
  termux-notification --id restic-backup --title "$1" --content "$2" >/dev/null 2>&1
}

# --- Refuse to run twice at once ------------------------------------------
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log "SKIP: another backup is already running"
  exit 0
fi

# --- Skip runs that are too close together --------------------------------
if [ "$MIN_INTERVAL_HOURS" -gt 0 ] && [ -f "$STAMP_FILE" ]; then
  age=$(( $(date +%s) - $(cat "$STAMP_FILE") ))
  if [ "$age" -lt $(( MIN_INTERVAL_HOURS * 3600 )) ]; then
    log "SKIP: last success was ${age}s ago (< ${MIN_INTERVAL_HOURS}h)"
    exit 0
  fi
fi

# --- Keep the CPU awake for the whole run ---------------------------------
command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock
cleanup() {
  command -v termux-wake-unlock >/dev/null 2>&1 && termux-wake-unlock
}
trap cleanup EXIT

# Cap restic's memory appetite; Android kills greedy background processes.
export GOGC="${GOGC:-20}"

# Only pass flags this restic build actually knows about, so the script keeps
# working on older versions instead of dying on an unknown option.
backup_flags=()
forget_flags=()
if restic backup --help 2>&1 | grep -q -- '--no-scan'; then
  backup_flags+=(--no-scan)
fi
if restic backup --help 2>&1 | grep -q -- '--retry-lock'; then
  backup_flags+=(--retry-lock 10m)
  forget_flags+=(--retry-lock 10m)
fi

started_at=$(date +%s)
log "=== backup started -> $RESTIC_REPOSITORY"

# --- Back up ---------------------------------------------------------------
restic backup \
  --files-from "$PATHS_FILE" \
  --exclude-file "$EXCLUDES_FILE" \
  --exclude-caches \
  --tag android \
  --tag "$(getprop ro.product.model 2>/dev/null || echo phone)" \
  "${backup_flags[@]}" \
  >> "$LOG_FILE" 2>&1
status=$?

if [ $status -ne 0 ]; then
  log "ERROR: restic backup exited with status $status"
  notify "Backup failed" "restic exited with $status — see ~/.restic/logs/backup.log"
  exit $status
fi

# --- Apply retention -------------------------------------------------------
# `forget` on its own is cheap: it only rewrites snapshot metadata.
forget_args=(forget
  --keep-daily   "$KEEP_DAILY"
  --keep-weekly  "$KEEP_WEEKLY"
  --keep-monthly "$KEEP_MONTHLY"
  --keep-yearly  "$KEEP_YEARLY"
  "${forget_flags[@]}")

if [ "$PRUNE_ON_WEEKDAY" -ne 0 ] && [ "$(date +%u)" -eq "$PRUNE_ON_WEEKDAY" ]; then
  log "weekly prune enabled for this run"
  forget_args+=(--prune)
fi

restic "${forget_args[@]}" >> "$LOG_FILE" 2>&1 \
  || log "WARNING: forget/prune failed with status $?"

date +%s > "$STAMP_FILE"

log "=== backup finished in $(( $(date +%s) - started_at ))s"

# --- Rotate the log --------------------------------------------------------
if [ "$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)" -gt "$MAX_LOG_BYTES" ]; then
  mv "$LOG_FILE" "$LOG_FILE.1"
fi

exit 0
