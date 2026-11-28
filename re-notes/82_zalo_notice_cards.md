# Zalo notice cards

Date: 2026-11-23. Changes how official-account messages (`chat.list.action`, `chat.ecard`) are read
and shown.

## Problem

In the "Zalo" conversation, Zalolite showed only a title, `[Hình ảnh]` or "📢 Thông báo hệ thống Zalo".
Zalo shows the same messages as cards with a picture, a title, a description and, for lists, more
articles.

## Evidence (`/Applications/Zalo.app/Contents/Resources/app.asar`)

- Message type map: `chat.list.action` → `MSG_OA`, `chat.ecard` → `MSG_ECARD`.
- `MSG_OA` content is an array of parts. The OA renderer reads:
  - `type`: `l.a.header.full` or `l.a.header.only` draws a header (large picture `thumb`, `title`,
    `description`); `l.a.child.full` draws a row (small picture and `title`);
  - `href`, opened on click when `action` is `""` or `action.open.inapp`;
  - `action.open.popup` opens a Zalo popup from `params`; Zalolite does not support it.
- `MSG_ECARD` content is an object `{title, description, thumb, href, params (JSON), type,
  childnumber, action}`. The conversation list shows `params.previewTxt` when present.

## Change

- `chat::rich_card` turns a content array into `RichCard::Board` with every part, not only the first.
- `chat::ecard_board` reads a `chat.ecard` object the same way.
- The message carries `card: {kind: "board", parts: [{title, desc, thumb, url, header}]}`. The first
  part still fills the `link_*` fields for clients that read only those.
- The Zalo PC importer (`store.rs`) also writes board cards for content arrays.
- The macOS app draws `BoardCard`: header parts with a large picture and the full description, then
  child rows. A part with a web `href` opens it.

## Tests

- `chat::tests::zalo_notice_cards_keep_every_part`
- `BoardCardTests` (Swift)

## Not verified

- No live payload was captured. The shapes come from Zalo PC's code.
- Rows stored earlier without a card are fixed only when Zalolite reads that history again.
- E-card buttons in `params` and popup actions are not shown.
