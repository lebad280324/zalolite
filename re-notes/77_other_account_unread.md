# Unread counts of the other accounts on this Mac

Date: 2026-11-19. Adds periodic read-only requests made with another saved account's session.

## Goal

Several accounts are kept on one Mac, but only the active one keeps a socket. The account switcher
showed other accounts' unread counts from their saved conversation lists, which are only as fresh as
the last time each account was used. The user asked for a near-live count.

## Design

- Every 180 s (the first check 30 s after start), the core checks each other saved account in turn:
  - it loads that account's `accounts/<uin>.json` session in memory;
  - it sends one `get-last-msgs` preview request with it (`chat::get_last_msgs`, the call Zalo PC makes
    at startup; no socket, no `getChatFromPolling` queue cursor);
  - it applies the reply to an in-memory copy of that account's `native_threads.json` with the core's
    own live merge (`merge_live_previews`, which also applies the `clearUnreads` read points).
- Nothing of the other account is written: no session refresh, no message store, no thread cache.
- The saved list carries read points but no messages, so a message read on the phone after the list was
  saved could look unread again. Only messages sent after the list's modification time are added to the
  unread messages the list already had (`count_with_previews`).
- The count follows the native badge: unread messages in conversations that are not muted or hidden,
  and one for a conversation only marked unread.
- The core emits `account_unread {uin, count, conversations, checked_at}`, or `{uin, error: "expired"}`
  when the saved session no longer works. The switcher and the optional account tabs prefer it over the
  saved list.

## Live check (with the user's approval)

One request for the second account on this Mac returned `error_code 0` with `clearUnreads[119]`,
`clearUnreadsReact[46]`, `msgs[12]`, `groupMsgs[12]`, `pageMsgs[0]`, `lastActionId`, `more`. The saved
list had 23 unread messages; with the reply applied the count was 24, so one message had arrived since.
Only counts and key names were printed. The active account stayed connected throughout.

## Account tabs (UI)

Cài đặt → Tài khoản & khóa → "Hiện thanh tài khoản trên danh sách hội thoại", off by default. When on,
a row of account chips sits above the conversation list, each with its unread count; a click switches.

## Tests

- `muted_hidden_and_read_conversations_do_not_count`
- `other_accounts_skips_the_active_one_and_non_accounts`
- `only_messages_after_the_saved_list_add_to_its_unread`

## Not verified

- The count has not been compared with the phone over a longer period.
- Long-term effects of two accounts sending requests from one Mac are unknown; Zalo PC does not do this.
