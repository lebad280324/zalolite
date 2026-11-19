# Group polls and Zalo emoticon codes

Date: 2026-11-19. Adds poll reading and voting (new requests) and changes display only for emoticon codes.

## What users saw

Groups filled with notices such as "Có thành viên tham gia cuộc bình chọn: …", one per vote, but the poll
itself never appeared. Local history has 1,712 vote, 129 change-vote, 52 create and 7 lock notices in one
account, and no poll body. Notices come from `action: "vote"` content (re-notes/65), whose `params` hold
the template, the name and `question`.

## Evidence (installed Zalo PC bundle, `app.asar`)

- A notice names its poll by `JSON.parse(message.params).pollId`.
- Command map, domain `GROUP_POLL` (service map key `"group_poll"`): `12080 /api/poll/create`,
  `12081 /api/poll/detail`, `12083 /api/poll/option/add`, `12084 /api/poll/vote`,
  `12085 /api/poll/share`, `12089 /api/poll/end`.
- `getPollDetail(e,t)`: `n={poll_id:t, imei}`; `GET getGroupPollDomain()+"/api/poll/detail?"+common+"&params="+encodeAES(n)`.
- `vote(e,t,n)`: `a={poll_id:t, option_ids:n, imei}`; `GET …/api/poll/vote?…&params=encodeAES(a)`.
- Poll model fields: `poll_id, question, creator, options[{option_id, content, votes, voted, voters}],
  joined, closed, allow_multi_choices, allow_add_new_option, num_vote, expired_time, created_time`.

## Implementation

- `Domains.group_poll` is taken from `zpw_service_map_v3.group_poll` and persisted. Sessions signed in
  before this change call `getLoginInfo` once and take only that host from it; keys and cookies in the
  reply are not applied.
- `chat::poll_detail` and `chat::poll_vote` follow the standard path: params → ParamCipher v2 →
  signkey → cookie, with `get_endpoint` host failover.
- Commands `poll_detail {thread_id, poll_id}` and `poll_vote {thread_id, poll_id, option_ids}` return
  a trimmed poll DTO; server bodies never reach the UI.
- Vote notices keep `card.poll_id`. Cached notices gain it on the next server copy.
- The transcript keeps only the newest notice per poll and draws it as a poll card: options with vote
  bars, single or multiple choice, "Bình chọn" / "Đổi bình chọn", and the locked or expired state.

Tests: `vote_notices_keep_their_poll_id`, `poll_dto_keeps_only_drawn_fields`.
**Not yet verified live**: no poll has been opened or voted from Zalolite. The `group_poll` host for
this account is unknown until the first request. `option_ids` is sent as a JSON number array, inferred
from `votedOptionIds`.

## Emoticon codes

The quick "like" button in Zalo sends the text `/-strong`, and Zalo draws it as a thumbs-up. Zalolite
showed the raw code. The bundle lists the `/-name` codes. `chat::display_emoticons` maps the ones with
an unambiguous picture (strong, weak, heart, break, ok, v, rose, cake, coffee, beer, flag, punch, shit,
thanks) wherever they stand as a word. It maps the quick faces `:>`, `:o`, `:-((`, `:-h` (from the
quick-emoji map `like/smile/surprised/cry/heart/rage`) only when they are the whole message. Stored text
is unchanged; only the message DTO and the sidebar preview are converted.

Test: `emoticon_codes_show_as_emoji_without_touching_text`.
