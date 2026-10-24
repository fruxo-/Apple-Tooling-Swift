# mail-utils

Exports Apple Mail correspondence between pairs of people as Markdown: one folder per correspondence, one file per message, sorted by timestamp.

Requires macOS 13+ and Swift 5.9+.

## Build

```sh
swift build -c release
.build/release/mail-utils --help
```

Your terminal needs **Full Disk Access** (System Settings → Privacy & Security) to read `~/Library/Mail`.

## Usage

```sh
# See which correspondences exist (count, address, address), busiest first. Writes nothing.
mail-utils --dry-run

# Everyone you've corresponded with, in 2024 only
mail-utils --party me@example.com --from 2024-01-01 --to 2024-12-31 -o ~/Desktop/mail-2024

# One specific pair
mail-utils --party alice@example.com --party bob@example.org

# Mail data somewhere other than the default (e.g. a backup)
mail-utils --mail-directory /Volumes/Backup/Library/Mail/V10
```

| Option | Meaning |
|---|---|
| `-m, --mail-directory <path>` | A `V*` folder (e.g. `~/Library/Mail/V10`) or its parent. Default: newest `~/Library/Mail/V*`. |
| `-o, --output <path>` | Output directory. Default: `./mail-utils`. |
| `--from <date>` / `--to <date>` | Date window. `YYYY-MM-DD` (local time; `--to` includes the whole day) or ISO 8601 date-time. |
| `--party <address>` | Repeatable. Once: pairs involving that address. Twice or more: only pairs made of those addresses. |
| `--min-messages <n>` | Skip correspondences with fewer than *n* messages. |
| `--include-deleted` | Include messages flagged as deleted. |
| `--dry-run` | List correspondences and exit. |
| `-v, --verbose` | List messages whose body could not be found. |

## Output

```
mail-utils/
├── index.md
└── alice@example.com__bob@example.org/
    ├── 2024-03-02_091500_project-kickoff_48213.md
    └── 2024-03-02_154210_re-project-kickoff_48230.md
```

- A correspondence is an unordered pair of addresses: the sender plus one recipient (To, Cc or Bcc). A message sent to several people appears in each relevant folder. Messages to yourself only are skipped.
- File names are `<UTC timestamp>_<subject slug>_<message id>.md`, so alphabetical order is chronological. All times are UTC.
- The body is in a fenced `text` block so quoting and line wraps survive intact. HTML-only messages are converted to plain text.
- The same message filed in several mailboxes is exported once.

## How it works

- The `Envelope Index` SQLite database (plus its `-wal`/`-shm` files) is copied to a temp folder and read from there. Mail's live database is never opened.
- Metadata (parties, date, subject) comes from the database. **Message bodies are not stored in it**, so they are read from the `.emlx` files. The tool scans the Mail folder once, matches files to messages by numeric file name, and confirms a match against the Message-ID header when it can.
- If no `.emlx` is found (not downloaded, or only a partial copy), the file still contains the headers and the database snippet, and says the body is unavailable.

## Assumptions to verify on your data

- Timestamps are Unix-epoch seconds (`date_sent`, falling back to `date_received`).
- Recipient `type` 0 / 1 / 2 is To / Cc / Bcc. Check with `SELECT DISTINCT type FROM recipients`; anything else is labelled "Other recipients".
- `.emlx` file names correspond to `messages.ROWID` (or `remote_id`). The Mail folder layout has changed between macOS versions.
