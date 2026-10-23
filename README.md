# Apple Tooling (Swift)

Standalone Swift Package Manager command-line tools for exporting or backing up
Apple app data. Each executable has its own package manifest and can be built,
installed, archived, and released independently.

## Requirements

- macOS
- Swift 5.9 or newer
- Full Disk Access for the terminal or process reading the app databases
- `rsync` for incremental Safari snapshot synchronization

## WhatsApp chat exporter

Exports WhatsApp chats to one UTF-8 text file per chat. If no database path is
given, the executable checks the standard WhatsApp Desktop locations and then
`./ChatStorage.sqlite`.

```sh
cd WhatsApp
swift build -c release
.build/release/whatsapp-exporter --help
.build/release/whatsapp-exporter /path/to/ChatStorage.sqlite -o ~/Desktop/whatsapp-export
```

Options include `--utc` and `--include-status`.

## Messages exporter

Exports macOS Messages conversations from `chat.db`, merging threads with the
same identifier. If no database path is given, the executable checks
`~/Library/Messages/chat.db` and then `./chat.db`.

```sh
cd Messages
swift build -c release
.build/release/messages-exporter --help
.build/release/messages-exporter ~/Library/Messages/chat.db --out ~/Desktop/messages-export
.build/release/messages-exporter --out ~/Desktop/messages-export
```

Use `--me NAME` to change the label for your own messages and
`--oldest-first` to reverse the default newest-first order.

## Safari tabs backup

Creates a consistent SQLite snapshot of Safari's tabs database, compares its
content (excluding volatile SQLite header counters) with the last successful
snapshot, and uses `rsync` to incrementally synchronize changed snapshots.
Defaults match the original script's locations under `~/Library`.

```sh
cd Safari
swift build -c release
.build/release/safari-tabs-backup --help
.build/release/safari-tabs-backup
```

Use `--database`, `--backup-dir`, `--snapshot-dir`, and `--log-dir` to override
the default paths. Each package is versioned independently in its own
`Package.swift`; release only the package you intend to distribute.

# VoiceMemosUtils

A small macOS command-line tool, `VoiceMemosUtils`, that finds Voice Memos recordings by **date**, **date range** and a **boolean search over the title**, and prints the paths of the matching audio files, one per line, which makes it easy to script.

```console
$ voice-memos-utils --from 2026-10-01 --search 'meeting and (budget or roadmap)'
/Users/me/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/20261003 091500-A1B2C3D4.m4a
/Users/me/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/20261017 140200-E5F6A7B8.m4a
```

Add `--describe` to see each recording's description (the title you see, and can edit, in Voice Memos) before its path:

```console
$ voice-memos-utils --from 2026-10-01 --search 'meeting and (budget or roadmap)' --describe
Description: Q4 budget meeting
Path: /Users/me/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/20261003 091500-A1B2C3D4.m4a

Description: Roadmap meeting
Path: /Users/me/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/20261017 140200-E5F6A7B8.m4a
```

More in its [README.md](./VoiceMemos/README.md).