# termux-restic-backup

Encrypted, deduplicated, automatic backups from Android to any cloud, with no root.

Built from [restic](https://restic.net) and [rclone](https://rclone.org) running
inside [Termux](https://termux.dev), scheduled by Android's own JobScheduler.
One interactive installer, then it looks after itself.

| | |
|---|---|
| **Encrypted** | restic encrypts on the device (AES-256 + Poly1305). The provider stores opaque blobs — not your filenames, not your directory tree, not your file sizes. |
| **Incremental** | Content-defined chunking with deduplication. After the first run only new chunks are uploaded; moving or renaming a folder uploads nothing at all. |
| **Automatic** | Registered with Android's JobScheduler. Survives closing Termux and rebooting the phone. |
| **Versioned** | Every run is a snapshot. Restore yesterday's copy of a file you ruined today. |
| **Lightweight** | Two Go binaries. No daemon, no JVM, no persistent service. |
| **Free software** | restic BSD-2, rclone MIT, Termux GPLv3, this repository MIT. |
| **Any cloud** | Anything rclone speaks: pCloud, Nextcloud, S3, Backblaze B2, Google Drive, SFTP, and [70+ more](https://rclone.org/overview/). |

## Prerequisites

**Android 7 or newer.** No root required.

**Termux, installed from [F-Droid](https://f-droid.org/packages/com.termux/) or
[GitHub](https://github.com/termux/termux-app/releases).** Not from the Play
Store — that build was abandoned in 2020 and lacks the scheduler.

**The Termux:API app**, from *the same source as Termux*. This trips up almost
everyone: the `termux-api` package installed by this script is only the
command-line half, and the permission linking it to the app is
signature-protected. Mixing an F-Droid Termux with a GitHub Termux:API fails
silently — every `termux-*` command hangs forever instead of erroring. The
installer checks for this and tells you before going any further.

**A cloud account** reachable by rclone, and **~200 MB** free for packages.

## Install

```bash
pkg install -y git
git clone https://github.com/Lorenzo-DM/termux-restic-backup ~/termux-restic-backup
bash ~/termux-restic-backup/install.sh
```

The installer runs start to finish in a single session. It installs the
packages, verifies Termux:API actually answers, requests storage access, walks
you through `rclone config` inline, asks for a repository password, creates the
repository, and registers the daily job. Re-running it is safe: it never
overwrites an existing password, repository, or customised file list.

Two things Android will not let a script do on your behalf, so do them by hand
afterwards — the installer reminds you:

- **Settings → Apps → Termux → Battery → Unrestricted.** Otherwise Android
  files the app under an increasingly restrictive standby bucket and defers the
  job for hours.
- **Settings → Apps → Termux:API → Notifications → allow.** Failures are the
  only thing this tool notifies you about, and a silent failure is worse than
  no backup at all.

## Choosing what to back up

Two files, both in `~/.restic/`:

```bash
nano ~/.restic/paths.txt        # what to include
nano ~/.restic/excludes.txt     # what to carve back out
```

One absolute path per line; directories are recursive; `#` comments a line out.
Changes take effect on the next run — nothing to re-register.

Preview without uploading anything:

```bash
source ~/.restic/env
restic backup --files-from ~/.restic/paths.txt \
              --exclude-file ~/.restic/excludes.txt --dry-run -v
```

Two rules worth internalising:

**Missing paths are skipped, not fatal.** If a listed path does not exist,
`backup.sh` leaves it out, logs a `WARNING` line and notifies you how many were
skipped, rather than failing the whole run — a single stale entry should not
cost you the backup of everything else. If *nothing* in the list exists, that
does fail, loudly. Check what was skipped with:

```bash
grep WARNING ~/.restic/logs/backup.log
```

**Do not nest.** Listing both `Pictures` and `Pictures/Screenshots` costs no
extra space — restic deduplicates — but it puts the same data in two branches
of the snapshot and makes restores confusing.

To decide what is worth it, sort your storage by size:

```bash
du -sh /storage/emulated/0/* 2>/dev/null | sort -h
```

Back up what you cannot re-download. Camera photos, scanned documents, voice
memos and app exports are irreplaceable. Streamed music and downloaded films
are dead weight that costs hours of upload and nothing at restore time.

## What it cannot reach

Without root, Termux cannot read another app's private storage under
`/data/data/`. Only shared storage is visible. For WhatsApp, Signal and
friends, use the app's own export or local-backup feature, point it at a
folder in shared storage, and list that folder in `paths.txt`.

## Restoring

A backup you have never restored is not a backup. Test it once, now, rather
than discovering a problem on the worst day of your year.

From a desktop, browse everything as a filesystem:

```bash
export RESTIC_REPOSITORY="rclone:pcloud:Backup/phone"
export RESTIC_PASSWORD_FILE=~/.config/restic/phone-password
tools/maintenance.sh mount        # then open /tmp/phone-backup
```

Or pull back a specific piece:

```bash
restic snapshots
restic restore latest --target ~/restored --include /storage/emulated/0/Documents
```

On the phone itself, `restic restore` works the same way once you have run
`source ~/.restic/env`.

## Maintenance

`forget` runs after every backup and is cheap. `prune` — which physically
rewrites data packs on the remote — runs weekly by default, on Sundays. Over a
slow uplink you may prefer to disable it on the phone and do it from a desktop:

```bash
echo 'export PRUNE_ON_WEEKDAY=0' >> ~/.restic/env
```

Then, from a machine with a real connection:

```bash
tools/maintenance.sh snapshots   # list every backup
tools/maintenance.sh stats       # real space used after deduplication
tools/maintenance.sh check       # verify integrity against a 5% sample
tools/maintenance.sh prune       # apply retention, reclaim space
tools/maintenance.sh restore latest ~/restored
```

Retention defaults to 7 daily, 4 weekly, 12 monthly and 3 yearly snapshots.
Override any of them in `~/.restic/env`.

## How the scheduling works

`termux-job-scheduler` hands the job to Android's JobScheduler, which owns it
from then on. That has consequences worth knowing:

- **Closing Termux is fine** — expected, even. The OS wakes the app when the
  job is due; nothing needs to stay open.
- **Swiping Termux out of Recents** is usually harmless on stock Android, though
  some manufacturers treat it as a force-stop.
- **Force-stopping Termux cancels every scheduled job.** Android puts the app
  into the "stopped" state and the jobs do not come back until you launch
  Termux by hand. Never force-stop it.
- **Rebooting is covered** by `--persisted true`, though jobs are only restored
  after the first unlock, since the configuration lives in credential-encrypted
  storage.
- **The 24-hour period is a floor, not an appointment.** Android batches jobs to
  save power, and the constraints must be satisfied. Skip a night of charging
  and the run waits for the next one rather than being lost.

The default constraints are Wi-Fi, charging, battery not low, storage not low.
Because the job only runs while plugged in, battery cost is effectively zero,
and Android's Battery Saver — which switches itself off while charging — never
gets in the way.

Verify it actually fires before trusting it. Shorten the period to Android's
15-minute minimum, leave the phone charging on Wi-Fi with Termux closed, and
come back:

```bash
termux-job-scheduler --script ~/.restic/backup.sh --job-id 1001 \
  --period-ms 900000 --persisted true --network unmetered \
  --charging true --battery-not-low true --storage-not-low true

# twenty minutes later
tail -20 ~/.restic/logs/backup.log
```

A log line from a moment you were not touching the phone is the proof. Then
re-run the installer, or the same command with `--period-ms 86400000`, to
restore the daily cadence.

## Security model

**What this protects against:** the cloud provider reading your files, a breach
at the provider, or anyone intercepting the uploads. Encryption happens on the
device; nothing legible ever leaves it.

**What it does not protect against:** someone with your unlocked phone. The
repository password is stored in plain text at `~/.restic/password`, mode 600,
inside Termux's per-UID sandbox. It has to be: an unattended job running at 4am
needs the key without you there to type it. This is inherent to every automated
backup — anything a background process can read unattended, an attacker with
that same level of access can read too. It is also not much of a loss: whoever
holds your unlocked phone already has the original photos and does not need the
backup.

The password file is deliberately excluded from the backup itself. Storing the
key inside the thing it unlocks buys nothing.

`RESTIC_PASSWORD_FILE` holds a *path*, never the password. Using
`RESTIC_PASSWORD` instead would place the secret in the environment of every
child process, readable through `/proc/<pid>/environ`.

**Losing the password means losing the data.** There is no recovery mechanism
and no one to appeal to. Put it in a password manager before you finish
installing.

## Troubleshooting

**Every `termux-*` command hangs.** The Termux:API app is missing, or was
installed from a different source than Termux. Confirm with
`timeout 10 termux-battery-status` — a 124 exit status means the timeout hit.

**The job never runs.** Check `termux-job-scheduler --pending` lists job 1001.
If it does not, Termux was force-stopped: open it once and re-run the
installer. If it does, the constraints are probably unmet — the phone has to be
charging and on Wi-Fi — or battery optimisation is still throttling the app.
Samsung users should also clear Termux from *Device care → Battery →
Background usage limits*; Xiaomi users need autostart enabled and battery
saver set to "No restrictions".

**"backup failed" on every run.** Almost always a path in `paths.txt` that does
not exist. Find it with the `--dry-run` command above.

**pCloud listing fails after authorising.** European accounts live on a
different endpoint: `rclone config` → edit the remote → advanced options →
set `hostname` to `eapi.pcloud.com`.

## Uninstalling

```bash
bash ~/termux-restic-backup/uninstall.sh
```

Cancels the job and optionally removes the local configuration. It never
touches the remote repository — deleting your backups stays a deliberate act
you perform yourself with `rclone purge`.

## License

MIT. See [LICENSE](LICENSE).
