# Delete conversation: the message Zalo PC names

Date: 2026-11-20. Changes the body of `/api/message/deleteconver` (11778) and `/api/group/deleteconver` (11835).

## Problem

"Xóa hội thoại" failed with "Không thực hiện được thao tác. Kiểm tra kết nối rồi thử lại." Zalolite sent
`conver: {}` and reused the last message's client ID as the top-level `cliMsgId`.

## Evidence (`/Applications/Zalo.app/Contents/Resources/app.asar`)

- `deleteOneOneConversationV2(e,t,n)` → `{toid:e, cliMsgId:t, conver:n, onlyMe:1, imei}`;
  `deleteGroupConversationV2` sends `grid` instead of `toid`. Both are unchanged.
- `_syncDeleteConversation(e)`:
  - `n = _initObjDel(preview)`, where `_initObjDel` returns
    `{ownerId: (fromUid == "0" ? uidMe : fromUid), cliMsgId, globalMsgId: msgId}`, but only when `fromUid`,
    `cliMsgId` and `msgId` are valid. Without a valid preview it falls back to `getInfoLastMessageValid`.
  - The conversation is always deleted locally (`hardDeleteConversation`).
  - `syncDeleteConversation(e, isGroup, n, h.a.next()+"")` runs only when `n` exists. The top-level
    `cliMsgId` is a new request ID, not the message's own ID.

## Change

- `chat::delete_conversation_anchor` picks the newest loaded message with a numeric server ID, preferring
  one with a client ID. It builds `{ownerId, cliMsgId, globalMsgId}` with the same owner rule as
  message delete (`delete_target`).
- `delete_conversation` takes that object as `conver` and sends `next_client_message_id()` as `cliMsgId`.
- With no such message, Zalolite clears the history on this Mac without a request, like Zalo PC.
- The legacy egui worker only has the last client ID, so it sends `{cliMsgId}` as `conver`. It is not used
  by the native app.

## Tests

- `deleting_a_conversation_names_its_newest_server_message`

## Not verified

- No live delete was sent; the fix has not been checked against the server yet.
