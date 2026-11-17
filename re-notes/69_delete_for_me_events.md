# 69 — "Delete for me" events from other devices

## Symptom

After the user chose "Xóa ở phía tôi" on the phone, Zalolite showed an empty outgoing
bubble, "Loại tin này chưa hiển thị được — xem trên điện thoại", and the deleted message stayed.
The time stamp was also drawn over that label.

## Evidence (2026-11-16, live account, redacted)

The cached copy of the WebSocket push (`native_threads.json`, `wire_ref.fields`) has
`cmd: 122` with `msgType: "chat.delete"` and this `content`:

```json
[{"actionType":0,"clientDelMsgId":<int>,"destId":<own uid>,"globalDelMsgId":<int>,
  "type":2,"uidFrom":<peer uid>,"uidTo":<peer uid>}]
```

`globalDelMsgId` / `clientDelMsgId` name the message that was deleted for this account;
the event itself carries no text. The parser treated the event as a message with empty text.

## Handling

- `chat::local_delete_targets` recognises `chat.delete` and returns the target IDs.
  `parse_chat_message` never returns a message for it.
- `merge_preview_batch` (live pushes and `get-last-msgs`) removes the targets from the thread,
  matching the server ID or the client message ID, and returns `(thread_id, msg_id)` rows.
- `Core::forget_removed` deletes those rows from SQLite (`MessageStore::delete_thread_messages`)
  and emits `message_removed`.
- On start, `chat::purge_local_delete_events` applies events that older builds cached as messages,
  so the existing empty bubble and its target disappear.

No request is sent; only incoming events are interpreted. Tests: `chat::delete_for_me_tests`.
