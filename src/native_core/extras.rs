//! Additional native UI intents routed through the existing protocol and store APIs.

use anyhow::{bail, Context, Result};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use crate::chat::{self, ChatMessage, Thread};
use crate::session::{Session, SessionError};

const MAX_TEXT_BYTES: usize = 20_000;
/// Formats that must be read into memory in full (JSON, encrypted Zalo PC pages).
const MAX_BUFFERED_IMPORT_BYTES: u64 = 2 * 1024 * 1024 * 1024;
/// SQLite sources are copied and opened in place, so only disk space bounds them.
const MAX_SQLITE_IMPORT_BYTES: u64 = 256 * 1024 * 1024 * 1024;
static NEXT_IMPORT: AtomicU64 = AtomicU64::new(0);

/// List the additional commands understood by the native command dispatcher.
pub(super) fn commands() -> &'static [&'static str] {
    &[
        "sticker_packs",
        "sticker_pack",
        "search_stickers",
        "suggest_stickers",
        "sticker_keywords",
        "send_sticker",
        "forward_message",
        "lookup_phone",
        "check_friend",
        "get_profile",
        "full_avatar",
        "thread_library",
        "add_friend",
        "accept_friend",
        "reject_friend",
        "undo_friend",
        "import_history",
        "schedule_message",
        "list_scheduled",
        "cancel_scheduled",
    ]
}

/// Execute an additional UI intent, returning `None` for an unknown command.
///
/// # Errors
/// Returns validation, transport, authentication, or persistence errors. Server
/// response bodies and authentication material are never returned to the UI.
pub(super) async fn execute(
    command: &str,
    params: &Value,
    session: &Session,
    threads: &[Thread],
    db_path: &str,
    output: &tokio::sync::mpsc::Sender<Value>,
) -> Result<Option<Value>> {
    if !commands().contains(&command) {
        return Ok(None);
    }
    if command == "thread_library" {
        // Local history only, so it also works offline and in demo mode.
        let thread_id = required_text(params, "thread_id", 256)?;
        let is_group = boolean(params, "is_group", false)?;
        let thread = known_thread(threads, &thread_id, is_group)?.clone();
        return Ok(Some(thread_library(thread, db_path.to_owned()).await?));
    }
    if session.login.is_none() {
        bail!(super::UserError(
            "Vui lòng đăng nhập Zalo trước khi thực hiện thao tác này."
        ));
    }
    let value = match command {
        "sticker_packs" => {
            let packs = chat::fetch_sticker_store_packs(session)
                .await
                .map_err(safe_error)?;
            let packs: Vec<_> = packs
                .into_iter()
                .take(1000)
                .map(|pack| {
                    json!({
                        "id": pack.id,
                        "name": pack.name,
                        "total_image": pack.total_image,
                        "icon_url": http_url(&pack.icon_url),
                    })
                })
                .collect();
            json!({"packs": packs})
        }
        "sticker_pack" => {
            let cate_id = unsigned(params, "cate_id", true)?;
            let name = optional_text(params, "name", 512)?.unwrap_or_default();
            let items = chat::fetch_sticker_pack_items(session, cate_id, &name)
                .await
                .map_err(safe_error)?;
            // Animation is optional: a failure here still returns the static items.
            let art = chat::fetch_sticker_pack_art(session, cate_id).await.unwrap_or_default();
            let mut rows = sticker_items(items);
            for row in &mut rows {
                let id = row.get("sticker_id").and_then(Value::as_u64).unwrap_or(0);
                if let (Some(object), Some(art)) = (row.as_object_mut(), art.get(&id)) {
                    object.insert("sprite_url".into(), json!(art.sprite_url));
                    object.insert("total_frames".into(), json!(art.total_frames));
                    object.insert("duration_ms".into(), json!(art.duration_ms));
                }
            }
            json!({"cate_id": cate_id, "items": rows})
        }
        "search_stickers" | "suggest_stickers" => {
            let keyword = required_text(params, "keyword", 512)?;
            let items = chat::search_stickers_by_keyword(session, &keyword)
                .await
                .map_err(safe_error)?;
            json!({"keyword": keyword, "items": sticker_items(items)})
        }
        "sticker_keywords" => {
            let mut keywords = chat::fetch_sticker_suggest_keywords(session)
                .await
                .map_err(safe_error)?;
            keywords.truncate(10_000);
            json!({"keywords": keywords})
        }
        "send_sticker" => {
            let thread_id = required_text(params, "thread_id", 256)?;
            let is_group = boolean(params, "is_group", false)?;
            known_thread(threads, &thread_id, is_group)?;
            let sticker_id = unsigned(params, "sticker_id", false)?;
            let cate_id = unsigned(params, "cate_id", true)?;
            let sticker_type = match params.get("sticker_type") {
                None => 7,
                Some(_) => u32::try_from(unsigned(params, "sticker_type", false)?)
                    .context(super::UserError("Loại nhãn dán không hợp lệ."))?,
            };
            let client_id = chat::next_client_message_id();
            let response = chat::send_sticker_with_client_id(
                session,
                &thread_id,
                sticker_id,
                cate_id,
                sticker_type,
                is_group,
                client_id,
            )
            .await
            .map_err(safe_error)?;
            let mut result = sent_response(&response, &thread_id, client_id)?;
            result["sticker_id"] = json!(sticker_id);
            result["cate_id"] = json!(cate_id);
            result["sticker_type"] = json!(sticker_type);
            result
        }
        "forward_message" => {
            let source_id = required_text(params, "thread_id", 256)?;
            let message_id = required_text(params, "message_id", 256)?;
            let target_id = required_text(params, "target_thread_id", 256)?;
            let target_is_group = boolean(params, "target_is_group", false)?;
            known_thread(threads, &target_id, target_is_group)?;
            let source = threads
                .iter()
                .find(|thread| thread.id == source_id)
                .and_then(|thread| {
                    thread
                        .messages
                        .iter()
                        .find(|message| message.id == message_id)
                })
                .context(super::UserError(
                    "Không tìm thấy tin nhắn để chuyển tiếp. Hãy tải lại hội thoại.",
                ))?;
            let client_id = chat::next_client_message_id();
            let response = chat::forward_message_with_client_id(
                session,
                &target_id,
                target_is_group,
                source,
                client_id,
            )
            .await
            .map_err(safe_error)?;
            sent_response(&response, &target_id, client_id)?
        }
        "lookup_phone" => {
            let phone = required_text(params, "phone", 64)?;
            let digits = chat::normalize_phone_for_lookup(&phone);
            if !(8..=16).contains(&digits.len()) {
                bail!(super::UserError("Số điện thoại không hợp lệ."));
            }
            let user = chat::find_user_by_phone(session, &phone)
                .await
                .map_err(safe_error)?;
            json!({
                "user_id": user.user_id,
                "display_name": user.display_name,
                "zalo_name": user.zalo_name,
                "phone": user.phone,
                "avatar": http_url(&user.avatar),
                "status": user.status,
                "friendship": user.friendship,
            })
        }
        "full_avatar" => {
            // Zalo PC `getFullAvatar`: GET profile service `/api/social/profile/avatar`, `{fid, imei}`,
            // answers `full_avatar` (re-notes/67_full_avatar_and_open_unread.md).
            let user_id = required_text(params, "user_id", 64)?;
            if !user_id.bytes().all(|b| b.is_ascii_digit()) {
                bail!(super::UserError("Mã người dùng không hợp lệ."));
            }
            let encoded = session.encoded_params(&json!({"fid": user_id, "imei": session.imei}))?;
            let response = session
                .get_endpoint("profile", &format!("/api/social/profile/avatar?{}&params={encoded}", session.common_params()))
                .await
                .map_err(safe_error)?;
            let response = session.maybe_decrypt(response, session.session_key_bytes()).await;
            if response.get("error_code").and_then(Value::as_i64).is_some_and(|code| code != 0) {
                bail!(super::UserError("Zalo chưa trả về ảnh gốc."));
            }
            let data = response.get("data").cloned().unwrap_or(Value::Null);
            let url = ["full_avatar", "bk_full_avatar"]
                .iter()
                .find_map(|key| data.get(*key).and_then(Value::as_str))
                .map(str::trim)
                .filter(|url| url.starts_with("https://") || url.starts_with("http://"))
                .map(http_url);
            json!({"user_id": user_id, "url": url})
        }
        "check_friend" => {
            let user_id = required_text(params, "user_id", 256)?;
            let friendship = chat::check_friendship_status(session, &user_id)
                .await
                .map_err(safe_error)?;
            json!({"user_id": user_id, "friendship": friendship})
        }
        "get_profile" => {
            let user_id = required_text(params, "user_id", 256)?;
            if !user_id.bytes().all(|b| b.is_ascii_digit()) {
                bail!(super::UserError("Mã người dùng không hợp lệ."));
            }
            // The full profile is often friend-only; a stranger still gets name and avatar.
            let full = session.get_friend_social_profile_value(&user_id).await.ok();
            let mini = if full.is_none() {
                chat::get_mini_profiles(session, std::slice::from_ref(&user_id)).await.ok()
                    .and_then(|map| map.get(&user_id).cloned())
            } else { None };
            let source = full.as_ref().or(mini.as_ref());
            let text = |keys: &[&str]| -> Option<String> {
                keys.iter().find_map(|key| source?.get(*key).and_then(Value::as_str))
                    .map(str::trim).filter(|value| !value.is_empty()).map(str::to_owned)
            };
            let friendship = chat::check_friendship_status(session, &user_id).await.ok();
            json!({
                "user_id": user_id,
                "display_name": text(&["displayName", "zaloName"]),
                "zalo_name": text(&["zaloName"]),
                "avatar": text(&["avatar", "avt"]).map(|url| http_url(&url)),
                "cover": text(&["cover"]).map(|url| http_url(&url)),
                "gender": source.and_then(|p| p.get("gender")).and_then(Value::as_i64),
                "birthday": text(&["sdob"]),
                "status": text(&["status", "statusMsg"]),
                "phone": text(&["phoneNumber", "phone"]),
                "friendship": friendship,
                "full_profile": full.is_some(),
                // Official accounts (pages) carry `oaInfo`; they take no friend requests.
                "is_official": source.is_some_and(|p| p.get("oaInfo").is_some_and(|oa| oa.as_object().is_some_and(|o| !o.is_empty()))
                    || p.get("oa_status").is_some_and(|v| !v.is_null())),
            })
        }
        "add_friend" | "accept_friend" | "reject_friend" | "undo_friend" => {
            let user_id = required_text(params, "user_id", 256)?;
            let response = match command {
                "add_friend" => {
                    let message = optional_text(params, "message", 2048)?
                        .unwrap_or_else(|| "Xin chào, mình kết bạn nhé!".into());
                    chat::send_friend_request(session, &user_id, &message).await
                }
                "accept_friend" => chat::accept_friend_request(session, &user_id).await,
                "reject_friend" => chat::reject_friend_request(session, &user_id).await,
                _ => chat::undo_friend_request(session, &user_id).await,
            }
            .map_err(safe_error)?;
            check_response(&response)?;
            json!({"user_id": user_id})
        }
        "import_history" => {
            let path = PathBuf::from(required_text(params, "path", 4096)?);
            let include_media = boolean(params, "include_media", false)?;
            let db_path = db_path.to_owned();
            let login = session.login.clone().unwrap_or_default();
            let output = output.clone();
            tokio::task::spawn_blocking(move || {
                if crate::zalo_backup::ContainerVersion::from_path(&path).is_some() {
                    let mut result = import_zalo_export(&path, &login.dkey, &login.uin, &db_path, &output)?;
                    if include_media && result["cancelled"] != json!(true) {
                        let media = import_zalo_media(&path, &login.dkey, &login.uin, &db_path, &output)?;
                        if let (Some(target), Some(extra)) = (result.as_object_mut(), media.as_object()) {
                            target.extend(extra.clone());
                        }
                    }
                    Ok(result)
                } else {
                    import_history(&path, &db_path)
                }
            })
                .await
                .context(super::UserError("Không hoàn tất việc nhập lịch sử."))??
        }
        "schedule_message" => {
            let thread_id = required_text(params, "thread_id", 256)?;
            let is_group = boolean(params, "is_group", false)?;
            let thread_name = known_thread(threads, &thread_id, is_group)?.name.clone();
            let text = required_text(params, "text", MAX_TEXT_BYTES)?;
            let now = crate::login::unix_now();
            let deliver_at = params
                .get("deliver_at")
                .and_then(Value::as_i64)
                .context(super::UserError("Thời gian hẹn gửi không hợp lệ."))?;
            validate_schedule_time(deliver_at, now)?;
            let db_path = db_path.to_owned();
            let item = tokio::task::spawn_blocking(move || {
                crate::scheduler::schedule_message(
                    &db_path,
                    &thread_id,
                    &thread_name,
                    is_group,
                    &text,
                    deliver_at,
                    now,
                )
            })
            .await
            .context(super::UserError("Không lưu được tin nhắn hẹn giờ."))??;
            scheduled_item(&item)
        }
        "list_scheduled" => {
            let thread_id = optional_text(params, "thread_id", 256)?;
            let db_path = db_path.to_owned();
            let items = tokio::task::spawn_blocking(move || {
                crate::scheduler::list_pending_scheduled(&db_path, thread_id.as_deref())
            })
            .await
            .context(super::UserError("Không đọc được tin nhắn hẹn giờ."))??;
            let items: Vec<_> = items.iter().take(1000).map(scheduled_item).collect();
            json!({"items": items})
        }
        "cancel_scheduled" => {
            let id = params
                .get("schedule_id")
                .and_then(Value::as_i64)
                .filter(|id| *id > 0)
                .context(super::UserError("Mã tin nhắn hẹn giờ không hợp lệ."))?;
            let db_path = db_path.to_owned();
            let cancelled = tokio::task::spawn_blocking(move || {
                let connection = rusqlite::Connection::open(db_path)?;
                cancel_pending(&connection, id)
            })
            .await
            .context(super::UserError("Không hủy được tin nhắn hẹn giờ."))??;
            if !cancelled {
                bail!(super::UserError(
                    "Tin nhắn đang được gửi hoặc không còn trong hàng đợi; không thể hủy."
                ));
            }
            json!({"schedule_id": id, "cancelled": true})
        }
        _ => return Ok(None),
    };
    Ok(Some(value))
}

/// Deliver at most one due scheduled message and return its acknowledged row.
///
/// # Errors
/// Returns a queue or persistence error. Individual delivery failures remain in
/// the queue as failed items; they are never automatically retried.
pub(super) async fn deliver_due(
    session: &Session,
    db_path: &str,
) -> Result<Vec<(String, ChatMessage)>> {
    if session.login.is_none() {
        return Ok(Vec::new());
    }
    let now = crate::login::unix_now();
    let queue_path = db_path.to_owned();
    let due = tokio::task::spawn_blocking(move || {
        let mut connection = rusqlite::Connection::open(&queue_path)?;
        connection.execute_batch(
            "PRAGMA journal_mode = WAL;
             PRAGMA synchronous = NORMAL;
             PRAGMA busy_timeout = 5000;
             PRAGMA foreign_keys = ON;",
        )?;
        claim_next_due(&mut connection, now)
    })
    .await
    .context(super::UserError("Không đọc được hàng đợi hẹn giờ."))??;
    let mut sent = Vec::new();
    if let Some(item) = due {
        let client_id = chat::next_client_message_id();
        let send = async {
            let response = if item.is_group {
                chat::send_group_message_with_client_id(
                    session,
                    &item.thread_id,
                    &item.text,
                    client_id,
                )
                .await
            } else {
                chat::send_message_with_client_id(session, &item.thread_id, &item.text, client_id)
                    .await
            }?;
            sent_response(&response, &item.thread_id, client_id)
        };
        let outcome = tokio::time::timeout(Duration::from_secs(15), send).await;
        let (id, error, row) = match outcome {
            Ok(Ok(response)) => {
                let row = ChatMessage {
                    kind: crate::message_model::MessageKind::Text,
                    id: response["message_id"]
                        .as_str()
                        .unwrap_or_default()
                        .to_owned(),
                    client_message_id: client_id.to_string(),
                    sender: "Tôi".into(),
                    text: item.text,
                    ts: crate::login::unix_now() * 1000,
                    time: crate::ui::clock(),
                    is_outgoing: true,
                    ..Default::default()
                };
                (item.id, None, Some((item.thread_id, row)))
            }
            Ok(Err(_)) => (
                item.id,
                Some("Không gửi được tin nhắn hẹn giờ. Hãy kiểm tra kết nối trước khi thử lại."),
                None,
            ),
            Err(_) => (
                item.id,
                Some("Chưa xác định được kết quả gửi. Hãy kiểm tra hội thoại trước khi thử lại."),
                None,
            ),
        };
        let queue_path = db_path.to_owned();
        tokio::task::spawn_blocking(move || match error {
            None => crate::scheduler::mark_scheduled_sent(&queue_path, id),
            Some(message) => crate::scheduler::mark_scheduled_failed(&queue_path, id, message),
        })
        .await
        .context(super::UserError("Không cập nhật được kết quả hẹn giờ."))??;
        if let Some(row) = row {
            sent.push(row);
        }
    }
    Ok(sent)
}

fn claim_next_due(
    connection: &mut rusqlite::Connection,
    now: i64,
) -> Result<Option<crate::scheduler::ScheduledMessage>> {
    use rusqlite::OptionalExtension;
    crate::scheduler::init_scheduler_schema(connection)?;
    let transaction =
        connection.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
    // Claiming one item keeps user commands responsive and leaves the rest pending.
    let item = transaction
        .query_row(
            "SELECT id, thread_id, thread_name, is_group, text, deliver_at, created_at, status
             FROM scheduled_messages WHERE status = 'pending' AND deliver_at <= ?1
             ORDER BY deliver_at ASC, id ASC LIMIT 1",
            rusqlite::params![now],
            |row| {
                Ok(crate::scheduler::ScheduledMessage {
                    id: row.get(0)?,
                    thread_id: row.get(1)?,
                    thread_name: row.get(2)?,
                    is_group: row.get::<_, i64>(3)? != 0,
                    text: row.get(4)?,
                    deliver_at: row.get(5)?,
                    created_at: row.get(6)?,
                    status: row.get(7)?,
                    error_msg: String::new(),
                })
            },
        )
        .optional()?;
    if let Some(ref item) = item {
        transaction.execute(
            "UPDATE scheduled_messages SET status = 'sending' WHERE id = ?1 AND status = 'pending'",
            rusqlite::params![item.id],
        )?;
    }
    transaction.commit()?;
    Ok(item)
}

fn cancel_pending(connection: &rusqlite::Connection, id: i64) -> Result<bool> {
    connection.busy_timeout(Duration::from_secs(5))?;
    // The poll task can claim concurrently; a sending item must never report cancelled.
    let deleted = connection.execute(
        "DELETE FROM scheduled_messages WHERE id = ?1 AND status IN ('pending','failed')",
        rusqlite::params![id],
    )?;
    Ok(deleted > 0)
}

/// Newest stored messages scanned for the conversation library (photos, files, links).
const LIBRARY_SCAN_LIMIT: usize = 20_000;
/// Items returned per library section.
const LIBRARY_SECTION_LIMIT: usize = 300;

/// Photos, files and links of one conversation from the whole local history, not only
/// the page loaded in the transcript. Media classification matches the transcript DTO.
async fn thread_library(thread: Thread, db_path: String) -> Result<Value> {
    tokio::task::spawn_blocking(move || -> Result<Value> {
        let mut scope = vec![Thread {
            messages: thread.messages.clone(),
            ..thread
        }];
        if !db_path.is_empty() && Path::new(&db_path).exists() {
            let store = crate::store::MessageStore::open(&db_path)?;
            store.hydrate_loaded_threads(&mut scope, LIBRARY_SCAN_LIMIT)?;
        }
        let mut messages = std::mem::take(&mut scope[0].messages);
        messages.sort_by(|a, b| b.ts.cmp(&a.ts).then_with(|| b.id.cmp(&a.id)));
        let (mut photos, mut files, mut links) = (Vec::new(), Vec::new(), Vec::new());
        for message in &messages {
            let dto = serde_json::to_value(super::message_dto(message, ""))?;
            let has = |key: &str| dto.get(key).is_some_and(|value| !value.is_null());
            let kind = dto.get("msg_type").and_then(Value::as_str).unwrap_or_default();
            let bucket = if kind == "chat.photo" || kind == "chat.video.msg" && has("image_url") {
                &mut photos
            } else if kind == "share.file" || kind == "chat.video.msg" {
                &mut files
            } else if kind != "chat.sticker" && kind != "chat.location" && has("link_url") {
                &mut links
            } else {
                continue;
            };
            if bucket.len() < LIBRARY_SECTION_LIMIT {
                bucket.push(dto);
            }
        }
        Ok(json!({
            "thread_id": scope[0].id,
            "scanned": messages.len(),
            "photos": photos,
            "files": files,
            "links": links,
        }))
    })
    .await
    .context("thread library task")?
}

fn required_text(params: &Value, key: &str, max_bytes: usize) -> Result<String> {
    let value = optional_text(params, key, max_bytes)?
        .context(super::UserError("Thiếu thông tin cần thiết."))?;
    if value.trim().is_empty() {
        bail!(super::UserError("Thông tin bắt buộc không được để trống."));
    }
    Ok(value)
}

fn known_thread<'a>(threads: &'a [Thread], id: &str, is_group: bool) -> Result<&'a Thread> {
    threads
        .iter()
        .find(|thread| thread.id == id && thread.is_group == is_group)
        .context(super::UserError(
            "Hội thoại không còn khả dụng. Hãy làm mới danh sách.",
        ))
}

fn optional_text(params: &Value, key: &str, max_bytes: usize) -> Result<Option<String>> {
    let Some(value) = params.get(key) else {
        return Ok(None);
    };
    let value = value
        .as_str()
        .context(super::UserError("Thông tin nhập phải là văn bản."))?;
    if value.len() > max_bytes || value.contains('\0') {
        bail!(super::UserError(
            "Thông tin nhập vượt quá giới hạn cho phép."
        ));
    }
    Ok(Some(value.to_owned()))
}

fn boolean(params: &Value, key: &str, default: bool) -> Result<bool> {
    match params.get(key) {
        None => Ok(default),
        Some(value) => value
            .as_bool()
            .context(super::UserError("Tùy chọn nhập không hợp lệ.")),
    }
}

fn unsigned(params: &Value, key: &str, allow_zero: bool) -> Result<u64> {
    params
        .get(key)
        .and_then(Value::as_u64)
        .filter(|value| allow_zero || *value > 0)
        .context(super::UserError("Định danh nhập không hợp lệ."))
}

fn http_url(raw: &str) -> Option<String> {
    reqwest::Url::parse(raw)
        .ok()
        .filter(|url| {
            matches!(url.scheme(), "https" | "http")
                && url.username().is_empty()
                && url.password().is_none()
        })
        .map(|url| url.to_string())
}

fn sticker_items(items: Vec<chat::StickerItem>) -> Vec<Value> {
    items
        .into_iter()
        .take(500)
        .map(|item| {
            json!({
                "sticker_id": item.sticker_id,
                "cate_id": item.cate_id,
                "sticker_type": item.sticker_type,
                "label": item.label,
                "image_url": format!("{}/api/emoticon/sticker/webpc?eid={}&size=130", crate::endpoints::STICKER_CDN, item.sticker_id),
            })
        })
        .collect()
}

fn check_response(response: &Value) -> Result<()> {
    let code = response
        .get("error_code")
        .and_then(Value::as_i64)
        .context(super::UserError("Máy chủ trả về dữ liệu không hợp lệ."))?;
    if code != 0 {
        return Err(SessionError::new(code, "Zalo không thực hiện được yêu cầu.").into());
    }
    Ok(())
}

fn sent_response(response: &Value, thread_id: &str, client_id: u64) -> Result<Value> {
    check_response(response)?;
    let message_id = response
        .get("data")
        .and_then(|data| data.get("msgId"))
        .and_then(|id| match id {
            Value::String(value) => Some(value.clone()),
            Value::Number(value) => Some(value.to_string()),
            _ => None,
        })
        .filter(|id| !id.is_empty())
        .unwrap_or_else(|| format!("out_{client_id}"));
    Ok(json!({
        "message_id": message_id,
        "client_message_id": client_id.to_string(),
        "target_thread_id": thread_id,
    }))
}

fn safe_error(error: anyhow::Error) -> anyhow::Error {
    if let Some(server) = error.downcast_ref::<SessionError>() {
        return SessionError::new(server.code, "Zalo không thực hiện được yêu cầu.").into();
    }
    anyhow::anyhow!("Không hoàn tất được yêu cầu. Hãy kiểm tra kết nối rồi thử lại.")
}

fn validate_schedule_time(deliver_at: i64, now: i64) -> Result<()> {
    if deliver_at <= now || deliver_at > now.saturating_add(366 * 24 * 60 * 60) {
        bail!(super::UserError(
            "Chọn thời gian hẹn gửi trong vòng một năm tới."
        ));
    }
    Ok(())
}

fn scheduled_item(item: &crate::scheduler::ScheduledMessage) -> Value {
    json!({
        "id": item.id,
        "thread_id": item.thread_id,
        "thread_name": item.thread_name,
        "is_group": item.is_group,
        "text": item.text,
        "deliver_at": item.deliver_at,
        "status": item.status,
        "has_error": !item.error_msg.is_empty(),
    })
}

/// Imports an official Zalo PC export, reporting progress as lossy events.
fn import_zalo_export(
    source: &Path,
    data_key: &str,
    own_uid: &str,
    db_path: &str,
    output: &tokio::sync::mpsc::Sender<Value>,
) -> Result<Value> {
    let metadata = std::fs::symlink_metadata(source)
        .context(super::UserError("Không đọc được tệp sao lưu đã chọn."))?;
    if !metadata.is_file() || metadata.file_type().is_symlink() {
        bail!(super::UserError("Hãy chọn trực tiếp tệp sao lưu .zl.zip."));
    }
    crate::zalo_backup::IMPORT_CANCEL.store(false, Ordering::Relaxed);
    let mut last_percent = -1i64;
    let report = crate::zalo_backup::import_zalo_export(source, data_key, own_uid, db_path, |fraction, rows| {
        let percent = (fraction * 1000.0) as i64;
        if percent != last_percent {
            last_percent = percent;
            // Progress is advisory: a full channel drops the update instead of stalling the import.
            let _ = output.try_send(json!({"event": "import_progress", "data": {
                "progress": fraction.clamp(0.0, 1.0), "rows": rows,
            }}));
        }
    })
    .map_err(|error| match error.downcast::<crate::zalo_backup::BackupError>() {
        Ok(backup) => anyhow::Error::new(super::UserError(backup.0)),
        Err(_) => anyhow::Error::new(super::UserError("Không nhập được tệp sao lưu. Kiểm tra dung lượng ổ đĩa rồi thử lại.")),
    })?;
    Ok(json!({
        "threads_imported": report.threads_imported,
        "messages_imported": report.messages_imported,
        "messages_seen": report.messages_seen,
        "lines_skipped": report.lines_skipped,
        "cancelled": report.cancelled,
        "media_imported": false,
        "sources_read": report.database_files,
    }))
}

/// Second pass over the same export: copies photos, videos and files into `<account>/media/` and
/// links them to the messages (re-notes/64).
fn import_zalo_media(
    source: &Path,
    data_key: &str,
    own_uid: &str,
    db_path: &str,
    output: &tokio::sync::mpsc::Sender<Value>,
) -> Result<Value> {
    let account = Path::new(db_path)
        .parent()
        .filter(|dir| !dir.as_os_str().is_empty())
        .context(super::UserError("Không xác định được thư mục tài khoản."))?;
    let media_root = account.join("media");
    let mut last_percent = -1i64;
    let report = crate::zalo_backup::media::import_zalo_media(source, data_key, own_uid, db_path, &media_root, |fraction, files| {
        let percent = (fraction * 1000.0) as i64;
        if percent != last_percent {
            last_percent = percent;
            let _ = output.try_send(json!({"event": "import_progress", "data": {
                "progress": fraction.clamp(0.0, 1.0), "rows": files, "phase": "media",
            }}));
        }
    })
    .map_err(|error| match error.downcast::<crate::zalo_backup::BackupError>() {
        Ok(backup) => anyhow::Error::new(super::UserError(backup.0)),
        Err(_) => anyhow::Error::new(super::UserError("Không chép được ảnh, video và tệp. Kiểm tra dung lượng ổ đĩa rồi thử lại.")),
    })?;
    Ok(json!({
        "media_imported": true,
        "media_files_written": report.files_written,
        "media_files_present": report.files_already_present,
        "media_bytes_written": report.bytes_written,
        "media_messages_linked": report.messages_linked,
        "media_files_unmatched": report.files_unmatched,
        "cancelled": report.cancelled,
    }))
}

fn import_history(source: &Path, db_path: &str) -> Result<Value> {
    let metadata = std::fs::symlink_metadata(source).context(super::UserError(
        "Không đọc được nguồn dữ liệu lịch sử đã chọn.",
    ))?;
    if metadata.file_type().is_symlink() {
        bail!(super::UserError(
            "Hãy chọn trực tiếp tệp hoặc thư mục dữ liệu lịch sử."
        ));
    }
    let staging = std::env::temp_dir().join(format!(
        "ctdozlite-native-import-{}-{}",
        std::process::id(),
        NEXT_IMPORT.fetch_add(1, Ordering::Relaxed)
    ));
    // Imports may initialize a legacy source database; operate only on private copies.
    let mut builder = std::fs::DirBuilder::new();
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        builder.mode(0o700);
    }
    builder.create(&staging).context(super::UserError(
        "Không tạo được thư mục tạm để nhập lịch sử.",
    ))?;
    crate::data_dir::prepare(&staging, true).context(super::UserError(
        "Không tạo được thư mục tạm để nhập lịch sử.",
    ))?;
    let result = (|| {
        let mut copied = 0usize;
        if metadata.is_dir() {
            for name in [
                "zalo_history.db",
                "ctdozlite_history.db",
                "threads_cache.json",
                "export.json",
            ] {
                let path = source.join(name);
                if path.is_file() {
                    stage_history_file(&path, &staging)?;
                    copied += 1;
                }
            }
        } else if metadata.is_file() {
            stage_history_file(source, &staging)?;
            copied += 1;
        }
        if copied == 0 {
            bail!(super::UserError(
                "Không tìm thấy tệp lịch sử được hỗ trợ trong thư mục đã chọn."
            ));
        }
        let report = crate::store::import_history_from_path(&staging, db_path)
            .context(super::UserError("Không nhập được lịch sử từ tệp đã chọn."))?;
        if report.sources_read.is_empty() {
            bail!(super::UserError(
                "Tệp đã chọn không chứa dữ liệu lịch sử được hỗ trợ."
            ));
        }
        Ok(json!({
            "threads_imported": report.threads_imported,
            "messages_imported": report.messages_imported,
            "sources_read": copied,
        }))
    })();
    // Staging cleanup must not replace the original import result.
    let _ = std::fs::remove_dir_all(staging);
    result
}

fn stage_history_file(source: &Path, staging: &Path) -> Result<()> {
    let metadata = std::fs::symlink_metadata(source)
        .context(super::UserError("Không đọc được tệp lịch sử đã chọn."))?;
    if !metadata.is_file() || metadata.file_type().is_symlink() {
        bail!(super::UserError(
            "Nguồn lịch sử phải là một tệp thông thường."
        ));
    }
    let name = source
        .file_name()
        .and_then(|value| value.to_str())
        .context(super::UserError("Tên tệp lịch sử không hợp lệ."))?;
    let lower = name.to_ascii_lowercase();
    if lower.contains("session") || lower.contains("cookie") || lower.contains("credential") {
        bail!(super::UserError(
            "Tệp xác thực không phải là dữ liệu lịch sử để nhập."
        ));
    }
    let extension = source
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase();
    if !matches!(extension.as_str(), "db" | "sqlite" | "sqlite3" | "json") {
        bail!(super::UserError(
            "Chỉ hỗ trợ tệp lịch sử .db, .sqlite, .sqlite3 hoặc .json."
        ));
    }
    let wal = source.with_file_name(format!("{name}-wal"));
    if std::fs::metadata(wal).is_ok_and(|metadata| metadata.len() > 0) {
        bail!(super::UserError(
            "Hãy đóng ứng dụng đang dùng tệp lịch sử trước khi nhập."
        ));
    }
    use std::io::Read;
    let mut input =
        std::fs::File::open(source).context(super::UserError("Không mở được tệp lịch sử."))?;
    let mut header = [0u8; 16];
    let header_len = input.read(&mut header).unwrap_or(0);
    let limit = if header[..header_len].starts_with(b"SQLite format 3") {
        MAX_SQLITE_IMPORT_BYTES
    } else {
        MAX_BUFFERED_IMPORT_BYTES
    };
    if metadata.len() > limit {
        bail!(super::UserError(
            "Tệp lịch sử quá lớn với định dạng này. Tệp JSON tối đa 2 GB; bản xuất của Zalo (.zl.zip) và SQLite không giới hạn theo cách này."
        ));
    }
    use std::io::Seek;
    input
        .seek(std::io::SeekFrom::Start(0))
        .context(super::UserError("Không đọc được tệp lịch sử."))?;
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut output = options
        .open(staging.join(name))
        .context(super::UserError("Không tạo được bản sao tệp lịch sử."))?;
    let copied = std::io::copy(&mut input.take(limit + 1), &mut output)
        .context(super::UserError("Không sao chép được tệp lịch sử. Kiểm tra dung lượng ổ đĩa."))?;
    if copied > limit {
        bail!(super::UserError("Tệp lịch sử thay đổi trong lúc sao chép. Hãy thử lại."));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_oversized_and_non_string_input() {
        assert!(required_text(&json!({"text": "abcd"}), "text", 3).is_err());
        assert!(required_text(&json!({"text": 42}), "text", 64).is_err());
        assert!(required_text(&json!({"text": "   "}), "text", 64).is_err());
        assert!(required_text(&json!({"text": "a\u{0}b"}), "text", 64).is_err());
    }

    #[test]
    fn validates_boolean_and_unsigned_intent_fields() {
        assert!(boolean(&json!({"is_group": "false"}), "is_group", false).is_err());
        assert!(!boolean(&json!({}), "is_group", false).unwrap());
        assert!(unsigned(&json!({"id": -1}), "id", false).is_err());
        assert!(unsigned(&json!({"id": 0}), "id", false).is_err());
        assert_eq!(unsigned(&json!({"id": 0}), "id", true).unwrap(), 0);
    }

    #[test]
    fn permits_only_future_schedule_times_within_one_year() {
        let now = 1_800_000_000;
        assert!(validate_schedule_time(now, now).is_err());
        assert!(validate_schedule_time(now - 1, now).is_err());
        assert!(validate_schedule_time(i64::MAX, now).is_err());
        assert!(validate_schedule_time(now + 3600, now).is_ok());
    }

    #[test]
    fn redacts_server_errors_and_preserves_auth_code() {
        let original: anyhow::Error = SessionError::new(600, "zpw_sek=not-a-real-key").into();
        let safe = safe_error(original);
        assert!(!safe.to_string().contains("not-a-real-key"));
        assert!(safe.downcast_ref::<SessionError>().unwrap().is_auth());
    }

    #[test]
    fn does_not_copy_untrusted_server_fields_into_send_result() {
        let result = sent_response(
            &json!({"error_code": 0,"data": {"msgId": 42,"secret":"not-for-ui"}}),
            "thread-1",
            101,
        )
        .unwrap();
        assert_eq!(result["message_id"], "42");
        assert!(!result.to_string().contains("not-for-ui"));
        let error = sent_response(&json!({"error_code": -102}), "thread-1", 101).unwrap_err();
        assert!(error.downcast_ref::<SessionError>().unwrap().is_auth());
    }

    #[test]
    fn rejects_executable_and_credential_image_urls() {
        assert!(http_url("file:///tmp/test.png").is_none());
        assert!(http_url("https://user:password@example.invalid/test.png").is_none());
        assert!(http_url("https://example.invalid/test.png").is_some());
    }

    struct Scratch(PathBuf);

    impl Scratch {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "ctdozlite-native-extra-test-{}-{}",
                std::process::id(),
                NEXT_IMPORT.fetch_add(1, Ordering::Relaxed)
            ));
            std::fs::create_dir(&path).unwrap();
            Self(path)
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            // Synthetic test artifacts are disposable even when an assertion failed.
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn importing_legacy_database_preserves_original_bytes_and_is_idempotent() {
        let scratch = Scratch::new();
        let source = scratch.0.join("legacy.db");
        let target = scratch.0.join("account-1.db");
        let source_db = rusqlite::Connection::open(&source).unwrap();
        source_db
            .execute_batch(
                "CREATE TABLE messages (msg_id TEXT PRIMARY KEY, thread_id TEXT, sender_id TEXT,
                 sender_name TEXT, text TEXT, msg_type TEXT, ts INTEGER, is_outgoing INTEGER,
                 raw_json TEXT);
                 CREATE TABLE threads (thread_id TEXT PRIMARY KEY, name TEXT,
                 is_group INTEGER, last_ts INTEGER);
                 INSERT INTO threads VALUES ('thread-1','Test',0,1000);
                 INSERT INTO messages VALUES ('msg-1','thread-1','user-1','Test','Hello','text',1000,0,'');
                 INSERT INTO messages VALUES ('placeholder-1','thread-1','user-1','Test',
                 'sendBubbleMessage','text',999,0,'');",
            )
            .unwrap();
        drop(source_db);
        let original = std::fs::read(&source).unwrap();
        let target = target.to_str().unwrap();
        let first = import_history(&source, target).unwrap();
        assert_eq!(first["messages_imported"], 1);
        assert_eq!(std::fs::read(&source).unwrap(), original);
        let second = import_history(&source, target).unwrap();
        assert_eq!(second["messages_imported"], 0); // (INV-4)
        assert_eq!(std::fs::read(&source).unwrap(), original);
    }

    #[test]
    fn refusing_credentials_or_live_wal_does_not_copy_source() {
        let scratch = Scratch::new();
        let staging = scratch.0.join("staging");
        std::fs::create_dir(&staging).unwrap();
        let credentials = scratch.0.join("session.json");
        std::fs::write(&credentials, b"{}").unwrap();
        assert!(stage_history_file(&credentials, &staging).is_err());
        assert!(!staging.join("session.json").exists());
        let source = scratch.0.join("history.db");
        std::fs::write(&source, b"synthetic").unwrap();
        std::fs::write(scratch.0.join("history.db-wal"), b"pending").unwrap();
        assert!(stage_history_file(&source, &staging).is_err());
        assert!(!staging.join("history.db").exists());
    }

    #[test]
    fn destination_kind_must_match_known_thread() {
        let threads = vec![Thread {
            id: "thread-1".into(),
            is_group: false,
            ..Default::default()
        }];
        assert!(known_thread(&threads, "thread-1", false).is_ok());
        assert!(known_thread(&threads, "thread-1", true).is_err());
        assert!(known_thread(&threads, "thread-other", false).is_err());
    }

    #[test]
    fn schedule_batch_claims_one_due_item_and_keeps_remaining_items_pending() {
        let mut connection = rusqlite::Connection::open_in_memory().unwrap();
        crate::scheduler::init_scheduler_schema(&connection).unwrap();
        for (text, due) in [("first", 10), ("second", 20), ("future", 100)] {
            connection
                .execute(
                    "INSERT INTO scheduled_messages (thread_id,text,deliver_at,created_at)
                     VALUES (?1,?2,?3,?4)",
                    rusqlite::params!["thread-1", text, due, 0],
                )
                .unwrap();
        }
        let claimed = claim_next_due(&mut connection, 30).unwrap().unwrap();
        assert_eq!(claimed.text, "first");
        let pending: i64 = connection
            .query_row(
                "SELECT COUNT(*) FROM scheduled_messages WHERE status = 'pending'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(pending, 2);
        let next = claim_next_due(&mut connection, 30).unwrap().unwrap();
        assert_eq!(next.text, "second");
        assert!(claim_next_due(&mut connection, 30).unwrap().is_none());
    }

    #[test]
    fn cancellation_cannot_claim_success_after_delivery_was_claimed() {
        let mut connection = rusqlite::Connection::open_in_memory().unwrap();
        crate::scheduler::init_scheduler_schema(&connection).unwrap();
        connection
            .execute(
                "INSERT INTO scheduled_messages (thread_id,text,deliver_at,created_at)
                 VALUES (?1,?2,?3,?4)",
                rusqlite::params!["thread-1", "Test", 10, 0],
            )
            .unwrap();
        let claimed = claim_next_due(&mut connection, 20).unwrap().unwrap();
        assert!(!cancel_pending(&connection, claimed.id).unwrap());
        connection
            .execute(
                "UPDATE scheduled_messages SET status = 'failed' WHERE id = ?1",
                rusqlite::params![claimed.id],
            )
            .unwrap();
        assert!(cancel_pending(&connection, claimed.id).unwrap());
        assert!(!cancel_pending(&connection, claimed.id).unwrap());
    }
}
