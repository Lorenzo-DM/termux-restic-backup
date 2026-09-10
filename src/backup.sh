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
PRUNE_STAMP_FILE="$CONFIG_DIR/last-prune"
PATHS_FILE="$CONFIG_DIR/paths.txt"
EXCLUDES_FILE="$CONFIG_DIR/excludes.txt"

# --- Retention: how many snapshots to keep --------------------------------
# Override any of these by exporting them from ~/.restic/env
KEEP_DAILY="${KEEP_DAILY:-7}"
KEEP_WEEKLY="${KEEP_WEEKLY:-4}"
KEEP_MONTHLY="${KEEP_MONTHLY:-12}"
KEEP_YEARLY="${KEEP_YEARLY:-3}"

# Pruning rewrites data packs on the remote: slow and bandwidth-hungry, so it
# runs on its own clock rather than on every backup. Days to wait after a
# successful prune before the next one. 0 never prunes from the phone — run
# `tools/maintenance.sh prune` from a desktop instead.
PRUNE_EVERY_DAYS="${PRUNE_EVERY_DAYS:-7}"

# PRUNE_ON_WEEKDAY pinned pruning to a fixed weekday, which silently never
# fired for anyone whose job ran less often than daily. Honour the one value
# that was unambiguous — 0, "never from the phone" — rather than quietly
# turning pruning back on for someone who had deliberately switched it off.
obsolete_prune_setting=""
if [ -n "${PRUNE_ON_WEEKDAY:-}" ]; then
  if [ "$PRUNE_ON_WEEKDAY" = 0 ]; then
    PRUNE_EVERY_DAYS=0
    obsolete_prune_setting="PRUNE_ON_WEEKDAY=0 is obsolete; it still disables pruning, but set PRUNE_EVERY_DAYS=0 instead"
  else
    obsolete_prune_setting="PRUNE_ON_WEEKDAY is obsolete and ignored; pruning now runs every ${PRUNE_EVERY_DAYS} day(s) — see PRUNE_EVERY_DAYS"
  fi
fi

# Skip the run if the last successful backup is younger than this many hours.
# 0 disables the check. Useful if you register more than one trigger.
MIN_INTERVAL_HOURS="${MIN_INTERVAL_HOURS:-0}"

MAX_LOG_BYTES="${MAX_LOG_BYTES:-2000000}"

# Dead-man's switch: the push URL of an Uptime Kuma "Push" monitor, or any
# endpoint that expects a periodic GET. Empty disables the ping. This is the
# only check that catches the one failure nothing else can see — JobScheduler
# never firing at all, which leaves a perfectly healthy repository quietly
# going stale.
HEALTHCHECK_URL="${HEALTHCHECK_URL:-}"

mkdir -p "$LOG_DIR"

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE"; }

notify() {
  command -v termux-notification >/dev/null 2>&1 || return 0
  termux-notification --id restic-backup --title "$1" --content "$2" >/dev/null 2>&1
}

ping_monitor() {   # ping_monitor <up|down> <message> [duration_seconds]
  [ -n "$HEALTHCHECK_URL" ] || return 0
  if ! command -v curl >/dev/null 2>&1; then
    log "WARNING: HEALTHCHECK_URL is set but curl is missing (pkg install curl)"
    return 0
  fi
  local dur="${3:-}"
  local args=(--get --data-urlencode "status=$1" --data-urlencode "msg=$2")
  # Uptime Kuma plots this as the response time, which turns its chart into a
  # history of how long the backup takes.
  [ -n "$dur" ] && args+=(--data-urlencode "ping=$(( dur * 1000 ))")
  # An unreachable monitor — no Wi-Fi, homelab down, phone on a foreign
  # network — is not a backup failure, so this never changes the exit status.
  curl -fsS -m 15 --retry 2 "${args[@]}" "$HEALTHCHECK_URL" >/dev/null 2>&1 \
    || log "WARNING: could not reach HEALTHCHECK_URL"
}

[ -n "$obsolete_prune_setting" ] && log "WARNING: $obsolete_prune_setting"

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
effective_paths=""
# Invoked by the EXIT trap below, which shellcheck does not follow (SC2317
# before 0.10, SC2329 after).
# shellcheck disable=SC2317,SC2329
cleanup() {
  command -v termux-wake-unlock >/dev/null 2>&1 && termux-wake-unlock
  [ -n "$effective_paths" ] && rm -f "$effective_paths"
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

# --- Pre-flight: drop paths that no longer exist --------------------------
# A path listed in paths.txt but missing on disk makes restic exit non-zero,
# which fails the WHOLE run — valid directories included — and fires a
# "backup failed" notification every single time. Backing up what is there
# and reporting what is not is far more useful than failing wholesale.
# It lives under logs/, which excludes.txt keeps out of the repository.
effective_paths="$(mktemp "$LOG_DIR/paths.XXXXXX")"
kept=0
missing=0
while IFS= read -r entry; do
  if [ -e "$entry" ]; then
    printf '%s\n' "$entry" >> "$effective_paths"
    kept=$((kept + 1))
  else
    log "WARNING: skipping missing path: $entry"
    missing=$((missing + 1))
  fi
done < <(grep -vE '^[[:space:]]*(#|$)' "$PATHS_FILE")

if [ "$kept" -eq 0 ]; then
  log "ERROR: none of the paths in $PATHS_FILE exist — nothing to back up"
  notify "Backup failed" "No usable paths in paths.txt — check the log"
  ping_monitor down "no usable paths in paths.txt"
  exit 1
fi
if [ "$missing" -gt 0 ]; then
  notify "Backup: $missing path(s) missing" "Backed up $kept of $((kept + missing)) — see the log"
fi

# --- Clear stale locks ------------------------------------------------------
# JobScheduler kills the job the moment its constraints stop being met — cable
# pulled, Wi-Fi dropped — which can leave a lock behind in the repository.
# restic normally recognises a lock of its own whose process is gone, but
# --retry-lock would sit out its full timeout first waiting for something that
# will never be released. Plain `unlock` removes only stale locks; never
# --remove-all, which would also tear the lock away from maintenance running
# on another machine.
restic unlock >> "$LOG_FILE" 2>&1 || log "WARNING: restic unlock failed"

started_at=$(date +%s)
log "=== backup started -> $RESTIC_REPOSITORY ($kept paths)"

# --- Back up ---------------------------------------------------------------
restic backup \
  --files-from "$effective_paths" \
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
  ping_monitor down "restic backup exited with $status"
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

# Elapsed days, not a weekday: a fixed weekday only ever comes round for a job
# that runs daily, and Android is free to shift any run by hours anyway.
prune_stamp=0
if [ -f "$PRUNE_STAMP_FILE" ]; then
  prune_stamp="$(cat "$PRUNE_STAMP_FILE" 2>/dev/null)"
  # An empty or corrupted stamp counts as no stamp: a prune that can never be
  # scheduled again is precisely the failure this replaced.
  case "${prune_stamp:-x}" in *[!0-9]*) prune_stamp=0 ;; esac
fi

prune_now=no
if [ "$PRUNE_EVERY_DAYS" -gt 0 ]; then
  if [ "$prune_stamp" -eq 0 ]; then
    # First run: the initial upload is the heaviest there will ever be and has
    # nothing to prune yet. Start the clock instead.
    date +%s > "$PRUNE_STAMP_FILE"
    log "prune clock started; first prune in $PRUNE_EVERY_DAYS day(s)"
  else
    prune_age_days=$(( ( $(date +%s) - prune_stamp ) / 86400 ))
    if [ "$prune_age_days" -ge "$PRUNE_EVERY_DAYS" ]; then
      prune_now=yes
      log "prune due: $prune_age_days day(s) since the last one"
      forget_args+=(--prune)
    fi
  fi
fi

restic "${forget_args[@]}" >> "$LOG_FILE" 2>&1
forget_status=$?
maintenance_error=""
if [ $forget_status -ne 0 ]; then
  maintenance_error="forget/prune exited with $forget_status"
  log "ERROR: $maintenance_error"
elif [ "$prune_now" = yes ]; then
  # Only a prune that actually finished resets the clock. A failed one is
  # retried on the next run rather than deferred by another full interval.
  date +%s > "$PRUNE_STAMP_FILE"
fi

date +%s > "$STAMP_FILE"

elapsed=$(( $(date +%s) - started_at ))
log "=== backup finished in ${elapsed}s"

# The data is stored either way, so this is not a failed backup — but it must
# not report green either. Retention quietly ceasing to apply is exactly how a
# repository grows without bound while every dashboard stays reassuring.
if [ -n "$maintenance_error" ]; then
  notify "Backup ok, maintenance failed" "$maintenance_error — see ~/.restic/logs/backup.log"
  ping_monitor down "backup ok ($kept paths, ${elapsed}s) but $maintenance_error"
else
  ping_monitor up "$kept paths, $missing missing, ${elapsed}s" "$elapsed"
fi

# --- Rotate the log --------------------------------------------------------
if [ "$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)" -gt "$MAX_LOG_BYTES" ]; then
  mv "$LOG_FILE" "$LOG_FILE.1"
fi

exit 0
