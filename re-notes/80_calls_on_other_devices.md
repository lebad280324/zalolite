# Calls held on another device must not ring here

Date: 2026-11-20. Changes how `src/call.rs` reads `answer` and `request` control events. No request,
signing or frame ID changes.

## Problem

- A call placed from the phone showed "Cuộc gọi video đến" in Zalolite and kept ringing after it ended.
- An incoming call picked up on the phone kept ringing in Zalolite.

## Evidence (local `call_trace.log`, 15 calls, identifiers not copied)

- Every real invite is a `request` with `uidTo`, `session` and `rtpAddress`, and its `params` carry
  `Dname` and `zrtc_config`.
- For a call placed from the phone this Mac receives `ring_ring` and then `answer` (callee picked up).
  Its `params` hold the callee's answer (`reveiverId`, `extendData`, `sessId`), with no `uidTo` or
  `zrtc_config`.
- Zalolite turned any such `answer` into a synthetic `request` when no call was active. That code
  (2026-10-30) had no capture behind it, and every `request` without `uidTo` in the log is one of these
  synthetic copies. This is the false ringing.
- In every `answer` received while ringing, `uidN` is the caller's 19-digit ID, never this account's.
  Rule 1 of re-notes/60 (`uidN == own UIN`) therefore never matched.

## Change

1. With no active call, an `answer` is logged and ignored. It is never turned into an invite.
2. A 1:1 `request` rings only if `is_call_invite` holds: it has a non-empty `uidTo` or a `zrtc_config`
   in `params`. `group_request` is unchanged.
3. While this Mac rings as callee, any `answer` for the primary leg means another device of this account
   answered or declined. Zalolite stops ringing with `answered_elsewhere`. A local accept sets
   `is_connected` before sending its own `402`, so its echo cannot reach this branch.

## Tests

- `call::tests::only_real_invites_ring`

## Not verified

- Neither case has been re-tested live with the fix.
- Rule 3 assumes the caller never sends `answer` to a ringing 1:1 callee. Nothing in the log contradicts
  this.
