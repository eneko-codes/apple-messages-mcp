# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Data rule

No tool modifies or deletes an existing message. `send_message` requires `confirm=true`.

**Tests run against fakes** — in-memory doubles, fixtures, data invented for the test. Never the owner's real conversations, and never out of convenience: the suite exists to catch breaking changes and does not need real data to do that.

**Debugging against live data is legitimate, but it is the owner's call, not yours.** Never decide it alone. Ask in chat as an explicit choice they can pick — not a remark inside a longer message — saying exactly what you will run, exactly which live data it would touch, and what it would create, change or delete and whether that is undoable. A yes covers that run only; a wider or different check needs a fresh question.

**Read paths have a gentle route: `SystemMessageStore` takes a `databasePath`,** so work on a copy of `chat.db` under a temporary directory you made yourself — never the live file — and delete it in the same session. A send has no copy equivalent: it either reaches a real number or it does not happen, so it needs the ask above every time, must be marked `TESTING: ...`, and must go only to the owner's own number.

## What this is

A local MCP server (Swift 6, stdio transport) for Messages. Reads come from `~/Library/Messages/chat.db` (read-only, immutable); sending goes through a Shortcuts app shortcut. No network, no credential, no cloud API.

## Commands

```bash
swift build
swift build -c release
swift test
```

```bash
otool -P .build/release/apple-messages-mcp | grep NSAppleEventsUsageDescription
```
