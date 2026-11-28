# Seen receipts that clear the phone badge

Date: 2026-11-27. Changes the `msgInfos` body of `/api/message/seenv2` (cmd 12118) and
`/api/group/seenv2` (cmd 12124). Endpoint, signing and cipher flow are unchanged.

## Problem

A conversation read in Zalolite still showed as unread on the phone. No `mark_seen` error was logged,
and the privacy guard (`native_privacy.json`) was not set, so the receipt was sent and accepted.

## Evidence (`/Applications/Zalo.app/Contents/Resources/app.asar`)

Zalo PC's `sendSeenV2` sends every unseen message of the conversation (newest 50), each as:

```
{cmi: cliMsgId, gmi: msgId, si: uidFrom, di: idTo, mt: originMsgType || msgType,
 st: st ?? -1, at: at ?? -1, cmd: cmd ?? -1, ts: ts || sendDttm || -1}
```

- `di` drops the group `g` prefix. In a 1:1 chat it is `"0"` when it equals the sender.
- The body is `{data: [...], senderId}` for a 1:1 chat and `{data: [...], grid}` for a group.

Zalolite sent only `{gmi: <newest id>, cmi: <same id>}` for the newest row, which could be our own
reply, and used the server ID as the client ID.

## Change

- `chat::seen_items` builds the Zalo PC item from `ChatMessage::wire_ref`. It falls back to
  `client_message_id`, the thread ID as sender, our UIN as `di` and `-1` for unknown numbers.
- `native_core` `mark_seen` acknowledges the incoming messages after the read point. With no read
  point it acknowledges the newest incoming message. It sends nothing when there is no incoming message.
- `chat::send_seen_v2` (egui worker) keeps the old one-item body.

## Tests

- `chat::rich_card_tests::seen_items_match_zalo_pc_shape`
- `native_core::tests::seen_receipt_covers_unread_incoming_messages`

## Not verified

- That the phone badge clears was not checked live. Needs a message from another account, read in
  Zalolite, then a look at the phone.
- Messages loaded from the local store may lack `cliMsgId`; they then send the server ID as before.
