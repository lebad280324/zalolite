//! Account-scoped workspace features and existing Zalo conversation actions.
//!
//! Local organization is explicitly marked `scope: local`; server operations
//! only update presentation after a checked acknowledgement.

use crate::{
    chat::{self, ChatMessage, Thread},
    session::Session,
    store::MessageStore,
};
use anyhow::{anyhow, bail, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeMap;

#[path = "zalo_actions.rs"]
mod zalo_actions;

#[derive(Clone, Deserialize, Serialize)]
#[serde(tag = "command", rename_all = "snake_case")]
pub(super) enum FeatureCommand {
    ListContacts {
        #[serde(default)]
        query: String,
    },
    ListGroups {
        #[serde(default)]
        query: String,
    },
    GetGroupMembers {
        thread_id: String,
    },
    OpenContact {
        user_id: String,
        #[serde(default)]
        name: String,
        #[serde(default)]
        avatar: Option<String>,
    },
    ListFriendRequests,
    ListGroupInvitations,
    JoinGroupInvitation {
        thread_id: String,
    },
    CreateGroup {
        name: String,
        member_ids: Vec<String>,
    },
    AddGroupMembers {
        thread_id: String,
        member_ids: Vec<String>,
    },
    ListBlockedContacts,
    SetContactBlocked {
        user_id: String,
        blocked: bool,
    },
    GetWorkspaceFeatures,
    SetThreadPriority {
        thread_id: String,
        priority: bool,
    },
    SetThreadCategory {
        thread_id: String,
        category: String,
    },
    UpdateAlias {
        thread_id: String,
        alias: String,
    },
    MarkThreadUnread {
        thread_id: String,
        #[serde(default)]
        is_group: bool,
        unread: bool,
    },
    HideThread {
        thread_id: String,
        #[serde(default)]
        is_group: bool,
        hide: bool,
    },
    DeleteThread {
        thread_id: String,
        #[serde(default)]
        is_group: bool,
        #[serde(default)]
        confirmed: bool,
    },
    MessageDetails {
        thread_id: String,
        message_id: String,
    },
    BookmarkMessage {
        thread_id: String,
        message_id: String,
        bookmarked: bool,
    },
    ListBookmarks,
    PinMessageLocal {
        thread_id: String,
        message_id: String,
        pinned: bool,
    },
    ListPinnedTopics {
        thread_id: String,
    },
    /// Nicknames this account set on Zalo, so the native UI shows the same single name as Zalo.
    ListAliases,
    UpsertQuickReply {
        id: String,
        shortcut: String,
        text: String,
    },
    DeleteQuickReply {
        id: String,
    },
    UpsertReminder {
        id: String,
        thread_id: String,
        title: String,
        remind_at: i64,
        #[serde(default)]
        completed: bool,
    },
    DeleteReminder {
        id: String,
    },
    SearchHistory {
        query: String,
        #[serde(default)]
        thread_id: Option<String>,
        #[serde(default)]
        files_only: bool,
    },
    SendContact { thread_id: String, contact_id: String },
}

pub(super) fn commands() -> &'static [&'static str] {
    &[
        "list_contacts",
        "list_groups",
        "get_group_members",
        "open_contact",
        "list_friend_requests",
        "list_group_invitations",
        "join_group_invitation",
        "create_group",
        "add_group_members",
        "list_blocked_contacts",
        "set_contact_blocked",
        "get_workspace_features",
        "set_thread_priority",
        "set_thread_category",
        "update_alias",
        "mark_thread_unread",
        "hide_thread",
        "delete_thread",
        "message_details",
        "bookmark_message",
        "list_bookmarks",
        "pin_message_local",
        "list_pinned_topics",
        "list_aliases",
        "upsert_quick_reply",
        "delete_quick_reply",
        "upsert_reminder",
        "delete_reminder",
        "search_history",
        "send_contact",
    ]
}

impl FeatureCommand {
    pub(super) fn affects_workspace(&self) -> bool {
        matches!(
            self,
            Self::ListContacts { .. }
                | Self::ListGroups { .. }
                | Self::OpenContact { .. }
                | Self::SetThreadPriority { .. }
                | Self::SetThreadCategory { .. }
                | Self::UpdateAlias { .. }
                | Self::MarkThreadUnread { .. }
                | Self::HideThread { .. }
                | Self::DeleteThread { .. }
                | Self::CreateGroup { .. }
                | Self::AddGroupMembers { .. }
                | Self::JoinGroupInvitation { .. }
        )
    }
    pub(super) fn invalidates_poll(&self) -> bool {
        matches!(
            self,
            Self::MarkThreadUnread { .. }
                | Self::HideThread { .. }
                | Self::DeleteThread { .. }
                | Self::CreateGroup { .. }
                | Self::AddGroupMembers { .. }
                | Self::JoinGroupInvitation { .. }
                | Self::OpenContact { .. }
                | Self::UpdateAlias { .. }
        )
    }
    pub(super) fn name(&self) -> &'static str {
        match self {
            Self::ListContacts { .. } => "list_contacts",
            Self::ListGroups { .. } => "list_groups",
            Self::GetGroupMembers { .. } => "get_group_members",
            Self::OpenContact { .. } => "open_contact",
            Self::ListFriendRequests => "list_friend_requests",
            Self::ListGroupInvitations => "list_group_invitations",
            Self::JoinGroupInvitation { .. } => "join_group_invitation",
            Self::CreateGroup { .. } => "create_group",
            Self::AddGroupMembers { .. } => "add_group_members",
            Self::ListBlockedContacts => "list_blocked_contacts",
            Self::SetContactBlocked { .. } => "set_contact_blocked",
            Self::GetWorkspaceFeatures => "get_workspace_features",
            Self::SetThreadPriority { .. } => "set_thread_priority",
            Self::SetThreadCategory { .. } => "set_thread_category",
            Self::UpdateAlias { .. } => "update_alias",
            Self::MarkThreadUnread { .. } => "mark_thread_unread",
            Self::HideThread { .. } => "hide_thread",
            Self::DeleteThread { .. } => "delete_thread",
            Self::MessageDetails { .. } => "message_details",
            Self::BookmarkMessage { .. } => "bookmark_message",
            Self::ListBookmarks => "list_bookmarks",
            Self::PinMessageLocal { .. } => "pin_message_local",
            Self::ListPinnedTopics { .. } => "list_pinned_topics",
            Self::ListAliases => "list_aliases",
            Self::UpsertQuickReply { .. } => "upsert_quick_reply",
            Self::DeleteQuickReply { .. } => "delete_quick_reply",
            Self::UpsertReminder { .. } => "upsert_reminder",
            Self::DeleteReminder { .. } => "delete_reminder",
            Self::SearchHistory { .. } => "search_history",
            Self::SendContact { .. } => "send_contact",
        }
    }
}

#[derive(Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub(super) struct FeatureState {
    thread_features: BTreeMap<String, ThreadFeature>,
    /// Zalo's "Khác" list (`/api/archivedchat/list`), shared with the phone and Zalo PC.
    archived: ArchivedChats,
    bookmarks: BTreeMap<String, BTreeMap<String, SavedMessage>>,
    pinned_messages: BTreeMap<String, BTreeMap<String, SavedMessage>>,
    quick_replies: BTreeMap<String, QuickReply>,
    reminders: BTreeMap<String, Reminder>,
    #[serde(skip)]
    loaded_for: String,
}
/// Conversations Zalo files under "Khác"; everything else is "Ưu tiên".
#[derive(Clone, Default, Deserialize, Serialize)]
#[serde(default)]
struct ArchivedChats {
    /// True once the list has been read from the server at least once.
    synced: bool,
    version: i64,
    /// `(id, is_group)` exactly as the server lists them.
    items: Vec<(String, bool)>,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(default)]
struct ThreadFeature {
    priority: bool,
    category: String,
    alias: String,
}
impl Default for ThreadFeature {
    fn default() -> Self {
        Self {
            priority: true,
            category: String::new(),
            alias: String::new(),
        }
    }
}
#[derive(Clone, Deserialize, Serialize)]
struct SavedMessage {
    thread_id: String,
    message_id: String,
    text: String,
    sender: String,
    timestamp: i64,
}
#[derive(Clone, Deserialize, Serialize)]
struct QuickReply {
    id: String,
    shortcut: String,
    text: String,
}
#[derive(Clone, Deserialize, Serialize)]
struct Reminder {
    id: String,
    thread_id: String,
    title: String,
    remind_at: i64,
    completed: bool,
}

impl FeatureState {
    pub(super) fn snapshot(&self) -> Value {
        json!({"scope":"local",
          "thread_features":self.thread_features.iter().map(|(id,item)|json!({"thread_id":id,"priority":item.priority,"category":item.category,"alias":item.alias})).collect::<Vec<_>>(),
          "archived_chats":{"synced":self.archived.synced,"items":self.archived.items.iter().map(|(id,group)|json!({"id":id,"is_group":group})).collect::<Vec<_>>()},
          "bookmarks":self.bookmarks.values().flat_map(|items|items.values()).collect::<Vec<_>>(),
          "pinned_messages":self.pinned_messages.values().flat_map(|items|items.values()).collect::<Vec<_>>(),
          "quick_replies":self.quick_replies.values().collect::<Vec<_>>(),
          "reminders":self.reminders.values().collect::<Vec<_>>()})
    }
}

fn text(value: &str, max: usize, allow_empty: bool) -> Result<()> {
    if value.len() > max || (!allow_empty && value.trim().is_empty()) || value.contains('\0') {
        bail!(super::UserError("Nội dung trống hoặc vượt quá giới hạn."));
    }
    Ok(())
}
fn identifier(value: &str) -> Result<()> {
    super::require_identifier(value)
}
/// `(version, [(id, is_group)])` from an `archivedchat/list` reply; `type 1` is a group.
fn archived_items(data: &Value) -> Option<(i64, Vec<(String, bool)>)> {
    let data = match data {
        Value::String(text) => serde_json::from_str::<Value>(text).ok()?,
        other => other.clone(),
    };
    let version = data.get("version").and_then(|v| v.as_i64().or_else(|| v.as_str()?.parse().ok())).unwrap_or(0);
    let items = data.get("items")?.as_array()?;
    Some((
        version,
        items
            .iter()
            .filter_map(|item| {
                let id = match item.get("id")? {
                    Value::String(id) if !id.is_empty() => id.clone(),
                    Value::Number(n) => n.to_string(),
                    _ => return None,
                };
                let group = item.get("type").and_then(Value::as_i64) == Some(1);
                Some((id, group))
            })
            .collect(),
    ))
}

fn thread_index(threads: &[Thread], id: &str, group: Option<bool>) -> Result<usize> {
    identifier(id)?;
    threads
        .iter()
        .position(|thread| thread.id == id && (group.is_none() || group == Some(thread.is_group)))
        .ok_or_else(|| {
            anyhow!(super::UserError(
                "Hội thoại không còn trong danh sách. Hãy làm mới."
            ))
        })
}
fn clean_group_id(id: &str) -> &str {
    id.strip_prefix("group_")
        .or_else(|| id.strip_prefix('g'))
        .unwrap_or(id)
}

/// Mirrors PC forwardContactOA (11774/11827); see re-notes/52_native_contact_send.md.
fn contact_request(thread: &str, contact: &str, group: bool, client: u64) -> (&'static str, &'static str, Value) {
    if group {
        ("group","/api/group/contact",json!({"grid":clean_group_id(thread),"visibility":0,"clientId":client,"contactId":contact}))
    } else {
        ("chat","/api/message/contact",json!({"toId":thread,"clientId":client,"contactId":contact}))
    }
}
fn validate_members(ids: &[String]) -> Result<()> {
    if ids.is_empty() || ids.len() > 100 {
        bail!(super::UserError("Chọn từ 1 đến 100 thành viên."));
    }
    let mut unique = std::collections::HashSet::new();
    for id in ids {
        identifier(id)?;
        if !unique.insert(id) {
            bail!(super::UserError("Danh sách thành viên bị trùng."));
        }
    }
    Ok(())
}
fn message(threads: &[Thread], thread_id: &str, message_id: &str) -> Result<ChatMessage> {
    identifier(message_id)?;
    let index = thread_index(threads, thread_id, None)?;
    threads[index]
        .messages
        .iter()
        .find(|message| message.id == message_id)
        .cloned()
        .ok_or_else(|| {
            anyhow!(super::UserError(
                "Tin nhắn chưa được tải. Hãy mở đúng vị trí trong cuộc trò chuyện."
            ))
        })
}
fn saved(thread_id: &str, message: &ChatMessage) -> SavedMessage {
    SavedMessage {
        thread_id: thread_id.into(),
        message_id: message.id.clone(),
        text: message.text.clone(),
        sender: message.sender.clone(),
        timestamp: message.ts,
    }
}
fn row(thread: &Thread) -> Value {
    json!({"id":thread.id,"name":thread.name,"avatar":zalo_actions::safe_url(thread.avatar.as_deref()),
      "is_group":thread.is_group,"member_count":thread.presentation.member_count})
}
fn merge_rows(threads: &mut Vec<Thread>, incoming: Vec<Thread>) {
    for thread in incoming.into_iter().take(10_000) {
        if let Some(existing) = threads.iter_mut().find(|item| item.id == thread.id) {
            chat::merge_thread_into(existing, thread, false);
        } else if threads.len() < 10_000 {
            threads.push(thread);
        }
    }
}
async fn ensure_loaded(state: &mut FeatureState, db_path: &str, demo: bool) -> Result<()> {
    if demo || state.loaded_for == db_path {
        return Ok(());
    }
    if db_path.is_empty() {
        bail!(super::UserError("Bạn cần đăng nhập trước."));
    }
    let path = db_path.to_owned();
    let mut loaded = tokio::task::spawn_blocking(move || -> Result<FeatureState> {
        let store = MessageStore::open(&path)?;
        match store.native_preference("workspace")? {
            Some(text) => Ok(serde_json::from_str(&text)?),
            None => Ok(FeatureState::default()),
        }
    })
    .await??;
    loaded.loaded_for = db_path.into();
    *state = loaded;
    Ok(())
}
async fn save(state: &FeatureState, db_path: &str, demo: bool) -> Result<()> {
    if demo {
        return Ok(());
    }
    let serialized = serde_json::to_string(state)?;
    let path = db_path.to_owned();
    tokio::task::spawn_blocking(move || {
        MessageStore::open(&path)?.set_native_preference("workspace", &serialized)
    })
    .await??;
    Ok(())
}

/// Execute typed intents with exact thread identity and explicit local/server scope.
///
/// # Errors
/// Returns validation, database or authenticated protocol errors. The owning bridge
/// sanitizes upstream errors before exposing them to the frontend.
pub(super) async fn execute(
    command: &FeatureCommand,
    session: &Session,
    threads: &mut Vec<Thread>,
    db_path: &str,
    demo: bool,
    state: &mut FeatureState,
) -> Result<Value> {
    if !demo && session.login.is_none() {
        bail!(super::UserError("Bạn cần đăng nhập trước."));
    }
    ensure_loaded(state, db_path, demo).await?;
    let mut next = state.clone();
    let mut changed = false;
    let mut scope = "local";
    let result = match command {
        FeatureCommand::ListFriendRequests
        | FeatureCommand::ListGroupInvitations
        | FeatureCommand::ListBlockedContacts => {
            scope = "server";
            if demo {
                json!({"items":[],"partial":false})
            } else {
                let groups = matches!(command, FeatureCommand::ListGroupInvitations);
                let (service, path, params) = match command {
                    FeatureCommand::ListFriendRequests => (
                        "friend",
                        "/api/friend/requested/list",
                        json!({"imei":session.imei}),
                    ),
                    FeatureCommand::ListBlockedContacts => (
                        "friend",
                        "/api/friend/blocklistv2",
                        json!({"page":1,"count":50,"avatar":75}),
                    ),
                    _ => (
                        "group",
                        "/api/group/inv-box/list",
                        json!({"mpage":1,"page":0,"invPerPage":10,"mcount":10,"lastGroupId":null,"avatar_size":160,"member_avatar_size":160}),
                    ),
                };
                let data = zalo_actions::get_json(session, service, path, &params).await?;
                let items = if matches!(command, FeatureCommand::ListBlockedContacts) {
                    zalo_actions::blocked_rows(&data)
                } else {
                    zalo_actions::profile_rows(&data, groups)
                };
                let empty = data.is_null()
                    || data.as_object().is_some_and(|items| items.is_empty())
                    || data.as_array().is_some_and(|items| items.is_empty());
                // A block list with only counters (`{"total":0}`) is an empty list.
                let counters_only = data.as_object().is_some_and(|object| {
                    object.values().all(|value| !value.is_object() && !value.is_array() || value.as_array().is_some_and(|a| a.is_empty()))
                });
                if items.is_empty() && !empty && !(matches!(command, FeatureCommand::ListBlockedContacts) && counters_only) {
                    bail!(super::UserError("Zalo trả về danh sách chưa được hỗ trợ. Hãy thử lại sau khi cập nhật ứng dụng."));
                }
                // These observed APIs return pages; never imply that the first page is exhaustive.
                json!({"items":items,"partial":true,"page":if groups {0}else{1}})
            }
        }
        FeatureCommand::SetContactBlocked { user_id, blocked } => {
            identifier(user_id)?;
            scope = "server";
            if !demo {
                zalo_actions::post_json(
                    session,
                    "friend",
                    if *blocked {
                        "/api/friend/block"
                    } else {
                        "/api/friend/unblock"
                    },
                    &json!({"fid":user_id,"imei":session.imei}),
                )
                .await?;
            }
            json!({"user_id":user_id,"blocked":blocked})
        }
        FeatureCommand::JoinGroupInvitation { thread_id } => {
            identifier(thread_id)?;
            scope = "server";
            if !demo {
                zalo_actions::get_json(
                    session,
                    "group",
                    "/api/group/inv-box/join",
                    &json!({"grid":clean_group_id(thread_id),"lang":"vi"}),
                )
                .await?;
            }
            json!({"thread_id":thread_id,"joined":true})
        }
        FeatureCommand::CreateGroup { name, member_ids } => {
            text(name, 256, false)?;
            validate_members(member_ids)?;
            scope = "server";
            let group_id = if demo {
                format!("demo-group-{}", chat::next_client_message_id())
            } else {
                let data = zalo_actions::get_json(
                    session,
                    "group",
                    "/api/group/create/v2",
                    &zalo_actions::create_group_params(
                        session,
                        name,
                        member_ids,
                        chat::next_client_message_id(),
                    ),
                )
                .await?;
                let id = zalo_actions::pick(&data, &["groupId", "grid", "group_id"]);
                if id.is_empty() {
                    bail!(super::UserError(
                        "Zalo chưa trả về mã nhóm. Hãy làm mới danh sách trước khi tạo lại."
                    ));
                }
                id
            };
            if !threads.iter().any(|thread| thread.id == group_id) {
                threads.push(Thread {
                    id: group_id.clone(),
                    name: name.trim().into(),
                    avatar: None,
                    is_group: true,
                    preview: String::new(),
                    time: String::new(),
                    messages: Vec::new(),
                    presentation: Default::default(),
                    unread: Default::default(),
                });
            }
            json!({"thread_id":group_id,"created":true})
        }
        FeatureCommand::AddGroupMembers {
            thread_id,
            member_ids,
        } => {
            thread_index(threads, thread_id, Some(true))?;
            validate_members(member_ids)?;
            scope = "server";
            if !demo {
                zalo_actions::post_json(session,"group","/api/group/invite/v2",&json!({"grid":clean_group_id(thread_id),"members":member_ids,"imei":session.imei,"clientLang":"vi"})).await?;
            }
            json!({"thread_id":thread_id,"invited_count":member_ids.len()})
        }
        FeatureCommand::GetWorkspaceFeatures => {
            if !demo {
                // Offline or refused: keep the last list the server gave.
                if let Ok(data) = zalo_actions::get_json(session, "label", "/api/archivedchat/list", &json!({"version":0,"imei":session.imei})).await {
                    if let Some((version, items)) = archived_items(&data) {
                        next.archived = ArchivedChats { synced: true, version, items };
                        changed = true;
                    }
                }
            }
            next.snapshot()
        }
        FeatureCommand::ListContacts { query } | FeatureCommand::ListGroups { query } => {
            text(query, 512, true)?;
            let groups = matches!(command, FeatureCommand::ListGroups { .. });
            if !demo {
                let incoming = if groups {
                    chat::get_groups(session).await?
                } else {
                    chat::get_friends(session).await?
                };
                merge_rows(threads, incoming);
            }
            scope = "server";
            let query = query.trim().to_lowercase();
            json!({"items":threads.iter().filter(|thread|thread.is_group==groups&&(query.is_empty()||thread.name.to_lowercase().contains(&query))).take(10_000).map(row).collect::<Vec<_>>()})
        }
        FeatureCommand::GetGroupMembers { thread_id } => {
            let index = thread_index(threads, thread_id, Some(true))?;
            scope = "server";
            let items = if demo {
                threads[index]
                    .presentation
                    .members
                    .iter()
                    .map(
                        |item| json!({"id":item.id,"name":item.name,"avatar":item.avatar,"role":0}),
                    )
                    .collect()
            } else {
                zalo_actions::members(session, thread_id).await?
            };
            json!({"items":items})
        }
        FeatureCommand::OpenContact {
            user_id,
            name: _,
            avatar: _,
        } => {
            identifier(user_id)?;
            if let Some(thread) = threads
                .iter()
                .find(|thread| thread.id == *user_id && !thread.is_group)
            {
                json!({"thread_id":thread.id})
            } else {
                let (name, avatar) = if demo {
                    ("Người dùng minh họa".to_owned(), None)
                } else {
                    let profiles = chat::get_mini_profiles(session, &[user_id.clone()]).await?;
                    let profile = profiles.get(user_id).ok_or_else(|| {
                        anyhow!(super::UserError(
                            "Không lấy được thông tin người dùng từ Zalo."
                        ))
                    })?;
                    let name = zalo_actions::pick(profile, &["displayName", "zaloName", "name"]);
                    if name.is_empty() {
                        bail!(super::UserError("Hồ sơ người dùng không hợp lệ."));
                    }
                    (
                        name,
                        zalo_actions::safe_url(Some(&zalo_actions::pick(
                            profile,
                            &["avatar", "avt"],
                        ))),
                    )
                };
                threads.push(Thread {
                    id: user_id.clone(),
                    name,
                    avatar,
                    is_group: false,
                    preview: String::new(),
                    time: String::new(),
                    messages: Vec::new(),
                    presentation: Default::default(),
                    unread: Default::default(),
                });
                json!({"thread_id":user_id})
            }
        }
        FeatureCommand::SetThreadPriority {
            thread_id,
            priority,
        } => {
            let index = thread_index(threads, thread_id, None)?;
            if !demo {
                // Same list Zalo PC and the phone use: actionType 0 files the conversation under
                // "Khác", 1 brings it back to "Ưu tiên" (re-notes/72).
                let is_group = threads[index].is_group;
                let id = clean_group_id(thread_id).to_owned();
                let item = json!({"id": id, "type": if is_group { 1 } else { 0 }});
                let action = if *priority { 1 } else { 0 };
                zalo_actions::post_json(session, "label", "/api/archivedchat/update",
                    &json!({"ids":[item],"version":state.archived.version,"actionType":action,"imei":session.imei})).await?;
                next.archived.items.retain(|(existing, group)| !(existing == &id && *group == is_group));
                if !*priority {
                    next.archived.items.push((id, is_group));
                }
                if let Ok(data) = zalo_actions::get_json(session, "label", "/api/archivedchat/list", &json!({"version":0,"imei":session.imei})).await {
                    if let Some((version, items)) = archived_items(&data) {
                        next.archived = ArchivedChats { synced: true, version, items };
                    }
                }
                scope = "server";
            }
            next.thread_features
                .entry(thread_id.clone())
                .or_default()
                .priority = *priority;
            changed = true;
            next.snapshot()
        }
        FeatureCommand::SetThreadCategory {
            thread_id,
            category,
        } => {
            thread_index(threads, thread_id, None)?;
            text(category, 100, true)?;
            next.thread_features
                .entry(thread_id.clone())
                .or_default()
                .category = category.trim().into();
            changed = true;
            next.snapshot()
        }
        FeatureCommand::UpdateAlias { thread_id, alias } => {
            thread_index(threads, thread_id, Some(false))?;
            text(alias, 256, true)?;
            if !demo {
                zalo_actions::update_alias(session, thread_id, alias).await?;
            }
            next.thread_features
                .entry(thread_id.clone())
                .or_default()
                .alias = alias.trim().into();
            changed = true;
            scope = "server";
            json!({"thread_id":thread_id,"alias":alias.trim()})
        }
        FeatureCommand::MarkThreadUnread {
            thread_id,
            is_group,
            unread,
        } => {
            let index = thread_index(threads, thread_id, Some(*is_group))?;
            if !demo {
                super::check_response(
                    &chat::set_unread_mark(session, thread_id, *is_group, *unread).await?,
                )?;
            }
            // The explicit marker is independent of the count of unread server messages.
            threads[index].unread.marked_unread = *unread;
            scope = "server";
            json!({"thread_id":thread_id,"unread":unread})
        }
        FeatureCommand::HideThread {
            thread_id,
            is_group,
            hide,
        } => {
            let index = thread_index(threads, thread_id, Some(*is_group))?;
            if !demo {
                super::check_response(
                    &chat::set_hidden_conversation(session, thread_id, *is_group, *hide).await?,
                )?;
            }
            threads[index].presentation.hidden = *hide;
            scope = "server";
            json!({"thread_id":thread_id,"hidden":hide})
        }
        FeatureCommand::DeleteThread {
            thread_id,
            is_group,
            confirmed,
        } => {
            if !confirmed {
                bail!(super::UserError(
                    "Cần xác nhận trước khi xóa lịch sử hội thoại."
                ));
            }
            let index = thread_index(threads, thread_id, Some(*is_group))?;
            if !demo {
                // Zalo PC names the newest server message and syncs only when it has one;
                // otherwise the history is cleared on this Mac alone (re-notes/78).
                let own_uid = session.login.as_ref().map(|login| login.uin.as_str()).unwrap_or_default();
                if let Some(conver) = chat::delete_conversation_anchor(&threads[index].messages, thread_id, *is_group, own_uid) {
                    super::check_response(
                        &chat::delete_conversation(session, thread_id, *is_group, &conver).await?,
                    )?;
                }
                let path = db_path.to_owned();
                let id = thread_id.clone();
                tokio::task::spawn_blocking(move || MessageStore::open(&path)?.delete_thread(&id))
                    .await??;
            }
            threads[index].messages.clear();
            threads[index].preview.clear();
            threads[index].time.clear();
            threads[index].presentation.last_message_ts = 0;
            threads[index].presentation.last_message_id.clear();
            next.bookmarks.remove(thread_id);
            next.pinned_messages.remove(thread_id);
            next.reminders
                .retain(|_, item| item.thread_id != *thread_id);
            changed = true;
            scope = "server";
            json!({"thread_id":thread_id,"history_deleted":true})
        }
        FeatureCommand::MessageDetails {
            thread_id,
            message_id,
        } => {
            let message = message(threads, thread_id, message_id)?;
            json!({"message":super::message_dto(&message,&session.login.as_ref().map(|l|l.uin.clone()).unwrap_or_default()),"client_message_id":message.client_message_id,"scope":"local"})
        }
        FeatureCommand::BookmarkMessage {
            thread_id,
            message_id,
            bookmarked,
        } => {
            identifier(thread_id)?;
            identifier(message_id)?;
            let to_save = if *bookmarked {
                Some(saved(thread_id, &message(threads, thread_id, message_id)?))
            } else {
                None
            };
            let items = next.bookmarks.entry(thread_id.clone()).or_default();
            if let Some(message) = to_save {
                items.insert(message_id.clone(), message);
            } else {
                items.remove(message_id);
            }
            changed = true;
            next.snapshot()
        }
        FeatureCommand::ListBookmarks => {
            json!({"items":state.bookmarks.values().flat_map(|items|items.values()).collect::<Vec<_>>()})
        }
        FeatureCommand::PinMessageLocal {
            thread_id,
            message_id,
            pinned,
        } => {
            identifier(thread_id)?;
            identifier(message_id)?;
            let to_save = if *pinned {
                Some(saved(thread_id, &message(threads, thread_id, message_id)?))
            } else {
                None
            };
            let items = next.pinned_messages.entry(thread_id.clone()).or_default();
            if let Some(message) = to_save {
                items.insert(message_id.clone(), message);
            } else {
                items.remove(message_id);
            }
            changed = true;
            next.snapshot()
        }
        FeatureCommand::ListAliases => {
            scope = "server";
            let items = if demo {
                Vec::new()
            } else {
                zalo_actions::alias_list(session).await?
            };
            json!({"items": items})
        }
        FeatureCommand::ListPinnedTopics { thread_id } => {
            thread_index(threads, thread_id, None)?;
            scope = "server";
            let items = if demo {
                Vec::new()
            } else {
                zalo_actions::pinned_topics(session, thread_id).await?
            };
            json!({"items":items})
        }
        FeatureCommand::UpsertQuickReply {
            id,
            shortcut,
            text: body,
        } => {
            identifier(id)?;
            text(shortcut, 64, false)?;
            text(body, 20_000, false)?;
            if next.quick_replies.len() >= 500 && !next.quick_replies.contains_key(id) {
                bail!(super::UserError("Đã đạt giới hạn 500 tin nhắn nhanh."));
            }
            if next
                .quick_replies
                .values()
                .any(|item| item.id != *id && item.shortcut == *shortcut)
            {
                bail!(super::UserError("Phím tắt này đã được sử dụng."));
            }
            next.quick_replies.insert(
                id.clone(),
                QuickReply {
                    id: id.clone(),
                    shortcut: shortcut.clone(),
                    text: body.clone(),
                },
            );
            changed = true;
            next.snapshot()
        }
        FeatureCommand::DeleteQuickReply { id } => {
            identifier(id)?;
            next.quick_replies.remove(id);
            changed = true;
            next.snapshot()
        }
        FeatureCommand::UpsertReminder {
            id,
            thread_id,
            title,
            remind_at,
            completed,
        } => {
            identifier(id)?;
            thread_index(threads, thread_id, None)?;
            text(title, 2000, false)?;
            if *remind_at <= 0
                || (*remind_at < crate::login::unix_now()
                    && !*completed
                    && !next.reminders.contains_key(id))
            {
                bail!(super::UserError("Thời gian nhắc hẹn phải ở tương lai."));
            }
            if next.reminders.len() >= 1000 && !next.reminders.contains_key(id) {
                bail!(super::UserError("Đã đạt giới hạn 1000 nhắc hẹn."));
            }
            next.reminders.insert(
                id.clone(),
                Reminder {
                    id: id.clone(),
                    thread_id: thread_id.clone(),
                    title: title.clone(),
                    remind_at: *remind_at,
                    completed: *completed,
                },
            );
            changed = true;
            next.snapshot()
        }
        FeatureCommand::DeleteReminder { id } => {
            identifier(id)?;
            next.reminders.remove(id);
            changed = true;
            next.snapshot()
        }
        FeatureCommand::SendContact { thread_id, contact_id } => {
            let index=thread_index(threads,thread_id,None)?;
            identifier(contact_id)?;
            let client_id=chat::next_client_message_id();
            let (service,path,params)=contact_request(thread_id,contact_id,threads[index].is_group,client_id);
            scope="server";
            if !demo { zalo_actions::post_json(session,service,path,&params).await?; }
            json!({"thread_id":thread_id,"contact_id":contact_id,"client_message_id":client_id.to_string()})
        }
        FeatureCommand::SearchHistory { query, thread_id, files_only } => {
            text(query, 512, false)?;
            if let Some(id) = thread_id {
                identifier(id)?;
            }
            if demo {
                let query = query.to_lowercase();
                let items=threads.iter().filter(|thread|thread_id.as_ref().is_none_or(|id|id==&thread.id)).flat_map(|thread|thread.messages.iter().filter(|message|(!files_only || message.kind==crate::message_model::MessageKind::File) && message.text.to_lowercase().contains(&query)).map(|message|json!({"thread_id":thread.id,"message":super::message_dto(message,"")}))).take(300).collect::<Vec<_>>();
                json!({"items":items})
            } else {
                let path = db_path.to_owned();
                let query = query.clone();
                let filter = thread_id.clone();
                let files_only=*files_only;
                let items=tokio::task::spawn_blocking(move||->Result<Vec<Value>> {
                    let rows=MessageStore::open(&path)?.search_messages_scoped(&query,300,filter.as_deref(),files_only)?;
                    Ok(rows.into_iter().map(|row|{
                        let raw=serde_json::from_str::<Value>(&row.raw_json).unwrap_or(Value::Null);
                        let name=raw.get("fileName").or_else(||raw.get("file_name")).or_else(||raw.get("link_title")).or_else(||raw.get("title")).and_then(Value::as_str);
                        json!({"thread_id":row.thread_id,"message":{"id":row.msg_id,"text":row.text,"sender_id":row.sender_id,"sender_name":row.sender_name,"timestamp":row.ts,"is_outgoing":row.is_outgoing,"msg_type":row.msg_type,"file_name":name}})
                    }).collect())
                }).await??;
                json!({"items":items})
            }
        }
    };
    if changed {
        save(&next, db_path, demo).await?;
        *state = next;
    }
    let mut result = result;
    if let Some(object) = result.as_object_mut() {
        object.entry("scope").or_insert_with(|| json!(scope));
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    #[test]
    fn archived_list_reads_users_and_groups() {
        let data = serde_json::json!({"version": 7, "items": [{"id": "111", "type": 0}, {"id": 222, "type": 1}, {"id": ""}]});
        let (version, items) = super::archived_items(&data).unwrap();
        assert_eq!(version, 7);
        assert_eq!(items, vec![("111".to_string(), false), ("222".to_string(), true)]);
        let text = serde_json::json!("{\"version\":\"3\",\"items\":[]}");
        assert_eq!(super::archived_items(&text), Some((3, vec![])));
        assert!(super::archived_items(&serde_json::json!({"version": 1})).is_none());
    }

    use super::*;
    #[test]
    fn contact_request_uses_pc_recipient_keys_and_stable_client_id() {
        let (service,path,params)=contact_request("user-1","contact-1",false,123);
        assert_eq!((service,path),("chat","/api/message/contact"));
        assert_eq!(params,json!({"toId":"user-1","contactId":"contact-1","clientId":123}));
        let (service,path,params)=contact_request("group_42","contact-1",true,123);
        assert_eq!((service,path),("group","/api/group/contact"));
        assert_eq!(params,json!({"grid":"42","contactId":"contact-1","clientId":123,"visibility":0}));
    }
    fn thread() -> Thread {
        Thread {
            id: "thread-1".into(),
            name: "Example".into(),
            preview: String::new(),
            time: String::new(),
            avatar: None,
            is_group: false,
            messages: vec![ChatMessage {
                id: "msg-1".into(),
                text: "Hello".into(),
                ..Default::default()
            }],
            presentation: Default::default(),
            unread: Default::default(),
        }
    }
    #[tokio::test]
    async fn bookmarks_and_local_pins_are_distinct_and_idempotent() {
        let session = Session::new(false, false, false).unwrap();
        let mut rows = vec![thread()];
        let mut state = FeatureState::default();
        let bookmark = FeatureCommand::BookmarkMessage {
            thread_id: "thread-1".into(),
            message_id: "msg-1".into(),
            bookmarked: true,
        };
        execute(&bookmark, &session, &mut rows, "", true, &mut state)
            .await
            .unwrap();
        execute(&bookmark, &session, &mut rows, "", true, &mut state)
            .await
            .unwrap();
        assert_eq!(state.bookmarks["thread-1"].len(), 1);
        assert!(state.pinned_messages.is_empty());
        execute(
            &FeatureCommand::PinMessageLocal {
                thread_id: "thread-1".into(),
                message_id: "msg-1".into(),
                pinned: true,
            },
            &session,
            &mut rows,
            "",
            true,
            &mut state,
        )
        .await
        .unwrap();
        assert_eq!(state.pinned_messages["thread-1"].len(), 1);
    }
    #[tokio::test]
    async fn unconfirmed_delete_and_group_mismatch_preserve_history() {
        let session = Session::new(false, false, false).unwrap();
        let mut rows = vec![thread()];
        let mut state = FeatureState::default();
        assert!(execute(
            &FeatureCommand::DeleteThread {
                thread_id: "thread-1".into(),
                is_group: false,
                confirmed: false
            },
            &session,
            &mut rows,
            "",
            true,
            &mut state
        )
        .await
        .is_err());
        assert!(execute(
            &FeatureCommand::HideThread {
                thread_id: "thread-1".into(),
                is_group: true,
                hide: true
            },
            &session,
            &mut rows,
            "",
            true,
            &mut state
        )
        .await
        .is_err());
        assert_eq!(rows[0].messages.len(), 1);
    }
    #[test]
    fn preferences_migrate_idempotently_and_keep_account_stores_independent() {
        let first = MessageStore::open(":memory:").unwrap();
        let second = MessageStore::open(":memory:").unwrap();
        first
            .set_native_preference("workspace", "{\"bookmarks\":{}}")
            .unwrap();
        assert!(second.native_preference("workspace").unwrap().is_none());
        assert_eq!(
            first
                .conn
                .query_row("PRAGMA user_version", [], |row| row.get::<_, i64>(0))
                .unwrap(),
            2
        );
        assert!(first
            .set_native_preference("workspace", &"x".repeat(2 * 1024 * 1024 + 1))
            .is_err());
    }
    #[tokio::test]
    async fn duplicate_quick_reply_shortcuts_are_rejected() {
        let session = Session::new(false, false, false).unwrap();
        let mut rows = vec![thread()];
        let mut state = FeatureState::default();
        execute(
            &FeatureCommand::UpsertQuickReply {
                id: "reply-1".into(),
                shortcut: "hello".into(),
                text: "Hello".into(),
            },
            &session,
            &mut rows,
            "",
            true,
            &mut state,
        )
        .await
        .unwrap();
        assert!(execute(
            &FeatureCommand::UpsertQuickReply {
                id: "reply-2".into(),
                shortcut: "hello".into(),
                text: "Changed".into()
            },
            &session,
            &mut rows,
            "",
            true,
            &mut state
        )
        .await
        .is_err());
        assert_eq!(state.quick_replies.len(), 1);
    }
}
