# Message deletion: target fields and group admin delete

Date: 2026-11-19. Changes the `msgs[]` items of the delete requests and adds `onlyMe: 0` for group admins.

## Reported

"Xóa ở phía tôi" in a group fails with "Không thực hiện được thao tác. Kiểm tra kết nối rồi thử lại."
Group admins also want Zalo's "Xóa cho cả nhóm".

## Evidence (installed Zalo PC bundle, `app.asar`)

- `deleteGroupMessageV2(e,t,n,a=1)` posts `{grid, cliMsgId, msgs, onlyMe: 1 !== a ? 0 : a}` to the group
  domain at `/api/group/deletemsg` (11834). `deleteOneOneMessageV2` posts `{toid, cliMsgId, msgs, onlyMe,
  imei}` to `/api/message/delete` (11779). The outer body already matched.
- Every `msgs[]` item is built as `{cliMsgId: e.cliMsgId, globalMsgId: e.msgId,
  ownerId: "0" == e.fromUid ? me : e.fromUid, destId: e.toUid || e.userId}`.
- The same code checks `isExpiredAdminDFE` / `isExpiredSenderDFE`. Delete-for-everyone exists for admins
  with a time limit (`expire_time_DFE_admin`).

## Findings

- `ownerId` for someone else's group message was `msg.sender`, the sender's **display name**, and
  `cliMsgId` was the message time. Zalo rejected the delete.
- `chat::delete_target` now builds the item from the sender UID (`sidebar_sender_id`), the stored client
  message ID (falling back to the time when none was kept), and the bare group ID as `destId`.
- `chat::delete_message(…, only_me)` sends `onlyMe: 0` when a group admin deletes for everyone. The
  `delete_message` intent takes `for_everyone` (groups only).
- The UI offers "Xóa cho cả nhóm" on other members' messages only when the member list marks this
  account as owner or deputy (`role > 0`), and asks for confirmation. Zalo enforces the role and the time
  limit; a refusal shows a plain explanation.

## Tests

- `delete_targets_use_sender_uid_and_client_id`.

## Not verified

- No message has been deleted with the new fields on a live account.
- The admin time limit is not read locally; Zalo's refusal is the only signal.
