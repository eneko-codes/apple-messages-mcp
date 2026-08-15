# Manual verification

Everything below runs against **your real message history**, which is why no agent may run
it (see the hard rule in `CLAUDE.md`). Work through it yourself, in order.

```bash
npx @modelcontextprotocol/inspector ./.build/release/apple-messages-mcp
```

**Every send in this script goes to your own number and nowhere else.** There is no
allow-list to widen any more — the switch below and your own judgement are the whole guard,
so keep this deliberate and never run it while an agent is unsupervised.

## 0 — Before you start

**A send shortcut.** In the Shortcuts app, build one named **exactly** `Claude Send
Message` that takes the shortcut input, splits it into a recipient and a body, and sends an
iMessage. Test it once by hand, to yourself. The name is fixed in code, not a setting —
there is nothing left to configure in the extension itself; the only guard on
`send_message` is its own allow/ask/prohibit switch in Claude Desktop, so leave that on
"ask" while you run this script.

## 1 — The permission that has no dialog

Full Disk Access cannot be requested. Do this before anything else, so you know which
failure you are looking at.

| Step | Call | Expected |
|---|---|---|
| 1.1 | `messages_status` **before** granting Full Disk Access | Reports the database as unreadable and names System Settings → Privacy & Security → Full Disk Access. It does **not** report "no messages". |
| 1.2 | `conversations_list` in the same state | Refused with the same instruction. |
| 1.3 | Grant Full Disk Access to the installed server binary, restart Claude Desktop, `messages_status` | Readable, with conversation and message counts. |
| 1.4 | Read the status output | It states that the database is opened **read-only and immutable**. |

The binary to grant lives at
`~/Library/Application Support/Claude/Claude Extensions/local.mcpb.eneko-codes.apple-messages-mcp/server/apple-messages-mcp`.

Step 1.1 is the important one. A server that answered "no conversations" here would be
indistinguishable from an empty Mac.

## 2 — Dates, which is where this will be wrong if it is wrong

| Step | Call | Expected |
|---|---|---|
| 2.1 | `messages_status` | `dateUnit` reported. On macOS 26 it should be nanoseconds. |
| 2.2 | `conversations_list` | The most recent conversation's last-message date matches what Messages.app shows, **to the minute**. |
| 2.3 | `conversation_get` on it | Timestamps ascend or descend consistently and match the app. |

If everything is out by roughly 31 years, the epoch unit is being read wrong — that is the
one bug in this server most likely to look plausible and ship.

## 3 — Message bodies

| Step | Call | Expected |
|---|---|---|
| 3.1 | `conversation_get` on an old thread (several years back) | Text present; `bodySource` reads `text`. |
| 3.2 | `conversation_get` on a recent thread | Text present; `bodySource` reads `attributedBody`. |
| 3.3 | A message that is a photo, a sticker or an Apple Cash request | Reported as having no text, with `bodySource` `none` — not as an empty message. |

Step 3.2 is the check that the typed-stream reader works. If recent messages come back
empty while old ones do not, `AttributedBody` has broken against a newer archive layout.

## 4 — Search

| Step | Call | Expected |
|---|---|---|
| 4.1 | `messages_search` with a word you know appears | Matches, newest first. |
| 4.2 | Add `participant` | Narrows correctly. |
| 4.3 | `from` and `to` as plain days, one day apart | Includes messages sent late on the `to` day. |
| 4.4 | `to` earlier than `from` | Refused. |
| 4.5 | `has_attachment: true` | Only messages with attachments. |
| 4.6 | A search that hits the scan ceiling | Says the result was truncated and what it withheld. |

Step 4.3 catches the off-by-one-day that makes a search look like it lost messages.

## 5 — Attachments

| Step | Call | Expected |
|---|---|---|
| 5.1 | `message_attachments` with several ids at once | One call, all of them. |
| 5.2 | An attachment that was never downloaded to this Mac | Reported as absent from disk, not as an error. |

## 6 — Sending, to yourself only

There is no recipient allow-list in this server any more: the owner removed it along with
the connector setting that used to configure it. The switch below, and your own judgement
about what to confirm, are the whole guard — treat that as a reason to be more careful by
hand, not less.

| Step | Call | Expected |
|---|---|---|
| 6.1 | `send_message` to your own number **without** `confirm` | Refused, naming the confirmation. Nothing sent. |
| 6.2 | A body over 4,000 characters | Refused before anything is sent. |
| 6.3 | Rename the send shortcut, then `send_message` | Fails with a clear message about the shortcut, not a silent non-delivery. |
| 6.4 | Restore the name "Claude Send Message", `send_message` to your own number with `confirm: true` | Arrives, exactly as written. |
| 6.5 | Set the tool's switch to "prohibit" in Claude Desktop, try again | The call never reaches this server at all. |

Step 6.1 is the safety property that still lives in code. If it ever sends, stop and fix it
before using this server at all — everything else is now enforced by the permission switch,
not by this file.

## 7 — Sending survives an unreadable database

| Step | Call | Expected |
|---|---|---|
| 7.1 | Revoke Full Disk Access, restart Claude Desktop | |
| 7.2 | `conversations_list` | Refused, naming the permission. |
| 7.3 | `send_message` to your own number with `confirm: true` | **Still works** — sending goes through Shortcuts, not the database. |
| 7.4 | Restore Full Disk Access | |

## 8 — Packaging

| Step | Command | Expected |
|---|---|---|
| 8.1 | `otool -P .build/release/apple-messages-mcp \| grep NSAppleEventsUsageDescription` | Present. |
| 8.2 | `MCPB_SIGN_IDENTITY="Apple Development: …" bash scripts/pack.sh` | Every check passes; the designated-requirement line is not empty. |
| 8.3 | `codesign -dv extension/server/apple-messages-mcp` | `flags=0x0(none)` — never `linker-signed`. |
| 8.4 | Install, restart Claude Desktop | Six switches appear, one per tool. |

## 9 — Afterwards

Delete the test messages from the conversation with yourself.
