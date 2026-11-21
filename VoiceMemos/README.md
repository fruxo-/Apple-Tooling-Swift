# voice-memos-utils

A small macOS command-line tool (Swift) that reads the local Voice Memos database (`CloudRecordings.db`) and can:

1. **Find** recordings by **date** or **date range** (`--date`, `--from`, `--to`).
2. **Search** recording titles with a **boolean expression** (`--search`).
3. **Print** the paths of the matching audio files, one per line, which makes it easy to script, or each recording's description followed by its path (`--describe`).

Voice Memos stores recordings under opaque, timestamp-based file names, and the titles you see in the app live in a separate SQLite database. `voice-memos-utils` queries that database for you.

Everything runs locally. The tool never touches the network and never modifies your Voice Memos data.

---

## Contents

- [Requirements](#requirements)
- [Build and install](#build-and-install)
- [Where the database lives](#where-the-database-lives)
- [Quick start](#quick-start)
- [Command-line reference](#command-line-reference)
- [Date filters](#date-filters)
- [Title search](#title-search)
- [Output](#output)
- [Using the output](#using-the-output)
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
| Toolchain | Swift 6.0 toolchain (Xcode 16 or later) |
| Libraries | System `SQLite3` and [swift-argument-parser](https://github.com/apple/swift-argument-parser), which SwiftPM fetches on the first build. |
| Permissions | **Full Disk Access** for the terminal app you run it from (see [Where the database lives](#where-the-database-lives)) |

## Build and install

```sh
swift build -c release
```

The binary ends up at `.build/release/voice-memos-utils`. To install it, copy it to any directory on your `PATH`:

```sh
cp .build/release/voice-memos-utils ~/.local/bin/
```

During development you can skip the install step:

```sh
swift run voice-memos-utils --help
```

## Where the database lives

If you don't pass a database path, the tool reads the location used by macOS Sonoma (14) and later:

```
~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/CloudRecordings.db
```

On macOS versions before Sonoma, the database is in a different place. Pass it explicitly:

```sh
voice-memos-utils --db ~/Library/Application\ Support/com.apple.voicememos/Recordings/CloudRecordings.db --date 2026-10-23
```

**macOS privacy protection:** the Voice Memos data lives in a protected location, so the terminal app running `voice-memos-utils` needs access:

1. Open **System Settings > Privacy & Security > Full Disk Access**.
2. Enable your terminal app (Terminal, iTerm2, Ghostty, and so on).
3. Restart the terminal.

Without it, `voice-memos-utils` exits with an error that points here.

## Quick start

```sh
# Everything recorded on one day
voice-memos-utils --date 2026-10-23

# October 2026
voice-memos-utils --from 2026-10-01 --to 2026-10-31

# Everything since the start of the year
voice-memos-utils --from 2026-01-01

# Title contains "meeting" AND "budget"
voice-memos-utils --search 'meeting and budget'

# Title contains "idea" OR "lyrics" OR "melody"
voice-memos-utils --search 'idea or lyrics or melody'

# Grouping: (foo AND bar) OR (alice AND bob)
voice-memos-utils --search '(foo and bar) or (alice and bob)'

# Exact phrase combined with alternatives
voice-memos-utils --search '"team meeting" and (budget or roadmap)'

# Date range + search: "project" AND ("kickoff" OR "review")
voice-memos-utils --from 2026-01-01 --to 2026-06-30 --search 'project and (kickoff or review)'

# See each recording's description alongside its path
voice-memos-utils --search meeting --describe
```

## Command-line reference

```
voice-memos-utils [--date YYYY-MM-DD] [--from YYYY-MM-DD] [--to YYYY-MM-DD]
                  [--search EXPRESSION] [--describe] [--db PATH] [--include-missing]
```

| Option | Description |
| --- | --- |
| `--date <day>` | Recordings made on exactly that day. |
| `--from <day>` | Recordings made on or after that day (inclusive). |
| `--to <day>` | Recordings made on or before that day (inclusive). |
| `-s`, `--search <expression>` | Boolean expression matched against the recording's title. See [Title search](#title-search). |
| `-d`, `--describe` | Print `Description:` and `Path:` lines for each match instead of just the path. See [Output](#output). |
| `--db <path>` | Path to `CloudRecordings.db`. Defaults to the macOS Sonoma (14) and later location. |
| `--include-missing` | Also list recordings whose audio file isn't on disk (for example, evicted to iCloud). They are skipped by default, with a note on stderr. |
| `-h`, `--help` | Show help. |

Notes:

- Days are written as `YYYY-MM-DD`. See [Date filters](#date-filters) and [Time zones](#time-zones).
- Filters combine: a recording must match the date filter **and** the title search.
- Results are printed to **stdout**, so they can be piped straight into other tools. The note about skipped recordings goes to **stderr**.

## Date filters

Days are written as `YYYY-MM-DD` and interpreted in your **local time zone**.

- `--from` and `--to` can be used together (a closed range) or alone (an open-ended range).
- `--date` cannot be combined with `--from` or `--to`.
- With no date option, recordings from all dates are considered.

## Title search

`--search` (short form `-s`) takes a boolean expression that is matched against the recording's title:

```sh
voice-memos-utils --search '(foo and bar) or (alice and bob)'
```

| Element | Meaning |
| --- | --- |
| `word` | The title contains this text. Matching is a **case-insensitive and accent-insensitive substring** match, so `cafe` matches `Café notes` and `meet` matches `Team Meeting`. |
| `"two words"` | A phrase in double quotes, for terms that contain spaces. Use `\"` for a literal quote and `\\` for a literal backslash. |
| `and` | Both sides must match. |
| `or` | At least one side must match. |
| `( ... )` | Grouping. |

Rules worth knowing:

- **`and` binds tighter than `or`**, as in most query languages: `a or b and c` means `a or (b and c)`. Use parentheses whenever you mix them, so the intent is obvious.
- **Operators are explicit.** Two terms side by side (`foo bar`) are an error rather than a guess. Write `foo and bar`, or `"foo bar"` for the phrase.
- Operators are case-insensitive (`AND`, `Or`). To search for the literal word "and" or "or", quote it: `"and"`.
- **Quote the whole expression** with single quotes in your shell, so it isn't split or expanded.
- Mistakes are reported with the column where the problem is, for example `Missing 'and' or 'or' before 'bar' at column 5.`
- Recordings with no title never match a search.

## Output

By default `voice-memos-utils` prints **only the paths**, one per line, oldest recording first, so the output can be piped straight into other tools:

```console
$ voice-memos-utils --from 2026-10-01 --search 'meeting and (budget or roadmap)'
/Users/me/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/20261003 091500-A1B2C3D4.m4a
/Users/me/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/20261017 140200-E5F6A7B8.m4a
```

With `--describe` (short form `-d`), each match is printed as two labelled lines, with a blank line between recordings:

```
Description: <title as shown in Voice Memos>
Path: <path to the audio file>
```

For example, to see each recording's description (the title you see, and can edit, in Voice Memos) before its path:

```console
$ voice-memos-utils --from 2026-10-01 --search 'meeting and (budget or roadmap)' --describe
Description: Q4 budget meeting
Path: /Users/me/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/20261003 091500-A1B2C3D4.m4a

Description: Roadmap meeting
Path: /Users/me/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/20261017 140200-E5F6A7B8.m4a
```

The description is the recording's title. A recording with no title falls back to its audio file's name (without the extension). Use `--describe` for reading results yourself, and the default for scripting.

## Using the output

Paths are printed one per line, and the default Voice Memos folder contains a space (`Group Containers`), so quote them when passing them to other commands:

```sh
# Copy all matches to a folder
mkdir -p ~/Desktop/export
voice-memos-utils --search meeting | while IFS= read -r file; do
    cp "$file" ~/Desktop/export/
done

# Or with xargs
voice-memos-utils --search meeting | tr '\n' '\0' | xargs -0 -I{} cp {} ~/Desktop/export/
```

## Time zones

Day filters are interpreted in your **local time zone**. Internally they become a half-open interval `[start of first day, start of the day after the last day)` in local time, so DST changes are handled by `Calendar`.

## Privacy and safety

- **Read-only.** The database and its `-wal` / `-shm` sidecar files are copied to a temporary directory and queried there. The live Voice Memos database is never opened, modified or locked, and recent recordings still sitting in the write-ahead log are visible. The copy is deleted afterwards.
- **Local only.** No network access is used anywhere.
- **Sensitive output.** Recording titles and file paths can reveal private information. Store and share them accordingly.

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| "Couldn't read the Voice Memos database … Operation not permitted" | The terminal lacks Full Disk Access. See [Where the database lives](#where-the-database-lives). |
| "Database not found at …" | Wrong macOS version path. Use `--db`. |
| No output, but a note about skipped recordings | The audio files aren't on disk. Open them in Voice Memos to download them, or use `--include-missing` to list them. |
| Descriptions are empty, look like dates, or don't match the app | The title column differs on your macOS version. Inspect the raw columns (see below) and open an issue or adjust the query in `VoiceMemosLibrary.swift`. |
| A recording you expect isn't listed | Check its description with `--describe` (searching without `--search`), and remember that the date is in your local time zone. |

To inspect the raw title columns for your most recent recordings:

```sh
sqlite3 ~/Library/Group\ Containers/group.com.apple.VoiceMemos.shared/Recordings/CloudRecordings.db \
  "SELECT ZCUSTOMLABEL, ZCUSTOMLABELFORSORTING, ZENCRYPTEDTITLE, ZPATH FROM ZCLOUDRECORDING ORDER BY ZDATE DESC LIMIT 5;"
```

## Project layout and internals

```
VoiceMemos/
├── Package.swift                      Swift package manifest (macOS 13+)
├── README.md                          this file
├── Sources/
│   ├── VoiceMemosKit/                 Library: database access, filters, search
│   │   ├── SearchCriteria.swift       DateFilter, SearchCriteria, DayParser
│   │   ├── SearchExpression.swift     Boolean title expressions: lexer, parser, matcher, errors
│   │   └── VoiceMemosLibrary.swift    Recording, VoiceMemosLibrary, VoiceMemosError
│   └── VoiceMemosUtils/               Executable: the `voice-memos-utils` command (swift-argument-parser)
│       └── VoiceMemosUtils.swift
└── Tests/
    └── VoiceMemosUtilsTests/          Swift Testing suites
        └── VoiceMemosUtilsTests.swift
```

`VoiceMemosKit` has no command-line concerns, so it can be reused from other tools or tests.

| Part | Purpose |
| --- | --- |
| `DateFilter`, `DayParser` | Day and range filters, and `YYYY-MM-DD` parsing. |
| `SearchExpression` | Lexer, recursive-descent parser and matcher for `--search`. |
| `VoiceMemosLibrary` | Copying the database, querying it, resolving audio paths. |
| `Recording`, `VoiceMemosError` | Result type (with `displayName`) and error cases. |
| `VoiceMemosUtils` | The command: option parsing, validation, output. |

### How it works

- **Search:** The `--search` expression is parsed into a small tree (a recursive-descent parser, `and` above `or`) and evaluated in Swift rather than SQL, because SQLite's `LIKE` is only case-insensitive for ASCII and ignores diacritics. Date filters are applied in SQL; the title expression is applied to the rows that remain.
- **Paths:** `ZPATH` is normally absolute. If it is relative, it's resolved against the folder containing the database.

### Database tables and fields used

Titles, dates and file paths are in the `ZCLOUDRECORDING` table of `CloudRecordings.db`:

| Field | Used for |
| --- | --- |
| `ZENCRYPTEDTITLE` | The title on macOS Sonoma and later. Despite the name, it holds the plaintext title in the local database ("encrypted" refers to how it's stored in iCloud). |
| `ZCUSTOMLABEL` | The older title column, used as a fallback when `ZENCRYPTEDTITLE` is empty. |
| `ZDATE` | The recording date. A Core Data timestamp, in seconds since 2001-01-01 00:00:00 UTC. |
| `ZPATH` | The audio file. |

### Testing

```sh
swift test
```

The tests cover search-expression parsing (precedence, grouping, quoting, error positions) and matching, day and range boundaries, date parsing, and end-to-end searches against a small fixture SQLite database created on the fly. They never touch your real Voice Memos data.

## Known limitations

- **Title only.** Only the title is searched; transcripts are not.
- **Audio not on disk.** Recordings whose audio isn't downloaded locally are skipped unless you pass `--include-missing`.
- **Schema dependence.** The schema is private to Apple and can change between macOS releases. This tool was written against the schema of the `ZCLOUDRECORDING` table as found on macOS Sonoma and later.
- **Older macOS.** On macOS versions before Sonoma, the database is in a different place; pass it with `--db` (see [Where the database lives](#where-the-database-lives)).
