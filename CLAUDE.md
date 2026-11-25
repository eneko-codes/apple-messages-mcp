# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Data rule

No tool modifies or deletes an existing message. `send_message` requires `confirm=true`.

**Tests run against fakes** — in-memory doubles, fixtures, data invented for the test. Never the owner's real conversations, and never out of convenience: the suite exists to catch breaking changes and does not need real data to do that.

**Debugging against live data is legitimate, but it is the owner's call, not yours.** Never decide it alone. Ask in chat as an explicit choice they can pick — not a remark inside a longer message — saying exactly what you will run, exactly which live data it would touch, and what it would create, change or delete and whether that is undoable. A yes covers that run only; a wider or different check needs a fresh question.

**Read paths have a gentle route: `SystemMessageStore` takes a `databasePath`,** so work on a copy of `chat.db` together with its `-wal` and `-shm` files under a temporary directory you made yourself — never the live file — and delete it in the same session. A send has no copy equivalent: it either reaches a real number or it does not happen, so it needs the ask above every time, must be marked `TESTING: ...`, and must go only to the owner's own number.

## What this is

A local MCP server (Swift 6, stdio transport) for Messages. Reads come from `~/Library/Messages/chat.db` (read-only, through the write-ahead log); sending goes through a Shortcuts app shortcut. No network, no credential, no cloud API. There is **no third-party dependency**: `Package.swift` lists none, and the MCP protocol (JSON-RPC over stdio) is `MCPServer.swift` over Foundation. Adding a package needs the owner's say-so.

**`MCPServer.swift`, `Value.swift`, `ToolStandard.swift` and the tests `MCPProtocolTests.swift` and `ToolStandardTests.swift` are copied unchanged into every one of the owner's MCP servers** (the test files differ only in their `@testable import`). A change to one is made to every copy in the same piece of work; never let a copy drift.

`ToolStandard.swift` holds what every tool here must keep to: the longest result, description and error, the time a call may take, the fixed wording of each notice that says what a result left out (`Notice`), and the guard `MCPServer.swift` passes every result through. A tool bounds its own result and says how to get the rest; the guard only catches the one that forgot.

## APIs

No Apple framework covers Messages. Reads are the [SQLite C API](https://www.sqlite.org/c3ref/intro.html) against `chat.db`, opened read-only through a [URI filename](https://www.sqlite.org/uri.html) and read through its [write-ahead log](https://www.sqlite.org/wal.html); POSIX `open(2)` plus `errno` is the only way to tell a Full Disk Access denial from a missing file, since macOS exposes no API for that. Sending runs `/usr/bin/shortcuts` through `Foundation.Process`.

## Surface not used

- FTS and `MATCH`. Newer rows keep their text in a typed-stream `attributedBody` blob that SQL cannot search, so matching happens in Swift after decoding.
- `immutable=1` while the file is in use: it skips the write-ahead log and hides the newest messages. It is used only when no `-wal`/`-shm` pair exists, i.e. nothing has the database open. Also not used: the online-backup, blob, authorizer and busy-handler APIs.
- Every Apple-event API. This server drives no app, and `NSAppleEventsUsageDescription` is declared only because a prompt raised by the `shortcuts` subprocess may be attributed to this binary.
- The database is Apple's private schema, undocumented and free to change: `PRAGMA table_info` checks the columns before trusting them.

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

**Apple silicon only, deliberately.** `scripts/pack.sh` builds for arm64 alone — a plain `swift build -c release`, no `--arch` flags — and fails if the binary
holds any other architecture. A universal build doubles the bundle for an architecture
macOS 26 is the last release to support. Do not add an x86_64 slice back.

**How a tool keeps to the tool standard here.** Sizes are constants in `Configuration`, and the schemas, the descriptions and the instructions quote them by interpolation, never as literals; `extension/manifest.json` cannot, so `ManifestTests` holds its figures to the same constants. `Arguments.int` moves a quantity (`limit`, `offset`) into its range and collects the sentence that says so in `notices`; an id outside `Configuration.identifierRange` is refused, because the nearest one would name another row, and so is a list of more ids than `maximumMessageIDs`. A number sent as text is refused, an id as much as a limit. `conversations_list`, `conversation_get` and `messages_search` are paged by the store, which reads no more rows than the page needs, and `MessageTools.page` puts the notices and the page's position (`Notice.page`) before the data; `message_attachments` sorts every row and goes through `ToolStandard.page`. Both halve a page whose text would still be longer than a result may be, so a tool never leans on the guard. `Format` renders rows and never a notice.

**A search pages and stops at the source.** `SystemMessageStore.search` reads one match more than the page holds, to know whether another page exists without counting the rest, and at most `Configuration.scanLimit` rows. The date range is pushed into SQL a second wider at each end and settled in Swift, so a search for an old period starts there instead of spending the ceiling on newer rows. When the ceiling stops a scan the result names the `to_date` that goes on from the oldest row read (`Notice.scanStopped`). `to_date` is inclusive at the precision it is written in: `ParsedDate.end` is the first moment after the day, minute or second named.

**No tool reads one message in full.** A row clips a message's text to `Configuration.textWidth`, and `Format.clippedNotice` says so in its own words, because `Notice.clipped` names a tool that does not exist here. Adding that tool is the owner's decision: each tool is a permission switch. The text is the only field a row clips. A name, a participant list or an address is shown whole however long, since nothing else would return the rest of it; a page of such rows holds fewer of them instead.

**Every call has a deadline.** `MessageTools.handle` abandons a call after `defaultTimeout`, inside `ToolStandard.timeLimit`. Below it, `SystemMessageStore.run` stops the `shortcuts` subprocess at its own, shorter deadline; it drains each pipe on its own thread, because a read on the waiting thread would only return when the subprocess closes its end, which a shortcut stuck on a dialog never does.

## Diagnostics

Logs go to stderr through `Diagnostics`, which the host captures (Claude Desktop writes it to `~/Library/Logs/Claude/mcp-server-<name>.log`). stdout is the JSON-RPC stream: never `print`. The API takes no free-form text on purpose. Do not add one, and do not log an argument, a result, an error's `localizedDescription` or an identifier; log a fixed event, the tool name, the error's kind and a duration.
