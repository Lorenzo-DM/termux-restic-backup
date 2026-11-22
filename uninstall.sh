#!/data/data/com.termux/files/usr/bin/bash
#
# termux-restic-backup — remove the local installation.
#
# This NEVER touches the remote repository. Your backups stay where they are;
# deleting them is a deliberate act you perform yourself, with rclone.
#
set -euo pipefail

CONFIG_DIR="$HOME/.restic"
JOB_ID=1001

echo "==> Cancelling the scheduled job"
termux-job-scheduler --cancel --job-id "$JOB_ID" 2>/dev/null \
  || echo "    no job $JOB_ID registered"

echo
echo "==> Removing home-screen shortcuts"
rm -f "$HOME/.shortcuts/tasks/backup-now.sh" \
      "$HOME/.shortcuts/backup-now-log.sh"
echo "    removed from ~/.shortcuts (other shortcuts, if any, are left alone)"

echo
echo "==> Local configuration in $CONFIG_DIR"
echo "    This holds your repository password. Without it the remote backups"
echo "    become permanently unreadable — make sure it is in your password"
echo "    manager before you answer yes."
echo
read -rp "    Delete $CONFIG_DIR? [y/N] " reply
if [[ "$reply" =~ ^[Yy]$ ]]; then
  rm -rf "$CONFIG_DIR"
  echo "    deleted"
else
  echo "    kept"
fi

echo
echo "==> Left alone on purpose:"
echo "    - the remote repository (delete with: rclone purge <remote>:<path>)"
echo "    - the rclone remote itself (remove with: rclone config)"
echo "    - the restic and rclone packages (pkg uninstall restic rclone)"
echo
echo "Done."
