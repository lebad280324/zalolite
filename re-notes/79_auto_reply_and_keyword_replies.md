# Auto-reply (Zalo's own) and keyword replies

Date: 2026-11-20. Adds the `/api/autoreply/*` requests and a reply sent by Zalolite itself.

## Zalo's own auto-reply (evidence: `/Applications/Zalo.app/Contents/Resources/app.asar`)

- Host: `getAutoReplyDomain()` → `getDomainByType(AUTO_REPLY)`, where the service type `AUTO_REPLY` is
  `"auto_reply"`, a key of `zpw_service_map_v3`. Sessions saved before this change lack it, so the core
  reads it from a fresh `getLoginInfo` (the same path as `group_poll`, re-notes/74).
- Commands: 12048 `/api/autoreply/list`, 12049 `create`, 12050 `update`, 12051 `delete`.
- Every call puts the AES `params` in the query. `list` is a GET, and the writes are POSTs with no body
  (`this._post(url, null, null, cmd)`).
  - list: `{version: 0, cliLang}` → `data.item[]` and `data.version`.
  - create: `{cliLang, enable, content, startTime, endTime, recurrence, scope, uids}`.
  - update: same fields plus `id`.
  - delete: `{cliLang, id}`.
- `recurrence` defaults to `DefaultRecurrence = ["RRULE:FREQ=DAILY;"]`.
- `ScopeType`: ALL 0 (FRIENDS is an alias of 0), STRANGERS 1, FRIENDS_INCLUDE 2, FRIENDS_EXCLUDE 3.
  `uids` lists the friends for 2 and 3.
- Limits from the root config: `autoReplies.max_content_len` 2000 and `max_custom_fr` 50.
- Time window (module `73eU`): the editor keeps two offsets from local midnight in 30-minute steps.
  Presets are `[0,0]` all day, `[43.2e6, 48.6e6]` 12:00–13:30, and `[64.8e6, 27e6]` 18:00–07:30.
  `S(offsets)` turns them into absolute times anchored at local midnight of yesterday:
  - `startTime = base + start`;
  - an all-day window (gap ≥ 1 day or < 1 s) gets `end = start + day`;
  - an overnight window (`start > end`) gets `end += day`;
  - `endTime = base + end`.

  `R(abs)` reads the times back as local hour and minute. Zalolite's `AutoReplyTime` follows both.
- Availability: the sidebar entry opens a Zalo Business promotion link unless the account's business
  config has `ar.enable`. Accounts without it are expected to get a server error. Zalolite shows that
  error in the Settings section, not as a banner.

## Keyword replies (Zalolite only)

Zalo PC has no keyword reply. Zalolite sends one itself, using the normal send path
(`send_message_with_client_id` / `send_group_message_with_client_id`), so the request is identical to
a message typed by the user.

Guards:

- Off by default; groups are off by default.
- A message is answered only if all of these hold:
  - it is incoming text that a live merge (WebSocket or polling) just added;
  - it arrived in the last 2 minutes, so history replayed after a reconnect is never answered;
  - it is the newest incoming message of its thread.
- One reply per conversation per cooldown (15 minutes to 24 hours; 3 hours by default). The cooldown
  starts even if the send fails, and a failed reply is not retried.
- At most 3 replies per batch of incoming messages.
- Rules use the existing `api_mcp::AutoReplyRule` matcher: contains, exact or prefix; case-insensitive;
  all, direct-only or group-only. Up to 50 rules.
- Settings live in `accounts/<uin>/keyword_replies.json` (private, atomic write), per account.

## Scheduled sending

Unchanged (local queue, `extras::deliver_due`). The new Settings page only explains it and opens the
existing list.

## Tests

- Rust `native_core::auto_reply`:
  - `server_rule_body_matches_zalo_pc`
  - `server_list_reads_items`
  - `keyword_replies_respect_guards`
  - `only_new_recent_incoming_text_is_answered`
  - `a_batch_sends_at_most_three_and_starts_the_cooldown`
- Swift `AutoReplyTimeTests` (window anchoring, read-back, settings round trip).

## Not verified

- No `/api/autoreply/*` request has been sent. The list reply shape (`item`, `version`), the type of
  `id`, and the error an account without Zalo Business gets all come from reading the code, not from a
  capture.
- Keyword replies have not been tested on a real account.
