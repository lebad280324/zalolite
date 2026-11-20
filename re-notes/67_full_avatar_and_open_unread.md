# 67 — Original profile photo; unread badge on the open conversation

## Full avatar
Evidence: Zalo PC `app.asar`, `static getFullAvatar(e)`:
GET `getProfileDomain() + "/api/social/profile/avatar?" + commonParams + "&params=" + AES({fid, imei})`
(action code 11860). Callers read `full_avatar` (fallback `bk_full_avatar`) and show it on avatar
click (`showImage(b, o.fullAvatar || o.avatar)`). Native command `full_avatar {user_id}` returns
`{user_id, url}`; the viewer opens the small photo at once and swaps to the original when it
arrives. Not yet confirmed against a live response; the response shape is as read from the bundle.

## Unread on the open conversation
A live message reaches the UI as `messages` before the `threads` snapshot that counts it unread,
so the "mark read while visible" check ran while the thread still looked read and was never
repeated. The UI now repeats the check on every `threads` snapshot; `mark_seen` publishes the
cleared badge before the slow full-store write.

## Update 2026-11-19: never reached the core

`full_avatar` was listed in `extras::commands()` but had no `Command` variant, so every request
failed to decode. The UI ignores errors from this background read, so the viewer kept the 160 px
avatar (`s160-26-ava-talk.zadn.vn`); the CDN serves at most 240 px. `Command::FullAvatar` now exists.
`every_extra_command_decodes_as_a_request` checks every extra command against the enum.

Live check, with the user's approval, one request each for the account's own photo and one group member:

- `error_code 0`, with `full_avatar` (JPEG XL) and `bk_full_avatar` (JPEG) on `zpsocial2-*-org.zadn.vn`.
- Own photo: 709×708 px. Member photo: 1280×1280 px.
- `NSImage(data:)` decodes both formats at full size.

Only key names, hosts and pixel sizes were printed.
