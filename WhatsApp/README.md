# whatsapp-exporter

A small, dependency-free macOS command-line tool (Swift) that reads the local WhatsApp
`ChatStorage.sqlite` database and can:

1. **Export** every chat to a readable, one-file-per-chat text transcript.
2. **Count messages** per sender per day, ISO week and month (`--stats`).
3. **Extract the main topics** of a conversation, with who talks about them and when (`--topics`).

Everything runs locally. The tool never touches the network, never modifies your WhatsApp data,
and the topic extraction uses Apple's on-device NaturalLanguage framework (no cloud, no model download).

---

## Contents

- [Requirements](#requirements)
- [Build and install](#build-and-install)
- [Where the database lives](#where-the-database-lives)
- [Quick start](#quick-start)
- [Command-line reference](#command-line-reference)
- [Selecting a chat with `--party`](#selecting-a-chat-with---party)
- [Export mode](#export-mode)
- [Statistics mode (`--stats`)](#statistics-mode---stats)
- [Topic mode (`--topics`)](#topic-mode---topics)
- [Time zones](#time-zones)
- [Privacy and safety](#privacy-and-safety)
- [Troubleshooting](#troubleshooting)
- [Project layout and internals](#project-layout-and-internals)
- [Known limitations](#known-limitations)
- [Ideas for future work](#ideas-for-future-work)

---

## Requirements

| Item | Requirement |
| --- | --- |
| OS | macOS 13 (Ventura) or later |
| Hardware | Intel **and** Apple silicon Macs |
| Toolchain | Swift 5.9+ (Xcode or the Command Line Tools) |
| Libraries | System `sqlite3` and the built-in `NaturalLanguage` framework. No third-party packages. |

`--topics` relies on NaturalLanguage language models that ship with macOS. Which languages have
part-of-speech and lemmatization models depends on your macOS version; the tool checks this at
runtime and prints a warning on stderr when something is missing (see [Troubleshooting](#troubleshooting)).

## Build and install

```bash
cd WhatsApp
swift build -c release
```

The binary is produced at `.build/release/whatsapp-exporter`. To use it from anywhere:

```bash
sudo cp .build/release/whatsapp-exporter /usr/local/bin/
whatsapp-exporter --help
```

Or run it without installing: `swift run whatsapp-exporter --stats --party "Ana"`.

## Where the database lives

If you don't pass a database path, the tool looks, in order, for:

1. `~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite`
2. `~/Library/Group Containers/group.net.whatsapp.WhatsApp/ChatStorage.sqlite`
3. `./ChatStorage.sqlite` (current directory)

You can also pass any `ChatStorage.sqlite` path explicitly, for example a copy extracted from a
backup that uses the same Core Data schema.

**macOS privacy protection:** the WhatsApp group container is protected. If you see
`Operation not permitted`, grant your terminal app **Full Disk Access**
(System Settings > Privacy & Security > Full Disk Access), then restart the terminal.

## Quick start

```bash
# Export all chats to ./whatsapp_export/
whatsapp-exporter

# Message counts per sender (daily / weekly / monthly) for one chat
whatsapp-exporter --stats --party "Ana"

# The 20 most-discussed topics of one chat
whatsapp-exporter --topics 20 --party "Ana"

# Stats and topics together, saved to a file (reports go to stdout)
whatsapp-exporter --stats --topics --party "Ana" > ana-report.txt
```

## Command-line reference

```
whatsapp-exporter [DB] [-o|--output DIR] [--utc] [--include-status]
                  [--party NAME] [--stats] [--topics [N] [--lang CODE]
                  [--ignore WORD,WORD,...]]
```

| Option | Description |
| --- | --- |
| `DB` | Path to `ChatStorage.sqlite`. Auto-detected if omitted (see above). |
| `-o`, `--output DIR` | Output directory for the export (default `./whatsapp_export`). Ignored with `--stats` / `--topics`. |
| `--utc` | Use UTC instead of local time, both for timestamps and for day/week/month boundaries. |
| `--include-status` | Include status/broadcast pseudo-chats (skipped by default). |
| `--party NAME` | Process only one chat. Matches the chat name, phone number or JID. See [below](#selecting-a-chat-with---party). Works with and without `--stats`. |
| `--stats` | Print message counts per sender per day, ISO week and month instead of exporting. Covers every chat unless `--party` is given. |
| `--topics [N]` | Print the `N` (default 15) most-discussed topics of one chat. **Requires `--party`.** |
| `--lang CODE` | Language of the chat for `--topics`, e.g. `it`, `en`, `es` (default: auto-detect). |
| `--ignore W1,W2,...` | Comma-separated nouns to exclude from `--topics` (case- and accent-insensitive). |
| `-h`, `--help` | Show usage. |

Notes:

- `--stats` and `--topics` can be combined; the stats report is printed first.
- In `--stats` / `--topics` mode the report goes to **stdout** and the `Reading: ...` line goes to
  **stderr**, so redirecting (`> file.txt`) captures a clean report.
- Errors are printed to stderr as `error: ...` and the exit status is `1`.

## Selecting a chat with `--party`

`--party NAME` always resolves to **exactly one** chat:

1. Matching ignores case, accents and width differences (`ana lopez` matches `Ana López`).
2. A chat matches if `NAME` equals (or, in the fallback step, is contained in) its **title**, its
   **JID** (e.g. `34600111222@s.whatsapp.net`, or a group's `120363...@g.us`) or the **phone
   number** part of the JID. Phone numbers can be typed with spaces, `+`, dashes or parentheses:
   `"+34 600 11 22 33"` works.
3. An **exact** match wins. If there is none, a **partial** match is accepted only if it is unique.
4. If several chats match, the tool lists them (with their JIDs) and asks you to be more specific:

   ```
   error: 'Ana' matches 2 chats:
     - Ana López  [34600111222@s.whatsapp.net]
     - Ana Ruiz  [34600333444@s.whatsapp.net]
   Use a longer name, the phone number, or the full JID to pick one.
   ```

Two chats with the same title can always be told apart by JID or phone number.

## Export mode

Run with no mode flag to write one UTF-8 text file per chat:

```bash
whatsapp-exporter                       # auto-detect DB, write to ./whatsapp_export
whatsapp-exporter ~/ChatStorage.sqlite -o ~/Desktop/chats --utc
whatsapp-exporter --party "Family"      # export just one chat
```

Console output lists each file with its message count, then a summary:

```
   1234 msgs  Ana López [34600111222].txt
    876 msgs  Family [120363111].txt

Done: 2 chats, 2110 messages -> /Users/you/whatsapp_export
```

### File naming

`<chat title> [<JID user part>].txt`. Characters illegal in filenames are replaced with `_`,
names are capped in length, and a numeric suffix (`(2)`, `(3)`, ...) resolves any collision.

### Transcript format

```
Chat:      Ana López
JID:       34600111222@s.whatsapp.net
Type:      individual
Messages:  1234
Range:     2025-01-03 09:12:44 -> 2026-11-08 08:01:10 (CET)
Exported:  2026-11-08 12:00:00
========================================================================

--- 2025-01-03 ---
[2025-01-03 09:12:44] Me: Hello!
[2025-01-03 09:13:02] Ana López: Hi, how are you?
[2025-01-03 09:13:40] Me: [Image: 1.2 MB] Look at this (file: Media/...jpg) *
[2025-01-03 09:14:00] [System message] Messages and calls are end-to-end encrypted.
```

- A date separator is written whenever the day changes.
- A trailing ` *` marks a **starred** message.
- Multi-line messages are indented under their first line.
- System events (group changes, notices) are written without a sender, prefixed by their type label.
- Media is shown as a placeholder with details, followed by any caption and the local file path.

Media type labels: Image, Video (with duration), Audio (with duration), Contact (with name),
Location (as a Google Maps link), Document, Link, GIF, Sticker, Deleted message, System message,
System/group event. Unknown types appear as `[Type N]`.

Sender names are resolved in this order: the saved contact / partner name, the message's push
name (the name the person set for themselves), the profile push-name table, and finally the phone
number (`+34...`). Your own messages are labelled `Me`.

## Statistics mode (`--stats`)

Counts how many messages each sender wrote per **day**, per **ISO week** (Monday to Sunday,
labelled like `2026-W41 (2026-10-05)` with the Monday date) and per **month**.

```bash
whatsapp-exporter --stats --party "Family"
```

Illustrative output (names and numbers are made up):

```
Chat:      Family
JID:       120363-111@g.us
Type:      group
Messages:  412 from 4 senders (system events excluded)
Range:     2026-09-01 07:55:10 -> 2026-11-07 22:03:31 (CET)
========================================================================

Total per sender
----------------
Me          190   46.1%
Marta       122   29.6%
Paolo        70   17.0%
Luca         30    7.3%

Messages per month
------------------
Month    Me  Marta  Paolo  Luca  Total
2026-09  80     55     30    12    177
2026-10  95     60     32    15    202
2026-11  15      7      8     3     33
```

Behaviour worth knowing:

- Each section is a **table** (one row per period, one column per sender, `-` for zero) when the
  chat has up to **6 senders**. Larger groups would make the table too wide, so each period is
  printed as a short **list** of senders instead.
- Only periods with at least one message are listed.
- **Not counted:** system/group events (message types 6 and 10, which have no sender) and messages
  with no valid date (their number is reported in a `Note:` line).
- Deleted messages **are** counted (they were sent by someone).
- Without `--party`, every chat gets its own report, separated by blank lines. For long-lived chats
  the daily section can be long; redirect to a file or pipe through `less`.

## Topic mode (`--topics`)

Lists the topics most discussed in **one** chat, found entirely on-device.

```bash
whatsapp-exporter --topics --party "Ana"
whatsapp-exporter --topics 30 --party "Ana" --lang it --ignore cosa,volta,giorno,roba
```

### How topics are found

1. Only plain **text messages** are used (media, stickers, link-only messages and system events
   have no usable text). URLs are stripped and newlines collapsed.
2. The chat language is auto-detected from a sample of the messages (override with `--lang`).
3. Apple's `NLTagger` marks the **nouns** in every message and reduces them to their **base form**
   (lemma), so singular/plural or inflected forms count together.
4. Words shorter than 3 letters, words containing digits and anything in `--ignore` are dropped.
5. A noun becomes a topic if it appears in at least **5 messages**; a message counts **once** per
   noun. Topics are ranked by the number of messages that mention them.

### What each topic shows

Illustrative output:

```
Topics:    NaturalLanguage noun extraction, on-device | language: Italian (auto-detected)
Messages:  1180 text messages analysed (media, link-only and system messages skipped)
Range:     2025-01-03 -> 2026-11-07 (CET)
========================================================================
Top 15 topics: nouns found in the most messages (a message counts once per topic)

 1. lavoro  -  87 messages  |  2025-02-11 -> 2026-10-28  |  peak 2026-05 (14)
      Ana López 47 (54%), Me 40 (46%)
      e.g. [2026-05-12] Me: "Domani riunione con il cliente, devo preparare la presentazione e..."

 2. vacanza  -  41 messages  |  2025-06-02 -> 2026-08-20  |  peak 2025-07 (12)
      ...
```

- **Messages:** how many messages mention the topic.
- **Dates:** first and last mention.
- **Peak:** the month with the most mentions (count in brackets).
- **Parties:** who mentions it, with counts and share. Big groups show the top 5 senders and `+N more`.
- **Example:** the longest message mentioning the topic, truncated, so you can sanity-check it.

### Tuning the results

- **Generic words** ("cosa", "volta", "thing", "time") are the main source of noise. Hide them with
  `--ignore word1,word2,...`.
- **Length:** `--topics 40` for more, `--topics 8` for fewer.
- **Language:** if auto-detection picks the wrong language (chats mixing two languages are
  common), force it with `--lang`.
- The thresholds (minimum 5 messages per topic, 5 parties shown, 110-character examples) are
  constants in `TopicSettings` in `main.swift`.

## Time zones

By default all timestamps and day/week/month boundaries use your **local time zone**; the zone
abbreviation is printed in each report header. `--utc` switches everything to UTC, which is useful
for reproducible results across machines or when comparing chats from people in other zones.
Weeks follow the **ISO 8601** calendar (Monday-Sunday, week 1 contains the first Thursday), so a
week can belong to a different ISO year than its calendar year near January 1.

## Privacy and safety

- **Read-only.** The tool copies `ChatStorage.sqlite` (plus its `-wal` and `-shm` side files, if
  present, so recent messages are included) into a temporary directory, opens the **copy**
  read-only, and deletes the temporary directory when it exits. Your original database is only
  ever read by the file copy.
- **Local only.** No network access is used anywhere. `--topics` uses on-device NaturalLanguage
  models.
- **Sensitive output.** Transcripts, stats and topic reports contain private conversations
  (including other people's messages). Store and share them accordingly.
- **Close WhatsApp for the most consistent snapshot** if you are exporting while it is syncing,
  although the WAL-aware copy normally handles an open app fine.

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `Operation not permitted` | Grant your terminal **Full Disk Access** and restart it. |
| `could not auto-detect ChatStorage.sqlite` | Pass the database path explicitly as the first argument. |
| `table ZWACHATSESSION not found - is this a WhatsApp ChatStorage.sqlite?` | The file isn't a WhatsApp database, or the schema differs from the one this tool targets. |
| `no chat matches '...'` | Check the spelling, or try the phone number. A plain export (no `--party`) prints every chat title on the console. |
| `'...' matches N chats` | Be more specific: use the full name, the phone number or the JID. |
| `--topics works on a single chat: add --party NAME` | `--topics` needs exactly one chat. |
| `could not detect the chat language` | Pass `--lang`, e.g. `--lang it`. |
| `warning: no part-of-speech model for 'xx'` | macOS has no noun tagger for that language. The tool falls back to all words of 5+ letters, which gives weak topics. Try another `--lang` or add many `--ignore` words. |
| `no analysable text messages in this chat` | The chat has no plain text messages with a valid date. |
| Many generic topics | Use `--ignore`. |
| Counts differ from the WhatsApp app | System events, undated messages and (for `--topics`) all non-text messages are excluded. |

## Project layout and internals

```
WhatsApp/
├── Package.swift                     Swift package manifest (macOS 13+)
├── README.md                         this file
└── Sources/
    ├── CSQLite/                      system-library target exposing sqlite3 to Swift
    │   ├── module.modulemap
    │   └── shim.h
    └── WhatsAppExporter/
        └── main.swift                the whole CLI
```

`main.swift` is organised in these parts:

| Part | Purpose |
| --- | --- |
| `SQLiteDatabase`, `SQLiteRow`, `SQLiteValue` | Thin read-only wrapper over the C sqlite3 API. |
| `Options`, `parseArguments`, `usage` | Command-line parsing. |
| `resolveDatabase`, `makeSnapshot` | Locating and safely copying the database. |
| `chatTitle`, `senderName` | Shared naming logic used by export, stats and topics. |
| `exportChat` | Transcript writer. |
| `selectChat` | `--party` matching. |
| `computeStats`, `renderSection`, `statsReport` | `--stats`. |
| `extractTopics`, `topicsReport` | `--topics`. |
| `WhatsAppExporter.main` | Entry point that wires the modes together. |

### Database tables and fields used

| Table | Used for |
| --- | --- |
| `ZWACHATSESSION` | Chats: JID, partner name, type (0 individual, 1 group, 2 broadcast, 3 status, 4 community), archived flag. |
| `ZWAMESSAGE` | Messages: date, sender flag, type, text, push name, starred flag, links to media/group member. |
| `ZWAGROUPMEMBER` | Sender JID and contact name of a group message. |
| `ZWAMEDIAITEM` | Media path, title, vCard name, coordinates, file size, duration. |
| `ZWAPROFILEPUSHNAME` | JID to push-name fallback (optional table). |

Dates are Core Data timestamps: seconds since **2001-01-01 UTC**.

### Adding a new mode

1. Add a flag to `Options` and parse it in `parseArguments`.
2. Add a line to `usage()`.
3. In `WhatsAppExporter.main`, add the mode next to the `--stats` / `--topics` branch (the chats
   have already been filtered and, if requested, narrowed down by `--party` at that point).
4. Reuse `senderName` / `chatTitle` so every mode names people the same way.

## Known limitations

- **Text only for topics.** Voice notes, images and other media are invisible to `--topics`.
- **Single-word topics.** Topics are single nouns; multi-word concepts are split, and near-synonyms
  ("job", "office") are separate topics.
- **Generic nouns** rank high in some languages until you add them to `--ignore`.
- **Language mixing.** Chats that mix languages are analysed with one language model.
- **Sender names can collide.** Two group members with the same display name are counted as one
  sender, and a contact literally named "Me" would merge with your own messages.
- **Schema dependence.** The tool targets the Core Data schema used by current WhatsApp versions.
  A future schema change may require updating the SQL.
- **Deleted/expired media** is exported as a placeholder only.

## Ideas for future work

- Rank topics by **distinctiveness** against all other chats, so generic words drop out
  automatically instead of needing `--ignore`.
- Merge near-duplicate topics with word embeddings (`NLEmbedding`).
- Support multi-word (noun-phrase) topics.
- Topic **timelines** (topic mentions per month per sender).
- Optional local-LLM backend (for example through a local server) for richer topic and tone
  analysis, kept strictly opt-in and on-device.
- CSV/JSON output for `--stats` and `--topics`.