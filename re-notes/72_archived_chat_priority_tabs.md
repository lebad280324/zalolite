# 72 — "Ưu tiên / Khác" uses Zalo's archived-chat list

Date: 2026-11-17.

## Evidence (Zalo PC 26.11.10, `compact-app-pc.*.js`)

- Command 12076 `GET {label}/api/archivedchat/list?<common>&params=enc({version, imei})`.
- Command 12077 `POST {label}/api/archivedchat/update?<common>` body `params=enc({ids, version, actionType, imei})`,
  `ids = [{id, type}]` with `type 1` for a group (id without the group prefix) and `0` otherwise;
  `actionType 0` moves into the archived list ("Khác"), `1` removes from it ("Ưu tiên").
  The reply carries `version` and `needSync` (then the client reads the list again).
- The conversation list shows `FilterType.FOCUSED` (Ưu tiên) and `FilterType.ARCHIVED` (Khác); a
  conversation is in Khác when `isArchivedChat(id)` finds it in that list.
- Live read on the signed-in account (counts only): `error_code 0`, `data = {version, items}`,
  `items[] = {id, type}`, 2 items.

## Change

- `native_core::features`: `get_workspace_features` reads the list (version 0) and includes
  `archived_chats {synced, items}` in the snapshot; `set_thread_priority` calls `archivedchat/update`
  and re-reads the list. Demo mode keeps the local flag. Test: `archived_list_reads_users_and_groups`.
- UI: Ưu tiên / Khác tabs above the conversation list (dot on the other tab when it has unread
  conversations); search covers both; the context menu moves a conversation between them.
