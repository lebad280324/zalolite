# 70 — Phone sync v2 requests: Zalolite vs Zalo PC 26.11.10

Status: request and receive paths rewritten (2026-11-17); awaiting a live test with the phone.

## Symptom (2026-11-17)

- "Đồng bộ tin nhắn từ điện thoại" brings in far less history than importing a Zalo PC backup (`.zl.zip`).
- After the request, tapping **Đồng bộ ngay** on the phone makes the Zalo mobile app quit.
- `sync_v2_keys.json` was regenerated at the attempt (14:01 local), so the v2 request did go out with
  real zproto keys from the installed Zalo PC `libzproto` (the earlier placeholder-key crash, fixed in
  `eb6df2f`, is not the cause this time).

## What Zalolite sends today (`chat::request_phone_sync_v2`)

Alongside the v1 `pull_mobile_msg` request (cmd 12000, RSA key), one SyncFull v2 request:

```json
{ "syncType": 0, "toDevice": 0, "ver": 1, "ussidx": 0,
  "req": { "type": "message", "priority": 1, "batchSize": 2000,
           "queries": [{ "partition": "", "from": 0, "to": 9007199254740991, "limit": 2000 }] } }
```

So at most 2 000 messages in total, from a single query with an empty partition.

## What Zalo PC 26.11.10 does (`/Applications/Zalo.app/Contents/Resources/app.asar`)

From `pc-dist/shared-worker.cfeba43a9a8e4e40dda3.js` (`requestSync`) and
`pc-dist/lazy/main-startup.89bb530b91927fd5dd28.js` (sync client):

- Request object is the same shape: `{syncId, syncType: SyncFull, ek, ik, toDevice, tempKey,
  deviceName, req: {type, priority, queries: [{partition, from, to, limit}], batchSize}, ver: 1, ussidx}`.
- Session options: `connectTimeout 10 s, batchTimeout 10 s, wakeupTimeout 180 s, transferBatchSize 2000`.
- `ussidx` is a per-`userSyncSessionId` counter (`nextIndex`), incremented for every request in one
  user sync session; Zalolite always sends 0 and has no `userSyncSessionId`.
- One request may hold several queries, but all must target one database `type` and one `priority`.
- There are two remote databases: `"conversation"` (ordered by `lastTs`) and `"message"` (ordered by
  `timestamp`). Message rows are partitioned by conversation (`partition: <userId or group id>`).
- The full sync is staged, driven by server-provided config (`getSyncRemoteConfigs`):
  conversation list → preview and recent messages per conversation
  (`maxNumberOfMsgPerConv.recentMessages`, `maxNumberOfConv.previewMessage`, `thresholdRanges`) →
  all remaining messages per conversation (`maxNumberOfMsgPerConv.allRemainingMessages`), in
  `conversationsBatchSize` chunks, plus on-demand sync for the conversation the user opens.

## Hypotheses to verify with a capture

1. Missing history: the single `partition: ""` query with `limit: 2000` caps the transfer at 2 000
   messages, versus per-conversation queries in Zalo PC.
2. Phone crash: the mobile app may not handle a `message` query with an empty partition, or the v1 and
   v2 requests arriving together. Needs a WebSocket capture of Zalo PC's own requests (cmd 590 payloads)
   and of the replies before the request format is changed.

## Further evidence (same Zalo PC build)

- Partition names: module `aSMs` returns `${isGroup ? "group" : "oneone"}/${id}`, where `id` is the
  conversation's *global* id (`pcNoised2gNoised`). The lookup reads `friend.globalId` and
  `group.globalId`; conversations without one are dropped (`friend-without-global-id`,
  `user-not-in-friend-list`).
- Live check on the signed-in account (field names and counts only): `getfriends` returned 385 friends,
  all with `globalId`, none equal to `userId`; `getmg-v2` returned `globalId` for 40/40 probed groups,
  none equal to the group id.
- `yo.a = 2147483647` is the "no limit" value used when a query has no explicit limit.
- Downloaded batches are read by `Ul` as consecutive `u32 LE length | record` items; each record is
  decrypted on its own. Metadata (`decryptMetaData`) yields the session record; every message record
  of the same `syncId` is decrypted with that one session (`waitSessionRecord`).
- Zalo PC still has the v1 `pullMobileMsg` path, but only for its legacy restore flow.

## Receive-side defects found in Zalolite

1. After importing the first message batch, `import_sync_v2_messages_to` deleted the keys and the
   session and called `clean_sync`, so every later batch failed to decrypt.
2. The helper kept one key and session file in the working directory for all requests.
3. Only single-record files decrypted (the 4-byte header was stripped only when it covered the whole file).
4. Messages were stored under the partition name instead of the Zalolite thread id, and the sender
   was compared with the account uin although senders are global ids.
5. Decrypt failures were swallowed without any log.

## Change

- `src/phone_sync_v2.rs`: plans one partition per conversation from friend/group global ids, sends
  SyncFull requests of 50 partitions (`limit 2147483647`, `batchSize 2000`, `ussidx` 0,1,2…), one key
  folder per request (`sync_v2/<syncId>/`), waits for each request's batches (3 min for the first,
  then 1 min; done on `isLast` or 20 s idle), maps partitions and senders back to threads, defers
  message batches that arrive before their metadata, and writes `phone_sync.log` (counts, short id
  prefixes, hosts; no keys, URLs or content).
- `sync_v2_helper.js`: `SYNC_V2_DIR` working folder and `decrypt-batch` (record by record).
- The v1 request is no longer sent alongside v2.
- Tests: `phone_sync_v2::tests` (partition names, payload, record split, direction and sender mapping,
  `globalId` parsing, type labels).

## Still unverified

- Whether the phone stops crashing (needs the live test).
- The `upload_batch` field names (`msgUrl`, `batchType`, `isLast`) were guesses; `phone_sync.log` now
  records the field names of every `transfer_sync2` control to confirm them.
- Message fields beyond sender, ids, type, timestamp and text (attachments, quotes) are not decoded yet.
