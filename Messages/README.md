# messages-exporter

A small, dependency-free macOS command-line tool (Swift) that reads the local Apple Messages
database (`chat.db`, iMessage and SMS) and can:

1. **Export** every conversation to a readable, one-file-per-conversation text transcript.
2. **Count messages** per sender per day, ISO week and month (`--stats`).
3. **Extract the main topics** of a conversation, with who talks about them and when (`--topics`).

Everything runs locally. The tool never touches the network, never modifies your Messages data,
and the topic extraction uses Apple's on-device NaturalLanguage framework (no cloud, no model download).

> `messages-exporter` has **exactly the same command-line options** as its sibling
> `whatsapp-exporter`, so the commands you know from one work unchanged on the other.
> See [Shared CLI with whatsapp-exporter](#shared-cli-with-whatsapp-exporter).

---

## Contents

- [Requirements](#requirements)
- [Build and install](#build-and-install)
- [Where the database lives](#where-the-database-lives)
- [Quick start](#quick-start)
- [Command-line reference](#command-line-reference)
- [Shared CLI with whatsapp-exporter](#shared-cli-with-whatsapp-exporter)
- [Selecting a chat with `--party`](#selecting-a-chat-with---party)
- [Export mode](#export-mode)
- [Statistics mode (`--stats`)](#statistics-mode---stats)
- [Topic mode (`--topics`)](#topic-mode---topics)
- [Time zones](#time-zones)
- [Privacy and safety](#privacy-and-safety)
- [Troubleshooting](#troubleshooting)
- [Project layout and internals](#project-layout-and-internals)
- [Known limitations](#known-limitations)
- [Changes from earlier versions](#changes-from-earlier-versions)

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
cd Messages
swift build -c release
```

The binary is produced at `.build/release/messages-exporter`. To use it from anywhere:

```bash
sudo cp .build/release/messages-exporter /usr/local/bin/
messages-exporter --help
```

Or run it without installing: `swift run messages-exporter --stats --party "+39 333 123 4567"`.

## Where the database lives

If you don't pass a database path, the tool looks, in order, for:

1. `~/Library/Messages/chat.db`
2. `./chat.db` (current directory)

You can also pass any `chat.db` path explicitly, for example a copy from another Mac.

**macOS privacy protection:** `~/Library/Messages` is protected. If you see
`Operation not permitted`, grant your terminal app **Full Disk Access**
(System Settings > Privacy & Security > Full Disk Access), then restart the terminal.

## Quick start

```bash
# Export all conversations to ./messages_export/ (newest message first)
messages-exporter

# Same, but oldest message first, with "Marco" as the label for your own messages
messages-exporter --oldest-first --me Marco

# Message counts per sender (daily / weekly / monthly) for one conversation
messages-exporter --stats --party "+39 333 123 4567"

# The 20 most-discussed topics of one conversation
messages-exporter --topics 20 --party "Weekend Trip"

# Stats and topics together, saved to a file (reports go to stdout)
messages-exporter --stats --topics --party "Weekend Trip" > trip-report.txt
```

## Command-line reference

```
messages-exporter [DB] [-o|--output DIR] [--me NAME] [--oldest-first] [--utc]
                  [--include-status] [--party NAME] [--stats]
                  [--topics [N]] [--lang CODE] [--ignore WORD,WORD,...]
```

| Option | Description |
| --- | --- |
| `DB` | Path to `chat.db`. Auto-detected if omitted (see above). |
| `-o`, `--output DIR` | Output directory for the export (default `./messages_export`). `--out` is accepted as an alias (it was the original spelling). Ignored with `--stats` / `--topics`. |
| `--me NAME` | Label for your own messages in exports and reports (default `Me`). |
| `--oldest-first` | Export messages oldest to newest. The default is **newest first**. Affects the export only. |
| `--utc` | Use UTC instead of local time, both for timestamps and for day/week/month boundaries. |
| `--include-status` | Accepted for compatibility with `whatsapp-exporter` and **ignored**: Messages has no status pseudo-chats. |
| `--party NAME` | Process only one conversation. Matches the group name, phone number, e-mail address or chat identifier. See [below](#selecting-a-chat-with---party). Works with and without `--stats`. |
| `--stats` | Print message counts per sender per day, ISO week and month instead of exporting. Covers every conversation unless `--party` is given. |
| `--topics [N]` | Print the `N` (default 15) most-discussed topics of one conversation. **Requires `--party`.** |
| `--lang CODE` | Language of the chat for `--topics`, e.g. `it`, `en`, `es` (default: auto-detect). |
| `--ignore W1,W2,...` | Comma-separated nouns to exclude from `--topics` (case- and accent-insensitive). |
| `-h`, `--help` | Show usage. |

Notes:

- `--stats` and `--topics` can be combined; the stats report is printed first.
- In `--stats` / `--topics` mode the report goes to **stdout** and the `Reading: ...` line goes to
  **stderr**, so redirecting (`> file.txt`) captures a clean report.
- Errors are printed to stderr as `error: ...` and the exit status is `1`.

## Shared CLI with whatsapp-exporter

`messages-exporter` and `whatsapp-exporter` accept **exactly the same options**, with the same
meaning and the same help text (apart from the program name, the source database and the default
output directory). Commands therefore transfer 1:1:

```bash
messages-exporter --stats --party "+39 333 123 4567" --utc
whatsapp-exporter --stats --party "Ana" --utc
```

Differences that come from the data, not from the options:

| | messages-exporter | whatsapp-exporter |
| --- | --- | --- |
| Source database | `chat.db` | `ChatStorage.sqlite` |
| Chat names | numbers, e-mails and group names only (no Contacts lookup) | contact names from WhatsApp |
| `--include-status` | accepted, no effect | includes status pseudo-chats |
| Transcript layout | header with participants, blank-line-separated messages | header with `JID`/`Range`, day separators, one line per message |
| `--party` ID | chat identifier / phone number / e-mail | JID / phone number |

When you add or change an option, change it in both tools so the contract stays identical.

## Selecting a chat with `--party`

`--party NAME` always resolves to **exactly one** conversation. A conversation is everything that
shares one chat identifier, so the iMessage thread and the SMS thread with the same number are one
conversation.

1. Matching ignores case, accents and width differences.
2. A conversation matches if `NAME` equals (or, in the fallback step, is contained in) its **title**
   (the group name, or the number/e-mail for one-to-one chats), its **chat identifier**
   (`+393331234567`, `ana@example.com`, or `chat123456789` for groups), or the **phone number**
   written with any separators: `"+39 333 123 4567"` works.
3. An **exact** match wins. If there is none, a **partial** match is accepted only if it is unique.
   The partial step also looks at the **participants** of group chats, so a number that has no
   one-to-one conversation can still find the single group it belongs to.
4. If several conversations match, the tool lists them (with their identifiers) and asks you to be
   more specific:

   ```
   error: '+393339998888' matches 2 chats:
     - chat999  [chat999]
     - Weekend Trip  [chat555]
   Use a longer name, the phone number, the e-mail address or the full chat identifier to pick one.
   ```

Messages' database does not store contact names (they live in the Contacts app), so you select by
number, e-mail address or group name. Groups without a name are known by their `chatNNN...`
identifier; matching on a participant's number is usually the easier way to find them.

## Export mode

Run with no mode flag to write one UTF-8 text file per conversation:

```bash
messages-exporter                          # auto-detect DB, write to ./messages_export, newest first
messages-exporter ~/chat.db -o ~/Desktop/chats --utc
messages-exporter --party "Weekend Trip"   # export just one conversation
messages-exporter --oldest-first           # chronological transcripts
```

The final line summarises the run:

```
Wrote 14 conversation file(s), 8120 messages -> /Users/you/messages_export
```

### File naming

- One-to-one: `<identifier>.txt`, e.g. `+393331234567.txt`.
- Groups: `group_<group name or chat identifier>.txt`.
- Characters outside letters, digits and `. + @ -` become `_`; a numeric suffix (`_2`, `_3`, ...)
  resolves any collision.

### Transcript format

```
Conversation: +393331234567
Type:         one-to-one
Participants: Me, +393331234567
Messages:     5
Order:        most recent first
========================================================================

[2026-10-12 00:05:00] +393331234567: Domani lavoro tutto il giorno

[2026-10-11 23:30:00] Me: [attachment: IMG_0001.heic]

[2026-10-05 11:00:00] +393331234567: Hello via blob

[2026-10-05 10:00:00] +393331234567: Ciao! come va?

[2026-10-05 09:00:00] Me: Ciao Ana
```

- Messages are listed **newest first** by default; `--oldest-first` reverses this. The `Order:`
  header line says which one was used.
- Each message is `[timestamp] sender: text`; continuation lines of a multi-line message are
  indented under the first line.
- Attachments appear as `[attachment: name1; name2]`, after any text of the same message.
- Your own messages are labelled `Me`, or whatever you pass to `--me`. Other senders are shown by
  their number or e-mail address.

### What is included and what is not

- **Included:** messages with text and/or attachments. Text that macOS stores only inside the
  `attributedBody` blob (common on recent macOS versions) is decoded.
- **Left out:** tapbacks/reactions (`associated_message_type`), group events such as people
  joining or leaving (`item_type`), and messages that have neither text nor attachments.
- **Merged:** all `chat` rows with the same identifier (iMessage + SMS threads), with messages
  de-duplicated by their row id.

## Statistics mode (`--stats`)

Counts how many messages each sender wrote per **day**, per **ISO week** (Monday to Sunday,
labelled like `2026-W41 (2026-10-05)` with the Monday date) and per **month**.

```bash
messages-exporter --stats --party "Weekend Trip"
```

Illustrative output (names and numbers are made up):

```
Chat:      Weekend Trip
ID:        chat555
Type:      group
Messages:  412 from 3 senders (tapbacks and system events excluded)
Range:     2026-09-01 07:55:10 -> 2026-11-07 22:03:31 (CET)
========================================================================

Total per sender
----------------
Me                190   46.1%
+393339998888     142   34.5%
+393331234567      80   19.4%

Messages per month
------------------
Month    Me  +393339998888  +393331234567  Total
2026-09  80             60             37    177
2026-10  95             70             37    202
2026-11  15             12              6     33
```

Behaviour worth knowing:

- Each section is a **table** (one row per period, one column per sender, `-` for zero) when the
  conversation has up to **6 senders**. Larger groups would make the table too wide, so each
  period is printed as a short **list** of senders instead.
- Only periods with at least one message are listed.
- **Counted:** messages with text and/or attachments. **Not counted:** tapbacks, group events,
  empty messages, and messages with no valid date (their number is reported in a `Note:` line).
- Without `--party`, every conversation gets its own report, separated by blank lines. For
  long-lived chats the daily section can be long; redirect to a file or pipe through `less`.

## Topic mode (`--topics`)

Lists the topics most discussed in **one** conversation, found entirely on-device.

```bash
messages-exporter --topics --party "Weekend Trip"
messages-exporter --topics 30 --party "+39 333 123 4567" --lang it --ignore cosa,volta,giorno,roba
```

### How topics are found

1. Only **text messages** are used (attachment-only messages, link-only messages, tapbacks and
   group events have no usable text). URLs are stripped and newlines collapsed.
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
Messages:  1180 text messages analysed (attachments, link-only messages, tapbacks and system events skipped)
Range:     2025-01-03 -> 2026-11-07 (CET)
========================================================================
Top 15 topics: nouns found in the most messages (a message counts once per topic)

 1. lavoro  -  87 messages  |  2025-02-11 -> 2026-10-28  |  peak 2026-05 (14)
      +393331234567 47 (54%), Me 40 (46%)
      e.g. [2026-05-12] Me: "Domani riunione con il cliente, devo preparare la presentazione e..."
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
for reproducible results across machines. Weeks follow the **ISO 8601** calendar (Monday-Sunday,
week 1 contains the first Thursday), so a week can belong to a different ISO year than its
calendar year near January 1.

## Privacy and safety

- **Read-only.** The tool copies `chat.db` (plus its `-wal` and `-shm` side files, if present, so
  recent messages are included) into a temporary directory, opens the **copy** read-only, and
  deletes the temporary directory when it exits. Your original database is only ever read by the
  file copy.
- **Local only.** No network access is used anywhere. `--topics` uses on-device NaturalLanguage
  models.
- **Sensitive output.** Transcripts, stats and topic reports contain private conversations
  (including other people's messages). Store and share them accordingly.

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `Operation not permitted` / `Unable to copy chat.db` | Grant your terminal **Full Disk Access** and restart it. |
| `could not auto-detect chat.db` | Pass the database path explicitly as the first argument. |
| `table chat not found - is this a Messages chat.db?` | The file isn't a Messages database, or its schema differs from the one this tool targets. |
| `no chat matches '...'` | Check the spelling or try the phone number / e-mail. Contact names are not available (see above). A plain export (no `--party`) writes one file per conversation, named after its identifier. |
| `'...' matches N chats` | Be more specific: use the full number, e-mail or chat identifier. |
| `--topics works on a single chat: add --party NAME` | `--topics` needs exactly one conversation. |
| `could not detect the chat language` | Pass `--lang`, e.g. `--lang it`. |
| `warning: no part-of-speech model for 'xx'` | macOS has no noun tagger for that language. The tool falls back to all words of 5+ letters, which gives weak topics. Try another `--lang` or add many `--ignore` words. |
| `no analysable text messages in this chat` | The conversation has no plain text messages with a valid date. |
| Message text missing in an export | The text is only in `attributedBody` and could not be decoded; the decoder is best-effort (see limitations). |
| Counts differ from the Messages app | Tapbacks, group events and empty messages are excluded; for `--topics` all non-text messages are too. |

## Project layout and internals

```
Messages/
├── Package.swift                     Swift package manifest (macOS 13+)
├── README.md                         this file
└── Sources/
    ├── CSQLite/                      system-library target exposing sqlite3 to Swift
    │   ├── module.modulemap
    │   └── shim.h
    └── MessagesExporter/
        └── main.swift                the whole CLI
```

`main.swift` is organised in these parts:

| Part | Purpose |
| --- | --- |
| `SQLiteDatabase`, `SQLiteRow`, `SQLiteValue` | Thin read-only wrapper over the C sqlite3 API. |
| `Options`, `parseArguments`, `usage` | Command-line parsing (identical to `whatsapp-exporter`). |
| `resolveDatabase`, `makeSnapshot` | Locating and safely copying the database. |
| `loadConversations`, `fetchMessages` | Conversation grouping and the shared message query used by every mode. |
| `exportConversations`, `exportLine` | Transcript writer. |
| `selectConversation` | `--party` matching. |
| `computeStats`, `renderSection`, `statsReport` | `--stats`. |
| `extractTopics`, `topicsReport` | `--topics`. |
| `MessagesExporter.main` | Entry point that wires the modes together. |

### Database tables used

| Table | Used for |
| --- | --- |
| `chat` | Conversations: `chat_identifier`, `style` (43 = group), `display_name`. Rows sharing an identifier are merged. |
| `handle` | Sender and participant ids (numbers / e-mails). |
| `message` | Text, `attributedBody`, date, `is_from_me`, sender handle, tapback/event markers. |
| `chat_message_join`, `chat_handle_join` | Which messages and participants belong to which chat. |
| `attachment`, `message_attachment_join` | Attachment names. |

Dates are Core Data timestamps (since **2001-01-01 UTC**). Recent macOS versions store
**nanoseconds**, older ones seconds; values above 1e11 are treated as nanoseconds.

### Adding a new mode

1. Add a flag to `Options` and parse it in `parseArguments`.
2. Add a line to `usage()`.
3. In `MessagesExporter.main`, add the mode next to the `--stats` / `--topics` branch (the
   conversations have already been narrowed down by `--party` at that point).
4. Use `fetchMessages` so every mode applies the same inclusion rules and sender labels.
5. Make the same change in `whatsapp-exporter` (options, help text and parser are meant to stay identical).

## Known limitations

- **No contact names.** `chat.db` only has numbers and e-mail addresses; there is no Contacts
  lookup, so reports show numbers and `--party` cannot match a person's name.
- **Unnamed groups** are known by their `chatNNN...` identifier.
- **`attributedBody` decoding is best-effort.** Edited or heavily formatted messages may lose text.
- **Edits, unsent messages and reactions** are not reconstructed; reactions are excluded.
- **Text only for topics.** Photos, audio and other attachments are invisible to `--topics`.
- **Single-word topics.** Topics are single nouns; multi-word concepts are split and near-synonyms
  are separate topics. Generic nouns rank high until you add them to `--ignore`.
- **Sender names can collide.** Two senders with the same label count as one, and a participant
  literally labelled like your `--me` value would merge with your own messages.
- **Schema dependence.** The tool targets the `chat.db` schema of current macOS versions; a future
  change may require updating the SQL.

## Changes from earlier versions

This version brings the tool to feature parity with `whatsapp-exporter` and unifies the CLI:

- **New options:** `--utc`, `--party`, `--stats`, `--topics [N]`, `--lang`, `--ignore`, and
  `--include-status` (accepted, no effect).
- **Renamed:** the output directory option is now `-o` / `--output`; the previous `--out` still
  works as an alias.
- **Unchanged:** `--me`, `--oldest-first`, the newest-first default, the transcript layout and the
  file naming.
- **Behaviour details:** conversations are processed most-recently-active first, and a
  `Reading: <path>` line is printed (to stderr in `--stats` / `--topics` mode).
