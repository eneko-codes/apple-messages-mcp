# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Data rule

No tool modifies or deletes an existing message. `send_message` requires `confirm=true`; test sends should be clearly marked `TESTING: ...` and only go to the owner's own number.

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
