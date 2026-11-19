# Reactions: client message target, self ID and quick reactions

Date: 2026-11-19. Changes one request field (`cMsgID`) and the reaction host lookup.

## Reported

A user picks one reaction in Zalolite and sees two reactors ("Bạn" and "Thành viên"); the phone
shows none. Reactions could also only be added through the right-click menu.

## Evidence (installed Zalo PC bundle, `app.asar`)

- `sendReaction(e,t,n,a,i=6)` builds each target as
  `{gMsgID: a.msgId (or "" when fake), cMsgID: parseInt(a.cliMsgId), msgType: a.msgType}`, then
  `{rMsg, rIcon, rType, source}`, queued as `{message: JSON, clientId}`.
- `sendReactionMessage(e,t,n)` posts `{react_list}` plus `grid`/`imei` (group) or `toid` (1-1) to
  domain `REACTION`, `/api/group/reaction` (12411) or `/api/message/reaction` (12410).
- The receive side maps a target by `gMsgID`, or by `cMsgID` through `getMapCliID`.

## Findings

- `send_reaction` filled `cMsgID` with the message **timestamp**. Zalo accepted the request but
  matched no message by client ID, so other devices never showed the reaction. It now sends the
  stored `client_message_id` (`cliMsgId`) and falls back to the timestamp only when no client ID
  was kept (`chat::reaction_client_id`).
- The request used a hard-coded `reaction.api.zaloapp.com`. It now goes through
  `post_endpoint_form("reaction", …)`, which uses the verified host in `src/endpoints.rs` with
  failover.
- Zalo's reaction snapshots key this account as `"0"` (fixture `{"0":{"5":1}}`). A reaction sent from
  here was recorded under the UIN. The same person was therefore counted twice: "Bạn" for the UIN
  and "Thành viên" for `0`. `reaction_details` now maps `"0"` to the UIN and drops the duplicate
  from the list and the count. Stored summaries are unchanged.

## Quick reactions (UI only)

Hovering a message shows a small 👍 beside the bubble. A click sends 👍; hovering it opens the six
Zalo reactions. Choosing your current reaction again removes it. Native rows place it at the
measured bubble edge; SwiftUI rows (messages with reactions, quotes or mentions) place it beside
the pointer.

## Tests

- Rust: `reactions_target_the_client_message_id`, `own_reaction_under_zero_and_uin_counts_once`.

## Not verified

- No live reaction has been sent with the new `cMsgID`. Confirm on a phone before release.
- The quick-reaction placement has not been checked by hand.
