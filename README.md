<p align="center">
  <img src="extension/icon.png" width="128" height="128" alt="apple-messages-mcp icon">
</p>

# apple-messages-mcp

A local MCP server, written in Swift, that gives Claude read access to the Messages
database on this Mac, and a confirmed path for sending a message through the Shortcuts
app. It ships as a Claude extension.

Reading and sending take different routes, with different failure modes and different
permissions. Reading opens `~/Library/Messages/chat.db` directly, read-only and
immutable — there is no framework for Messages, so the database is the only complete
source, and it costs the broadest permission on the Mac, Full Disk Access. Sending goes
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

**The database is opened `mode=ro&immutable=1`.** Read-only alone still takes locks and
can touch the write-ahead log; `immutable=1` goes further and promises SQLite the file
will not change underneath it, so it opens no journal and writes nothing at all. This
server cannot alter Messages' own storage. The price is honest: writes Messages has not
yet checkpointed are not visible, so the newest message can be briefly missing —
`messages_status` reports that rather than letting it read as data loss.

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

That builds a universal (arm64 + x86_64) release binary, signs it, checks the embedded
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
the child cannot inherit Claude.app's own permissions. The embedded
`Resources/Info.plist` carries the usage description the Shortcuts path needs. If no
prompt ever appears:

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
- **The newest message can be briefly absent.** `immutable=1` means writes Messages has
  not yet checkpointed to disk are invisible to this server. `messages_status` reports
  this state rather than it looking like the message was never sent.
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

20 tests, all against an in-memory fake (`FakeMessageStore`) — no Full Disk Access, no
real database, and no message ever leaves the process. See `CLAUDE.md`, whose first
section is the hard rule that makes that non-negotiable: agents in this repository may
never send a message or read the owner's real conversations, by any route.

Manual verification against a real database and a real send is the owner's job, done by
hand with MCP Inspector; `verification.md` is the script for it.

## Licence

MIT.
