# 71 — Zalo PC export key comes from a PC-type `getLoginInfo`

Date: 2026-11-17. Corrects the key source used since note 50.

## Symptom

People importing a `backup_zalo_*.zl.zip` into the released Zalolite saw
"Chưa tìm được khóa xuất dữ liệu phù hợp…". It worked on the developer's Mac only.

## Evidence

- Zalo PC 26.11.10 (`compact-app-pc.*.js`, `fetchLoginInfo`) resolves
  `{config, UIN: data.dkey, decryptKey: data.zpw_enk}` from `/api/login/getLoginInfo`, and the export
  cipher key source is that `UIN` (note 49). The request carries `imei, computer_name, language, ts`
  plus the client `type` and `client_version`, like Zalolite's.
- The only place the key exists on disk is the Local Storage record `<n>_sync_cross_state_backup`.
  A scan of all 1,190 files under `ZaloData` (caches and media excluded) found it nowhere else.
  That record is the state store of Zalo PC's phone → PC message restore (`sync-message-storage`,
  key prefix `sync_cross_state`), so it exists only for people who used that feature. This is why
  the note-50 lookup worked on one Mac and failed for others.
- The key is not derived locally: MD5 or raw combinations of the account id with Zalolite's imei and
  Zalo PC's `z_uuid` / device ids match neither key.
- Zalo PC's Local Storage records `zpw_type = 23`; Zalolite declares `type = 30`.
- Live check (2026-11-17, approved by the account owner, one read-only request, key compared by
  SHA-256 prefix only): `getLoginInfo` with `type = 23` returned a `dkey` equal to the key that opens
  the real export (length 32, hex). With `type = 30` the `dkey` differs. The key does not depend on
  the device, so it also opens exports made on another computer, as Zalo PC's own import does.

## Change

- `session::ZPW_PC_TYPE = "23"`; `login::get_login_info_as(s, type, version)` (the existing request
  with an explicit client type; `get_login_info` is unchanged).
- `native_core::ensure_export_key`: if the stored key (or a key Zalo PC left on this Mac) does not
  open the export's first tar header, request the PC-type `dkey`, verify it on the header, and persist
  it in `session.json` as `login.dkey`. A web-type request remains the last fallback. Nothing is
  imported with an unverified key; the key never crosses the UI bridge or logs.
- The error now says the file was not exported from this account or is incomplete.
- Test: `login::login_info_type_tests` checks the signed query declares the requested type.

## Not verified

- An export made on Windows Zalo PC (expected to use the same account key).
- Accounts that never logged in to Zalo PC.
