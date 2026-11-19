//! UI-independent worker and bounded JSON-lines bridge for native clients.
//!
//! Only presentation DTOs cross this boundary. Session cookies, keys, raw server
//! responses, and egui objects remain inside the Rust process (INV-2, INV-3).

use std::collections::{HashMap, HashSet, VecDeque};
use std::io::{BufRead, Write};
use std::path::Path;
use std::time::Duration;

use anyhow::{anyhow, bail, Context, Result};
use base64::Engine;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tokio::sync::mpsc;

use crate::chat::{self, ChatMessage, Thread};
use crate::session::{Session, SessionError, SessionStatus};
use crate::store::{self, MessageStore};

mod account_settings;
mod account_watch;
mod client_preferences;
mod extras;
mod features;
mod history;
mod platform;

const MAX_FRAME: usize = 256 * 1024;
const MAX_TEXT: usize = 20_000;
const MAX_MESSAGES: usize = 2_000;
const MAX_THREADS: usize = 10_000;
const SNAPSHOT_BYTES: usize = 3 * 1024 * 1024;
const MAX_OUTPUT_FRAME: usize = 4 * 1024 * 1024;
const CAPABILITIES: &[&str] = &[
    "bootstrap",
    "request_qr",
    "refresh_threads",
    "load_messages",
    "select_thread",
    "load_message_page",
    "send_message",
    "send_attachment",
    "send_quote",
    "react",
    "recall_message",
    "delete_message",
    "poll_detail",
    "poll_vote",
    "sync_history",
    "mark_seen",
    "pin_thread",
    "mute_thread",
    "logout",
    "shutdown",
];

#[derive(Clone, Deserialize, Serialize)]
struct Request {
    id: String,
    #[serde(flatten)]
    command: NativeIntent,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(tag = "command", rename_all = "snake_case")]
enum Command {
    Bootstrap,
    RequestQr,
    RefreshThreads,
    /// The UI opened a conversation it already has cached; no history request is made.
    SelectThread {
        thread_id: String,
        #[serde(default)]
        is_group: bool,
    },
    LoadMessages {
        thread_id: String,
        #[serde(default)]
        is_group: bool,
        #[serde(default = "default_limit")]
        limit: usize,
    },
    LoadMessagePage {
        thread_id: String,
        #[serde(default)]
        is_group: bool,
        #[serde(default)]
        before: Option<history::Cursor>,
        #[serde(default)]
        after: Option<history::Cursor>,
        #[serde(default = "default_limit")]
        limit: usize,
    },
    SendMessage {
        thread_id: String,
        #[serde(default)]
        is_group: bool,
        text: String,
        /// Members tagged with `@Name` in a group; they are notified like in Zalo.
        #[serde(default)]
        mentions: Vec<chat::Mention>,
    },
    SendAttachment {
        thread_id: String,
        #[serde(default)]
        is_group: bool,
        path: String,
        #[serde(default)]
        caption: String,
    },
    SendQuote {
        thread_id: String,
        #[serde(default)]
        is_group: bool,
        text: String,
        message_id: String,
    },
    React {
        thread_id: String,
        #[serde(default)]
        is_group: bool,
        message_id: String,
        reaction: String,
    },
    RecallMessage {
        thread_id: String,
        #[serde(default)]
        is_group: bool,
        message_id: String,
    },
    DeleteMessage {
        thread_id: String,
        #[serde(default)]
        is_group: bool,
        message_id: String,
        /// A group admin removing the message for every member (`onlyMe: 0`, re-notes/76).
        #[serde(default)]
        for_everyone: bool,
    },
    /// Question, options and votes of a group poll (re-notes/74).
    PollDetail {
        thread_id: String,
        poll_id: u64,
    },
    /// Replace this account's choice in a group poll.
    PollVote {
        thread_id: String,
        poll_id: u64,
        option_ids: Vec<u64>,
    },
    SyncHistory {
        thread_id: String,
        #[serde(default)]
        is_group: bool,
    },
    MarkSeen {
        thread_id: String,
        #[serde(default)]
        is_group: bool,
        #[serde(default)]
        message_id: String,
    },
    PinThread {
        thread_id: String,
        #[serde(default)]
        is_group: bool,
        pin: bool,
    },
    MuteThread {
        thread_id: String,
        #[serde(default)]
        is_group: bool,
        mute: bool,
    },
    StickerPacks,
    StickerPack {
        cate_id: u64,
        #[serde(default)]
        name: String,
    },
    SearchStickers {
        keyword: String,
    },
    SuggestStickers {
        keyword: String,
    },
    StickerKeywords,
    SendSticker {
        thread_id: String,
        #[serde(default)]
        is_group: bool,
        sticker_id: u64,
        cate_id: u64,
        #[serde(default = "default_sticker_type")]
        sticker_type: u32,
    },
    ForwardMessage {
        thread_id: String,
        message_id: String,
        target_thread_id: String,
        #[serde(default)]
        target_is_group: bool,
    },
    LookupPhone {
        phone: String,
    },
    CheckFriend {
        user_id: String,
    },
    ThreadLibrary {
        thread_id: String,
        #[serde(default)]
        is_group: bool,
    },
    GetProfile {
        user_id: String,
    },
    AddFriend {
        user_id: String,
        #[serde(default)]
        message: Option<String>,
    },
    AcceptFriend {
        user_id: String,
    },
    RejectFriend {
        user_id: String,
    },
    UndoFriend {
        user_id: String,
    },
    ImportHistory {
        path: String,
        /// Also copy photos, videos and files from a Zalo PC export (re-notes/64).
        #[serde(default)]
        include_media: bool,
    },
    ScheduleMessage {
        thread_id: String,
        #[serde(default)]
        is_group: bool,
        text: String,
        deliver_at: i64,
    },
    ListScheduled {
        #[serde(default)]
        thread_id: Option<String>,
    },
    CancelScheduled {
        schedule_id: i64,
    },
    Logout,
    Shutdown,
}

/// A closed union of typed intent families; no arbitrary request escape hatch.
#[derive(Clone, Deserialize, Serialize)]
#[serde(untagged)]
enum NativeIntent {
    Base(Command),
    Features(features::FeatureCommand),
    Client(ClientCommand),
    Settings(account_settings::SettingsCommand),
    Platform(platform::PlatformCommand),
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(tag = "command", rename_all = "snake_case")]
enum ClientCommand {
    /// Acknowledged here; the input reader already raised the cancel flag.
    CancelImport,
    GetPrivacyGuard,
    SetPrivacyGuard {
        block_typing: bool,
        block_delivered: bool,
        block_seen: bool,
    },
}
impl NativeIntent {
    fn name(&self) -> &'static str {
        match self {
            Self::Base(command) => command.name(),
            Self::Features(command) => command.name(),
            Self::Client(ClientCommand::CancelImport) => "cancel_import",
            Self::Client(ClientCommand::GetPrivacyGuard) => "get_privacy_guard",
            Self::Client(ClientCommand::SetPrivacyGuard { .. }) => "set_privacy_guard",
            Self::Settings(command) => command.name(),
            Self::Platform(command) => command.name(),
        }
    }
    fn is_base(&self, predicate: impl FnOnce(&Command) -> bool) -> bool {
        match self {
            Self::Base(command) => predicate(command),
            _ => false,
        }
    }
}
impl From<Command> for NativeIntent {
    fn from(command: Command) -> Self {
        Self::Base(command)
    }
}
fn intent_fingerprint(command: &NativeIntent) -> Result<String> {
    use sha2::{Digest, Sha256};
    Ok(format!(
        "{:x}",
        Sha256::digest(serde_json::to_vec(command)?)
    ))
}

fn default_limit() -> usize {
    500
}
fn default_sticker_type() -> u32 {
    7
}

impl Command {
    fn name(&self) -> &'static str {
        match self {
            Self::Bootstrap => "bootstrap",
            Self::RequestQr => "request_qr",
            Self::RefreshThreads => "refresh_threads",
            Self::LoadMessages { .. } => "load_messages",
            Self::SelectThread { .. } => "select_thread",
            Self::LoadMessagePage { .. } => "load_message_page",
            Self::SendMessage { .. } => "send_message",
            Self::SendAttachment { .. } => "send_attachment",
            Self::SendQuote { .. } => "send_quote",
            Self::React { .. } => "react",
            Self::RecallMessage { .. } => "recall_message",
            Self::DeleteMessage { .. } => "delete_message",
            Self::PollDetail { .. } => "poll_detail",
            Self::PollVote { .. } => "poll_vote",
            Self::SyncHistory { .. } => "sync_history",
            Self::MarkSeen { .. } => "mark_seen",
            Self::PinThread { .. } => "pin_thread",
            Self::MuteThread { .. } => "mute_thread",
            Self::Logout => "logout",
            Self::Shutdown => "shutdown",
            Self::StickerPacks => "sticker_packs",
            Self::StickerPack { .. } => "sticker_pack",
            Self::SearchStickers { .. } => "search_stickers",
            Self::SuggestStickers { .. } => "suggest_stickers",
            Self::StickerKeywords => "sticker_keywords",
            Self::SendSticker { .. } => "send_sticker",
            Self::ForwardMessage { .. } => "forward_message",
            Self::LookupPhone { .. } => "lookup_phone",
            Self::CheckFriend { .. } => "check_friend",
            Self::GetProfile { .. } => "get_profile",
            Self::ThreadLibrary { .. } => "thread_library",
            Self::AddFriend { .. } => "add_friend",
            Self::AcceptFriend { .. } => "accept_friend",
            Self::RejectFriend { .. } => "reject_friend",
            Self::UndoFriend { .. } => "undo_friend",
            Self::ImportHistory { .. } => "import_history",
            Self::ScheduleMessage { .. } => "schedule_message",
            Self::ListScheduled { .. } => "list_scheduled",
            Self::CancelScheduled { .. } => "cancel_scheduled",
        }
    }
}

#[derive(Serialize)]
struct ThreadDto {
    id: String,
    name: String,
    is_group: bool,
    avatar: Option<String>,
    /// Members drawn in a composite group avatar when the group has no own image.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    avatar_members: Vec<AvatarMemberDto>,
    #[serde(skip_serializing_if = "Option::is_none")]
    member_total: Option<usize>,
    unread: usize,
    marked_unread: bool,
    pinned: bool,
    muted: bool,
    hidden: bool,
    last_message: String,
    last_message_ts: i64,
}

#[derive(Serialize)]
struct AvatarMemberDto {
    name: String,
    avatar: Option<String>,
}

/// Splits the `multi:<total>;<name>|<url>;…` composite produced by `chat::get_groups`.
/// Only web URLs survive, as for every other avatar crossing the bridge.
fn composite_avatar(value: Option<&str>) -> (Vec<AvatarMemberDto>, Option<usize>) {
    let Some(rest) = value.and_then(|value| value.strip_prefix("multi:")) else {
        return (Vec::new(), None);
    };
    let mut parts = rest.split(';');
    let total = parts.next().and_then(|count| count.trim().parse().ok());
    let members = parts
        .take(4)
        .filter_map(|slot| {
            let (name, url) = slot.split_once('|')?;
            Some(AvatarMemberDto { name: name.trim().chars().take(80).collect(), avatar: web_url(Some(url.trim())) })
        })
        .collect();
    (members, total)
}

#[derive(Clone, PartialEq, Serialize)]
struct MessageDto {
    id: String,
    sender_id: String,
    sender_name: String,
    text: String,
    timestamp: i64,
    is_outgoing: bool,
    msg_type: String,
    image_url: Option<String>,
    file_url: Option<String>,
    file_name: Option<String>,
    reactions: Vec<String>,
    /// Per-emoji counts and reactor IDs, so the UI can show who reacted.
    reaction_details: Vec<ReactionDetailDto>,
    reply_to_id: Option<String>,
    reply_to_sender: Option<String>,
    reply_to_text: Option<String>,
    sticker_id: Option<u64>,
    sticker_cate_id: Option<u64>,
    sticker_type: Option<u32>,
    link_url: Option<String>,
    link_title: Option<String>,
    link_desc: Option<String>,
    link_thumb: Option<String>,
    /// The attachment's copy on this Mac (absolute path), when one was imported.
    local_path: Option<String>,
    /// Contact or call card read from the attachment (re-notes/65).
    #[serde(skip_serializing_if = "Option::is_none")]
    card: Option<serde_json::Value>,
    /// Batch placement of a photo, so the UI can draw the batch as one grid.
    #[serde(skip_serializing_if = "Option::is_none")]
    photo_group: Option<chat::PhotoLayout>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
struct ReactionDetailDto {
    emoji: String,
    count: u64,
    reactors: Vec<String>,
    /// How many times each reactor in `reactors` reacted with this emoji (same order).
    reactor_counts: Vec<u64>,
}

/// Zalo's reaction snapshots name this account `"0"`, while a reaction sent from here is recorded
/// under the account's UIN. Both are the same person: `"0"` becomes the UIN, and when both are
/// present the duplicate is dropped from the list and the count (re-notes/75).
fn reaction_details(message: &ChatMessage, own_uid: &str) -> Vec<ReactionDetailDto> {
    message
        .reaction_summaries
        .iter()
        .filter(|summary| summary.count > 0)
        .filter_map(|summary| {
            let mut count = summary.count;
            let mut reactors: Vec<(String, u64)> = Vec::new();
            for id in &summary.reactor_ids {
                let n = summary.reactor_counts.get(id).copied().unwrap_or(1);
                let id = if id == "0" && !own_uid.is_empty() { own_uid.to_owned() } else { id.clone() };
                if reactors.iter().any(|(seen, _)| seen == &id) {
                    count = count.saturating_sub(n);
                } else {
                    reactors.push((id, n));
                }
            }
            reactors.truncate(200);
            (count > 0).then(|| ReactionDetailDto {
                emoji: summary.emoji.clone(),
                count,
                reactors: reactors.iter().map(|(id, _)| id.clone()).collect(),
                reactor_counts: reactors.iter().map(|(_, n)| *n).collect(),
            })
        })
        .collect()
}

/// Group notices ("X đã rời khỏi nhóm", pin/unpin) arrive as ordinary text rows.
/// Presentation only: the stored message and its identity are unchanged.
fn is_group_notice(message: &ChatMessage, sender_id: &str) -> bool {
    use crate::message_model::MessageKind;
    if message.kind == MessageKind::System {
        return true;
    }
    if message.sticker_id.is_some() || message.reply_to_id.is_some() {
        return false;
    }
    let text = message.text.trim();
    if text.is_empty() || text.contains('\n') || text.chars().count() > 300 {
        return false;
    }
    // Wording Zalo uses only for generated notices, safe to match without an actor.
    let distinctive = [
        " đã rời khỏi nhóm",
        " đã rời nhóm",
        " đã tham gia nhóm",
        " đã được thêm vào nhóm",
        " đã đồng ý kết bạn",
    ]
    .iter()
    .any(|suffix| text.ends_with(suffix))
        || text.starts_with("Bạn vừa kết bạn với ")
        || text.starts_with("Bạn và ") && text.ends_with(" đã trở thành bạn bè")
        || text.contains(" ghim 1 tin nhắn")
        || text.contains(" bỏ ghim 1 tin nhắn");
    if distinctive {
        return true;
    }
    // Broader wording counts only when the text opens with its actor's own name.
    const ACTIONS: [&str; 6] = [
        " vào nhóm",
        " khỏi nhóm",
        " đã đổi tên nhóm",
        " đã đổi ảnh đại diện nhóm",
        " đã tạo nhóm",
        " làm phó nhóm",
    ];
    !sender_id.is_empty()
        && message.sender.chars().count() >= 2
        && text.starts_with(message.sender.as_str())
        && ACTIONS.iter().any(|action| text.contains(action))
}

/// The WebSocket, with `file_done` controls resolved as soon as they arrive.
///
/// `send_attachment` uploads with `asyncfile/upload` and then waits for the `file_done` control
/// that carries the file URL. The command loop awaits that request inline, so it cannot read
/// the socket meanwhile; without this tap the wait timed out and the fallback
/// `sharefile_full` endpoint answered HTTP 405 (native_errors.log, 2026-11-12).
fn websocket_feed(session: crate::session::Session) -> mpsc::UnboundedReceiver<crate::socket::WsEvent> {
    let mut inner = crate::socket::spawn(session);
    let (tx, rx) = mpsc::unbounded_channel();
    tokio::spawn(async move {
        while let Some(event) = inner.recv().await {
            // Same node the egui worker feeds, plus the decoded form when `data` is a JSON string.
            chat::dispatch_file_done_controls(event.payload.get("data").unwrap_or(&event.payload));
            if event.payload.get("data").is_some_and(Value::is_string) {
                chat::dispatch_file_done_controls(&live_data_node(&event.payload));
            }
            if tx.send(event).is_err() {
                break;
            }
        }
    });
    rx
}

fn chrono_now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// Decode a WebSocket body the same way `merge_live_previews` does: `data` may be
/// a JSON string and may wrap a second `data` object.
fn live_data_node(payload: &Value) -> Value {
    let mut node = match payload.get("data") {
        Some(Value::String(text)) => serde_json::from_str(text.trim()).unwrap_or(Value::Null),
        Some(value) => value.clone(),
        None => payload.clone(),
    };
    if let Some(inner) = node.get("data").filter(|v| v.is_object() || v.is_array()) {
        node = inner.clone();
    }
    node
}

/// "Is typing" controls from a WebSocket body: `actions[]` items with `act_type: "typing"` and
/// `act` `typing` (1:1, thread = `uid`) or `gtyping` (group, thread = `gid`). Zalo PC wraps
/// `data` in braces before parsing it (re-notes/66_typing_and_live_latency.md).
fn typing_events(payload: &Value, own_uid: &str) -> Vec<Value> {
    let node = match payload.get("data") {
        Some(Value::String(text)) => serde_json::from_str(text.trim()).unwrap_or(Value::Null),
        Some(value) => value.clone(),
        None => payload.clone(),
    };
    let mut out = Vec::new();
    for container in [&node, node.get("data").unwrap_or(&Value::Null)] {
        for action in container.get("actions").and_then(Value::as_array).into_iter().flatten() {
            if action.get("act_type").and_then(Value::as_str) != Some("typing") {
                continue;
            }
            let group = match action.get("act").and_then(Value::as_str) {
                Some("typing") => false,
                Some("gtyping") => true,
                _ => continue,
            };
            let data = match action.get("data") {
                Some(Value::String(text)) => {
                    let text = text.trim();
                    let wrapped = if text.starts_with('{') { text.to_owned() } else { format!("{{{text}}}") };
                    serde_json::from_str::<Value>(&wrapped).unwrap_or(Value::Null)
                }
                Some(value) => value.clone(),
                None => continue,
            };
            let id = |keys: &[&str]| {
                keys.iter().find_map(|key| match data.get(*key) {
                    Some(Value::String(text)) if !text.is_empty() => Some(text.clone()),
                    Some(Value::Number(number)) => Some(number.to_string()),
                    _ => None,
                })
            };
            let Some(user) = id(&["uid"]).filter(|uid| uid != own_uid) else { continue };
            let thread = if group { id(&["gid", "grid", "groupId"]) } else { Some(user.clone()) };
            let Some(thread) = thread.filter(|t| t.bytes().all(|b| b.is_ascii_digit())) else { continue };
            out.push(json!({"thread_id": thread, "user_id": user, "is_group": group}));
        }
    }
    out
}

/// Apply `reacts` / `reactGroups` and `chat.reaction` rows from a live push to the
/// loaded messages they target. Returns whether any message changed.
fn apply_live_reactions(threads: &mut [Thread], payload: &Value) -> bool {
    let node = live_data_node(payload);
    let mut events = crate::reactions::parse_reaction_events(&node);
    for key in ["msgs", "groupMsgs"] {
        for item in node.get(key).and_then(Value::as_array).into_iter().flatten() {
            if item.get("msgType").and_then(Value::as_str) == Some("chat.reaction") {
                events.extend(crate::reactions::parse_reaction_events(item));
            }
        }
    }
    let mut changed = false;
    for event in events {
        let target = threads.iter_mut().flat_map(|thread| thread.messages.iter_mut()).find(|message| {
            (!event.message_id.is_empty() && message.id == event.message_id)
                || (!event.client_message_id.is_empty()
                    && (message.client_message_id == event.client_message_id
                        || message.id == event.client_message_id))
        });
        if let Some(message) = target {
            changed |= message.apply_reaction(&event);
        }
    }
    changed
}

fn web_url(value: Option<&str>) -> Option<String> {
    value
        .filter(|url| {
            reqwest::Url::parse(url).is_ok_and(|url| {
                matches!(url.scheme(), "http" | "https")
                    && url.host_str().is_some()
                    && url.username().is_empty()
                    && url.password().is_none()
            })
        })
        .map(str::to_owned)
}

/// Poll errors reach the UI as plain Vietnamese; server bodies are never forwarded.
fn poll_error(error: &anyhow::Error) -> &'static str {
    if SessionStatus::from_error(error) == SessionStatus::Expired {
        "Phiên đăng nhập đã hết hạn. Hãy quét mã QR để đăng nhập lại."
    } else {
        "Không tải được cuộc bình chọn. Hãy thử lại."
    }
}

/// The poll fields the UI draws (Zalo PC poll model: question, options, joined, closed,
/// allow_multi_choices, allow_add_new_option, expired_time, num_vote, creator).
fn poll_dto(data: &Value) -> Value {
    let text = |value: &Value, key: &str| value.get(key).and_then(Value::as_str).unwrap_or_default().chars().take(2_000).collect::<String>();
    let number = |value: &Value, key: &str| value.get(key).and_then(|v| v.as_i64().or_else(|| v.as_str()?.parse().ok())).unwrap_or(0);
    let flag = |value: &Value, key: &str| value.get(key).is_some_and(|v| v.as_bool().unwrap_or_else(|| v.as_i64() == Some(1)));
    let options: Vec<Value> = data
        .get("options")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .take(100)
        .map(|option| {
            let voters: Vec<String> = option
                .get("voters")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(|v| v.as_str().map(str::to_owned).or_else(|| v.as_u64().map(|n| n.to_string())))
                .take(500)
                .collect();
            json!({
                "option_id": number(option, "option_id"),
                "content": text(option, "content"),
                "votes": number(option, "votes"),
                "voted": flag(option, "voted"),
                "voters": voters,
            })
        })
        .collect();
    json!({
        "poll_id": number(data, "poll_id"),
        "question": text(data, "question"),
        "creator": text(data, "creator"),
        "options": options,
        "joined": flag(data, "joined"),
        "closed": flag(data, "closed"),
        "multiple": flag(data, "allow_multi_choices"),
        "num_vote": number(data, "num_vote"),
        "expired_time": number(data, "expired_time"),
    })
}

fn message_dto(message: &ChatMessage, own_uid: &str) -> MessageDto {
    let mut hydrated = message.clone();
    hydrated.hydrate_media_metadata();
    // Older history stored link previews as photos because their thumbnail sits on the photo CDN.
    let links_to_web_page = hydrated.link_url.as_deref().is_some_and(|url| {
        (url.starts_with("http://") || url.starts_with("https://")) && !chat::is_zalo_photo_cdn_url(url)
    }) && (hydrated.link_desc.is_some()
        || hydrated.link_title.as_deref() == hydrated.link_url.as_deref());
    let is_photo = (hydrated.link_src.as_deref() == Some("Hình ảnh Zalo")
        || hydrated.kind == crate::message_model::MessageKind::Photo)
        && !links_to_web_page;
    let is_location = hydrated.link_src.as_deref() == Some(chat::LOCATION_LINK_SRC);
    let is_video = hydrated.link_src.as_deref() == Some("Video Zalo")
        || hydrated.kind == crate::message_model::MessageKind::Video;
    let is_file = !is_photo
        && !is_video
        && (hydrated.link_src.as_deref() == Some("Tập tin Zalo")
            || hydrated.kind == crate::message_model::MessageKind::File
            || hydrated.text.starts_with("[Tập tin]"));
    let sticker_url = hydrated.sticker_image_url();
    let sender_id = chat::sidebar_sender_id(&hydrated).unwrap_or_default();
    let card_kind = hydrated.card.as_ref().and_then(|card| card["kind"].as_str()).unwrap_or_default().to_owned();
    let is_notice = card_kind == "notice"
        || card_kind.is_empty() && !is_photo && !is_video && !is_file && !is_location && is_group_notice(&hydrated, &sender_id);
    MessageDto {
        id: hydrated.id.clone(),
        sender_id,
        sender_name: hydrated.sender.clone(),
        text: chat::display_emoticons(&hydrated.text).into_owned(),
        timestamp: hydrated.ts,
        is_outgoing: hydrated.is_outgoing,
        msg_type: if is_notice {
            "chat.system"
        } else if hydrated.sticker_id.is_some() {
            "chat.sticker"
        } else if is_photo {
            "chat.photo"
        } else if is_video {
            "chat.video.msg"
        } else if is_file {
            "share.file"
        } else if is_location {
            "chat.location"
        } else {
            "chat.text"
        }
        .into(),
        image_url: if is_photo {
            web_url(hydrated.link_url.as_deref())
        } else {
            web_url(sticker_url.as_deref())
        },
        file_url: if is_video || is_file {
            web_url(hydrated.link_url.as_deref())
        } else {
            None
        },
        file_name: (is_video || is_file).then(|| {
            hydrated
                .link_title
                .clone()
                .unwrap_or_else(|| hydrated.text.clone())
        }),
        reactions: hydrated.reactions.clone(),
        reaction_details: reaction_details(&hydrated, own_uid),
        reply_to_id: hydrated.reply_to_id,
        reply_to_sender: hydrated.reply_to_sender,
        reply_to_text: hydrated.reply_to_text,
        sticker_id: hydrated.sticker_id,
        sticker_cate_id: hydrated.sticker_cate_id,
        sticker_type: hydrated.sticker_type,
        link_url: web_url(hydrated.link_url.as_deref()),
        link_title: hydrated.link_title,
        link_desc: hydrated.link_desc.clone(),
        local_path: hydrated.local_path.clone().filter(|path| path.starts_with('/') && !path.contains("/../")),
        link_thumb: web_url(hydrated.link_thumb.as_deref()),
        card: hydrated.card.clone().filter(|card| card_kind == "contact" || card_kind == "call" || card.get("poll_id").is_some()),
        photo_group: hydrated.photo_layout.clone().filter(|_| is_photo),
    }
}

#[derive(Debug)]
struct UserError(&'static str);
impl std::fmt::Display for UserError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(self.0)
    }
}
impl std::error::Error for UserError {}

/// Shown when Zalo refuses delivery to a person; the native UI matches this text to show its bar.
const SEND_BLOCKED_MESSAGE: &str =
    "Không gửi được tin nhắn: người này đã chặn bạn hoặc không nhận tin nhắn từ bạn.";

fn safe_error(error: &anyhow::Error) -> String {
    if let Some(error) = error.downcast_ref::<UserError>() {
        return error.0.into();
    }
    if SessionStatus::from_error(error) == SessionStatus::Expired {
        return "Phiên đăng nhập đã hết hạn. Hãy quét mã QR để đăng nhập lại.".into();
    }
    // Zalo answers 119 to every send to someone who blocked this account or does not accept
    // messages from it (confirmed by the user: no message type goes through, 2026-11-13).
    if error
        .chain()
        .filter_map(|cause| cause.downcast_ref::<crate::session::SessionError>())
        .any(|server| server.code == 119)
    {
        return SEND_BLOCKED_MESSAGE.into();
    }
    // Underlying protocol errors may embed a raw response or a credential-bearing URL.
    "Không thực hiện được thao tác. Kiểm tra kết nối rồi thử lại.".into()
}

fn check_response(response: &Value) -> Result<()> {
    let code = response
        .get("error_code")
        .and_then(Value::as_i64)
        .ok_or_else(|| anyhow!(UserError("Máy chủ trả về dữ liệu không hợp lệ.")))?;
    if code != 0 {
        return Err(SessionError::new(code, "Zalo rejected the request").into());
    }
    Ok(())
}

fn require_text(text: &str) -> Result<()> {
    if text.trim().is_empty() || text.len() > MAX_TEXT {
        return Err(UserError("Tin nhắn trống hoặc quá dài.").into());
    }
    Ok(())
}

fn require_identifier(identifier: &str) -> Result<()> {
    if identifier.is_empty() || identifier.len() > 256 || identifier.chars().any(char::is_control) {
        return Err(UserError("Mã hội thoại hoặc tin nhắn không hợp lệ.").into());
    }
    Ok(())
}

fn event(name: &str, data: Value) -> Value {
    json!({"event": name, "data": data})
}

fn authenticated(session: &Session) -> bool {
    session
        .login
        .as_ref()
        .is_some_and(|login| !login.uin.is_empty())
        && matches!(session.session_key_bytes().len(), 16 | 32)
        && session
            .zpw_sek
            .as_ref()
            .is_some_and(|cookie| !cookie.is_empty())
}

/// One line per failed command in `native_errors.log` (the worker runs in the data folder), so a
/// generic "Không thực hiện được thao tác" can be traced. The UI still never sees these details.
/// Query strings, long key-like tokens and anything past 400 characters are removed.
fn record_failure(command: &str, error: &anyhow::Error) {
    if error.downcast_ref::<UserError>().is_some() {
        return;
    }
    let chain = error
        .chain()
        .map(|cause| sanitize_diagnostic(&cause.to_string()))
        .collect::<Vec<_>>()
        .join(" <- ");
    let line = format!(
        "{} {} {}\n",
        chrono_now_ms(),
        command,
        chain.chars().take(400).collect::<String>()
    );
    let path = std::path::Path::new("native_errors.log");
    if std::fs::metadata(path).is_ok_and(|m| m.len() > 256 * 1024) {
        let _ = std::fs::remove_file(path);
    }
    if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
        let _ = file.write_all(line.as_bytes());
    }
}

fn sanitize_diagnostic(text: &str) -> String {
    text.split_whitespace()
        .map(|token| {
            if let Some(start) = token.find("http") {
                let url = &token[start..];
                let end = url.find(['?', '#']).unwrap_or(url.len());
                format!("{}{}", &token[..start], &url[..end])
            } else if token.len() > 40 && token.chars().all(|c| c.is_ascii_alphanumeric() || "+/=_-.".contains(c)) {
                "…".to_owned()
            } else {
                token.to_owned()
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

fn terminal(request: &Request, result: &Result<Value>) -> Value {
    let response = match result {
        Ok(data) => {
            json!({"id": request.id, "event": "result", "command": request.command.name(), "ok": true, "data": data})
        }
        Err(error) => {
            json!({"id": request.id, "event": "result", "command": request.command.name(), "ok": false, "data": null, "error": safe_error(error)})
        }
    };
    bounded_event(response)
}

fn bounded_event(value: Value) -> Value {
    let oversized = serde_json::to_vec(&value).map_or(true, |bytes| bytes.len() > MAX_OUTPUT_FRAME);
    if !oversized {
        return value;
    }
    if value.get("event").and_then(Value::as_str) == Some("result") {
        json!({"event": "result", "id": value.get("id"), "command": value.get("command"),
            "ok": false, "data": null, "error": "Dữ liệu quá lớn. Hãy thu hẹp nội dung rồi thử lại."})
    } else {
        event(
            "status",
            json!({"message": "Dữ liệu quá lớn để hiển thị cùng lúc. Hãy chọn một hội thoại cụ thể."}),
        )
    }
}

async fn emit(sender: &mpsc::Sender<Value>, value: Value) -> Result<()> {
    sender
        .send(bounded_event(value))
        .await
        .map_err(|_| anyhow!("native event receiver closed"))
}

struct Core {
    history_context: history::SharedContext,
    history_recent: HashMap<String, VecDeque<String>>,
    // The worker owns snapshots; the short lock only supports shared publish helpers.
    published_messages: std::sync::Mutex<HashMap<String, HashMap<String, MessageDto>>>,
    session: Session,
    threads: Vec<Thread>,
    pinned: HashSet<String>,
    selected: Option<String>,
    poll_state: chat::PollState,
    demo: bool,
    demo_logged_in: bool,
    next_demo_id: u64,
    output: mpsc::Sender<Value>,
    db_path: String,
    cache_path: String,
    persisted_digest: std::sync::Arc<std::sync::Mutex<Option<[u8;32]>>>,
    features: features::FeatureState,
    preferences: client_preferences::ClientPreferences,
    account_settings: account_settings::SettingsState,
    platform: platform::PlatformState,
    platform_updates: Option<mpsc::UnboundedReceiver<platform::PlatformUpdate>>,
}

struct PollResult {
    generation: u64,
    state: chat::PollState,
    response: Result<Value>,
    scheduled: Result<Vec<(String, ChatMessage)>>,
}

impl Core {
    /// Drop messages hidden by a delete-for-me from another device: SQLite and the open transcript.
    async fn forget_removed(&self, removed: Vec<(String, String)>) -> Result<()> {
        if removed.is_empty() {
            return Ok(());
        }
        if !self.demo && !self.db_path.is_empty() {
            let db_path = self.db_path.clone();
            let rows = removed.clone();
            tokio::task::spawn_blocking(move || MessageStore::open(&db_path)?.delete_thread_messages(&rows))
                .await??;
        }
        for (thread_id, message_id) in removed {
            emit(&self.output, event("message_removed", json!({"thread_id": thread_id, "message_id": message_id}))).await?;
        }
        Ok(())
    }

    fn new(demo: bool, output: mpsc::Sender<Value>) -> Result<Self> {
        let (platform, updates) = platform::PlatformState::new();
        Ok(Self {
            history_context: Default::default(),
            history_recent: Default::default(),
            published_messages: Default::default(),
            session: Session::new(false, false, false)?,
            threads: Vec::new(),
            pinned: HashSet::new(),
            selected: None,
            poll_state: chat::PollState::default(),
            demo,
            demo_logged_in: demo,
            next_demo_id: 10,
            output,
            db_path: String::new(),
            cache_path: String::new(),
            persisted_digest:Default::default(),
            features: Default::default(),
            preferences: Default::default(),
            account_settings: Default::default(),
            platform,
            platform_updates: Some(updates),
        })
    }

    fn update_history_context(&self, generation: u64) {
        if let Ok(mut context) = self.history_context.lock() {
            context.generation = generation;
            context.account = if self.logged_in() {
                self.session.login.as_ref().map(|login| login.uin.clone()).unwrap_or_else(|| "demo".into())
            } else { String::new() };
            context.db_path = self.db_path.clone();
            context.demo = self.demo;
            context.threads = self.threads.iter().map(|thread| {
                let snapshot = Thread {
                    id:thread.id.clone(),name:thread.name.clone(),is_group:thread.is_group,
                    avatar:thread.avatar.clone(),preview:thread.preview.clone(),time:thread.time.clone(),
                    presentation:thread.presentation.clone(),unread:thread.unread.clone(),
                    messages:if self.demo {thread.messages.clone()} else {Vec::new()},
                };
                (snapshot.id.clone(), snapshot)
            }).collect();
        }
    }

    fn logged_in(&self) -> bool {
        if self.demo {
            self.demo_logged_in
        } else {
            authenticated(&self.session)
        }
    }

    fn require_login(&self) -> Result<()> {
        if !self.logged_in() {
            return Err(UserError("Bạn cần đăng nhập trước.").into());
        }
        Ok(())
    }

    async fn emit_session(&self) -> Result<()> {
        let login = self.session.login.as_ref();
        emit(&self.output, event("session", json!({
            "logged_in": self.logged_in(),
            "uin": if self.demo && self.demo_logged_in { "demo-user" } else { login.map(|login| login.uin.as_str()).unwrap_or("") },
            "name": if self.demo && self.demo_logged_in { "Tài khoản minh họa" } else { login.map(|login| login.display_name.as_str()).unwrap_or("") },
            "avatar": login.and_then(|login| web_url(Some(&login.avatar))),
            "demo": self.demo,
        }))).await
    }

    async fn emit_threads(&self) -> Result<()> {
        let generation = self.history_context.lock().map(|c| c.generation).unwrap_or_default();
        self.update_history_context(generation);
        let mut threads: Vec<ThreadDto> = self
            .threads
            .iter()
            .take(MAX_THREADS)
            .map(|thread| {
                let (avatar_members, member_total) = composite_avatar(thread.avatar.as_deref());
                ThreadDto {
                id: thread.id.clone(),
                name: thread.name.clone(),
                is_group: thread.is_group,
                avatar: web_url(thread.avatar.as_deref()),
                avatar_members,
                member_total,
                unread: thread.unread.count(),
                marked_unread: thread.unread.marked_unread,
                pinned: self.pinned.contains(&thread.id) || thread.presentation.pinned,
                muted: thread.unread.is_muted(),
                hidden: thread.presentation.hidden,
                last_message: chat::display_emoticons(&thread.sidebar_preview()).into_owned(),
                last_message_ts: thread.sidebar_activity_ts(),
            }})
            .collect();
        threads.sort_by(|a, b| {
            b.pinned
                .cmp(&a.pinned)
                .then(b.last_message_ts.cmp(&a.last_message_ts))
                .then(a.name.cmp(&b.name))
        });
        let mut bytes = 0;
        threads.retain(|thread| {
            let size = serde_json::to_vec(thread)
                .map(|bytes| bytes.len())
                .unwrap_or(SNAPSHOT_BYTES);
            bytes += size;
            bytes <= SNAPSHOT_BYTES
        });
        emit(
            &self.output,
            event("threads", serde_json::to_value(threads)?),
        )
        .await
    }

    /// This account's UIN, which Zalo's reaction snapshots write as `"0"`.
    fn own_uid(&self) -> String {
        self.session.login.as_ref().map(|login| login.uin.clone()).unwrap_or_default()
    }

    async fn emit_messages(&self, thread_id: &str, limit: usize) -> Result<()> {
        let thread = self
            .threads
            .iter()
            .find(|thread| thread.id == thread_id)
            .ok_or_else(|| anyhow!(UserError("Không tìm thấy hội thoại.")))?;
        let count = limit.clamp(1, MAX_MESSAGES);
        let mut messages = Vec::new();
        let mut bytes = 0;
        let own_uid = self.own_uid();
        for message in thread.messages.iter().rev().take(count) {
            let message = message_dto(message, &own_uid);
            bytes += serde_json::to_vec(&message)?.len();
            if bytes > SNAPSHOT_BYTES {
                break;
            }
            messages.push(message);
        }
        messages.reverse();
        let has_more = messages.len() < thread.messages.len();
        emit(
            &self.output,
            event(
                "messages",
                json!({"thread_id": thread_id, "messages": messages, "has_more": has_more}),
            ),
        )
        .await
    }

    async fn emit_message_updates(&self, thread_id: &str) -> Result<()> {
        let thread=self.threads.iter().find(|thread|thread.id==thread_id).ok_or(UserError("Không tìm thấy hội thoại."))?;
        let own_uid=self.own_uid();
        let current:HashMap<_,_>=thread.messages.iter().map(|m|{let dto=message_dto(m,&own_uid);(dto.id.clone(),dto)}).collect();
        let changes={
            let mut cache=self.published_messages.lock().map_err(|_|anyhow!("message snapshot cache poisoned"))?;
            if cache.len()>=24 && !cache.contains_key(thread_id){cache.clear();}
            let previous=cache.entry(thread_id.to_owned()).or_default();
            let mut changes:Vec<_>=current.values().filter(|m|previous.get(&m.id)!=Some(*m)).cloned().collect();
            changes.sort_by(|a,b|a.timestamp.cmp(&b.timestamp).then(a.id.cmp(&b.id)));
            *previous=current;
            changes
        };
        if !changes.is_empty() {
            // Chunk deltas so rich historical rows cannot crowd out an update to an older visible message.
            for page in changes.chunks(50) {
                emit(&self.output,event("messages",json!({"thread_id":thread_id,"messages":page,"incremental":true}))).await?;
            }
        }
        Ok(())
    }

    async fn publish(&self) -> Result<()> {
        self.emit_threads().await?;
        if let Some(thread_id) = &self.selected {
            if self.threads.iter().any(|thread| &thread.id == thread_id) {
                if self.demo {self.emit_messages(thread_id,50).await?;} else {self.emit_message_updates(thread_id).await?;}
            }
        }
        Ok(())
    }

    async fn persist(&self) -> Result<()> {
        if self.demo {
            return Ok(());
        }
        let threads = self.threads.clone();
        let db_path = self.db_path.clone();
        let cache_path = self.cache_path.clone();
        let previous=self.persisted_digest.clone();
        tokio::task::spawn_blocking(move || -> Result<()> {
            use sha2::{Digest,Sha256};
            let bytes=serde_json::to_vec(&threads)?;
            let mut hash=Sha256::new();hash.update(db_path.as_bytes());hash.update(&bytes);
            let digest:[u8;32]=hash.finalize().into();
            // This is only a write-elision cache, never the authority for history.
            if previous.lock().ok().and_then(|value|*value)==Some(digest) {return Ok(())}
            store::persist_threads(&mut MessageStore::open(&db_path)?, &threads)?;
            crate::data_dir::write_private_atomic(
                Path::new(&cache_path),
                &bytes,
            )?;
            if let Ok(mut previous)=previous.lock(){*previous=Some(digest);}
            Ok(())
        })
        .await??;
        Ok(())
    }

    async fn persist_best_effort(&self) -> Result<()> {
        if self.persist().await.is_err() {
            emit(
                &self.output,
                event(
                    "status",
                    json!({"message": "Đã nhận dữ liệu nhưng chưa lưu được lịch sử trên máy."}),
                ),
            )
            .await?;
        }
        Ok(())
    }

    async fn bootstrap(&mut self) -> Result<Value> {
        if self.demo {
            self.threads = demo_threads();
            self.demo_logged_in = true;
            self.emit_session().await?;
            self.emit_threads().await?;
            return Ok(json!({"demo": true}));
        }
        let session = self.session.clone();
        let (session, threads, db_path, cache_path) =
            tokio::task::spawn_blocking(move || -> Result<_> {
                let mut session = session;
                if Path::new("session.json").exists()
                    && (session.load_from_file("session.json").is_err()
                        || session.is_expired_marked()
                        || !authenticated(&session))
                {
                    session.logout();
                }
                let (db_path, cache_path) = if session.login.is_some() {
                    account_paths(&session)?
                } else {
                    (String::new(), String::new())
                };
                let mut threads = if session.login.is_some() {
                    std::fs::read(&cache_path)
                        .ok()
                        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
                        .unwrap_or_default()
                } else {
                    Vec::new()
                };
                if !db_path.is_empty() {
                    let mut store = MessageStore::open(&db_path)?;
                    // Older builds cached delete-for-me events as empty messages.
                    let stale = chat::purge_local_delete_events(&mut threads);
                    store.delete_thread_messages(&stale)?;
                    store.hydrate_threads(&mut threads, MessageStore::PRELOAD_MSGS)?;
                }
                Ok((session, threads, db_path, cache_path))
            })
            .await??;
        self.session = session;
        self.threads = threads;
        self.pinned = self
            .threads
            .iter()
            .filter(|thread| thread.presentation.pinned)
            .map(|thread| thread.id.clone())
            .collect();
        self.db_path = db_path;
        self.cache_path = cache_path;
        if self.logged_in() {
            self.preferences.load(&self.db_path, self.demo).await?;
        }
        self.emit_session().await?;
        self.emit_threads().await?;
        if self.logged_in() {
            self.refresh().await?;
        }
        Ok(json!({"logged_in": self.logged_in()}))
    }

    async fn expire(&mut self) -> Result<()> {
        self.features = Default::default();
        self.preferences.reset();
        self.account_settings.reset();
        self.platform.stop();
        self.session.logout();
        self.threads.clear();
        self.selected = None;
        self.pinned.clear();
        self.db_path.clear();
        self.cache_path.clear();
        self.poll_state = chat::PollState::default();
        self.emit_session().await?;
        self.emit_threads().await?;
        if !self.demo {
            tokio::task::spawn_blocking(|| -> Result<()> {
                match std::fs::remove_file("session.json") {
                    Ok(()) => Ok(()),
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
                    Err(error) => Err(error.into()),
                }
            })
            .await??;
        }
        Ok(())
    }

    async fn refresh(&mut self) -> Result<Value> {
        self.require_login()?;
        if self.demo {
            self.publish().await?;
            return Ok(json!({"threads": self.threads.len()}));
        }
        match tokio::time::timeout(Duration::from_secs(15), self.session.session_status()).await? {
            SessionStatus::Expired => {
                self.expire().await?;
                return Err(UserError("Phiên đăng nhập đã hết hạn. Hãy đăng nhập lại.").into());
            }
            SessionStatus::Unreachable => {
                return Err(UserError(
                    "Không kết nối được Zalo. Lịch sử trên máy vẫn được giữ nguyên.",
                )
                .into())
            }
            SessionStatus::Valid => {}
        }
        emit(
            &self.output,
            event("status", json!({"message": "Đang cập nhật hội thoại…"})),
        )
        .await?;
        let mut succeeded = false;
        if let Ok(friends) =
            tokio::time::timeout(Duration::from_secs(20), chat::get_friends(&self.session)).await?
        {
            merge_threads(&mut self.threads, friends);
            succeeded = true;
        }
        if let Ok(groups) =
            tokio::time::timeout(Duration::from_secs(20), chat::get_groups(&self.session)).await?
        {
            merge_threads(&mut self.threads, groups);
            succeeded = true;
        }
        if let Ok(response) = chat::get_last_msgs(&self.session, &[]).await {
            check_response(&response)?;
            let removed = chat::merge_previews(&mut self.threads, &response);
            self.forget_removed(removed).await?;
            succeeded = true;
        }
        if !succeeded {
            return Err(UserError("Không tải được hội thoại. Hãy thử lại.").into());
        }
        for thread in &mut self.threads {
            thread.presentation.pinned = self.pinned.contains(&thread.id);
        }
        self.persist_best_effort().await?;
        self.publish().await?;
        emit(
            &self.output,
            event("status", json!({"message": "Đã cập nhật hội thoại"})),
        )
        .await?;
        Ok(json!({"threads": self.threads.len()}))
    }

    /// Makes sure the stored account data key opens the selected Zalo PC export.
    ///
    /// Zalo PC encrypts exports with the `dkey` that `getLoginInfo` returns to a PC client
    /// (type 23); a web-type request returns a different key (re-notes/71). The stored key is
    /// checked against the export's first tar header; when it does not open the file, the PC
    /// key is requested, verified the same way, and persisted with the session (secret).
    /// Sessions signed in before poll support never kept the `group_poll` host; the account's
    /// service map from `getLoginInfo` names it. Only that host is taken from the reply.
    async fn ensure_poll_host(&mut self) -> Result<()> {
        if !self.session.domains.group_poll.is_empty() {
            return Ok(());
        }
        let info = crate::login::get_login_info(&self.session).await?;
        let data = info.get("data").unwrap_or(&info);
        let map = data.get("zpw_service_map_v3").or_else(|| data.get("zpw_service_map_new"));
        let host = map
            .and_then(|map| map.get("group_poll"))
            .and_then(|hosts| hosts.as_array().and_then(|list| list.first()).or(Some(hosts)))
            .and_then(Value::as_str)
            .filter(|host| host.starts_with("https://"))
            .map(|host| host.trim_end_matches('/').to_owned());
        let Some(host) = host else {
            bail!(UserError("Zalo chưa cung cấp máy chủ bình chọn cho phiên này. Hãy đăng nhập lại."));
        };
        self.session.domains.group_poll = host;
        let session = self.session.clone();
        tokio::task::spawn_blocking(move || session.save_to_file("session.json")).await??;
        Ok(())
    }

    async fn ensure_export_key(&mut self, path: &str) -> Result<()> {
        if crate::zalo_backup::ContainerVersion::from_path(Path::new(path)).is_none() {
            return Ok(());
        }
        let Some(login) = self.session.login.clone() else { return Ok(()) };
        if export_key_opens(path, &login.dkey, &login.uin).await? {
            return Ok(());
        }
        let mut fetched = None;
        for zpw_type in [crate::session::ZPW_PC_TYPE, crate::session::ZPW_TYPE] {
            let Ok(info) = crate::login::get_login_info_as(&self.session, zpw_type, crate::session::ZPW_VER).await else { continue };
            let key = info
                .get("data")
                .unwrap_or(&info)
                .get("dkey")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned();
            if key.is_empty() {
                continue;
            }
            if export_key_opens(path, &key, &login.uin).await? {
                fetched = Some(key);
                break;
            }
        }
        let Some(key) = fetched else {
            bail!(UserError(
                "Không mở được tệp sao lưu bằng khóa của tài khoản đang đăng nhập. Hãy chắc tệp được xuất từ chính tài khoản này trong Zalo PC và đã xuất xong, rồi thử lại."
            ));
        };
        if let Some(login) = self.session.login.as_mut() {
            login.dkey = key;
        }
        let session = self.session.clone();
        // Same relative file the login flow writes; the worker runs inside its data directory.
        tokio::task::spawn_blocking(move || session.save_to_file("session.json"))
            .await?
            .map_err(|_| UserError("Chưa lưu được khóa dữ liệu của tài khoản.").into())
    }

    fn known_thread(&self, thread_id: &str, is_group: bool) -> Result<usize> {
        require_identifier(thread_id)?;
        self.threads
            .iter()
            .position(|thread| thread.id == thread_id && thread.is_group == is_group)
            .ok_or_else(|| {
                anyhow!(UserError(
                    "Hội thoại không tồn tại hoặc đã thay đổi. Hãy làm mới danh sách."
                ))
            })
    }

    fn known_message(
        &self,
        thread_id: &str,
        is_group: bool,
        message_id: &str,
    ) -> Result<ChatMessage> {
        require_identifier(message_id)?;
        let index = self.known_thread(thread_id, is_group)?;
        self.threads[index]
            .messages
            .iter()
            .find(|message| message.id == message_id)
            .cloned()
            .ok_or_else(|| anyhow!(UserError("Không tìm thấy tin nhắn trong hội thoại.")))
    }

    async fn load_messages(
        &mut self,
        thread_id: &str,
        is_group: bool,
        limit: usize,
    ) -> Result<Value> {
        self.require_login()?;
        let index = match self.known_thread(thread_id, is_group) {
            Ok(index) => index,
            Err(error) => {
                // Refresh the UI snapshot before rejecting a stale read intent. Mutating
                // commands still require an exact, current thread identity.
                self.emit_threads().await?;
                return Err(error);
            }
        };
        let limit = limit.clamp(1, MAX_MESSAGES);
        self.selected = Some(thread_id.into());
        if !self.demo {
            let thread = self.threads[index].clone();
            let db_path = self.db_path.clone();
            let mut thread = tokio::task::spawn_blocking(move || -> Result<_> {
                let mut threads = vec![thread];
                MessageStore::open(&db_path)?.hydrate_loaded_threads(&mut threads, limit)?;
                threads
                    .pop()
                    .ok_or_else(|| anyhow!("missing thread snapshot"))
            })
            .await??;
            // Show local history before a potentially slow network history request.
            self.threads[index] = thread.clone();
            self.emit_messages(thread_id, limit).await?;
            let is_cloud = self
                .session
                .login
                .as_ref()
                .is_some_and(|login| login.send2me_id == thread_id);
            if is_group || is_cloud {
                let response = chat::get_cloud_messages(
                    &self.session,
                    thread_id,
                    "9223372036854775808",
                    false,
                    50,
                )
                .await?;
                check_response(&response)?;
                chat::merge_group_history(&mut thread, &response);
                self.threads[index] = thread;
            } else {
                let response = chat::get_last_msgs(&self.session, &[thread_id.to_owned()]).await?;
                check_response(&response)?;
                let removed = chat::merge_previews(&mut self.threads, &response);
                self.forget_removed(removed).await?;
            }
            self.persist_best_effort().await?;
        }
        self.emit_messages(thread_id, limit).await?;
        Ok(json!({"thread_id": thread_id}))
    }

    async fn add_sent(
        &mut self,
        thread_id: &str,
        is_group: bool,
        message: ChatMessage,
    ) -> Result<Value> {
        let index = self.known_thread(thread_id, is_group)?;
        let id = message.id.clone();
        chat::merge_sent_message(&mut self.threads[index], message);
        self.persist_best_effort().await?;
        self.publish().await?;
        Ok(json!({"thread_id": thread_id, "message_id": id}))
    }

    async fn send_text(
        &mut self,
        thread_id: &str,
        is_group: bool,
        text: &str,
        quoted: Option<ChatMessage>,
        mentions: &[chat::Mention],
    ) -> Result<Value> {
        self.require_login()?;
        self.known_thread(thread_id, is_group)?;
        require_text(text)?;
        let mention_info = if is_group && quoted.is_none() { chat::mention_info(text, mentions) } else { None };
        let client_id = chat::next_client_message_id();
        let (message_id, timestamp) = if self.demo {
            self.next_demo_id += 1;
            (
                format!("demo-message-{}", self.next_demo_id),
                crate::login::unix_now() * 1000,
            )
        } else {
            let response = if let Some(quoted) = &quoted {
                chat::send_quote_message_with_client_id(
                    &self.session,
                    thread_id,
                    text,
                    quoted,
                    is_group,
                    client_id,
                )
                .await?
            } else if let Some(info) = &mention_info {
                chat::send_group_mention_with_client_id(&self.session, thread_id, text, info, client_id)
                    .await?
            } else if is_group {
                chat::send_group_message_with_client_id(&self.session, thread_id, text, client_id)
                    .await?
            } else {
                chat::send_message_with_client_id(&self.session, thread_id, text, client_id).await?
            };
            check_response(&response)?;
            let id = response
                .get("data")
                .and_then(|data| data.get("msgId"))
                .and_then(|id| {
                    id.as_str()
                        .map(str::to_owned)
                        .or_else(|| id.as_u64().map(|id| id.to_string()))
                })
                .filter(|id| !id.is_empty())
                .unwrap_or_else(|| format!("out_{client_id}"));
            (id, client_id as i64)
        };
        let message = ChatMessage {
            id: message_id,
            sender: self
                .session
                .login
                .as_ref()
                .map(|login| login.display_name.clone())
                .unwrap_or_else(|| "Bạn".into()),
            text: text.into(),
            ts: timestamp,
            is_outgoing: true,
            client_message_id: client_id.to_string(),
            reply_to_id: quoted.as_ref().map(|message| message.id.clone()),
            reply_to_sender: quoted.as_ref().map(|message| message.sender.clone()),
            reply_to_text: quoted.map(|message| message.text),
            ..Default::default()
        };
        self.add_sent(thread_id, is_group, message).await
    }

    async fn execute_intent(&mut self, intent: &NativeIntent) -> Result<Value> {
        match intent {
            NativeIntent::Base(command) => self.execute(command).await,
            NativeIntent::Features(command) => {
                self.require_login()?;
                let result = features::execute(
                    command,
                    &self.session,
                    &mut self.threads,
                    &self.db_path,
                    self.demo,
                    &mut self.features,
                )
                .await?;
                if command.affects_workspace() {
                    self.persist_best_effort().await?;
                    self.publish().await?;
                }
                Ok(result)
            }
            NativeIntent::Client(command) => {
                self.require_login()?;
                match command {
                    ClientCommand::CancelImport => Ok(json!({"cancelling": true})),
                    ClientCommand::GetPrivacyGuard => {
                        self.preferences.load(&self.db_path, self.demo).await
                    }
                    ClientCommand::SetPrivacyGuard {
                        block_typing,
                        block_delivered,
                        block_seen,
                    } => {
                        self.preferences
                            .save(
                                client_preferences::PrivacyGuard {
                                    block_typing: *block_typing,
                                    block_delivered: *block_delivered,
                                    block_seen: *block_seen,
                                },
                                &self.db_path,
                                self.demo,
                            )
                            .await
                    }
                }
            }
            NativeIntent::Platform(command) => {
                self.require_login()?;
                self.platform
                    .execute(
                        command,
                        &self.session,
                        &self.threads,
                        &self.db_path,
                        self.output.clone(),
                        self.demo,
                    )
                    .await
            }
            NativeIntent::Settings(command) => {
                self.require_login()?;
                self.account_settings
                    .execute(command, &self.session, self.demo)
                    .await
            }
        }
    }

    async fn execute(&mut self, command: &Command) -> Result<Value> {
        match command {
            Command::Bootstrap => self.bootstrap().await,
            Command::RefreshThreads => self.refresh().await,
            Command::LoadMessages {
                thread_id,
                is_group,
                limit,
            } => self.load_messages(thread_id, *is_group, *limit).await,
            // Live updates are pushed only for the selected conversation. Opening a cached one used to
            // send no command, so the worker kept pushing to the previous chat and new messages here
            // reached the sidebar but not the transcript. Send what the UI has not seen yet.
            Command::SelectThread { thread_id, is_group } => {
                self.require_login()?;
                self.known_thread(thread_id, *is_group)?;
                self.selected = Some(thread_id.clone());
                if self.demo {
                    self.emit_messages(thread_id, 50).await?;
                } else {
                    self.emit_message_updates(thread_id).await?;
                }
                Ok(json!({"thread_id": thread_id}))
            }
            Command::LoadMessagePage { .. } => Err(UserError("Yêu cầu lịch sử phải qua luồng đọc riêng.").into()),
            Command::SendMessage {
                thread_id,
                is_group,
                text,
                mentions,
            } => self.send_text(thread_id, *is_group, text, None, mentions).await,
            Command::SendQuote {
                thread_id,
                is_group,
                text,
                message_id,
            } => {
                let quoted = self.known_message(thread_id, *is_group, message_id)?;
                self.send_text(thread_id, *is_group, text, Some(quoted), &[])
                    .await
            }
            Command::SendAttachment {
                thread_id,
                is_group,
                path,
                caption,
            } => {
                self.require_login()?;
                self.known_thread(thread_id, *is_group)?;
                if self.demo {
                    return Err(UserError("Chế độ minh họa không tải tệp lên Zalo.").into());
                }
                if caption.len() > MAX_TEXT || path.len() > 4096 {
                    return Err(UserError("Tệp hoặc chú thích không hợp lệ.").into());
                }
                let path = std::path::PathBuf::from(path);
                let checked = path.clone();
                tokio::task::spawn_blocking(move || -> Result<()> {
                    let metadata = std::fs::metadata(&checked)?;
                    if !metadata.is_file()
                        || metadata.len() == 0
                        || metadata.len() > 50 * 1024 * 1024
                    {
                        return Err(UserError("Chỉ gửi tệp từ 1 byte đến 50 MB.").into());
                    }
                    Ok(())
                })
                .await??;
                let (response, message) =
                    chat::send_attachment(&self.session, thread_id, *is_group, &path, caption)
                        .await?;
                check_response(&response)?;
                self.add_sent(thread_id, *is_group, message).await
            }
            Command::React {
                thread_id,
                is_group,
                message_id,
                reaction,
            } => {
                self.require_login()?;
                let message = self.known_message(thread_id, *is_group, message_id)?;
                // Zalo's six reaction types; equivalent emoji spellings share one type.
                let reaction = &match reaction.as_str() {
                    "😂" => "😆".to_owned(),
                    "😡" => "😠".to_owned(),
                    "❤" => "❤️".to_owned(),
                    other => other.to_owned(),
                };
                if !["👍", "❤️", "😆", "😮", "😢", "😠", ""].contains(&reaction.as_str()) {
                    return Err(UserError("Zalo chỉ hỗ trợ 6 biểu cảm: ❤️ 👍 😆 😮 😢 😠.").into());
                }
                if !self.demo {
                    check_response(
                        &chat::send_reaction(
                            &self.session,
                            thread_id,
                            *is_group,
                            &message,
                            reaction,
                        )
                        .await?,
                    )?;
                }
                let index = self.known_thread(thread_id, *is_group)?;
                if let Some(message) = self.threads[index]
                    .messages
                    .iter_mut()
                    .find(|message| &message.id == message_id)
                {
                    // Recorded as this account's event so other reactors are kept.
                    let own_id = self
                        .session
                        .login
                        .as_ref()
                        .map(|login| login.uin.clone())
                        .unwrap_or_default();
                    let (_, r_type) = chat::reaction_code_and_type(reaction);
                    let applied = !own_id.is_empty()
                        && message.apply_reaction(&crate::reactions::ReactionEvent {
                            message_id: message.id.clone(),
                            client_message_id: message.client_message_id.clone(),
                            thread_id: thread_id.clone(),
                            sender_id: own_id,
                            r_type: if reaction.is_empty() { -1 } else { r_type },
                            emoji: reaction.clone(),
                            ts: chrono_now_ms(),
                            ..Default::default()
                        });
                    if !applied && !reaction.is_empty() && !message.reactions.contains(reaction) {
                        message.reactions.push(reaction.clone());
                    }
                }
                self.persist_best_effort().await?;
                self.publish().await?;
                Ok(json!({"message_id": message_id}))
            }
            Command::RecallMessage {
                thread_id,
                is_group,
                message_id,
            }
            | Command::DeleteMessage {
                thread_id,
                is_group,
                message_id,
                ..
            } => {
                self.require_login()?;
                let message = self.known_message(thread_id, *is_group, message_id)?;
                let recall = matches!(command, Command::RecallMessage { .. });
                let for_everyone = matches!(command, Command::DeleteMessage { for_everyone: true, .. });
                if recall && !message.is_outgoing {
                    return Err(UserError("Chỉ thu hồi được tin nhắn do bạn gửi.").into());
                }
                if for_everyone && !*is_group {
                    return Err(UserError("Chỉ quản trị viên nhóm mới xóa được tin cho cả nhóm.").into());
                }
                if !self.demo {
                    let response = if recall {
                        chat::recall_message(&self.session, thread_id, *is_group, &message).await?
                    } else {
                        chat::delete_message(&self.session, thread_id, *is_group, &message, !for_everyone)
                            .await
                            .map_err(|error| if for_everyone && SessionStatus::from_error(&error) != SessionStatus::Expired {
                                anyhow!(UserError("Zalo không cho xóa tin này cho cả nhóm. Chỉ trưởng hoặc phó nhóm xóa được, và chỉ trong thời gian Zalo cho phép."))
                            } else { error })?
                    };
                    check_response(&response)?;
                    let message = message.clone();
                    let thread_id = thread_id.clone();
                    let db_path = self.db_path.clone();
                    tokio::task::spawn_blocking(move || {
                        MessageStore::open(&db_path)?.delete_message(
                            &thread_id,
                            &message.id,
                            message.ts,
                        )
                    })
                    .await??;
                }
                let index = self.known_thread(thread_id, *is_group)?;
                self.threads[index]
                    .messages
                    .retain(|message| &message.id != message_id);
                emit(&self.output, event("message_removed", json!({"thread_id":thread_id,"message_id":message_id}))).await?;
                self.persist_best_effort().await?;
                self.publish().await?;
                Ok(json!({"message_id": message_id}))
            }
            Command::SyncHistory {
                thread_id,
                is_group,
            } => {
                self.require_login()?;
                let index = self.known_thread(thread_id, *is_group)?;
                if self.demo {
                    self.publish().await?;
                    return Ok(json!({"added": 0}));
                }
                let is_cloud = self
                    .session
                    .login
                    .as_ref()
                    .is_some_and(|login| login.send2me_id == *thread_id);
                if !is_group && !is_cloud {
                    return Err(UserError(
                        "Đồng bộ lịch sử máy chủ hiện hỗ trợ nhóm và Cloud của tôi.",
                    )
                    .into());
                }
                let mut thread = self.threads[index].clone();
                let before = thread.messages.len();
                for _ in 0..20 {
                    let cursor = thread
                        .messages
                        .iter()
                        .map(|message| message.id.as_str())
                        .find(|id| !id.is_empty() && id.bytes().all(|byte| byte.is_ascii_digit()))
                        .unwrap_or("9223372036854775808")
                        .to_string();
                    let response =
                        chat::get_cloud_messages(&self.session, thread_id, &cursor, true, 50)
                            .await?;
                    check_response(&response)?;
                    let previous = thread.messages.len();
                    chat::merge_group_history(&mut thread, &response);
                    if thread.messages.len() == previous {
                        break;
                    }
                    self.threads[index] = thread.clone();
                    self.persist_best_effort().await?;
                    self.emit_messages(thread_id, MAX_MESSAGES).await?;
                    emit(&self.output, event("status", json!({"message": format!("Đã tải thêm {} tin nhắn", thread.messages.len() - before)}))).await?;
                    tokio::time::sleep(Duration::from_millis(400)).await;
                }
                let added = thread.messages.len() - before;
                self.threads[index] = thread;
                self.persist_best_effort().await?;
                self.publish().await?;
                Ok(json!({"added": added}))
            }
            Command::PollDetail { thread_id, poll_id } | Command::PollVote { thread_id, poll_id, .. } => {
                self.require_login()?;
                self.known_thread(thread_id, true)?;
                if self.demo {
                    return Err(UserError("Chế độ minh họa không mở được cuộc bình chọn.").into());
                }
                self.ensure_poll_host().await?;
                let data = if let Command::PollVote { option_ids, .. } = command {
                    if option_ids.is_empty() || option_ids.len() > 100 {
                        return Err(UserError("Hãy chọn ít nhất một lựa chọn.").into());
                    }
                    chat::poll_vote(&self.session, *poll_id, option_ids).await.map_err(|error| anyhow!(UserError(poll_error(&error))))?;
                    chat::poll_detail(&self.session, *poll_id).await
                } else {
                    chat::poll_detail(&self.session, *poll_id).await
                }
                .map_err(|error| anyhow!(UserError(poll_error(&error))))?;
                Ok(json!({"thread_id": thread_id, "poll_id": poll_id, "poll": poll_dto(&data)}))
            }
            Command::MarkSeen {
                thread_id,
                is_group,
                message_id,
            } => {
                self.require_login()?;
                let index = self.known_thread(thread_id, *is_group)?;
                let message_id = if message_id.is_empty() {
                    self.threads[index]
                        .messages
                        .last()
                        .map(|message| message.id.as_str())
                        .unwrap_or("")
                } else {
                    message_id
                };
                if !self.demo {
                    check_response(
                        &chat::send_seen_v2(&self.session, thread_id, *is_group, message_id)
                            .await?,
                    )?;
                }
                let messages = self.threads[index].messages.clone();
                self.threads[index].unread.read_visible(&messages);
                // The badge clears before the store write, which is slow on a large account.
                self.emit_threads().await?;
                self.persist_best_effort().await?;
                Ok(json!({"thread_id": thread_id}))
            }
            Command::PinThread {
                thread_id,
                is_group,
                pin,
            } => {
                self.require_login()?;
                let index = self.known_thread(thread_id, *is_group)?;
                if !self.demo {
                    check_response(
                        &chat::update_pinned_conversation(
                            &self.session,
                            thread_id,
                            *is_group,
                            *pin,
                        )
                        .await?,
                    )?;
                }
                if *pin {
                    self.pinned.insert(thread_id.clone());
                } else {
                    self.pinned.remove(thread_id);
                }
                self.threads[index].presentation.pinned = *pin;
                self.persist_best_effort().await?;
                self.emit_threads().await?;
                Ok(json!({"thread_id": thread_id}))
            }
            Command::MuteThread {
                thread_id,
                is_group,
                mute,
            } => {
                self.require_login()?;
                let index = self.known_thread(thread_id, *is_group)?;
                if !self.demo {
                    check_response(
                        &chat::set_mute_conversation(
                            &self.session,
                            thread_id,
                            *is_group,
                            -1,
                            *mute,
                        )
                        .await?,
                    )?;
                }
                self.threads[index].unread.muted = *mute;
                self.persist_best_effort().await?;
                self.emit_threads().await?;
                Ok(json!({"thread_id": thread_id}))
            }
            Command::Logout => {
                if self.demo {
                    self.demo_logged_in = false;
                }
                self.expire().await?;
                Ok(json!({}))
            }
            Command::Shutdown => Ok(json!({})),
            Command::RequestQr => Err(UserError("Yêu cầu QR chưa được khởi tạo.").into()),
            // Reads only the local history, so it also serves demo mode.
            Command::ThreadLibrary { .. } => {
                let params = serde_json::to_value(command)?;
                extras::execute("thread_library", &params, &self.session, &self.threads, &self.db_path, &self.output)
                    .await?
                    .ok_or_else(|| anyhow!(UserError("Tính năng chưa được hỗ trợ.")))
            }
            command => {
                self.require_login()?;
                if self.demo {
                    return Err(UserError("Tính năng này cần kết nối tài khoản Zalo thật.").into());
                }
                if let Command::ImportHistory { path, .. } = command {
                    self.ensure_export_key(path).await?;
                }
                let params = serde_json::to_value(command)?;
                let result = extras::execute(
                    command.name(),
                    &params,
                    &self.session,
                    &self.threads,
                    &self.db_path,
                    &self.output,
                )
                .await?
                .ok_or_else(|| anyhow!(UserError("Tính năng chưa được hỗ trợ.")))?;
                if command.name() == "import_history" {
                    let db_path = self.db_path.clone();
                    let threads = self.threads.clone();
                    self.threads = tokio::task::spawn_blocking(move || -> Result<_> {
                        let mut threads = threads;
                        MessageStore::open(&db_path)?
                            .hydrate_threads(&mut threads, MessageStore::PRELOAD_MSGS)?;
                        Ok(threads)
                    })
                    .await??;
                    self.persist_best_effort().await?;
                    self.publish().await?;
                }
                if matches!(
                    command,
                    Command::SendSticker { .. } | Command::ForwardMessage { .. }
                ) {
                    if let Some(thread_id) = result.get("target_thread_id").and_then(Value::as_str)
                    {
                        if let Some(index) = self
                            .threads
                            .iter()
                            .position(|thread| thread.id == thread_id)
                        {
                            let client_id = result
                                .get("client_message_id")
                                .and_then(Value::as_str)
                                .unwrap_or_default();
                            let message = ChatMessage {
                                id: result
                                    .get("message_id")
                                    .and_then(Value::as_str)
                                    .unwrap_or_default()
                                    .into(),
                                client_message_id: client_id.into(),
                                ts: client_id
                                    .parse()
                                    .unwrap_or_else(|_| crate::login::unix_now() * 1000),
                                sender: "Bạn".into(),
                                is_outgoing: true,
                                text: if matches!(command, Command::SendSticker { .. }) {
                                    "[Nhãn dán]".into()
                                } else {
                                    "[Tin nhắn chuyển tiếp]".into()
                                },
                                sticker_id: result.get("sticker_id").and_then(Value::as_u64),
                                sticker_cate_id: result.get("cate_id").and_then(Value::as_u64),
                                sticker_type: result
                                    .get("sticker_type")
                                    .and_then(Value::as_u64)
                                    .map(|kind| kind as u32),
                                ..Default::default()
                            };
                            chat::merge_sent_message(&mut self.threads[index], message);
                            self.persist_best_effort().await?;
                            self.publish().await?;
                        }
                    }
                }
                Ok(result)
            }
        }
    }

    async fn apply_poll(
        &mut self,
        response: Value,
        scheduled: Vec<(String, ChatMessage)>,
    ) -> Result<()> {
        if !self.logged_in() || self.demo {
            return Ok(());
        }
        for (thread_id, message) in scheduled {
            if let Some(thread) = self
                .threads
                .iter_mut()
                .find(|thread| thread.id == thread_id)
            {
                chat::merge_sent_message(thread, message);
            }
        }
        check_response(&response)?;
        self.platform.handle_control(
            &response,
            &self.session,
            &self.threads,
            &self.db_path,
            self.output.clone(),
            self.demo,
        );
        let removed = chat::merge_live_previews(&mut self.threads, &response);
        self.forget_removed(removed).await?;
        self.persist_best_effort().await?;
        self.publish().await
    }
}

fn merge_threads(threads: &mut Vec<Thread>, incoming: Vec<Thread>) {
    for thread in incoming {
        if let Some(existing) = threads.iter_mut().find(|existing| existing.id == thread.id) {
            chat::merge_thread_into(existing, thread, false);
        } else if threads.len() < MAX_THREADS {
            threads.push(thread);
        }
    }
}

fn account_paths(session: &Session) -> Result<(String, String)> {
    let uin = &session
        .login
        .as_ref()
        .ok_or_else(|| anyhow!(UserError("Bạn cần đăng nhập trước.")))?
        .uin;
    if uin.is_empty()
        || uin.len() > 128
        || !uin
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
    {
        return Err(UserError("Thông tin tài khoản không hợp lệ.").into());
    }
    let directory = Path::new("accounts").join(uin);
    crate::data_dir::prepare(&directory, true)?;
    Ok((
        directory
            .join("native_history.db")
            .to_string_lossy()
            .into_owned(),
        directory
            .join("native_threads.json")
            .to_string_lossy()
            .into_owned(),
    ))
}

fn demo_threads() -> Vec<Thread> {
    let now = crate::login::unix_now() * 1000;
    vec![Thread {
        id: "demo-group".into(), name: "Nhóm trải nghiệm macOS".into(), is_group: true,
        avatar: None, preview: String::new(), time: String::new(), presentation: Default::default(), unread: Default::default(),
        messages: vec![
            ChatMessage { id: "demo-message-1".into(), sender: "Hướng dẫn".into(), text: "Chào bạn! Đây là giao diện macOS mới, dùng SwiftUI và AppKit.".into(), ts: now - 240_000, ..Default::default() },
            ChatMessage { id: "demo-message-2".into(), sender: "Bạn".into(), text: "Phần giao thức Zalo vẫn chạy bằng Rust đúng không?".into(), ts: now - 180_000, is_outgoing: true, ..Default::default() },
            ChatMessage { id: "demo-message-3".into(), sender: "Hướng dẫn".into(), text: "Đúng rồi. Giao diện và lõi Rust trao đổi qua cầu nối riêng. Chế độ minh họa không kết nối tài khoản thật.".into(), ts: now - 120_000, ..Default::default() },
        ],
    }, Thread {
        id: "demo-person".into(), name: "Trò chuyện thử".into(), is_group: false, avatar: None,
        preview: "Thử gửi một tin nhắn".into(), time: String::new(), presentation: Default::default(), unread: Default::default(),
        messages: vec![ChatMessage { id: "demo-message-4".into(), sender: "Trò chuyện thử".into(), text: "Bạn có thể thử soạn tin, trả lời và biểu cảm tại đây.".into(), ts: now - 60_000, ..Default::default() }],
    }]
}

fn qr_png(qr: &crate::qr::QrLogin) -> Result<String> {
    if let Some(png) = &qr.base64_png {
        let png = png.strip_prefix("data:image/png;base64,").unwrap_or(png);
        if png.len() <= MAX_FRAME / 2 {
            return Ok(png.into());
        }
    }
    let payload = qr.payload().context("missing QR payload")?;
    let code = qrcode::QrCode::new(payload.as_bytes())?;
    let scale = 6;
    let side = code.width() + 8;
    let image = image::GrayImage::from_fn((side * scale) as u32, (side * scale) as u32, |x, y| {
        let x = x as usize / scale;
        let y = y as usize / scale;
        let dark = x >= 4
            && y >= 4
            && x < side - 4
            && y < side - 4
            && code[(x - 4, y - 4)] == qrcode::Color::Dark;
        image::Luma([if dark { 0 } else { 255 }])
    });
    let mut png = std::io::Cursor::new(Vec::new());
    image::DynamicImage::ImageLuma8(image).write_to(&mut png, image::ImageFormat::Png)?;
    Ok(base64::engine::general_purpose::STANDARD.encode(png.into_inner()))
}

async fn qr_login(mut session: Session, output: mpsc::Sender<Value>) -> Result<Session> {
    session.logout();
    let qr = tokio::time::timeout(
        Duration::from_secs(20),
        crate::qr::request_qr(&session, "vi"),
    )
    .await??;
    let png = qr_png(&qr)?;
    emit(
        &output,
        event(
            "qr",
            json!({"image_base64": png, "expires_in": qr.qr_timeout}),
        ),
    )
    .await?;
    emit(
        &output,
        event(
            "status",
            json!({"message": "Quét mã bằng Zalo trên điện thoại"}),
        ),
    )
    .await?;
    crate::qr::wait_for_scan(&session, &qr).await?;
    emit(
        &output,
        event(
            "status",
            json!({"message": "Đã quét mã. Hãy xác nhận đăng nhập trên điện thoại."}),
        ),
    )
    .await?;
    let response = crate::qr::confirm(&session, &qr).await?;
    check_response(&response)?;
    if let Some(cookie) = crate::qr::extract_zpw_sek(&response) {
        session.set_zpw_sek(cookie);
    }
    if let Some(data) = response.get("data") {
        crate::login::apply_login_config(&mut session, data);
    }
    let info = crate::login::get_login_info(&session).await?;
    check_response(&info)?;
    if let Some(data) = info.get("data") {
        crate::login::apply_login_config(&mut session, data);
        session.apply_server_info(data);
    }
    if !authenticated(&session) {
        return Err(UserError("Chưa nhận đủ thông tin đăng nhập từ Zalo.").into());
    }
    Ok(session)
}

fn read_frame(reader: &mut impl BufRead) -> std::io::Result<Option<Vec<u8>>> {
    let mut frame = Vec::new();
    let mut oversized = false;
    loop {
        let buffer = reader.fill_buf()?;
        if buffer.is_empty() {
            return Ok((!frame.is_empty() || oversized).then_some(frame));
        }
        let end = buffer.iter().position(|byte| *byte == b'\n');
        let take = end.map_or(buffer.len(), |end| end + 1);
        if !oversized {
            if frame.len() + take > MAX_FRAME {
                frame.clear();
                oversized = true;
            } else {
                frame.extend_from_slice(&buffer[..take]);
            }
        }
        reader.consume(take);
        if end.is_some() {
            return Ok(Some(frame));
        }
    }
}

fn parse_request(frame: &[u8]) -> Result<Request> {
    let request: Request = serde_json::from_slice(frame)?;
    if request.id.is_empty() || request.id.len() > 128 || request.id.chars().any(char::is_control) {
        bail!("invalid request ID");
    }
    Ok(request)
}

fn malformed_result(frame: &[u8]) -> Value {
    let value: Value = serde_json::from_slice(frame).unwrap_or(Value::Null);
    let safe_string = |key: &str| {
        value.get(key).and_then(Value::as_str).filter(|value| {
            !value.is_empty() && value.len() <= 128 && !value.chars().any(char::is_control)
        })
    };
    json!({"event": "result", "id": safe_string("id"), "command": safe_string("command"),
        "ok": false, "data": null, "error": "Yêu cầu không hợp lệ hoặc tính năng chưa được hỗ trợ."})
}

/// Run a bounded stdio worker until the parent closes stdin or requests shutdown.
///
/// `demo` uses synthetic, in-memory threads and never opens user storage or Zalo.
/// # Errors
/// Returns an error when initialization or the parent output pipe fails.
/// # Invariants
/// Session credentials never cross the UI boundary (INV-2); I/O stays in the worker (INV-3).
pub async fn run_stdio(demo: bool) -> Result<()> {
    let (input_tx, mut input_rx) = mpsc::channel::<Vec<u8>>(32);
    let (output_tx, mut output_rx) = mpsc::channel::<Value>(32);
    let history_context: history::SharedContext = Default::default();
    let (history_loaded_tx, mut history_loaded_rx) = mpsc::unbounded_channel();
    let history_sender = history::start(history_context.clone(), output_tx.clone(), history_loaded_tx)?;
    let (closed_tx, mut closed_rx) = tokio::sync::watch::channel(false);
    std::thread::Builder::new()
        .name("native-json-input".into())
        .spawn(move || {
            let stdin = std::io::stdin();
            let mut reader = stdin.lock();
            while let Ok(Some(frame)) = read_frame(&mut reader) {
                // The command loop is busy during an import, so the flag is raised here.
                if frame.windows(15).any(|window| window == b"\"cancel_import\"") {
                    crate::zalo_backup::IMPORT_CANCEL.store(true, std::sync::atomic::Ordering::Relaxed);
                }
                if let Ok(request) = parse_request(&frame) {
                    if matches!(request.command, NativeIntent::Base(Command::LoadMessagePage { .. })) {
                        if history_sender.blocking_send(request).is_err() { break; }
                        continue;
                    }
                }
                if input_tx.blocking_send(frame).is_err() {
                    break;
                }
            }
            // EOF means the parent no longer owns the worker; cancel in-flight I/O.
            if closed_tx.send(true).is_err() {
                eprintln!("native input owner closed");
            }
        })?;
    let writer = std::thread::Builder::new()
        .name("native-json-output".into())
        .spawn(move || -> std::io::Result<()> {
            let stdout = std::io::stdout();
            let mut writer = stdout.lock();
            while let Some(value) = output_rx.blocking_recv() {
                serde_json::to_writer(&mut writer, &value)?;
                writer.write_all(b"\n")?;
                writer.flush()?;
            }
            Ok(())
        })?;
    let mut core = Core::new(demo, output_tx.clone())?;
    core.history_context = history_context;
    let mut platform_rx = core
        .platform_updates
        .take()
        .context("missing native platform receiver")?;
    let capabilities: Vec<&str> = CAPABILITIES
        .iter()
        .chain(extras::commands())
        .chain(features::commands())
        .chain(platform::commands())
        .chain(account_settings::commands())
        .chain(["get_privacy_guard", "set_privacy_guard", "cancel_import"].iter())
        .copied()
        .collect();
    emit(
        &output_tx,
        event(
            "ready",
            json!({"protocol_version": 1, "capabilities": capabilities, "demo": demo}),
        ),
    )
    .await?;
    let (auth_tx, mut auth_rx) = mpsc::channel::<(Request, Result<Session>)>(1);
    let mut qr_task: Option<(Request, tokio::task::JoinHandle<()>)> = None;
    let mut websocket: Option<mpsc::UnboundedReceiver<crate::socket::WsEvent>> = None;
    let (poll_tx, mut poll_rx) = mpsc::channel::<PollResult>(1);
    let mut poll_task: Option<tokio::task::JoinHandle<()>> = None;
    let mut generation = 0u64;
    let mut history_generation = 0u64;
    let mut timer = tokio::time::interval(Duration::from_secs(5));
    timer.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    let mut completed: HashMap<String, (String, Value)> = HashMap::new();
    let mut completed_order = VecDeque::new();
    // Live pushes are shown at once and saved in batches, so a burst of messages is not held
    // behind full-store writes (re-notes/66_typing_and_live_latency.md).
    let mut live_unsaved = false;
    let mut save_timer = tokio::time::interval(Duration::from_secs(2));
    save_timer.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    // Other accounts' unread counts (re-notes/77): first check shortly after start, then every few minutes.
    let mut watch_timer = tokio::time::interval_at(
        tokio::time::Instant::now() + Duration::from_secs(30),
        Duration::from_secs(account_watch::INTERVAL_SECS),
    );
    watch_timer.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    let (watch_tx, mut watch_rx) = mpsc::channel::<Value>(8);
    let mut watch_task: Option<tokio::task::JoinHandle<()>> = None;
    loop {
        core.update_history_context(history_generation);
        tokio::select! {
            biased;
            page = history_loaded_rx.recv(), if !history_loaded_rx.is_closed() => {
                if let Some(page) = page {
                    if page.generation == history_generation && core.logged_in() {
                        if let Some(thread) = core.threads.iter_mut().find(|t| t.id == page.thread.id && t.is_group == page.thread.is_group) {
                            core.selected = Some(thread.id.clone());
                            let recent=core.history_recent.entry(thread.id.clone()).or_default();
                            for message in page.thread.messages {
                                recent.retain(|id| id != &message.id);recent.push_back(message.id.clone());
                                if !thread.messages.iter().any(|existing|existing.id==message.id) {thread.messages.push(message);}
                            }
                            thread.messages.sort_by(|a,b|a.ts.cmp(&b.ts).then(a.id.cmp(&b.id)));
                            while recent.len()>500 {recent.pop_front();}
                            let keep:HashSet<_>=recent.iter().cloned().chain(thread.messages.iter().rev().take(50).map(|m|m.id.clone())).collect();
                            thread.messages.retain(|m|keep.contains(&m.id));
                        }
                    }
                }
            }
            frame = input_rx.recv() => {
                let Some(frame) = frame else { break; };
                let request = match parse_request(&frame) {
                    Ok(request) => request,
                    Err(_) => { emit(&output_tx, malformed_result(&frame)).await?; continue; }
                };
                let fingerprint = intent_fingerprint(&request.command)?;
                if let Some((previous, result)) = completed.get(&request.id) {
                    if previous == &fingerprint { emit(&output_tx, result.clone()).await?; }
                    else { emit(&output_tx, terminal(&request, &Err(UserError("Mã yêu cầu đã được dùng cho thao tác khác.").into()))).await?; }
                    continue;
                }
                if qr_task.as_ref().is_some_and(|(pending, _)| pending.id == request.id) {
                    emit(&output_tx, terminal(&request, &Err(UserError("Yêu cầu này đang được xử lý.").into()))).await?;
                    continue;
                }
                if request.command.is_base(|command| matches!(command, Command::RequestQr | Command::Logout | Command::Shutdown)) {
                    if let Some((pending, task)) = qr_task.take() {
                        task.abort();
                        emit(&output_tx, terminal(&pending, &Err(UserError("Đã hủy yêu cầu đăng nhập trước.").into()))).await?;
                    }
                }
                if request.command.is_base(|command| matches!(command, Command::Bootstrap | Command::RequestQr | Command::Logout | Command::Shutdown)) {
                    generation = generation.wrapping_add(1);
                    history_generation = history_generation.wrapping_add(1);
                    completed.clear(); completed_order.clear();
                    if let Ok(mut context) = core.history_context.lock() {
                        context.account.clear(); context.generation = history_generation;
                    }
                    core.history_recent.clear();
                    if let Ok(mut cache)=core.published_messages.lock(){cache.clear();}
                    core.platform.stop();
                    while platform_rx.try_recv().is_ok() {}
                    if let Some(task) = poll_task.take() { task.abort(); }
                    websocket = None;
                }
                if request.command.is_base(|command| matches!(command, Command::RequestQr)) && !demo {
                    let session = core.session.clone();
                    let tx = auth_tx.clone();
                    let output = output_tx.clone();
                    let pending = request.clone();
                    let task = tokio::spawn(async move {
                        let result = tokio::time::timeout(Duration::from_secs(360), qr_login(session, output)).await
                            .map_err(anyhow::Error::from).and_then(|result| result);
                        // A closed receiver means the owning application has shut down.
                        if tx.send((pending, result)).await.is_err() { eprintln!("native QR owner closed"); }
                    });
                    qr_task = Some((request, task));
                    continue;
                }
                if matches!(&request.command, NativeIntent::Features(command) if command.invalidates_poll()) {
                    generation=generation.wrapping_add(1);
                    if let Some(task)=poll_task.take() { task.abort(); }
                }
                if request.command.is_base(|command| matches!(command, Command::Logout)) {
                    if let Ok(mut context) = core.history_context.lock() { context.account.clear(); }
                }
                let shutdown = request.command.is_base(|command| matches!(command, Command::Shutdown));
                let result = if request.command.is_base(|command| matches!(command, Command::RequestQr)) && demo {
                    Err(UserError("Chế độ minh họa không đăng nhập tài khoản thật.").into())
                } else {
                    // An export import (several GB of photos and videos) can run far past the usual limit;
                    // the UI allows it 12 hours as well.
                    let limit = if request.command.is_base(|command| matches!(command, Command::ImportHistory { .. })) {
                        Duration::from_secs(12 * 60 * 60)
                    } else {
                        Duration::from_secs(120)
                    };
                    tokio::select! {
                        result = tokio::time::timeout(limit, core.execute_intent(&request.command)) => {
                            result.map_err(anyhow::Error::from).and_then(|result| result)
                        }
                        _ = closed_rx.changed() => break,
                    }
                };
                if result.as_ref().err().is_some_and(|error| SessionStatus::from_error(error) == SessionStatus::Expired) {
                    generation = generation.wrapping_add(1);
                    if let Some(task) = poll_task.take() { task.abort(); }
                    completed.clear(); completed_order.clear(); core.expire().await?;
                }
                if let Err(error) = &result {
                    record_failure(request.command.name(), error);
                }
                let result_event = terminal(&request, &result);
                emit(&output_tx, result_event.clone()).await?;
                completed.insert(request.id.clone(), (fingerprint, result_event));
                completed_order.push_back(request.id);
                if completed_order.len() > 128 {
                    if let Some(oldest) = completed_order.pop_front() { completed.remove(&oldest); }
                }
                if core.logged_in() && !demo && websocket.is_none() { websocket = Some(websocket_feed(core.session.clone())); }
                if !core.logged_in() { websocket = None; }
                if shutdown { break; }
            }
            auth = auth_rx.recv(), if qr_task.is_some() => {
                let Some((request, result)) = auth else { continue; };
                if !qr_task.as_ref().is_some_and(|(pending, _)| pending.id == request.id) { continue; }
                qr_task = None;
                let result = match result {
                    Ok(session) => {
                        let save_session = session.clone();
                        match tokio::task::spawn_blocking(move || -> Result<_> {
                            let paths = account_paths(&save_session)?;
                            save_session.save_to_file("session.json")?;
                            Ok(paths)
                        }).await {
                            Ok(Ok((db_path, cache_path))) => {
                                core.session = session;
                                core.db_path = db_path;
                                core.cache_path = cache_path;
                                core.threads.clear();
                                core.selected = None;
                                core.pinned.clear();
                                core.features=Default::default(); core.preferences.reset(); core.account_settings.reset(); core.platform.stop();
                                completed.clear(); completed_order.clear();
                                core.poll_state = chat::PollState::default();
                                core.emit_session().await?;
                                websocket = Some(websocket_feed(core.session.clone()));
                                let refresh = tokio::select! {
                                    result = core.refresh() => result,
                                    _ = closed_rx.changed() => break,
                                };
                                match refresh {
                                    Ok(_) => Ok(json!({"logged_in": true})),
                                    Err(_) if core.logged_in() => {
                                        emit(&output_tx, event("status", json!({"message": "Đã đăng nhập. Chưa tải được danh sách hội thoại; hãy làm mới."}))).await?;
                                        Ok(json!({"logged_in": true}))
                                    }
                                    Err(error) => Err(error),
                                }
                            }
                            _ => Err(UserError("Đã xác nhận nhưng không lưu được phiên đăng nhập trên máy.").into()),
                        }
                    }
                    Err(error) => Err(error),
                };
                if let Err(error) = &result {
                    record_failure(request.command.name(), error);
                }
                let result_event = terminal(&request, &result);
                emit(&output_tx, result_event.clone()).await?;
                completed.insert(request.id.clone(), (intent_fingerprint(&request.command)?, result_event));
                completed_order.push_back(request.id);
                if completed_order.len() > 128 {
                    if let Some(oldest) = completed_order.pop_front() { completed.remove(&oldest); }
                }
            }
            ws_event = async {
                match websocket.as_mut() { Some(receiver) => receiver.recv().await, None => std::future::pending().await }
            } => {
                match ws_event {
                    Some(ws_event) => {
                        for typing in typing_events(&ws_event.payload, core.session.login.as_ref().map(|login| login.uin.as_str()).unwrap_or_default()) {
                            emit(&output_tx, event("typing", typing)).await?;
                        }
                        core.platform.handle_control(&ws_event.payload,&core.session,&core.threads,&core.db_path,output_tx.clone(),demo);
                        if apply_live_reactions(&mut core.threads, &ws_event.payload) && !ws_event.is_chat_ish() {
                            core.persist_best_effort().await?;
                            core.publish().await?;
                        }
                        if ws_event.is_chat_ish() {
                            let removed = chat::merge_live_previews(&mut core.threads, &ws_event.payload);
                            core.forget_removed(removed).await?;
                            core.publish().await?;
                            live_unsaved = true;
                        }
                    }
                    None => websocket = None,
                }
            }
            _ = save_timer.tick(), if live_unsaved => {
                live_unsaved = false;
                core.persist_best_effort().await?;
            }
            update = platform_rx.recv() => {
                if let Some(platform::PlatformUpdate::Threads { account, threads })=update {
                    if core.logged_in() && core.session.login.as_ref().is_some_and(|login|login.uin==account) {
                        merge_threads(&mut core.threads,threads);
                        core.persist_best_effort().await?;
                        core.publish().await?;
                    }
                }
            }
            watched = watch_rx.recv() => {
                let Some(watched) = watched else { continue; };
                if watched.get("done").is_some() { watch_task = None; continue; }
                emit(&core.output, event("account_unread", watched)).await?;
            }
            _ = watch_timer.tick(), if core.logged_in() && !demo && watch_task.is_none() => {
                let active = core.own_uid();
                let accounts = account_watch::other_accounts(Path::new("."), &active);
                if !accounts.is_empty() {
                    let sender = watch_tx.clone();
                    watch_task = Some(tokio::spawn(async move {
                        for uin in accounts {
                            if sender.send(account_watch::check(uin).await).await.is_err() { return; }
                        }
                        let _ = sender.send(json!({"done": true})).await;
                    }));
                }
            }
            polled = poll_rx.recv(), if poll_task.is_some() => {
                let Some(polled) = polled else { continue; };
                if polled.generation != generation { continue; }
                poll_task = None;
                core.poll_state = polled.state;
                let scheduled = match polled.scheduled {
                    Ok(rows) => rows,
                    Err(_) => {
                        emit(&output_tx, event("status", json!({"message": "Chưa xử lý được hàng đợi tin nhắn hẹn giờ."}))).await?;
                        Vec::new()
                    }
                };
                let result = match polled.response {
                    Ok(response) => core.apply_poll(response, scheduled).await,
                    Err(error) => {
                        // Acknowledged scheduled sends remain visible even if polling failed.
                        for (thread_id, message) in scheduled {
                            if let Some(thread) = core.threads.iter_mut().find(|thread| thread.id == thread_id) {
                                chat::merge_sent_message(thread, message);
                            }
                        }
                        core.persist_best_effort().await?;
                        core.publish().await?;
                        Err(error)
                    }
                };
                if let Err(error) = result {
                    if SessionStatus::from_error(&error) == SessionStatus::Expired {
                        generation = generation.wrapping_add(1);
                        websocket = None;
                        completed.clear(); completed_order.clear(); core.expire().await?;
                    } else {
                        emit(&output_tx, event("status", json!({"message": "Mất kết nối. Đang thử lại; lịch sử trên máy được giữ nguyên."}))).await?;
                    }
                }
            }
            _ = timer.tick(), if core.logged_in() && !demo && qr_task.is_none() && poll_task.is_none() => {
                let session = core.session.clone();
                let db_path = core.db_path.clone();
                let mut state = std::mem::take(&mut core.poll_state);
                let sender = poll_tx.clone();
                let owned_generation = generation;
                poll_task = Some(tokio::spawn(async move {
                    let scheduled = extras::deliver_due(&session, &db_path).await;
                    let response = tokio::time::timeout(Duration::from_secs(18),
                        chat::get_chat_from_polling(&session, &mut state)).await
                        .map_err(anyhow::Error::from).and_then(|result| result);
                    if sender.send(PollResult { generation: owned_generation, state, response, scheduled }).await.is_err() {
                        eprintln!("native poll owner closed");
                    }
                }));
            }
        }
    }
    if let Some((_, task)) = qr_task {
        task.abort();
    }
    if let Some(task) = poll_task {
        task.abort();
    }
    if let Some(task) = watch_task {
        task.abort();
    }
    drop(websocket);
    if live_unsaved {
        let _ = core.persist().await;
    }
    drop(core);
    drop(output_tx);
    // stdout drains on a separate thread; the UI process can terminate this helper
    // if its own output pipe stops consuming during application shutdown.
    writer
        .join()
        .map_err(|_| anyhow!("native output thread failed"))??;
    Ok(())
}

/// True when `key` (or a matching key Zalo PC left on this Mac) opens the export's first tar header.
async fn export_key_opens(path: &str, key: &str, own_uid: &str) -> Result<bool> {
    let (source, key, uid) = (path.to_owned(), key.to_owned(), own_uid.to_owned());
    Ok(tokio::task::spawn_blocking(move || crate::zalo_backup::resolve_export_key(Path::new(&source), &key, &uid).is_ok()).await?)
}

#[cfg(test)]
mod tests {
    #[test]
    fn own_reaction_under_zero_and_uin_counts_once() {
        let mut message = ChatMessage { id: "m".into(), ..Default::default() };
        message.reaction_summaries = crate::reactions::parse_reactions(&json!({"reactions": {"0": {"5": 1}, "peer": {"5": 1}}}));
        message.apply_reaction(&crate::reactions::ReactionEvent {
            message_id: "m".into(), sender_id: "777".into(), r_type: 5, emoji: "❤️".into(), ts: 1, ..Default::default()
        });
        let details = reaction_details(&message, "777");
        assert_eq!(details.len(), 1);
        assert_eq!(details[0].count, 2);
        let mut reactors = details[0].reactors.clone();
        reactors.sort();
        assert_eq!(reactors, vec!["777".to_string(), "peer".to_string()]);
        // Without a signed-in account "0" stays as it is.
        assert_eq!(reaction_details(&message, "")[0].count, 3);
    }

    #[test]
    fn poll_dto_keeps_only_drawn_fields() {
        let data = json!({"poll_id": 7, "question": "Đi đâu?", "creator": "1", "joined": true, "closed": 0,
            "allow_multi_choices": 1, "num_vote": 3, "expired_time": 0, "secret": "x",
            "options": [{"option_id": 11, "content": "Biển", "votes": 2, "voted": true, "voters": ["1", 2]},
                        {"option_id": "12", "content": "Núi", "votes": 1, "voted": false, "voters": []}]});
        let dto = poll_dto(&data);
        assert_eq!(dto["multiple"], json!(true));
        assert_eq!(dto["closed"], json!(false));
        assert_eq!(dto["options"][1]["option_id"], json!(12));
        assert_eq!(dto["options"][0]["voters"], json!(["1", "2"]));
        assert!(dto.get("secret").is_none());
    }

    use super::*;

    #[tokio::test]
    async fn unchanged_snapshot_persistence_benchmark() {
        use std::time::Instant;
        let directory=std::env::temp_dir().join(format!("ctdo-noop-perf-{}-{}",std::process::id(),crate::login::unix_now()));
        std::fs::create_dir_all(&directory).unwrap();
        let (sender,_)=mpsc::channel(32);
        let mut core=Core::new(false,sender).unwrap();
        core.db_path=directory.join("history.db").to_string_lossy().into_owned();
        core.cache_path=directory.join("cache.json").to_string_lossy().into_owned();
        core.threads=demo_threads();core.threads.truncate(1);core.threads[0].messages.clear();
        for i in 0..5000 {core.threads[0].messages.push(ChatMessage{id:format!("fake-message-{i}"),text:"Synthetic performance fixture".into(),ts:1000+i,..Default::default()});}
        core.persist().await.unwrap();
        let mut before=Vec::new();let mut after=Vec::new();
        for _ in 0..3 {
            let start=Instant::now();
            store::persist_threads(&mut MessageStore::open(&core.db_path).unwrap(),&core.threads).unwrap();
            crate::data_dir::write_private_atomic(Path::new(&core.cache_path),&serde_json::to_vec(&core.threads).unwrap()).unwrap();
            before.push(start.elapsed().as_secs_f64()*1000.0);
            let start=Instant::now();core.persist().await.unwrap();after.push(start.elapsed().as_secs_f64()*1000.0);
        }
        before.sort_by(f64::total_cmp);after.sort_by(f64::total_cmp);
        eprintln!("PERSIST_BENCHMARK synthetic_messages=5000 before_median_ms={} after_median_ms={}",before[1],after[1]);
        assert_eq!(MessageStore::open(&core.db_path).unwrap().conn.query_row("SELECT count(*) FROM messages",[],|row|row.get::<_,usize>(0)).unwrap(),5000);
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[tokio::test]
    async fn stale_read_returns_the_current_thread_snapshot_before_failure() {
        let (sender, mut receiver) = mpsc::channel(8);
        let mut core = Core::new(true, sender).unwrap();
        core.threads = demo_threads();
        let original_count = core.threads.len();
        assert!(core
            .load_messages("obsolete-thread", false, 100)
            .await
            .is_err());
        let snapshot = receiver.recv().await.unwrap();
        assert_eq!(snapshot["event"], "threads");
        assert_eq!(snapshot["data"].as_array().unwrap().len(), original_count);
        assert_eq!(core.threads.len(), original_count);
    }

    #[test]
    fn typing_controls_name_thread_and_person() {
        let payload = json!({"data": {"actions": [
            {"act_type":"typing","act":"typing","data":"\"uid\":\"42\",\"ts\":\"1700000000000\",\"isPC\":0"},
            {"act_type":"typing","act":"gtyping","data":"\"uid\":\"43\",\"gid\":\"900\",\"ts\":\"1\""},
            {"act_type":"typing","act":"typing","data":"\"uid\":\"7\""},
            {"act_type":"file_done","act":"x","data":"{}"}
        ]}});
        let events = typing_events(&payload, "7");
        assert_eq!(events, vec![
            json!({"thread_id":"42","user_id":"42","is_group":false}),
            json!({"thread_id":"900","user_id":"43","is_group":true}),
        ]);
    }

    #[test]
    fn oversized_frame_is_discarded_without_consuming_the_next_request() {
        let mut input = vec![b'x'; MAX_FRAME + 20];
        input.extend_from_slice(b"\n{\"id\":\"next\",\"command\":\"shutdown\"}\n");
        let mut reader = std::io::Cursor::new(input);
        assert!(read_frame(&mut reader).unwrap().unwrap().is_empty());
        assert_eq!(
            parse_request(&read_frame(&mut reader).unwrap().unwrap())
                .unwrap()
                .id,
            "next"
        );
    }

    #[test]
    fn invalid_commands_and_ids_cannot_trigger_an_operation() {
        assert!(parse_request(br#"{"id":"one","command":"shell","path":"anything"}"#).is_err());
        assert!(parse_request(
            br#"{"id":"","command":"send_message","thread_id":"user-1","text":"hi"}"#
        )
        .is_err());
    }

    #[test]
    fn underlying_errors_and_credentials_never_cross_the_boundary() {
        let error = anyhow!("response contains zpw_sek=secret and https://host/?key=private");
        let request = Request {
            id: "one".into(),
            command: Command::RefreshThreads.into(),
        };
        let output = terminal(&request, &Err(error)).to_string();
        assert!(!output.contains("secret")); // (INV-2)
        assert!(!output.contains("private"));
        assert!(!output.contains("zpw_sek"));
    }

    #[test]
    fn oversized_results_fail_with_the_original_correlation_id() {
        let request = Request {
            id: "large-result".into(),
            command: Command::ListScheduled { thread_id: None }.into(),
        };
        let response = terminal(
            &request,
            &Ok(json!({"items": "x".repeat(MAX_OUTPUT_FRAME)})),
        );
        assert_eq!(response["id"], "large-result");
        assert_eq!(response["command"], "list_scheduled");
        assert_eq!(response["ok"], false);
        assert!(serde_json::to_vec(&response).unwrap().len() < 1024);
    }

    #[test]
    fn incomplete_saved_credentials_never_enable_plain_parameter_requests() {
        let mut session = Session::new(false, false, false).unwrap();
        session.login = Some(crate::session::LoginInfo {
            uin: "user-test".into(),
            display_name: "Test".into(),
            zpw_enk: String::new(),
            zpw_sek: String::new(),
            send2me_id: String::new(),
            avatar: String::new(),
            dkey: String::new(),
        });
        session.zpw_sek = Some("fake-cookie".into());
        assert!(!authenticated(&session));
        session.secret_key = Some(vec![0; 8]);
        assert!(!authenticated(&session));
        session.secret_key = Some(vec![0; 16]);
        assert!(authenticated(&session));
        session.zpw_sek = None;
        assert!(!authenticated(&session));
    }

    #[test]
    fn empty_reaction_removes_instead_of_sending_a_heart() {
        assert_eq!(chat::reaction_code_and_type(""), ("", -1));
        assert_eq!(chat::reaction_code_and_type("😡"), (":-h", 20));
    }

    #[test]
    fn blocked_send_is_reported_plainly() {
        let error = anyhow::Error::from(crate::session::SessionError::new(119, "x"));
        assert_eq!(safe_error(&error), SEND_BLOCKED_MESSAGE);
        let other = anyhow::Error::from(crate::session::SessionError::new(114, "x"));
        assert_ne!(safe_error(&other), SEND_BLOCKED_MESSAGE);
    }

    #[test]
    fn group_notices_become_system_rows_but_ordinary_text_does_not() {
        let notice = |sender: &str, text: &str| ChatMessage {
            id: "1".into(),
            sender: sender.into(),
            text: text.into(),
            ..Default::default()
        };
        assert!(is_group_notice(&notice("Tôi", "Lai Van Hien đã rời khỏi nhóm"), ""));
        assert!(is_group_notice(
            &notice("Le Cuong", "Le Cuong bỏ ghim 1 tin nhắn file (cap nhat) HE_THON...."),
            "58"
        ));
        assert!(is_group_notice(&notice("Hà", "Hà đã đổi tên nhóm thành Kế toán"), "77"));
        // A person typing similar words is still a chat message.
        assert!(!is_group_notice(&notice("Hà", "mai em vào nhóm kia nhé"), "77"));
        assert!(!is_group_notice(&notice("Tôi", "anh vào nhóm chưa"), ""));
        assert!(!is_group_notice(&notice("Tôi", "dòng 1\nLan đã rời khỏi nhóm"), ""));
        let dto = message_dto(&notice("Tôi", "Thuyhoang đã rời khỏi nhóm"), "");
        assert_eq!(dto.msg_type, "chat.system");
    }

    #[test]
    fn live_reaction_push_updates_the_target_message_and_its_reactors() {
        let mut threads = vec![Thread {
            id: "g9".into(),
            is_group: true,
            messages: vec![ChatMessage {
                id: "777".into(),
                text: "thay ổ với dây điện".into(),
                is_outgoing: true,
                ..Default::default()
            }],
            ..Default::default()
        }];
        let content = json!({"rMsg":[{"gMsgID":"777","cMsgID":"1","msgType":1}],"rIcon":"/-strong","rType":3,"source":6});
        let push = json!({"data": {"reactGroups": [{
            "msgId": "900", "cliMsgId": "901", "uidFrom": "42", "idTo": "9", "ts": "1700000000000",
            "content": content
        }]}});
        assert!(apply_live_reactions(&mut threads, &push));
        let dto = message_dto(&threads[0].messages[0], "");
        assert_eq!(dto.reactions, vec!["👍".to_string()]);
        assert_eq!(dto.reaction_details[0].reactors, vec!["42".to_string()]);
        // Unrelated pushes change nothing.
        assert!(!apply_live_reactions(&mut threads, &json!({"data": {"msgs": []}})));
    }

    #[test]
    fn composite_group_avatar_keeps_only_web_member_images() {
        let (members, total) = composite_avatar(Some("multi:6;An|https://example.invalid/a.jpg;Bình|file:///etc/passwd;Chi|"));
        assert_eq!(total, Some(6));
        assert_eq!(members.len(), 3);
        assert_eq!(members[0].avatar.as_deref(), Some("https://example.invalid/a.jpg"));
        assert!(members[1].avatar.is_none() && members[2].avatar.is_none());
        assert!(composite_avatar(Some("https://example.invalid/a.jpg")).0.is_empty());
    }

    #[test]
    fn presentation_messages_exclude_raw_history_and_reject_unsafe_urls() {
        let message = ChatMessage {
            id: "message-1".into(),
            text: "hello".into(),
            link_url: Some("javascript:alert(1)".into()),
            history_source: Some(json!({"zpw_enk": "never-expose"})),
            ..Default::default()
        };
        let dto = serde_json::to_value(message_dto(&message, "")).unwrap();
        assert!(dto["link_url"].is_null());
        assert!(!dto.to_string().contains("never-expose")); // (INV-2)
    }

    #[test]
    fn captioned_file_keeps_its_attachment_kind_and_download_url() {
        let message = ChatMessage {
            id: "message-file".into(),
            text: "Tài liệu gửi bạn".into(),
            link_url: Some("https://example.invalid/manual.pdf".into()),
            link_title: Some("manual.pdf".into()),
            link_src: Some("Tập tin Zalo".into()),
            ..Default::default()
        };
        let dto = message_dto(&message, "");
        assert_eq!(dto.msg_type, "share.file");
        assert_eq!(
            dto.file_url.as_deref(),
            Some("https://example.invalid/manual.pdf")
        );
        assert_eq!(dto.file_name.as_deref(), Some("manual.pdf"));
        assert_eq!(dto.text, "Tài liệu gửi bạn");
    }

    #[tokio::test]
    async fn demo_sends_replies_and_recall_update_only_the_selected_thread() {
        let (tx, mut rx) = mpsc::channel(64);
        let mut core = Core::new(true, tx).unwrap();
        core.bootstrap().await.unwrap();
        core.load_messages("demo-group", true, 500).await.unwrap();
        let original = core.threads[1].messages.clone();
        let quote = core.threads[0].messages[0].clone();
        let result = core
            .send_text("demo-group", true, "Cảm ơn", Some(quote.clone()), &[])
            .await
            .unwrap();
        let id = result["message_id"].as_str().unwrap().to_string();
        let message = core.known_message("demo-group", true, &id).unwrap();
        assert!(message.is_outgoing);
        assert_eq!(message.reply_to_id.as_deref(), Some(quote.id.as_str()));
        core.execute(&Command::RecallMessage {
            thread_id: "demo-group".into(),
            is_group: true,
            message_id: id.clone(),
        })
        .await
        .unwrap();
        assert!(core.known_message("demo-group", true, &id).is_err());
        assert_eq!(
            serde_json::to_value(&core.threads[1].messages).unwrap(),
            serde_json::to_value(original).unwrap()
        );
        assert!(rx.try_recv().is_ok());
    }

    #[tokio::test]
    async fn logged_out_worker_rejects_send_and_retains_no_visible_threads() {
        let (tx, _rx) = mpsc::channel(32);
        let mut core = Core::new(true, tx).unwrap();
        core.bootstrap().await.unwrap();
        core.execute(&Command::Logout).await.unwrap();
        assert!(!core.logged_in());
        assert!(core.threads.is_empty());
        assert!(core
            .send_text("demo-person", false, "hello", None, &[])
            .await
            .is_err());
    }
}
