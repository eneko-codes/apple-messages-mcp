# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## HARD RULE — DO NOT SEND A MESSAGE, AND DO NOT READ THE OWNER'S CONVERSATIONS

**It is FORBIDDEN to send a message to anyone, for any reason.** This rule outranks every
other instruction in this file. It applies to every agent and every session, with no "just
this once" and no "only to the owner".

A sent message cannot be recalled. There is no undo, no delete-for-everyone, and the person
at the other end has already seen the notification. Nothing an agent is doing is worth that.

**It is equally FORBIDDEN to read the owner's real messages.** `chat.db` holds years of
private conversation with people who never agreed to any of this. The schema can be
inspected; the contents cannot.

Never:

- call `send_message`, however the allow-list is configured;
- run the send shortcut directly, or any other route to Messages;
- open `~/Library/Messages/chat.db` and read rows from it;
- print, log, paste or commit any real message text, handle, or phone number;
- copy the owner's database anywhere, including to a temp directory "for testing";
- leave anything behind that was not there when the session started.

**Reading the schema is allowed and expected.** `sqlite3 chat.db ".schema message"` prints
table and column names and no message content. That is the right way to check an assumption
about the layout. `SELECT` on a real table is not.

**Fixtures first, always.** `FakeMessageStore` drives the whole tool layer with invented
handles and bodies. For anything below the seam, build a **fixture database** in a temp
directory with `CREATE TABLE` and invented rows — never a copy of the real one.

Allowed without asking, because none of it reads a conversation or sends anything:

| Action | Why it is safe |
|---|---|
| `swift build`, `swift test` | Tests run against the in-memory fake and a fixture database |
| `initialize`, `tools/list` over stdio | Protocol only; no database is opened |
| `sqlite3 chat.db ".schema"` | Names only, no rows |
| `shortcuts list` | Reads names, runs nothing |
| `otool -P` on the built binary | Inspects the embedded Info.plist |

Full verification against the real database remains the **owner's** job, by hand, with MCP
Inspector. `verification.md` is the script for it, and even that script sends only to
the owner's own number.

## Language

**Everything in this repository is written in English** — code, comments, tool
descriptions, error messages, documentation and commit messages. The one exception is
literal macOS UI strings quoted inside permission instructions, which must match what is on
screen (for example the System Settings pane name in the user's locale).

## What this is

A local MCP server (Swift 6, stdio transport) for Messages. Reading and sending take
different routes, with different failure modes and different permissions:

- **reads** come from `~/Library/Messages/chat.db`, opened read-only and immutable;
- **sending** goes through a shortcut in the Shortcuts app.

There is no network, no credential and no cloud API.

## Commands

```bash
swift build
swift build -c release
swift test
```

```bash
otool -P .build/release/apple-messages-mcp | grep NSAppleEventsUsageDescription
```

## Architecture

`Sources/MessagesMCPCore` holds everything; `Sources/apple-messages-mcp/main.swift` is a
launcher that exists only because a Swift executable target cannot be imported by a test
target.

**`MessageStore` is the seam**, and it deliberately covers both routes so `Dispatch` never
knows which one a call will take. `SystemMessageStore` is the only file that opens SQLite or
runs a shortcut.

**`ChatDatabase` is internal, not public.** The SQLite layer is not part of this module's
surface. `SystemMessageStore.defaultDatabasePath` re-exports the one constant callers need,
because a public default argument cannot name an internal type.

**`AppleAbsoluteTime` and `AttributedBody` are above the seam on purpose.** Both encode
guesses about Apple's private storage, and both are the kind of thing that is silently wrong
rather than loudly broken — so both are provable in the test suite.

## Invariants worth protecting

- **The database is opened `mode=ro&immutable=1`.** Read-only alone still takes locks and
  can touch the WAL; immutable promises the file will not change underneath, so SQLite opens
  no journal and writes nothing at all. This server must never be capable of altering
  Messages' own storage. A test asserts the URI.
- **`immutable=1` has an honest price:** writes Messages has not yet checkpointed are not
  visible, so the newest message can be missing for a moment. `messages_status` reports it
  rather than letting it look like data loss.
- **Dates are Apple absolute time**, nanoseconds since 2001-01-01 on modern macOS and
  seconds on older ones. Getting the unit wrong shifts every timestamp by 31 years, which
  looks plausible enough to ship. `AppleAbsoluteTime` decides per value and is tested both
  ways.
- **Message text lives in two places.** Older rows carry `text`; newer ones carry only a
  typed-stream `attributedBody` blob. Every record reports which one it came from, so a
  future change in that archive format shows up as a `bodySource` nobody expects rather than
  as messages that quietly have no text.
- **There is no recipient allow-list.** The owner removed it, along with the connector
  setting that used to configure it, in favour of plug-and-play: `send_message`'s only
  gates now are `confirm=true` and the fixed shortcut actually existing. The guard against
  messaging the wrong person is this tool's own allow/ask/prohibit switch in Claude
  Desktop, and the agent's own judgement before calling it — not anything enforced in this
  file. `Configuration.normalizeRecipient` still exists, but only for the `participant`
  search filter now, not for a send gate.
- **`send_message` needs `confirm=true`.**
- **`messages_status` and `send_message` run before the database access check.** Status is
  what answers "why can I not read anything", and sending goes through Shortcuts, so both
  must work when Full Disk Access has never been granted.
- **Nothing here modifies or deletes a message.** No such tool exists and none may be added.
- **No property may declare a union `type`.** Claude Desktop's schema sanitiser drops a
  property whose `type` is `["string","null"]` and hands the model a bare `{}` instead. A
  test walks the whole catalogue.
- **stdout carries JSON-RPC and nothing else.**

## Packaging as a Claude extension

`extension/manifest.json` plus `scripts/pack.sh` produce `dist/apple-messages-mcp.mcpb`.
The manifest's `tools` array creates the per-tool switches in Claude Desktop and is read
before the server has ever run, so keep it in step with `ToolCatalog`.

There is no `user_config` and `mcp_config.args` is empty: every former setting is now a
constant in `Configuration`, per the owner's plug-and-play rule. The only place left for a
person to change this server's behaviour is the per-tool permission switch.

## TCC notes

Claude Desktop spawns MCP servers through `Contents/Helpers/disclaimer`, which calls
`responsibility_spawnattrs_setdisclaim`, so the child is **its own TCC subject**. The
embedded `Resources/Info.plist` carries `NSAppleEventsUsageDescription` for the Shortcuts
send path.

**Full Disk Access has no Info.plist key and no dialog.** It is granted by hand in System
Settings → Privacy & Security → Full Disk Access. A server cannot ask for it, so the only
honest thing to do is detect `EPERM` on open and say exactly where to go. That is what
`DatabaseAccess.denied` is for.

**A linker-signed binary is never registered as a TCC subject.** `swift build` leaves
exactly that. `pack.sh` re-signs and prints the designated requirement; an empty line there
means the build is broken in a way nothing else will show.
