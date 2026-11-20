# 60 — Incoming call answered on another device (12/11/2026)

Symptom: a call answered on the phone kept ringing in Zalolite until the caller hung up.

## Evidence

Local `call_trace.log` (values summarised; no identifiers or session data copied):
- Callee-side control events seen so far are `request`, `answer` (also used by the caller as
  an invite carrier, `uidN` = caller), `answer_ack`, `end_call`, `cancel`.
- For call `…7842` this device sent `402 answer` after the call had been picked up elsewhere;
  `voicecall/answer` returned `voicecall error -101`.

No capture yet shows which push (if any) Zalo sends to a ringing desktop when the phone answers.

## Change (`src/call.rs`, no request or signing changes)

1. While ringing as callee (`!is_caller && !is_connected`, primary leg), an `answer` whose
   `uidN` is this account's own UIN means this account answered on another device: the call
   state is cleared and `answered_elsewhere` then `free` are emitted. A local accept sets
   `is_connected` before its own answer could echo back, so it never matches.
2. If our own `402 answer` fails with `-101`, the call no longer exists server-side: the local
   state is cleared the same way instead of showing a dead "connected" call.
3. The native UI also drops a ringing card after 75 s without any end signal and withdraws the
   incoming-call banner whenever ringing stops.

## Not verified

Rule 1 never matched: the `answer` carries the caller's `uidN`. Replaced by re-notes/80. Rules 2 and 3 cover the
case where no echo arrives. Next live test: answer on the phone and check `call_trace.log` for
the event that arrives here.
