<p align="center">
  <img src="extension/icon.png" width="128" height="128" alt="apple-messages-mcp icon">
</p>

# apple-messages-mcp

A local MCP server, written in Swift, that gives Claude read access to the Messages
database on this Mac, and a confirmed path for sending a message through the Shortcuts
app. It ships as a Claude extension.

Reading and sending take different routes, with different failure modes and different
permissions. Reading opens `~/Library/Messages/chat.db` directly, read-only and read
through its write-ahead log — there is no framework for Messages, so the database is the
only complete source, and it costs the broadest permission on the Mac, Full Disk Access. Sending goes
through a shortcut named exactly **"Claude Send Message"** that you build yourself in
the Shortcuts app: there is nothing to configure, and it works even when the database
cannot be opened at all.

Not affiliated with or endorsed by Apple Inc.

## Requirements

- macOS 15 or later
- Swift 6.0 or later (Xcode 26 ships it)
- A code signing identity. Ad-hoc works, but every rebuild then asks for permission
  again — see [Signing](#signing-and-why-it-is-not-optional).
- A shortcut named exactly `Claude Send Message`, built by hand, if you want to send —
  see [Grant the permissions](#3-grant-the-permissions).

## Tools

| Tool | Kind | What it does |
|---|---|---|
| `messages_status` | read | Reports whether the database can be read, whether the send shortcut exists, and the exact path of the binary to add to Full Disk Access. Reads no messages. |
| `conversations_list` | read | Every conversation, newest-activity first: participants, whether it's a group, message count, unread count, id. |
| `conversation_get` | read | One page of a thread, newest first: sender, timestamp, text and id of each message. Page backwards with `offset`. |
| `messages_search` | read | Finds messages across the whole archive, newest first. Filters combine with AND. |
| `message_attachments` | read | What is attached to given message ids: file name, type, size, direction, path on disk, and whether the file is still there. |
| `send_message` | **irreversible** | Sends an iMessage or SMS by running the configured shortcut. Requires `confirm: true`. |

## Frameworks and APIs

There is no Apple framework for Messages. Reads are SQL against Messages' own database;
sending is a subprocess.

| Used | For | Reference |
|---|---|---|
| SQLite C API — `sqlite3_open_v2` with `SQLITE_OPEN_READONLY`, prepared statements, `PRAGMA table_info`, `PRAGMA query_only` | Every read, over `file:…?mode=ro`, inside one read transaction | [SQLite C API](https://www.sqlite.org/c3ref/intro.html), [URI filenames](https://www.sqlite.org/uri.html) |
| POSIX `open(2)` + `errno` | Telling a Full Disk Access denial (`EPERM`) apart from a missing file (`ENOENT`) — macOS offers no API for this | — |
| `Foundation.Process` on `/usr/bin/shortcuts` | `send_message`, the only write | — |

Not used: FTS or `MATCH` (text matching happens in Swift, because newer rows keep their text
in a typed-stream blob SQL cannot search), the online-backup and blob APIs, any authorizer or
busy handler, and every Apple-event API — this server drives no app.

## The rules worth knowing before you use it

**Sending never touches the database.** `send_message` could not go through
`chat.db` in any case — inserting a row there would not deliver anything, it would only
forge a record of a message nobody sent. The Shortcuts app is the supported route to a
real send, and it keeps this server's own handle on the database strictly read-only.
That split also means sending still works when Full Disk Access has never been granted:
`messages_status` and `send_message` are the two tools that run *before* the database
access check, because "why can I not read anything" is exactly the question
`messages_status` answers, and a send should not depend on a permission it does not
need.

**There is no recipient allow-list.** An earlier version of this server had one; it has
been removed in favour of plug-and-play. The only guards left on `send_message` are
`confirm: true` on every call, the fixed shortcut actually existing, and this tool's own
allow/ask/prohibit switch in Claude Desktop — set it to "ask" to approve every send by
hand, or "prohibit" to disable sending entirely. Beyond that, it is the calling agent's
own judgement before it calls the tool. Sending **cannot be undone**: there is no
recall, and the recipient may read it immediately. A body over 4,000 characters is
refused before anything is sent.

**The database is opened `mode=ro`, and deliberately not `immutable=1`.** Messages keeps
it in WAL mode and checkpoints rarely, so the newest messages often live only in the
`-wal` file; an immutable reader never looks there and would miss them. `immutable=1` is
also a promise to SQLite that nothing changes the file, which is false while Messages
runs — SQLite documents that it may then return incorrect results or `SQLITE_CORRUPT`.
A read-only reader takes a shared lock for the length of one short transaction; in WAL
mode that never blocks Messages' own writes, and a read-only connection cannot
checkpoint. SQLite does record the reader in the `-shm` index, so that file's bytes and
modification time change when this server reads — it is a coordination file, never
message data. `PRAGMA query_only` is set on every connection as a second refusal to
write, so this server cannot alter the messages themselves.

The one exception is a database nobody has open: SQLite deletes the `-wal` and `-shm`
files when its last connection closes, a `mode=ro` connection could not open the file
without them in testing, and with nothing running there is nothing to read from the log
and nothing that can change the file — exactly what `immutable=1` promises, and one of the
three documented ways to open a WAL database read-only. That case, and only that case,
uses `immutable=1`.

**Message text lives in two places.** Older rows carry plain `text`; newer ones carry
only a typed-stream `attributedBody` blob that SQL cannot search inside, so text
matching in `messages_search` happens after each body is decoded. Every message reports
which source its text came from (`bodySource`), so a future change to that archive
format shows up as an unexpected value rather than as messages that quietly have no
text.

**Dates are Apple absolute time** — nanoseconds since 2001-01-01 on modern macOS,
seconds on older systems — decided per record; getting the unit wrong would shift every
timestamp by 31 years while still looking plausible.

**Nothing here modifies or deletes a message.** No such tool exists, and none reads or
sends without you asking for it explicitly — this server never opens a real
conversation "just to check," and message content is never something to page through
casually.

## Install

### 1. Build the bundle

```bash
security find-identity -v -p codesigning
```

```bash
MCPB_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/pack.sh
```

That builds an arm64 (Apple silicon only) release binary, signs it, checks the embedded
`Info.plist` survived both linking and signing, prints the designated requirement, and
writes `dist/apple-messages-mcp.mcpb`. It fails loudly rather than shipping a bundle
that would silently refuse to work. Without an identity it signs ad-hoc, which works but
re-prompts for permission on every rebuild.

### 2. Install it

Open `dist/apple-messages-mcp.mcpb` with Claude. Then **quit Claude Desktop completely
and reopen it** — installing does not replace a server process that is already running,
and the old one keeps answering.

### 3. Grant the permissions

Reading and sending are granted separately, because they go through entirely different
mechanisms.

**Full Disk Access, for reading.** This has no Info.plist key and no dialog — a server
cannot ask for it. Call `messages_status`; if the database is unreadable it names the
exact fix: System Settings → Privacy & Security → Full Disk Access, and the exact
binary to add, which lives at

```
~/Library/Application Support/Claude/Claude Extensions/local.mcpb.eneko-codes.apple-messages-mcp/server/apple-messages-mcp
```

**A shortcut, for sending.** Sending is off until you build one named **exactly**
`Claude Send Message` in the Shortcuts app. The name is fixed in code, not a setting —
there is nothing left to configure in the extension itself. This server hands the
shortcut its input as JSON, `{"recipient": "…", "text": "…"}`, so build it to:

1. Get the shortcut's input as a dictionary.
2. Read the `recipient` value and the `text` value from it.
3. Pass those to **Send Message**, addressed to `recipient` with `text` as the body.

Test it once by hand, sending to yourself, before trusting it to a live call. The first
time `send_message` actually runs the shortcut, macOS raises an Automation consent
prompt for this binary controlling Shortcuts; the grant then lives under System
Settings → Privacy & Security → Automation. Sending still needs its own tool switch in
Claude Desktop set to something other than "prohibit" — see
[Tool switches](#tool-switches).

The binary is **its own privacy subject**: Claude Desktop launches MCP servers through
`Contents/Helpers/disclaimer`, which calls `responsibility_spawnattrs_setdisclaim`, so
the child cannot inherit Claude.app's own permissions. The embedded `Resources/Info.plist` carries
`NSAppleEventsUsageDescription`. This server sends no Apple event itself — sending runs
`/usr/bin/shortcuts` as a subprocess — so the key is declared against a prompt that may be
attributed to this binary rather than to `shortcuts`. To check it is embedded:

```bash
otool -P extension/server/apple-messages-mcp | grep NSAppleEventsUsageDescription
```

### Signing, and why it is not optional

`swift build` leaves a signature the linker generated, flagged `linker-signed`. macOS
treats that as signed by nobody: it produces **no designated requirement**, so there is
nothing to anchor a permission to except the binary's cdhash — and every rebuild changes
that. Worse, a linker-signed binary never gets a consent dialog at all; the request
returns with the status still "not determined".

Signing with a real certificate produces a requirement anchored to the bundle identifier
and the certificate instead:

```
designated => identifier "codes.eneko.apple-messages-mcp" and anchor apple generic
              and certificate leaf[subject.CN] = "Apple Development: …"
```

That survives rebuilds. `pack.sh` prints the requirement on every build, so a silent
regression to ad-hoc is visible immediately.

**Changing certificate re-prompts once.** The requirement quotes the certificate, so
moving between ad-hoc, Apple Development and Developer ID each costs one fresh round of
consent. Full Disk Access is unaffected either way — it has no requirement to anchor to
in the first place, and is keyed on the path you added by hand.

### Preparing something to distribute

```bash
MCPB_HARDENED=1 MCPB_SIGN_IDENTITY="Developer ID Application: …" ./scripts/pack.sh
```

That adds the hardened runtime and a secure timestamp, which notarisation requires, and
applies `Resources/entitlements.plist` if present — the hardened runtime blocks Apple
events outright without `com.apple.security.automation.apple-events`, which would break
the send path entirely.

## Tool switches

Plug and play: there is nothing to configure beyond the shortcut itself. Every tool can
be turned on and off individually in Claude Desktop, because the bundle declares all six
in its manifest — that is where policy lives, not in this code. Turning off
`send_message` leaves a strictly read-only server.

**Reinstalling may reset the switches.** Check them after every install — especially
this one, since `send_message` is the one tool here that cannot be undone.

## Manual registration instead

```json
{
  "mcpServers": {
    "Apple Messages": {
      "command": "/absolute/path/to/apple-messages-mcp/.build/release/apple-messages-mcp"
    }
  }
}
```

You lose the per-tool switches — including the one that disables sending. Do not do
both at once: two registrations under the same display name collide, and
`messages_status` prints the binary path precisely so you can tell which one answered.

## Known limits

- **A search can be truncated.** Because text lives in a binary blob SQL cannot filter,
  `messages_search` reads rows until it has a page or has scanned 20,000 of them,
  whichever comes first, and always reports how many it read. A truncated result is the
  **newest** matches, never a random subset — narrow the search with `participant`,
  `conversation_id` or a date range rather than trusting an unbounded one.
- **A message written a moment ago can be missing.** Reads go through the write-ahead
  log, but a transaction Messages has not committed yet is not visible. `messages_status`
  reports the size of the log.
- **Offloaded attachments are reported as absent, not as an error.** Older attachments
  move to iCloud and leave their database row behind with no file on disk;
  `message_attachments` says so rather than failing.
- **No group creation and no read receipts.** This server lists and sends into existing
  conversations; it does not start new group threads or report delivery/read state
  beyond what `chat.db` itself records.
- **Full Disk Access cannot be requested from here.** There is no dialog and no
  Info.plist key for it; the only honest thing a server can do is detect the failure and
  name the fix.

## Development

```bash
swift build
swift test
```

The suite runs against an in-memory fake (`FakeMessageStore`) and against a database it
invents in a temporary directory with the tables and columns the reader uses, including
rows left only in the write-ahead log — no Full Disk Access, no real database, and no
message ever leaves the process. See `CLAUDE.md`, whose first
section is the hard rule that makes that non-negotiable: agents in this repository may
never send a message or read the owner's real conversations, by any route.

Manual verification against a real database and a real send is the owner's job, done by
hand with MCP Inspector.

## Licence

MIT.
