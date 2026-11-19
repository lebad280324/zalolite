# Group mentions, photo albums, media forwarding and photo sharpness

Date: 2026-11-19. One protocol change (group mention send); everything else is local parsing or UI.

## Group mentions (protocol change)

Before: picking a member in the `@` suggestions only inserted the name as text. The message went through
`/api/group/sendmsg` with no mention data, so phones showed the text but nobody was notified.

Evidence: the installed Zalo PC bundle (`/Applications/Zalo.app/Contents/Resources/app.asar`):

- Command map: `11198:{domainType:GROUP, path:"/api/group/mention"}` next to `11163 /api/group/sendmsg`.
- `static sendMentionMessage(e,t,n,a,…)`: `a=JSON.stringify(a)`, then body
  `{grid, message, clientId, mentionInfo:a, language, visibility}` passed through `buildParams`,
  AES-encoded as `params=`, posted to `/api/group/mention`, command `11198`.
- Callers send `e.content.mentions`. `_replaceMentionedNames` keeps `{pos, len, uid}` with `pos`/`len`
  in JavaScript string units (UTF-16), and `len` covers `@` plus the name.
- Constants: `MENTION_ALL_ID="-1"`, `MENTION_TYPE_USER=0`, `MENTION_TYPE_ALL=1`.
- The receive side already reads `mentions[].uid` and `"-1"` (`src/unread.rs`).

Implementation:

- `chat::mention_info` builds `[{pos, uid, len, type}]`. It drops tags outside the text, overlapping tags
  and non-numeric IDs.
- `chat::send_group_mention_with_client_id` sends that body plus `imei`, the same as `sendmsg`. It uses
  the standard path: params → ParamCipher v2 → signkey → session cookie.
- The `send_message` intent takes an optional `mentions` array. It is used only for group messages
  without a quote; otherwise the old endpoint is unchanged.
- The Swift composer remembers members chosen from the suggestions, including `@All`. At send time it
  computes UTF-16 ranges for tags that are still present in the draft.

Tests: `mention_info_matches_zalo_pc_shape_and_counts_utf16` (Rust) and `MentionTests` (Swift).
**Not yet verified live**: no tagged message has been sent to a real group. Before release, send one in
a test group and confirm the tagged phone gets a mention notification.

## Photo albums

Zalo marks each photo of a batch with `params.group_layout_id`, `id_in_group` and `total_item_in_group`.
The batch's messages arrive separately. These fields were seen in the local history inside quoted
attachments; the numbers and keys are recorded here, no content.

- The parser keeps them as `ChatMessage.photo_layout`. History merges fill them from the next server copy.
- The DTO exposes them as `photo_group`.
- `TranscriptLayout.collapseAlbums` folds adjacent photos from one sender with the same batch into one
  row. The row draws a 2/3-column grid, and no row holds a single photo.

History stored before this change has no batch data, so it stays one photo per row until reloaded.

## Forwarding photos, videos and files

`forward_message_with_client_id` forwarded only `msg.text`, so a forwarded photo arrived as
`[Hình ảnh]` or as empty text. The UI now fetches the original (or its imported local copy) and sends it
through the existing `send_attachment` upload. Photos are re-encoded from JPEG XL to JPEG at quality 0.95
and full size. Temporary copies live in a private 0700 folder and are deleted after 15 minutes.

## Photo sharpness

Measured on three recent photos: the CDN `href` (equal to `hdUrl`/`oriUrl`/`params.hd`) is served at most
2560 px on the long edge. Example: declared 3024×4032, served 1920×2560. `rawUrl` gave the same pixels.
That is Zalo's ceiling; uploads already go to `photo_original` with the original bytes.

Locally, transcript decoding rose from 720 to 1440 px and the cache from 48 to 160 MB. The viewer now
opens images up to 40 MB instead of failing above 4 MB.

## Alignment

Photos in the SwiftUI row (messages with reactions, quotes or mentions) were wrapped in
`.frame(maxWidth: 360, maxHeight: 340)`. That frame was wider than the fitted photo and centred it away
from the bubble edge. The photo now sizes itself and clips to its own rounded shape.
