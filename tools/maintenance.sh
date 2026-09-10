#!/usr/bin/env bash
#
# termux-restic-backup — maintenance from a desktop.
#
# Pruning and integrity checks are far faster over a real connection than over
# a phone's radio, so keep the heavy work here.
#
# Requires restic and rclone on this machine, with the same rclone remote
# configured and the same repository password.
#
#   export RESTIC_REPOSITORY="rclone:remote:Backup/phone"
#   export RESTIC_PASSWORD_FILE="$HOME/.config/restic/phone-password"
#
set -euo pipefail

: "${RESTIC_REPOSITORY:?set RESTIC_REPOSITORY, e.g. rclone:remote:Backup/phone}"
: "${RESTIC_PASSWORD_FILE:?set RESTIC_PASSWORD_FILE to a file holding the password}"
export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE

case "${1:-help}" in
  snapshots) restic snapshots ;;
  stats)     restic stats --mode raw-data ;;
  check)     restic check --read-data-subset=5% ;;
  prune)     restic forget --keep-daily 7 --keep-weekly 4 \
                           --keep-monthly 12 --keep-yearly 3 --prune ;;
  mount)     mkdir -p /tmp/phone-backup
             echo "Browse it at /tmp/phone-backup — Ctrl-C to unmount."
             restic mount /tmp/phone-backup ;;
  restore)   restic restore "${2:?usage: restore <snapshot-id|latest> <target>}" \
                            --target "${3:?usage: restore <snapshot-id|latest> <target>}" ;;
  diff)      restic diff "${2:?usage: diff <snap1> <snap2>}" "${3:?usage: diff <snap1> <snap2>}" ;;
  *) cat <<HELP
Usage: $0 <command>

  snapshots              list every backup
  stats                  real space used after deduplication
  check                  verify integrity (reads a 5% sample of the data)
  prune                  apply retention and reclaim space on the remote
  mount                  browse the backups as a filesystem
  restore <id> <target>  restore a snapshot ("latest" works as an id)
  diff <id1> <id2>       what changed between two snapshots
HELP
  ;;
esac
