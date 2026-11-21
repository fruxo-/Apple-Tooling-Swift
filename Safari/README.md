# safari-tabs-backup

A small, dependency-free macOS command-line tool (Swift) that backs up Safari's tab groups database (`SafariTabs.db`). It:

1. **Snapshots** Safari's tabs database consistently, using SQLite's online backup API.
2. **Detects changes** by comparing the snapshot's content (excluding volatile SQLite header counters) with the last successful snapshot.
3. **Syncs** changed snapshots incrementally to a backup folder with `rsync`. By default that folder is in iCloud Drive.

Defaults match the original script's locations under `~/Library`.

Everything runs locally. The tool never modifies Safari's data and never touches the network itself; if the backup folder is in iCloud Drive, macOS syncs it.

---

## Contents

- [Requirements](#requirements)
- [Build and install](#build-and-install)
- [Where the database lives](#where-the-database-lives)
- [Quick start](#quick-start)
- [Command-line reference](#command-line-reference)
- [How a run works](#how-a-run-works)
- [Time zones](#time-zones)
- [Privacy and safety](#privacy-and-safety)
- [Troubleshooting](#troubleshooting)
- [Project layout and internals](#project-layout-and-internals)
- [Known limitations](#known-limitations)

---

## Requirements

| Item | Requirement |
| --- | --- |
| OS | macOS 13 (Ventura) or later |
| Toolchain | Swift 5.9+ (Xcode or the Command Line Tools) |
| Libraries | System `sqlite3` and the built-in `CryptoKit` framework. No third-party packages. |
| Tools | `rsync` at `/usr/bin/rsync` (included with macOS) |
| Permissions | **Full Disk Access** for the terminal or process running the tool (see [Where the database lives](#where-the-database-lives)) |

## Build and install

```sh
cd Safari
swift build -c release
.build/release/safari-tabs-backup --help
.build/release/safari-tabs-backup
```

To use it from anywhere, copy the binary to a directory on your `PATH`:

```sh
cp .build/release/safari-tabs-backup ~/.local/bin/
```

Unchanged snapshots are skipped, so the tool is cheap to run repeatedly from a scheduler such as `launchd`.

## Where the database lives

If you don't pass any paths, the tool uses these defaults (`~` is expanded):

| What | Option | Default |
| --- | --- | --- |
| Source database | `--database` | `~/Library/Containers/com.apple.Safari/Data/Library/Safari/SafariTabs.db` |
| Synchronized backup | `--backup-dir` | `~/Library/Mobile Documents/com~apple~CloudDocs/SafariTabGroupsBackups` |
| Local snapshot and content hash | `--snapshot-dir` | `~/Library/Caches/safaritabsbackup` |
| Logs | `--log-dir` | `~/Library/Logs` |

**macOS privacy protection:** Safari's container is protected. If the tool reports that the database was not found (or `Operation not permitted`), grant your terminal app **Full Disk Access** (System Settings > Privacy & Security > Full Disk Access), then restart the terminal.

## Quick start

```sh
# Back up with the default locations
safari-tabs-backup

# Choose where the backup, local snapshot and logs go
safari-tabs-backup --backup-dir ~/Backups/SafariTabs --snapshot-dir ~/.cache/safari-tabs --log-dir ~/Logs

# Back up a different database file
safari-tabs-backup --database /path/to/SafariTabs.db

# See what happened
tail ~/Library/Logs/safaritabsbackup.log
```

## Command-line reference

```
safari-tabs-backup [--database PATH] [--backup-dir DIR] [--snapshot-dir DIR] [--log-dir DIR]
```

| Option | Description |
| --- | --- |
| `--database PATH` | Source database. Default: see [above](#where-the-database-lives). |
| `--backup-dir DIR` | Synchronized snapshot destination. Created if needed. |
| `--snapshot-dir DIR` | Local snapshot and content hash directory. Created if needed. |
| `--log-dir DIR` | Directory for `safaritabsbackup.log` and `safaritabsbackup.err`. Created if needed. |
| `-h`, `--help` | Show usage. |

Notes:

- Each option takes exactly one value; `~` in paths is expanded.
- Log messages go to `safaritabsbackup.log` (and stdout). Errors go to `safaritabsbackup.err` (and stderr) as `ERROR: ...`, and the exit status is `1`.
- Each log file is trimmed when it grows past 1000 lines: the last 500 lines are kept.

## How a run works

1. **Prepare.** Paths are expanded, the log directory is created and old log lines are trimmed. The source database must exist.
2. **Snapshot** (`Backing up...`). The source is opened read-only and copied with SQLite's online backup API to `<snapshot-dir>/SafariTabs.db`. If the database is busy or locked, the copy retries every 0.1 seconds.
3. **Hash** (`Hashing...`). A SHA-256 hash is computed over the snapshot **without its first 100 bytes** (the SQLite file header, which holds counters that change even when no tab changed). It is compared with `<snapshot-dir>/content.sha`, the hash of the last successful sync.
4. **Skip if unchanged.** If the hashes match, the run logs `No changes since last backup` and stops.
5. **Sync** (`Syncing...`). Otherwise `rsync --stats -c -i --no-whole-file --inplace` copies the snapshot into the backup directory (checksum comparison, updating the destination file in place). Every `rsync` output line is logged with an `rsync:` prefix.
6. **Record.** Only after `rsync` succeeds is the new hash written to `content.sha` and `Backup updated` logged. A failed sync is therefore retried on the next run.

## Time zones

Log lines are timestamped in your **local time zone** (`yyyy-MM-dd HH:mm:ss`). Nothing else in the tool depends on the time zone.

## Privacy and safety

- **Read-only source.** The source database is opened read-only and copied with SQLite's backup API, so Safari's live file is never modified.
- **Local only.** The tool itself uses no network access. If `--backup-dir` is in iCloud Drive, macOS syncs the backup.
- **Sensitive output.** The snapshot and the backup contain your tab groups (titles and URLs of your tabs). Store and share them accordingly.

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `ERROR: … not found (missing Full Disk Access?)` | The database path is wrong, or your terminal lacks **Full Disk Access**. Check `--database` and grant access (see [Where the database lives](#where-the-database-lives)). |
| `ERROR: could not launch rsync` / `rsync failed (exit code N)` | `/usr/bin/rsync` is missing or the backup directory isn't writable. The `rsync:` lines in the log show the details. |
| `ERROR: missing value for --x` / `unexpected argument: …` | An option was given without a value, or an unknown argument was used. Run `--help`. |
| `ERROR: unable to create log …` / `unable to write log …` | `--log-dir` isn't writable. Pick another directory. |
| `No changes since last backup` | Normal: nothing in the tabs database changed since the last successful sync. |
| You want to force a full re-sync | Delete `content.sha` in the snapshot directory and run again. |

## Project layout and internals

```
Safari/
├── Package.swift                     Swift package manifest (macOS 13+)
├── README.md                         this file
└── Sources/
    ├── CSQLite/                      system-library target exposing sqlite3 to Swift
    │   ├── module.modulemap
    │   └── shim.h
    └── SafariTabsBackup/
        └── main.swift                the whole CLI
```

`main.swift` is organised in these parts:

| Part | Purpose |
| --- | --- |
| `Options`, `parseArguments`, `usage` | Command-line parsing. |
| `Logger` | `safaritabsbackup.log` / `.err` writing and trimming. |
| `createSnapshot` | Consistent copy of the source database via the SQLite backup API. |
| `contentHash` | SHA-256 of the snapshot without its first 100 bytes. |
| `runRsync` | Incremental sync of the snapshot to the backup directory. |
| `SafariTabsBackup.main` | Entry point that wires the steps together. |

### Files used

| File | Purpose |
| --- | --- |
| `<database>` (`SafariTabs.db`) | Source: Safari's tab groups database. Read-only. |
| `<snapshot-dir>/SafariTabs.db` | Local consistent snapshot, rewritten on every run. |
| `<snapshot-dir>/content.sha` | Content hash of the last successfully synced snapshot. |
| `<backup-dir>/SafariTabs.db` | The synchronized backup copy. |
| `<log-dir>/safaritabsbackup.log`, `.err` | Progress log and error log. |

### Adding a new option

1. Add a field to `Options` and parse it in `parseArguments`.
2. Add a line to `usage()`.
3. Use the value in `SafariTabsBackup.main`, and document it in this README.

## Known limitations

- **One copy, no history.** The backup directory holds a single `SafariTabs.db` that is updated in place; earlier versions are not kept.
- **Raw database.** The tool backs up the database file as is. It doesn't export or read the tabs into a readable format.
- **Needs `rsync`.** The sync step runs `/usr/bin/rsync`, which is expected to be present (it ships with macOS).
- **Schema independence, but not guarantees.** The tool doesn't interpret Safari's schema, but the file location is private to Safari and may change in a future macOS release.
