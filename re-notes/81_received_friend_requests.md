# Received friend requests

Date: 2026-11-23. Changes which API "Lời mời kết bạn" reads, and the body of `/api/friend/reject`.

## Problem

Friend requests sent to the user showed on Zalo but nowhere in Zalolite.

## Evidence (`/Applications/Zalo.app/Contents/Resources/app.asar`)

- `getRequestedFriends()` → GET `/api/friend/requested/list` `{imei}`, cmd 12203. Zalo PC uses it for
  `makeUndoSentRequestFriend`: it is the list of requests **this account sent**. Zalolite read it as
  the received list, so received requests never appeared.
- `getRecommendedFriendsV2()` → GET `/api/friend/recommendsv2/list` `{imei}`, cmd 11437, returns
  `recommItems[]`.
  - `getListFriendRequest` keeps the items whose `dataInfo.recommType === 2` and sorts them by
    `dataInfo.recommTime`, newest first. These are the received requests.
  - The other items are friend suggestions.
- Item fields that the request card reads from `dataInfo`:
  - `userId`, `displayName`, `zaloName`, `avatar`;
  - `recommTime` (−1 when unknown);
  - `recommInfo.message`, the note the sender wrote;
  - `recommInfo.source`.
- `acceptFriendRequest` sends `{fid, language}` (cmd 11427), the same as Zalolite.
- `rejectFriendRequest` sends `{fid}` (cmd 11428). Zalolite also sent `imei`.

## Change

- `list_friend_requests` reads `recommendsv2/list` and returns only the `recommType` 2 items, newest
  first, with `message` and `time` (`zalo_actions::received_friend_requests`). It is a full list
  (`partial: false`).
- `reject_friend_request` sends only `fid`.
- The macOS app:
  - re-reads the list on sign-in and every 5 minutes, because no push for new requests is handled;
  - shows "N lời mời kết bạn" above the conversation list;
  - adds a "Lời mời kết bạn" entry in the view menu;
  - shows the sender's note and the date in the list.

## Tests

- `native_core::zalo_actions::tests::received_friend_requests_keep_only_requests_newest_first`

## Not verified

- No live `recommendsv2/list` reply was captured. The shape comes from reading the code.
- Requests this account sent (`requested/list`) are not shown anywhere now.
