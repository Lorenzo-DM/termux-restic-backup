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
| **Any cloud** | Anything rclone speaks: S3, Backblaze B2, Google Drive, Dropbox, OneDrive, Nextcloud, SFTP, and [70+ more](https://rclone.org/overview/). |

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
repository, asks how often it should run, and registers the job. Re-running it
is safe: it never overwrites an existing password, repository, or customised
file list — the cadence you chose included.

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

## Running a backup by hand

The schedule will get there, but sometimes you want it now — right before
leaving on a trip, say. From a terminal:

```bash
bash ~/.restic/backup.sh
```

Or from the home screen, without opening Termux at all. The installer drops
two shortcuts into the directories Termux:Widget serves its entries from:

- `~/.shortcuts/tasks/backup-now.sh` — starts a backup in the background. A
  toast confirms it started; a failure reports itself with a notification.
  Success and skip stay silent, like every other run.
- `~/.shortcuts/backup-now-log.sh` — opens a Termux session that follows the
  live log until the run ends, SKIP lines included. The surest way to watch
  what a manual run actually did.

Long-press the launcher, add the *Termux:Widget* widget and pick either entry.
The widget app itself comes from the same source as Termux — F-Droid with
F-Droid, GitHub with GitHub — for the same signature reasons as Termux:API.
The shortcut files are harmless if you never install it.

Manual runs are first-class citizens: they take the same lock, so a tap while
a scheduled backup is running cannot start a second one, and the run counts
for retention and the prune clock like any other. If you set
`MIN_INTERVAL_HOURS` above zero, it gates manual runs too — a tap inside the
window is skipped, not silently dropped without a trace: the log says so.

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
export RESTIC_REPOSITORY="rclone:remote:Backup/phone"   # your rclone remote name
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

`forget` runs after every backup and is cheap: it only rewrites snapshot
metadata. `prune` — which physically rewrites data packs on the remote — is the
expensive one, so it keeps a clock of its own: it runs when `PRUNE_EVERY_DAYS`
have passed since the last prune that finished, whatever the backup cadence
happens to be. The installer sets it to 7 for a daily job and stretches it for
anything slower. A prune that fails does not reset the clock, so the next run
retries it instead of deferring it by another full interval.

Over a slow uplink you may prefer to keep it off the phone entirely and do the
heavy work elsewhere:

```bash
echo 'export PRUNE_EVERY_DAYS=0' >> ~/.restic/env
```

If you turn it off, make sure whatever you hand it to is itself monitored.

That "elsewhere" can be a desktop with `tools/maintenance.sh`, or a server-side
orchestrator. [backrest](https://github.com/garethgeorge/backrest) can adopt
this repository as a maintenance-only repo — no plan, just prune and check on a
schedule — which is how the author runs it. Two cautions if you do: keep
retention on the phone, because backrest applies its own with `--tag plan:<id>`
and these snapshots carry no such tag; and pick a fixed maintenance window away
from the phone's nightly run, since both hold the same repository lock.

Then, from a machine with a real connection:

```bash
tools/maintenance.sh snapshots   # list every backup
tools/maintenance.sh stats       # real space used after deduplication
tools/maintenance.sh check       # verify integrity against a 5% sample
tools/maintenance.sh prune       # apply retention, reclaim space
tools/maintenance.sh restore latest ~/restored
```

Retention defaults to 7 daily, 4 weekly, 12 monthly and 3 yearly snapshots.
Override any of them in `~/.restic/env`. Note that restic counts days that have
a snapshot, not calendar days: on a weekly job `--keep-daily 7` keeps the last
seven weekly snapshots and `--keep-weekly` adds nothing on top. If you back up
less often than daily, move the weight to `KEEP_WEEKLY` and `KEEP_MONTHLY`.

## Monitoring

The failure that matters is not a backup that breaks — that one notifies you.
It is a job that quietly stops firing, because Android decided Termux was not
worth waking. The repository stays perfectly healthy; it just stops growing,
and nothing tells you.

Point `HEALTHCHECK_URL` at an Uptime Kuma **Push** monitor (or any endpoint
that expects a periodic GET) and the phone reports every run:

```bash
echo 'export HEALTHCHECK_URL="https://kuma.example.org/api/push/XXXXXXXX"' \
  >> ~/.restic/env
```

Set the monitor's heartbeat interval comfortably above your backup period — 26
hours for a daily job, nine days for a weekly one — so one late run does not
page you. A successful run pushes `status=up` along with how long it took,
which Uptime Kuma plots as the response time; a failed one pushes `status=down`
with the reason, so you hear about it immediately instead of waiting for the
interval to lapse. Skipped runs stay silent by design: the lock and the
`MIN_INTERVAL_HOURS` guard mean a backup already succeeded recently.

There is a third state worth knowing about. If the backup succeeds but `forget`
or `prune` afterwards does not, the push is `down` with a message that says so
explicitly — the files are safely stored, but retention has stopped being
applied. That is not a failed backup and needs a different response, yet it
cannot be allowed to report green: a repository whose retention quietly stopped
working grows without bound while every dashboard stays reassuring.

Leave it unset and nothing is pinged. The ping never affects the backup's exit
status — an unreachable monitor is not a backup failure.

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
- **The period is a floor, not an appointment.** Android batches jobs to
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

A log line from a moment you were not touching the phone is the proof. Then put
your real cadence back with the command below.

## Changing the schedule

The installer asks how often to run and records the answer in `~/.restic/env`
as `BACKUP_PERIOD_HOURS`, so re-running it keeps your choice instead of
resetting you to daily. To change the cadence without re-running it, register
the job again with the same `--job-id` — that replaces the existing job rather
than adding a second one:

```bash
# weekly
termux-job-scheduler --script ~/.restic/backup.sh --job-id 1001 \
  --period-ms 604800000 --persisted true --network unmetered \
  --charging true --battery-not-low true --storage-not-low true

sed -i 's/^export BACKUP_PERIOD_HOURS=.*/export BACKUP_PERIOD_HOURS=168/' \
  ~/.restic/env
```

`--period-ms` is milliseconds: 86400000 is a day, 604800000 a week. Pass every
flag each time — anything you leave out is not carried over from the previous
registration, and dropping `--charging true` is how you end up backing up on
battery.

That `sed` line changes nothing on its own: the cadence lives in Android's
JobScheduler, and `BACKUP_PERIOD_HOURS` only records it, for the next installer
run and for your own reference. Two settings do want revisiting when the
cadence changes, and neither adjusts itself: `PRUNE_EVERY_DAYS` and, if you use
one, the heartbeat interval of your monitor.

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

**"repository is already locked".** A previous run was killed mid-flight, most
likely because the charger came out. `backup.sh` clears stale locks on every
run, so this resolves itself; if it persists, something really is holding the
lock — check that no maintenance is running elsewhere before reaching for
`restic unlock --remove-all`.

**Listing the remote fails right after authorising.** Several providers put
accounts on region-specific endpoints, and rclone defaults to the wrong one.
Check your backend's page under
[rclone.org/overview](https://rclone.org/overview/) for a `hostname`, `region`
or `endpoint` setting, then `rclone config` → edit the remote → advanced
options.

## Uninstalling

```bash
bash ~/termux-restic-backup/uninstall.sh
```

Cancels the job and optionally removes the local configuration. It never
touches the remote repository — deleting your backups stays a deliberate act
you perform yourself with `rclone purge`.

## License

MIT. See [LICENSE](LICENSE).
