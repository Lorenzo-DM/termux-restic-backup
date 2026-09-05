#!/data/data/com.termux/files/usr/bin/bash
#
# termux-restic-backup — interactive installer.
#
# Run inside Termux:   bash install.sh
#
# Safe to re-run: it never overwrites an existing password, repository or
# customised include/exclude list.
#
set -euo pipefail

CONFIG_DIR="$HOME/.restic"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)/src"
JOB_ID=1001
DEFAULT_PERIOD_MS=86400000     # 24 hours

bold=$'\033[1m'; blue=$'\033[1;34m'; yellow=$'\033[1;33m'
red=$'\033[1;31m'; green=$'\033[1;32m'; off=$'\033[0m'

step() { printf '\n%s==>%s %s%s%s\n' "$blue" "$off" "$bold" "$*" "$off"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '%s  ! %s%s\n' "$yellow" "$*" "$off"; }
ok()   { printf '%s  ✓ %s%s\n' "$green" "$*" "$off"; }
die()  { printf '\n%sERROR:%s %s\n\n' "$red" "$off" "$*" >&2; exit 1; }

ask() {   # ask <prompt> <default> -> echoes the answer
  local prompt="$1" default="${2:-}" reply
  if [ -n "$default" ]; then
    read -rp "    $prompt [$default]: " reply
    printf '%s' "${reply:-$default}"
  else
    read -rp "    $prompt: " reply
    printf '%s' "$reply"
  fi
}

confirm() {   # confirm <prompt> -> 0 for yes
  local reply
  read -rp "    $1 [y/N] " reply
  [[ "$reply" =~ ^[YySs] ]]
}

# ---------------------------------------------------------------------------
step "Checking the environment"

[ -d /data/data/com.termux ] || die "This installer must run inside Termux."
[ -d "$SRC_DIR" ] || die "src/ not found next to install.sh — run it from the repository root."
ok "running inside Termux"

# ---------------------------------------------------------------------------
step "Installing packages"

pkg update -y
pkg install -y restic rclone termux-api
ok "restic $(restic version | awk '{print $2}'), rclone $(rclone version | head -1 | awk '{print $2}')"

# ---------------------------------------------------------------------------
step "Checking the Termux:API app"

if ! timeout 10 termux-battery-status >/dev/null 2>&1; then
  die "Termux:API commands are not responding.

    The termux-api package is only the command-line half. You also need the
    separate Termux:API *app*, installed from the SAME source as Termux —
    F-Droid with F-Droid, GitHub with GitHub. The permission that links them
    is signature-protected, so mixing sources fails silently and every
    termux-* command hangs forever.

    Install it, then run this script again."
fi
ok "Termux:API is responding"

# ---------------------------------------------------------------------------
step "Granting access to shared storage"

if ls "$HOME/storage/shared" >/dev/null 2>&1; then
  ok "shared storage already accessible"
else
  info "Accept the Android permission dialog when it appears."
  termux-setup-storage
  printf '    waiting for the permission'
  waited=0
  while [ "$waited" -lt 60 ]; do
    printf '.'
    sleep 1
    waited=$((waited + 1))
    ls "$HOME/storage/shared" >/dev/null 2>&1 && break
  done
  printf '\n'
  ls "$HOME/storage/shared" >/dev/null 2>&1 \
    || die "Shared storage is still unreachable.
    Grant it by hand under Settings > Apps > Termux > Permissions > Files,
    then run this script again."
  ok "shared storage accessible"
fi

# ---------------------------------------------------------------------------
step "Setting up the cloud remote"

existing_remotes="$(rclone listremotes 2>/dev/null || true)"
need_config=yes

if [ -n "$existing_remotes" ]; then
  info "rclone already knows about these remotes:"
  printf '      %s\n' $existing_remotes
  confirm "Use one of them?" && need_config=no
fi

if [ "$need_config" = yes ]; then
  cat <<'GUIDE'

    rclone's interactive configuration will open next. Quick reference:

      pCloud     storage type: pcloud
                 leave client_id and client_secret empty
                 answer "y" to "Use auto config?" — rclone prints a link,
                 open it in your phone's browser and approve there
                 EU accounts: set hostname to eapi.pcloud.com in the
                 advanced options if listing fails afterwards

      Nextcloud  storage type: webdav
                 url:    https://your.domain/remote.php/dav/files/USERNAME/
                 vendor: nextcloud
                 pass:   an app password, not your account password

    Any of rclone's other backends works too. Pick "q" to quit when done.

GUIDE
  read -rp "    Press ENTER to launch rclone config... "
  rclone config
fi

remote_name="$(ask 'Remote name to use (no trailing colon)')"
[ -n "$remote_name" ] || die "No remote name given."

info "Testing the remote..."
rclone lsd "${remote_name}:" >/dev/null 2>&1 \
  || die "Cannot reach '${remote_name}:'. Fix it with 'rclone config' and re-run."
ok "remote '${remote_name}:' reachable"

remote_path="$(ask 'Path inside that remote' 'Backup/phone')"
rclone mkdir "${remote_name}:${remote_path}"
ok "destination ${remote_name}:${remote_path} ready"

# ---------------------------------------------------------------------------
step "Preparing the configuration directory"

mkdir -p "$CONFIG_DIR/logs"
chmod 700 "$CONFIG_DIR"

install -m 755 "$SRC_DIR/backup.sh" "$CONFIG_DIR/backup.sh"

for f in paths excludes; do
  if [ -f "$CONFIG_DIR/$f.txt" ]; then
    info "keeping your existing $f.txt"
  else
    cp "$SRC_DIR/$f.example.txt" "$CONFIG_DIR/$f.txt"
    info "created $f.txt from the example"
  fi
done
ok "$CONFIG_DIR ready"

# ---------------------------------------------------------------------------
step "Repository password"

if [ -f "$CONFIG_DIR/password" ]; then
  ok "an existing password file was found — leaving it untouched"
else
  cat <<'PWNOTE'

    This password is the ONLY key to your backups. There is no recovery:
    lose it and the data is gone for good, with no support line to call.
    Put it in your password manager now, before you type it.

PWNOTE
  read -rsp "    Password: " p1; echo
  read -rsp "    Confirm : " p2; echo
  [ -n "$p1" ] || die "Empty password."
  [ "$p1" = "$p2" ] || die "The two entries do not match."
  printf '%s' "$p1" > "$CONFIG_DIR/password"
  chmod 600 "$CONFIG_DIR/password"
  unset p1 p2
  ok "password saved to $CONFIG_DIR/password (mode 600)"
fi

# ---------------------------------------------------------------------------
step "Writing the environment file"

if [ -f "$CONFIG_DIR/env" ]; then
  cp "$CONFIG_DIR/env" "$CONFIG_DIR/env.bak"
  info "previous env backed up to env.bak"
fi

cat > "$CONFIG_DIR/env" <<ENV
# Generated by termux-restic-backup's installer. Safe to edit by hand.

export RESTIC_REPOSITORY="rclone:${remote_name}:${remote_path}"

# A path, deliberately — not the password itself. Using RESTIC_PASSWORD would
# expose the secret in the environment of every child process.
export RESTIC_PASSWORD_FILE="\$HOME/.restic/password"

# Keep uploads from saturating the link or draining the battery.
export RCLONE_BWLIMIT="4M"
export RCLONE_TRANSFERS="4"
export RCLONE_TIMEOUT="5m"

# --- Optional knobs, read by backup.sh -------------------------------------
# export KEEP_DAILY=7
# export KEEP_WEEKLY=4
# export KEEP_MONTHLY=12
# export KEEP_YEARLY=3
# 1=Mon .. 7=Sun, 0 to never prune from the phone
# export PRUNE_ON_WEEKDAY=7
# export MIN_INTERVAL_HOURS=0
ENV
chmod 600 "$CONFIG_DIR/env"
ok "env written"

# ---------------------------------------------------------------------------
step "Initialising the restic repository"

# shellcheck source=/dev/null
source "$CONFIG_DIR/env"

if [ -n "$(rclone lsf "${remote_name}:${remote_path}/config" 2>/dev/null)" ]; then
  # Something is already there. Distinguish "existing repo, correct password"
  # from "existing repo, wrong password" — otherwise restic init would fail
  # later with a message that explains nothing.
  if restic cat config >/dev/null 2>&1; then
    ok "existing repository opened successfully"
  else
    die "A restic repository already exists at
    ${remote_name}:${remote_path}
    but the password you entered does not open it.

    Either supply the original password, or pick a different destination
    path. Do NOT re-initialise over it: that would strand the existing
    backups permanently."
  fi
else
  restic init
  ok "repository created at $RESTIC_REPOSITORY"
fi

# ---------------------------------------------------------------------------
step "Scheduling the daily job"

job_flags=(
  --script "$CONFIG_DIR/backup.sh"
  --job-id "$JOB_ID"
  --period-ms "$DEFAULT_PERIOD_MS"
  --persisted true
  --network unmetered
  --battery-not-low true
  --storage-not-low true
)

# Older builds of termux-api lack --charging; only pass it if it exists.
if termux-job-scheduler --help 2>&1 | grep -q -- '--charging'; then
  job_flags+=(--charging true)
  info "constraint: Wi-Fi + charging + battery/storage not low"
else
  warn "this termux-api build has no --charging flag; scheduling without it"
fi

termux-job-scheduler "${job_flags[@]}"
echo
termux-job-scheduler --pending
ok "job $JOB_ID registered, every 24h"

# ---------------------------------------------------------------------------
step "Almost done — two things Android needs from you"

cat <<'MANUAL'

    1. Battery
       Settings > Apps > Termux > Battery > Unrestricted
       Without this, Android drops the app into an ever more restrictive
       standby bucket and defers the job for hours.

    2. Notifications
       Settings > Apps > Termux:API > Notifications > allow
       backup.sh only notifies you when a run FAILS. Without this permission
       that warning never arrives, and a silent failure is worse than none.

MANUAL

step "Next steps"
cat <<NEXT

    Edit what gets backed up:
        nano $CONFIG_DIR/paths.txt
        nano $CONFIG_DIR/excludes.txt

    Preview without uploading anything:
        source $CONFIG_DIR/env
        restic backup --files-from $CONFIG_DIR/paths.txt \\
                      --exclude-file $CONFIG_DIR/excludes.txt --dry-run -v

    Have restic ready in every new session:
        echo '[ -f ~/.restic/env ] && source ~/.restic/env' >> ~/.bashrc

NEXT

if confirm "Run the first backup now? (it can take hours)"; then
  step "First backup"
  info "Keep the phone plugged in and on Wi-Fi. Following the log:"
  echo
  bash "$CONFIG_DIR/backup.sh" &
  backup_pid=$!
  sleep 2
  tail -f "$CONFIG_DIR/logs/backup.log" --pid="$backup_pid" 2>/dev/null || true
  if wait "$backup_pid"; then
    ok "first backup complete"

    # Report what actually landed in the repository. A run that "succeeds"
    # while capturing nothing is the most misleading failure mode there is.
    stats_json="$(restic stats latest --json 2>/dev/null || true)"
    files="$(printf '%s' "$stats_json" | grep -o '"total_file_count":[0-9]*' | cut -d: -f2)"
    bytes="$(printf '%s' "$stats_json" | grep -o '"total_size":[0-9]*' | cut -d: -f2)"
    files="${files:-0}"; bytes="${bytes:-0}"
    info "snapshot contains $files files, $(( bytes / 1024 / 1024 )) MiB"

    if [ "$bytes" -lt 1048576 ]; then
      warn "That is under 1 MiB — almost certainly not what you expected.

    The usual cause is that shared storage was unreadable during the run.
    Check it with:
        ls /storage/emulated/0/DCIM
    If that says 'Permission denied', run termux-setup-storage, accept the
    dialog, and back up again with:
        bash $CONFIG_DIR/backup.sh
    Also look for skipped paths:
        grep WARNING $CONFIG_DIR/logs/backup.log"
    fi
  else
    warn "backup exited non-zero — check $CONFIG_DIR/logs/backup.log"
  fi
else
  info "Start it later with:  bash $CONFIG_DIR/backup.sh"
fi

echo
ok "Installation finished."
