# mail-utils

Command-line utilities for Apple Mail. Subcommands:

- `export` writes email threads as Markdown and/or HTML, one file per thread.
- `list` shows which threads exist, with email counts, participants and date ranges, without writing anything.

Requires macOS 13+ and Swift 5.9+.

## Build

```sh
swift build -c release
.build/release/mail-utils --help
.build/release/mail-utils export --help
```

Your terminal needs **Full Disk Access** (System Settings → Privacy & Security) to read `~/Library/Mail`.

## Usage

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

## Output

Exports go into a subfolder of the output directory named after the `--party` address, so several people can share one output folder without mixing. Inside it is one flat list of thread files, plus an index:

```
mail-export/
└── alice@example.com/
    ├── index.md
    ├── 2024-03-02_091500_project-kickoff_thread1234.md
    └── 2024-03-05_142210_invoice-march_thread1260.md
```

The subfolder is the address as given (lowercased); with `--only` it gets an `__only` suffix (`alice@example.com__only`) so a filtered export never mixes with a full export of the same person. With several `--party` options the addresses are joined with `__` (`alice@example.com__bob@example.org`), and without `--party` the folder is called `all`. Each folder has its own `index` listing only its threads. Re-running with the same party overwrites files with the same names; delete the folder first if you changed the filters and want a clean result.

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

## What `--only` does

Take a thread with four emails: alice writes to bob, bob writes to carol, carol writes to alice and bob (Cc), and bob writes to carol again.

| | Emails kept | Participants |
|---|---|---|
| `--party alice` | all 4 | alice, bob, carol |
| `--party alice --only` | the 1st and the 3rd, the two that list alice | alice, bob, carol |
| `--party alice --party bob --only` | the 1st and the 3rd, the two that list both | alice, bob, carol |

With `--only` the thread file, the index and `list` all describe the emails kept: the email count, the earliest and latest timestamp, the participants and the "emails sent" table. A thread in which the address appears on no email at all disappears from the result, as it does without `--only`. `--min-messages` is applied after the narrowing.

## HTML output

`--format html` writes each thread as a self-contained page for people who would rather not read Markdown:

- Same content as the Markdown file: timestamps, email count, participants table with emails sent, then the emails in order. `index.html` links to every thread with relative links, so the folder can be moved, zipped or shared as is.
- One file, inline styles, no JavaScript, no remote content. It follows the system light/dark setting and prints cleanly.
- Email bodies are always shown as escaped plain text with wrapping lines. The sender's own HTML is never rendered, so opening an export can't load tracking pixels, remote images or scripts. HTML-only emails are converted to plain text first, so newsletters lose their layout.
- Quoted replies are folded: a run of three or more lines starting with `>` becomes a "Show quoted text (N lines)" toggle, using the browser's built-in `<details>` element. The "On … wrote:" line stays visible above it. This only recognises `>`-style quoting; Outlook-style quoting (a "From: … Sent: …" block with no `>` marks) is left as is. If an email consists only of quoted lines, nothing is folded.
- Printing: folded quotes stay folded (the printout is shorter); open the toggles first if you want them in the printout.

## How it works

- The `Envelope Index` SQLite database (plus its `-wal`/`-shm` files) is copied to a temp folder and read from there. Mail's live database is never opened.
- Metadata (people, dates, subject, conversation) comes from the database. **Message bodies are not stored in it**, so they are read from the `.emlx` files. The tool scans the Mail folder once, matches files to emails by numeric file name, and confirms a match against the Message-ID header when it can.
- If no `.emlx` is found (not downloaded, or only a partial copy), the email still appears with its headers and the database snippet, and says the body is unavailable.

## Assumptions to verify on your data

- Timestamps are Unix-epoch seconds (`date_sent`, falling back to `date_received`).
- Recipient `type` 0 / 1 / 2 is To / Cc / Bcc. Check with `SELECT DISTINCT type FROM recipients`; anything else is labelled "Other recipients".
- `.emlx` file names correspond to `messages.ROWID` (or `remote_id`). The Mail folder layout has changed between macOS versions.
- `messages.conversation_id` groups related emails, and 0 means "no conversation". The whole export is built on this; if threads look wrong, that column is where to look.