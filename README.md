# Apple Tooling (Swift)

Standalone Swift Package Manager command-line tools for exporting, searching or backing up the data of Apple apps (and WhatsApp) on macOS. Every tool lives in its own folder with its own `Package.swift`, so it can be built, installed and released independently.

| Tool | Command | What it does |
| --- | --- | --- |
| [Mail](#mail) | `mail-utils` | Export Mail conversations as Markdown/HTML threads |
| [Messages](#messages) | `messages-exporter` | Export iMessage/SMS chats, count messages, find topics |
| [Safari](#safari) | `safari-tabs-backup` | Incrementally back up Safari's tab groups |
| [Voice Memos](#voice-memos) | `voice-memos-utils` | Find recordings by date and title |
| [WhatsApp](#whatsapp) | `whatsapp-exporter` | Export WhatsApp chats, count messages, find topics |

## Requirements

- macOS 13 or later
- Swift 5.9 or newer (Voice Memos needs the Swift 6.0 toolchain, i.e. Xcode 16)
- **Full Disk Access** for the terminal running the tool: System Settings > Privacy & Security > Full Disk Access
- `rsync` (Safari backup only)

## Build

Each tool is built from its own folder:

```sh
cd <Mail|Messages|Safari|VoiceMemos|WhatsApp>
swift build -c release
.build/release/<command> --help
```

All tools work on a private copy of the app's database and never modify your data. Everything runs locally, with no network access.

---

## Mail

Slice and dice Apple Mail conversations and export them as one Markdown and/or HTML file per thread, with participants, timestamps and message bodies. A `list` subcommand previews what would be exported.

- **Command:** `mail-utils` (subcommands `export`, `list`)
- **Reads:** `~/Library/Mail/V*` (the `Envelope Index` database and the `.emlx` files)

```sh
# Which threads exist?
mail-utils list --party alice@example.com --sort last

# Every thread alice@example.com took part in during 2024
mail-utils export --party alice@example.com --from 2024-01-01 --to 2024-12-31 -o ~/Desktop/alice-2024

# Same threads as browsable HTML pages
mail-utils export --party alice@example.com --format html

# Only the emails that actually involve both people
mail-utils export --party alice@example.com --party bob@example.org --only
```

More in [Mail/README.md](./Mail/README.md).

## Messages

Export macOS Messages conversations (iMessage and SMS) from `chat.db` to one text transcript per conversation, count messages per sender per day/week/month, and extract the most-discussed topics with on-device language models.

- **Command:** `messages-exporter`
- **Reads:** `~/Library/Messages/chat.db`
- **Shares its options with** `whatsapp-exporter`, so commands carry over 1:1.

```sh
# Export every conversation, oldest message first
messages-exporter --oldest-first --me Marco

# Message counts per sender (daily, weekly, monthly) for one conversation
messages-exporter --stats --party "+39 333 123 4567"

# The 20 most-discussed topics of a group chat
messages-exporter --topics 20 --party "Weekend Trip" --lang it

# Stats and topics together, saved to a file
messages-exporter --stats --topics --party "Weekend Trip" > trip-report.txt
```

More in [Messages/README.md](./Messages/README.md).

## Safari

Create a consistent SQLite snapshot of Safari's tab groups database, compare its content with the last successful snapshot, and use `rsync` to sync it to a backup folder (iCloud Drive by default) only when something changed. Meant to be run on a schedule.

- **Command:** `safari-tabs-backup`
- **Reads:** `~/Library/Containers/com.apple.Safari/Data/Library/Safari/SafariTabs.db`

```sh
# Back up with the default locations
safari-tabs-backup

# Choose where the backup, local snapshot and logs go
safari-tabs-backup --backup-dir ~/Backups/SafariTabs --snapshot-dir ~/.cache/safari-tabs --log-dir ~/Logs

# Back up a different database file
safari-tabs-backup --database /path/to/SafariTabs.db
```

More in [Safari/README.md](./Safari/README.md).

## Voice Memos

Find Voice Memos recordings by date, date range and a boolean search over the title, and print the matching audio file paths, one per line, which makes it easy to script.

- **Command:** `voice-memos-utils`
- **Reads:** `~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/CloudRecordings.db`

```sh
# Everything recorded on one day
voice-memos-utils --date 2026-10-23

# October 2026
voice-memos-utils --from 2026-10-01 --to 2026-10-31

# Boolean title search, shown with each recording's title
voice-memos-utils --search '"team meeting" and (budget or roadmap)' --describe

# Copy all matches to a folder
voice-memos-utils --search meeting | while IFS= read -r file; do cp "$file" ~/Desktop/export/; done
```

More in [VoiceMemos/README.md](./VoiceMemos/README.md).

## WhatsApp

Export WhatsApp chats from the desktop app's `ChatStorage.sqlite` to one text transcript per chat, count messages per sender per day/week/month, and extract the most-discussed topics with on-device language models.

- **Command:** `whatsapp-exporter`
- **Reads:** `~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite`
- **Shares its options with** `messages-exporter`, so commands carry over 1:1.

```sh
# Export every chat, oldest message first
whatsapp-exporter --oldest-first --me Marco

# Message counts per sender (daily, weekly, monthly) for one chat
whatsapp-exporter --stats --party "Ana"

# The 20 most-discussed topics of a chat, hiding generic words
whatsapp-exporter --topics 20 --party "Ana" --lang it --ignore cosa,volta,giorno

# Stats and topics together, saved to a file
whatsapp-exporter --stats --topics --party "Ana" > ana-report.txt
```

More in [WhatsApp/README.md](./WhatsApp/README.md).
