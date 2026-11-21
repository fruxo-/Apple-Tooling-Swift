# mail-utils

Command-line utilities for Apple Mail (Swift). Two subcommands:

1. **Export** email threads as Markdown and/or HTML, one file per thread (`export`).
2. **List** the threads found in Mail, with email counts, participants and date ranges, without writing anything (`list`).

Everything runs locally. The tool never touches the network and never modifies your Mail data.

---

## Contents

- [Requirements](#requirements)
- [Build and install](#build-and-install)
- [Where the data lives](#where-the-data-lives)
- [Quick start](#quick-start)
- [Command-line reference](#command-line-reference)
- [Selecting threads with `--party` and `--only`](#selecting-threads-with---party-and---only)
- [Export mode](#export-mode)
- [List mode](#list-mode)
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
| Libraries | System `sqlite3` and [swift-argument-parser](https://github.com/apple/swift-argument-parser), which SwiftPM fetches on the first build. |
| Permissions | **Full Disk Access** for your terminal (see [Where the data lives](#where-the-data-lives)) |

## Build and install

```sh
swift build -c release
.build/release/mail-utils --help
.build/release/mail-utils export --help
```

To use it from anywhere, copy the binary to a directory on your `PATH`:

```sh
cp .build/release/mail-utils ~/.local/bin/
```

## Where the data lives

If you don't pass `--mail-directory`, the tool uses the newest `~/Library/Mail/V*` folder (for example `~/Library/Mail/V10`). Inside it:

- `MailData/Envelope Index` is the SQLite database with the metadata (people, dates, subjects, conversations).
- The `.emlx` files next to it hold the message bodies.

`--mail-directory` accepts a version folder or its parent, so a backup such as `/Volumes/Backup/Library/Mail/V10` works too.

**macOS privacy protection:** `~/Library/Mail` is protected. Your terminal needs **Full Disk Access** (System Settings → Privacy & Security → Full Disk Access) to read it. Restart the terminal after enabling it.

## Quick start

```sh
# Which threads exist?
mail-utils list
mail-utils list --party alice@example.com --sort last

# Every thread alice@example.com took part in (as From, To, Cc or Bcc), in 2024
mail-utils export --party alice@example.com --from 2024-01-01 --to 2024-12-31 -o ~/Desktop/alice-2024

# Same threads as browsable HTML pages (or --format both for .md and .html side by side)
mail-utils export --party alice@example.com --format html -o ~/Desktop/alice-html

# Within those threads, keep only the emails that actually involve alice
mail-utils export --party alice@example.com --only

# Threads involving both addresses
mail-utils export --party alice@example.com --party bob@example.org

# Mail data somewhere other than the default (e.g. a backup)
mail-utils export --mail-directory /Volumes/Backup/Library/Mail/V10
```

## Command-line reference

```
mail-utils export [SELECTION OPTIONS] [-o|--output DIR] [--format markdown|html|both] [-v|--verbose]
mail-utils list   [SELECTION OPTIONS] [--format table|tsv|json] [--sort first|last|count|subject]

SELECTION OPTIONS:
  [-m|--mail-directory PATH] [--from DATE] [--to DATE] [--party ADDRESS]...
  [--only] [--min-messages N] [--include-deleted]
```

### Selection options (both subcommands)

| Option | Meaning |
|---|---|
| `-m, --mail-directory <path>` | A `V*` folder (e.g. `~/Library/Mail/V10`) or its parent. Default: newest `~/Library/Mail/V*`. |
| `--from <date>` / `--to <date>` | Date window on email timestamps. `YYYY-MM-DD` (local time; `--to` includes the whole day) or ISO 8601 date-time. A thread keeps only its emails inside the window, and its counts and timestamps describe that window. |
| `--party <address>` | Only threads in which this address took part, as sender, To, Cc or Bcc of any email. The whole thread is kept, including emails between other people. Repeat the option to require all of the addresses. |
| `--only` | Needs `--party`. Within each thread, keeps only the emails that feature the party address in From, To, Cc or Bcc; emails of the same thread between other people are left out. With several `--party` options an email must feature all of them. Emails, timestamps, participants and per-participant counts then describe just the emails kept. |
| `--min-messages <n>` | Skip threads with fewer than *n* emails. |
| `--include-deleted` | Include emails Mail has flagged as deleted. |

### `export` options

| Option | Meaning |
|---|---|
| `-o, --output <path>` | Output directory. Default: `./mail-export`. Files go into a subfolder named after the `--party` address (or `all`). |
| `--format markdown\|html\|both` | File format. Default `markdown`. `both` writes the `.md` and `.html` files side by side, with `index.md` and `index.html`. |
| `-v, --verbose` | Print every thread written and list emails whose body could not be found. |

### `list` options

| Option | Meaning |
|---|---|
| `--format table\|tsv\|json` | Default `table`. `tsv` columns: emails, participants, first, last, conversation id, subject. `json` also lists every participant with display name and emails sent. |
| `--sort first\|last\|count\|subject` | `first` (default): oldest first email first. `last`: most recent latest email first. `count`: most emails first. `subject`: alphabetical. |

Notes:

- `export` and `list` accept the same selection options, so `list` shows exactly the threads `export` would write.
- Progress and diagnostics go to **stderr**; the `list` result goes to **stdout**, so it can be piped or redirected.

## Selecting threads with `--party` and `--only`

`--party` keeps every thread in which the address took part, with all of its emails. Adding `--only` narrows each thread to the emails that feature the address. The two modes give different results on the same data.

### What `--only` does

Take a thread with four emails: alice writes to bob, bob writes to carol, carol writes to alice and bob (Cc), and bob writes to carol again.

| | Emails kept | Participants |
|---|---|---|
| `--party alice` | all 4 | alice, bob, carol |
| `--party alice --only` | the 1st and the 3rd, the two that list alice | alice, bob, carol |
| `--party alice --party bob --only` | the 1st and the 3rd, the two that list both | alice, bob, carol |

With `--only` the thread file, the index and `list` all describe the emails kept: the email count, the earliest and latest timestamp, the participants and the "emails sent" table. A thread in which the address appears on no email at all disappears from the result, as it does without `--only`. `--min-messages` is applied after the narrowing.

## Export mode

`export` reads Mail's `Envelope Index` (from a private temporary copy) and the `.emlx` message files next to it, groups the emails into threads and writes one file per thread.

### Output folders

Exports go into a subfolder of the output directory named after the `--party` address, so several people can share one output folder without mixing. Inside it is one flat list of thread files, plus an index:

```
mail-export/
└── alice@example.com/
    ├── index.md
    ├── 2024-03-02_091500_project-kickoff_thread1234.md
    └── 2024-03-05_142210_invoice-march_thread1260.md
```

The subfolder is the address as given (lowercased); with `--only` it gets an `__only` suffix (`alice@example.com__only`) so a filtered export never mixes with a full export of the same person. With several `--party` options the addresses are joined with `__` (`alice@example.com__bob@example.org`), and without `--party` the folder is called `all`. Each folder has its own `index` listing only its threads. Re-running with the same party overwrites files with the same names; delete the folder first if you changed the filters and want a clean result.

### Thread file format

Each thread file starts with a summary, then the emails in chronological order:

```
# Project kickoff

- **Earliest email:** 2024-03-02T09:15:00Z
- **Latest email:** 2024-03-09T16:40:12Z
- **Emails:** 7
- **Participants:** 3
- **Mail conversation id:** 1234

| Participant | Emails sent |
|---|---:|
| Alice (alice@example.com) | 4 |
| Bob (bob@example.org) | 3 |
| Carol (carol@example.net) | 0 |

---

## 1. 2024-03-02T09:15:00Z — Alice (alice@example.com)
- **To:** Bob (bob@example.org), Carol (carol@example.net)
...
```

- Participants are everyone who sent or received at least one email in the thread (From, To, Cc, Bcc). "Emails sent" is 0 for people who only received.
- File names are `<first email's UTC timestamp>_<subject slug>_thread<id>.md`, so alphabetical order is chronological. All times are UTC. A file's creation date is its first email and its modification date its last.
- Emails are grouped by Mail's `conversation_id`. An email Mail did not assign to a conversation becomes a one-email thread (file name ends in `msg<id>`).
- The body is in a fenced `text` block so quoting and line wraps survive intact. HTML-only emails are converted to plain text. The subject is repeated under an email's heading only when it differs from the thread's beyond a `Re:`/`Fwd:` prefix.
- The same email filed in several mailboxes is exported once.

### HTML output

`--format html` writes each thread as a self-contained page for people who would rather not read Markdown:

- Same content as the Markdown file: timestamps, email count, participants table with emails sent, then the emails in order. `index.html` links to every thread with relative links, so the folder can be moved, zipped or shared as is.
- One file, inline styles, no JavaScript, no remote content. It follows the system light/dark setting and prints cleanly.
- Email bodies are always shown as escaped plain text with wrapping lines. The sender's own HTML is never rendered, so opening an export can't load tracking pixels, remote images or scripts. HTML-only emails are converted to plain text first, so newsletters lose their layout.
- Quoted replies are folded: a run of three or more lines starting with `>` becomes a "Show quoted text (N lines)" toggle, using the browser's built-in `<details>` element. The "On … wrote:" line stays visible above it. This only recognises `>`-style quoting; Outlook-style quoting (a "From: … Sent: …" block with no `>` marks) is left as is. If an email consists only of quoted lines, nothing is folded.
- Printing: folded quotes stay folded (the printout is shorter); open the toggles first if you want them in the printout.

## List mode

`list` shows which threads exist, with email counts, participants and date ranges, without writing anything. It accepts the same selection options as `export`:

```sh
mail-utils list
mail-utils list --party alice@example.com --sort last
```

Choose the output with `--format table|tsv|json` and the order with `--sort first|last|count|subject` (see [`list` options](#list-options)). The number of threads is printed to stderr when the list is done.

## Time zones

- `--from` and `--to` written as a bare `YYYY-MM-DD` are interpreted in your **local time zone**, and `--to` includes the whole day. An ISO 8601 date-time (for example `2024-03-02T09:15:00Z`) is taken as written.
- **All times in the output are UTC**: the timestamps inside thread files, the index, `list` output and the timestamp at the start of each file name.

## Privacy and safety

- **Read-only.** The `Envelope Index` database (plus its `-wal` / `-shm` files) is copied to a temporary folder and read from there. Mail's live database is never opened, locked or checkpointed. The copy is deleted afterwards.
- **Local only.** No network access is used anywhere.
- **Safe to open.** HTML exports contain no scripts or remote content, and the sender's own HTML is never rendered.
- **Sensitive output.** Exports contain private correspondence (including other people's emails). Store and share them accordingly.

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `Could not find Mail's "MailData/Envelope Index" under …` | Your terminal probably lacks Full Disk Access (see [Where the data lives](#where-the-data-lives)). Otherwise point `--mail-directory` at the right folder. |
| `Could not copy … Envelope Index` | A permissions error: grant Full Disk Access to your terminal and try again. |
| `No matching threads found.` | Nothing matches the selection. Loosen `--from` / `--to` / `--party` / `--min-messages`, or preview with `mail-utils list`. |
| `--only needs at least one --party.` | `--only` only works together with `--party`. |
| `--from must not be later than --to.` | Swap the dates. |
| `--min-messages must be at least 1.` | Use 1 or more. |
| `Body not found for N emails (headers and snippet were written instead)` | No matching `.emlx` was found (not downloaded, or only a partial copy). Use `--verbose` to list them. |
| Quoted replies aren't folded in HTML | Only `>`-style quoting is recognised (see [HTML output](#html-output)). |
| Threads look wrong | Threads are built on `messages.conversation_id`; that column is where to look (see [Assumptions to verify on your data](#assumptions-to-verify-on-your-data)). |

## Project layout and internals

```
Mail/
├── Package.swift                     Swift package manifest (macOS 13+)
├── README.md                         this file
├── Sources/
│   └── MailUtils/
│       ├── MailUtils.swift           entry point: `mail-utils` and its subcommands
│       ├── SelectionOptions.swift    shared selection options, date parsing, loading
│       ├── ExportCommand.swift       `export`
│       ├── ListCommand.swift         `list`
│       ├── Models.swift              errors, logging, Mail location, message and thread model
│       ├── SQLite.swift              read-only SQLite wrapper, database snapshot
│       ├── MailStore.swift           the Envelope Index queries
│       ├── EmlxIndex.swift           .emlx index and matching emails to files
│       ├── MIME.swift                MIME parsing and .emlx reader
│       ├── ThreadDocument.swift      per-thread data, text helpers, name formatting
│       ├── Exporter.swift            writes thread files and indexes
│       ├── MarkdownRenderer.swift    Markdown output
│       └── HTMLRenderer.swift        HTML output
└── Tests/
    └── MailUtilsTests/
        └── MailUtilsTests.swift      XCTest suites (text helpers, MIME/.emlx parsing, threading, file matching)
```

### How it works

- The `Envelope Index` SQLite database (plus its `-wal`/`-shm` files) is copied to a temp folder and read from there. Mail's live database is never opened.
- Metadata (people, dates, subject, conversation) comes from the database. **Message bodies are not stored in it**, so they are read from the `.emlx` files. The tool scans the Mail folder once, matches files to emails by numeric file name, and confirms a match against the Message-ID header when it can.
- If no `.emlx` is found (not downloaded, or only a partial copy), the email still appears with its headers and the database snippet, and says the body is unavailable.

### Database tables used

| Table | Used for |
| --- | --- |
| `messages` | Emails: timestamps (`date_sent`, falling back to `date_received` and `display_date`), `deleted` flag, `global_message_id`, `remote_id`, `subject_prefix`, `conversation_id`, and links to the tables below. |
| `subjects`, `summaries` | Subject text and the snippet shown when a body is unavailable. |
| `mailboxes` | Mailbox URL, used to prefer the `.emlx` file in the right folder. |
| `addresses` | Email addresses and display names of senders and recipients. |
| `recipients` | To / Cc / Bcc per email, with their order. |
| `message_global_data` | The Message-ID header, shared by copies of the same email in several mailboxes. |

### Assumptions to verify on your data

- Timestamps are Unix-epoch seconds (`date_sent`, falling back to `date_received`).
- Recipient `type` 0 / 1 / 2 is To / Cc / Bcc. Check with `SELECT DISTINCT type FROM recipients`; anything else is labelled "Other recipients".
- `.emlx` file names correspond to `messages.ROWID` (or `remote_id`). The Mail folder layout has changed between macOS versions.
- `messages.conversation_id` groups related emails, and 0 means "no conversation". The whole export is built on this; if threads look wrong, that column is where to look.

### Testing

```sh
swift test
```

The tests cover the logic that doesn't need a real mailbox: subject and file-name helpers, RFC 2047 / quoted-printable / RFC 2231 decoding, HTML-to-text conversion, `.emlx` and multipart parsing, thread building and participant counts, the HTML quote folding, date-option parsing, locating the Mail folder, and matching emails to `.emlx` files. They build their fixtures in temporary folders and never touch your real Mail data.

### Adding a new subcommand

1. Create a `ParsableCommand` in its own file and add it to `subcommands` in `MailUtils.swift`.
2. Add `@OptionGroup var selection: SelectionOptions` and call `selection.load()`, so the command applies the same selection rules and gets the same threads as `export` and `list`.
3. Document the new options in this README.

## Known limitations

- **Plain text bodies.** HTML-only emails are converted to plain text, so newsletters lose their layout.
- **Quote folding.** Only `>`-style quoting is folded in HTML output; Outlook-style quoting is left as is.
- **Missing bodies.** Emails that are not downloaded (or only partially) are exported with headers and snippet only.
- **Schema and layout dependence.** The tool relies on Mail's private database schema and folder layout, which have changed between macOS versions (see [Assumptions to verify on your data](#assumptions-to-verify-on-your-data)).