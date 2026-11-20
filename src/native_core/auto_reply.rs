//! Automatic replies (re-notes/79).
//!
//! Two kinds, kept apart because they behave differently:
//! - **Zalo's own auto-reply** (`/api/autoreply/*`, Zalo PC "Trả lời tự động"): rules stored and run by
//!   Zalo's servers, so they answer even while this Mac is off. Zalo only enables them for accounts
//!   with the Zalo Business auto-reply feature.
//! - **Keyword replies**: rules kept on this Mac and sent by Zalolite itself while it is running. Zalo
//!   PC has no such feature, so every reply is guarded: off by default, groups off by default, one
//!   reply per conversation per cooldown, only for messages that arrived in the last two minutes.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::api_mcp::{match_autoreply_rule, AutoReplyRule};
use crate::chat::{ChatMessage, Thread};
use crate::message_model::MessageKind;
use crate::session::{Session, SessionError};

/// `zpw_service_map_v3` key Zalo PC resolves with `getAutoReplyDomain()`.
pub(super) const SERVICE: &str = "auto_reply";
/// `autoReplies.max_content_len` in Zalo PC's root config.
const MAX_SERVER_CONTENT: usize = 2_000;
/// `autoReplies.max_custom_fr` in Zalo PC's root config.
const MAX_SERVER_UIDS: usize = 50;
const MAX_KEYWORD_RULES: usize = 50;
const MAX_KEYWORD_LEN: usize = 200;
/// Only messages this recent are answered, so history replayed after a reconnect never is.
const FRESH_WINDOW_MS: i64 = 120_000;
/// At most this many keyword replies per batch of incoming messages.
const MAX_REPLIES_PER_BATCH: usize = 3;
const SETTINGS_FILE: &str = "keyword_replies.json";

#[derive(Clone, Deserialize, Serialize)]
#[serde(tag = "command", rename_all = "snake_case")]
pub(super) enum AutoReplyCommand {
    ServerAutoReplies,
    SaveServerAutoReply {
        /// Absent for a new rule.
        #[serde(default)]
        rule_id: Option<Value>,
        enable: bool,
        content: String,
        start_time: i64,
        end_time: i64,
        #[serde(default)]
        recurrence: Vec<String>,
        #[serde(default)]
        scope: i64,
        #[serde(default)]
        uids: Vec<String>,
    },
    DeleteServerAutoReply {
        rule_id: Value,
    },
    KeywordReplies,
    SaveKeywordReplies {
        enabled: bool,
        #[serde(default)]
        include_groups: bool,
        cooldown_minutes: u32,
        #[serde(default)]
        rules: Vec<AutoReplyRule>,
    },
}

impl AutoReplyCommand {
    pub(super) fn name(&self) -> &'static str {
        match self {
            Self::ServerAutoReplies => "server_auto_replies",
            Self::SaveServerAutoReply { .. } => "save_server_auto_reply",
            Self::DeleteServerAutoReply { .. } => "delete_server_auto_reply",
            Self::KeywordReplies => "keyword_replies",
            Self::SaveKeywordReplies { .. } => "save_keyword_replies",
        }
    }

    pub(super) fn uses_server(&self) -> bool {
        matches!(self, Self::ServerAutoReplies | Self::SaveServerAutoReply { .. } | Self::DeleteServerAutoReply { .. })
    }
}

pub(super) fn commands() -> &'static [&'static str] {
    &["server_auto_replies", "save_server_auto_reply", "delete_server_auto_reply", "keyword_replies", "save_keyword_replies"]
}

// ---------------------------------------------------------------------------------------------
// Zalo's own auto-reply
// ---------------------------------------------------------------------------------------------

/// Body of `createAutoReply` / `updateAutoReply` (`compact-app-pc.js`): the same keys, `id` only on
/// update, `recurrence` defaulting to `DefaultRecurrence`.
#[allow(clippy::too_many_arguments)]
fn server_rule_body(id: Option<&Value>, enable: bool, content: &str, start_time: i64, end_time: i64,
    recurrence: &[String], scope: i64, uids: &[String]) -> Result<Value> {
    let content = content.trim();
    if content.is_empty() {
        bail!(super::UserError("Nội dung không được để trống."));
    }
    if content.chars().count() > MAX_SERVER_CONTENT {
        bail!(super::UserError("Nội dung trả lời tối đa 2.000 ký tự."));
    }
    if start_time <= 0 || end_time <= start_time {
        bail!(super::UserError("Khung giờ trả lời không hợp lệ."));
    }
    // ScopeType: ALL 0, STRANGERS 1, FRIENDS_INCLUDE 2, FRIENDS_EXCLUDE 3.
    if !(0..=3).contains(&scope) {
        bail!(super::UserError("Đối tượng trả lời không hợp lệ."));
    }
    let uids: Vec<&str> = uids.iter().map(|uid| uid.trim()).filter(|uid| !uid.is_empty()).collect();
    if scope >= 2 && uids.is_empty() {
        bail!(super::UserError("Hãy chọn ít nhất một người bạn."));
    }
    if uids.len() > MAX_SERVER_UIDS || uids.iter().any(|uid| !uid.chars().all(|c| c.is_ascii_digit())) {
        bail!(super::UserError("Danh sách bạn bè không hợp lệ (tối đa 50 người)."));
    }
    let uids: Vec<&str> = if scope >= 2 { uids } else { Vec::new() };
    let recurrence: Vec<String> = if recurrence.is_empty() {
        vec!["RRULE:FREQ=DAILY;".into()]
    } else {
        if recurrence.len() > 8 || recurrence.iter().any(|rule| !rule.starts_with("RRULE:") || rule.len() > 200) {
            bail!(super::UserError("Lịch lặp lại không hợp lệ."));
        }
        recurrence.to_vec()
    };
    let mut body = serde_json::Map::new();
    body.insert("cliLang".into(), json!("vi"));
    if let Some(id) = id {
        if !(id.is_i64() || id.as_str().is_some_and(|id| !id.is_empty() && id.len() < 64)) {
            bail!(super::UserError("Mã trả lời tự động không hợp lệ."));
        }
        body.insert("id".into(), id.clone());
    }
    body.insert("enable".into(), json!(enable));
    body.insert("content".into(), json!(content));
    body.insert("startTime".into(), json!(start_time));
    body.insert("endTime".into(), json!(end_time));
    body.insert("recurrence".into(), json!(recurrence));
    body.insert("scope".into(), json!(scope));
    body.insert("uids".into(), json!(uids));
    Ok(Value::Object(body))
}

/// The UI's view of one rule from `/api/autoreply/list` (`data.item[]`).
fn server_rule_dto(item: &Value) -> Option<Value> {
    let id = item.get("id").filter(|id| id.is_i64() || id.is_string())?;
    let int = |key: &str| item.get(key).and_then(Value::as_i64).unwrap_or(0);
    Some(json!({
        "id": id,
        "enable": item.get("enable").and_then(Value::as_bool).unwrap_or(false),
        "content": item.get("content").and_then(Value::as_str).unwrap_or_default(),
        "start_time": int("startTime"),
        "end_time": int("endTime"),
        "recurrence": item.get("recurrence").cloned().filter(Value::is_array).unwrap_or_else(|| json!([])),
        "scope": int("scope"),
        "uids": item.get("uids").cloned().filter(Value::is_array).unwrap_or_else(|| json!([])),
    }))
}

fn server_rules(data: &Value) -> Value {
    let items = data.get("item").and_then(Value::as_array).map(Vec::as_slice).unwrap_or_default();
    json!({"rules": items.iter().filter_map(server_rule_dto).collect::<Vec<_>>(),
           "version": data.get("version").cloned().unwrap_or(Value::Null)})
}

fn server_error(error: anyhow::Error) -> anyhow::Error {
    match error.downcast_ref::<SessionError>() {
        Some(server) if crate::session::SessionStatus::from_error(&error) != crate::session::SessionStatus::Expired => anyhow::anyhow!(super::UserError(
            if server.code == 0 { "Zalo không thực hiện được yêu cầu." } else {
                "Zalo không cho tài khoản này dùng trả lời tự động. Tính năng này cần gói Zalo Business có Trả lời tự động."
            })),
        _ => error,
    }
}

async fn server_call(session: &Session, path: &str, body: &Value, get: bool) -> Result<Value> {
    let encoded = session.encoded_params(body)?;
    let query = format!("{path}?{}&params={encoded}", session.common_params());
    // Zalo PC sends every auto-reply call with its params in the query; writes are POSTs with no body.
    let response = if get {
        session.get_endpoint(SERVICE, &query).await?
    } else {
        session.post_endpoint_form(SERVICE, &query, String::new()).await?
    };
    let response = session.maybe_decrypt(response, session.session_key_bytes()).await;
    super::check_response(&response)?;
    Ok(response.get("data").cloned().unwrap_or(Value::Null))
}

async fn list_server(session: &Session) -> Result<Value> {
    let data = server_call(session, "/api/autoreply/list", &json!({"version": 0, "cliLang": "vi"}), true).await?;
    Ok(server_rules(&data))
}

// ---------------------------------------------------------------------------------------------
// Keyword replies
// ---------------------------------------------------------------------------------------------

#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq)]
pub(super) struct KeywordReplies {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub include_groups: bool,
    #[serde(default = "default_cooldown")]
    pub cooldown_minutes: u32,
    #[serde(default)]
    pub rules: Vec<AutoReplyRule>,
    /// Thread ID → time (ms) of the last keyword reply there.
    #[serde(default)]
    pub last_sent: BTreeMap<String, i64>,
}

fn default_cooldown() -> u32 {
    180
}

impl KeywordReplies {
    fn validated(enabled: bool, include_groups: bool, cooldown_minutes: u32, rules: &[AutoReplyRule]) -> Result<Self> {
        if !(5..=1440).contains(&cooldown_minutes) {
            bail!(super::UserError("Thời gian chờ giữa hai lần trả lời phải từ 5 phút đến 24 giờ."));
        }
        if rules.len() > MAX_KEYWORD_RULES {
            bail!(super::UserError("Tối đa 50 quy tắc trả lời theo từ khóa."));
        }
        let mut clean = Vec::with_capacity(rules.len());
        for (index, rule) in rules.iter().enumerate() {
            let keyword = rule.keyword.trim();
            let reply = rule.reply_text.trim();
            if keyword.is_empty() || reply.is_empty() {
                bail!(super::UserError("Mỗi quy tắc cần có từ khóa và nội dung trả lời."));
            }
            if keyword.chars().count() > MAX_KEYWORD_LEN || reply.chars().count() > MAX_SERVER_CONTENT {
                bail!(super::UserError("Từ khóa tối đa 200 ký tự, nội dung trả lời tối đa 2.000 ký tự."));
            }
            if !matches!(rule.match_mode.as_str(), "contains" | "exact" | "prefix") || !matches!(rule.scope.as_str(), "all" | "direct" | "group") {
                bail!(super::UserError("Cách khớp hoặc phạm vi của quy tắc không hợp lệ."));
            }
            let id = if rule.id.trim().is_empty() { format!("rule-{index}") } else { rule.id.trim().chars().take(64).collect() };
            clean.push(AutoReplyRule { id, keyword: keyword.into(), reply_text: reply.into(), ..rule.clone() });
        }
        Ok(Self { enabled, include_groups, cooldown_minutes, rules: clean, last_sent: BTreeMap::new() })
    }

    fn dto(&self) -> Value {
        json!({"enabled": self.enabled, "include_groups": self.include_groups,
               "cooldown_minutes": self.cooldown_minutes, "rules": self.rules})
    }

    /// The reply for one incoming message, or `None` when a guard says no.
    fn decide(&self, thread_id: &str, is_group: bool, text: &str, now_ms: i64) -> Option<String> {
        if !self.enabled || (is_group && !self.include_groups) {
            return None;
        }
        let cooldown = i64::from(self.cooldown_minutes) * 60_000;
        if self.last_sent.get(thread_id).is_some_and(|last| now_ms - last < cooldown) {
            return None;
        }
        match_autoreply_rule(&self.rules, text, is_group).map(|rule| rule.reply_text)
    }
}

/// Keyword reply settings of the signed-in account, loaded on first use.
#[derive(Default)]
pub(super) struct KeywordState {
    path: Option<PathBuf>,
    settings: KeywordReplies,
}

impl KeywordState {
    fn path_for(db_path: &str) -> Option<PathBuf> {
        let parent = Path::new(db_path).parent()?;
        (!parent.as_os_str().is_empty()).then(|| parent.join(SETTINGS_FILE))
    }

    fn load(&mut self, db_path: &str) -> &mut KeywordReplies {
        let path = Self::path_for(db_path);
        if self.path != path {
            self.settings = path
                .as_ref()
                .and_then(|path| std::fs::read(path).ok())
                .and_then(|bytes| serde_json::from_slice(&bytes).ok())
                .unwrap_or_default();
            self.path = path;
        }
        &mut self.settings
    }

    fn save(&self) -> Result<()> {
        let path = self.path.as_ref().context(super::UserError("Chưa đăng nhập tài khoản."))?;
        let text = serde_json::to_vec_pretty(&self.settings)?;
        crate::data_dir::write_private_atomic(path, &text)
    }

    /// True when keyword replies are on for this account, so the caller takes a snapshot first.
    pub(super) fn active(&mut self, db_path: &str, demo: bool) -> bool {
        !demo && self.load(db_path).enabled && !self.settings.rules.is_empty()
    }
}

/// IDs of the newest messages per thread, taken before a live update is merged.
pub(super) fn snapshot(threads: &[Thread]) -> HashMap<String, HashSet<String>> {
    threads
        .iter()
        .map(|thread| (thread.id.clone(), thread.messages.iter().rev().take(40).map(|m| m.id.clone()).collect()))
        .collect()
}

/// Incoming text messages added by the merge and received in the last two minutes.
pub(super) fn fresh_incoming(before: &HashMap<String, HashSet<String>>, threads: &[Thread], now_ms: i64) -> Vec<(String, bool, String)> {
    let mut found = Vec::new();
    for thread in threads {
        let known = before.get(&thread.id);
        // Only the newest incoming message of a thread is answered.
        let newest = thread.messages.iter().rev().take(40).find(|message: &&ChatMessage| {
            !message.is_outgoing
                && !message.id.is_empty()
                && message.kind == MessageKind::Text
                && !message.text.trim().is_empty()
                && now_ms - message.ts <= FRESH_WINDOW_MS
                && !known.is_some_and(|ids| ids.contains(&message.id))
        });
        if let Some(message) = newest {
            found.push((thread.id.clone(), thread.is_group, message.text.clone()));
        }
    }
    found
}

/// Replies to send for `incoming`, recording each as sent so the cooldown holds even if the send
/// fails (a failed auto-reply is not retried).
pub(super) fn plan_replies(state: &mut KeywordState, db_path: &str, incoming: &[(String, bool, String)], now_ms: i64) -> Vec<(String, bool, String)> {
    let settings = state.load(db_path);
    let mut replies = Vec::new();
    for (thread_id, is_group, text) in incoming {
        if replies.len() >= MAX_REPLIES_PER_BATCH {
            break;
        }
        if let Some(reply) = settings.decide(thread_id, *is_group, text, now_ms) {
            settings.last_sent.insert(thread_id.clone(), now_ms);
            replies.push((thread_id.clone(), *is_group, reply));
        }
    }
    if !replies.is_empty() {
        // Forget conversations whose cooldown is long over so the file stays small.
        let horizon = now_ms - 2 * 24 * 60 * 60 * 1000;
        settings.last_sent.retain(|_, last| *last > horizon);
        let _ = state.save();
    }
    replies
}

// ---------------------------------------------------------------------------------------------

pub(super) async fn execute(command: &AutoReplyCommand, session: &Session, db_path: &str, demo: bool, state: &mut KeywordState) -> Result<Value> {
    if demo && command.uses_server() {
        bail!(super::UserError("Tính năng này cần kết nối tài khoản Zalo thật."));
    }
    match command {
        AutoReplyCommand::ServerAutoReplies => list_server(session).await.map_err(server_error),
        AutoReplyCommand::SaveServerAutoReply { rule_id, enable, content, start_time, end_time, recurrence, scope, uids } => {
            let body = server_rule_body(rule_id.as_ref(), *enable, content, *start_time, *end_time, recurrence, *scope, uids)?;
            let path = if rule_id.is_some() { "/api/autoreply/update" } else { "/api/autoreply/create" };
            server_call(session, path, &body, false).await.map_err(server_error)?;
            list_server(session).await.map_err(server_error)
        }
        AutoReplyCommand::DeleteServerAutoReply { rule_id } => {
            if !(rule_id.is_i64() || rule_id.is_string()) {
                bail!(super::UserError("Mã trả lời tự động không hợp lệ."));
            }
            server_call(session, "/api/autoreply/delete", &json!({"cliLang": "vi", "id": rule_id}), false).await.map_err(server_error)?;
            list_server(session).await.map_err(server_error)
        }
        AutoReplyCommand::KeywordReplies => Ok(state.load(db_path).dto()),
        AutoReplyCommand::SaveKeywordReplies { enabled, include_groups, cooldown_minutes, rules } => {
            let mut next = KeywordReplies::validated(*enabled, *include_groups, *cooldown_minutes, rules)?;
            next.last_sent = std::mem::take(&mut state.load(db_path).last_sent);
            state.settings = next;
            state.save()?;
            Ok(state.settings.dto())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rule(keyword: &str, reply: &str) -> AutoReplyRule {
        AutoReplyRule { id: String::new(), keyword: keyword.into(), match_mode: "contains".into(),
            reply_text: reply.into(), enabled: true, scope: "all".into() }
    }

    #[test]
    fn server_rule_body_matches_zalo_pc() {
        let body = server_rule_body(None, true, " Đang họp ", 1_000, 2_000, &[], 0, &["1".into()]).unwrap();
        assert_eq!(body, json!({"cliLang": "vi", "enable": true, "content": "Đang họp", "startTime": 1000,
            "endTime": 2000, "recurrence": ["RRULE:FREQ=DAILY;"], "scope": 0, "uids": []}));
        let update = server_rule_body(Some(&json!(42)), false, "x", 1, 2, &[], 3, &["123".into()]).unwrap();
        assert_eq!((update["id"].clone(), update["uids"].clone()), (json!(42), json!(["123"])));
        assert!(server_rule_body(None, true, "", 1, 2, &[], 0, &[]).is_err());
        assert!(server_rule_body(None, true, "x", 2, 1, &[], 0, &[]).is_err());
        assert!(server_rule_body(None, true, "x", 1, 2, &[], 2, &[]).is_err());
        assert!(server_rule_body(None, true, &"a".repeat(2_001), 1, 2, &[], 0, &[]).is_err());
    }

    #[test]
    fn server_list_reads_items() {
        let data = json!({"version": 7, "item": [{"id": 5, "enable": true, "content": "Bận", "startTime": 10,
            "endTime": 20, "recurrence": ["RRULE:FREQ=DAILY;"], "scope": 1}, {"content": "no id"}]});
        let rules = server_rules(&data);
        assert_eq!(rules["rules"].as_array().unwrap().len(), 1);
        assert_eq!(rules["rules"][0]["uids"], json!([]));
        assert_eq!(rules["rules"][0]["start_time"], json!(10));
    }

    #[test]
    fn keyword_replies_respect_guards() {
        let mut settings = KeywordReplies::validated(true, false, 60, &[rule("giá", "Giá ở link này ạ")]).unwrap();
        assert_eq!(settings.decide("u1", false, "Cho hỏi GIÁ bao nhiêu", 0).as_deref(), Some("Giá ở link này ạ"));
        assert_eq!(settings.decide("g1", true, "giá?", 0), None);
        settings.last_sent.insert("u1".into(), 0);
        assert_eq!(settings.decide("u1", false, "giá?", 59 * 60_000), None);
        assert!(settings.decide("u1", false, "giá?", 60 * 60_000).is_some());
        settings.enabled = false;
        assert_eq!(settings.decide("u2", false, "giá?", 0), None);
        assert!(KeywordReplies::validated(true, false, 1, &[]).is_err());
        assert!(KeywordReplies::validated(true, false, 60, &[rule("", "x")]).is_err());
    }

    #[test]
    fn only_new_recent_incoming_text_is_answered() {
        let message = |id: &str, ts: i64, outgoing: bool| ChatMessage { id: id.into(), ts, text: "giá".into(),
            is_outgoing: outgoing, kind: MessageKind::Text, ..Default::default() };
        let mut thread = Thread { id: "u1".into(), ..Default::default() };
        thread.messages = vec![message("1", 1_000_000, false)];
        let before = snapshot(std::slice::from_ref(&thread));
        thread.messages.push(message("2", 1_000_000, false));
        thread.messages.push(message("3", 1_000_000, true));
        let mut old = Thread { id: "u2".into(), ..Default::default() };
        old.messages = vec![message("9", 0, false)];
        let fresh = fresh_incoming(&before, &[thread, old], 1_060_000);
        assert_eq!(fresh, vec![("u1".to_string(), false, "giá".to_string())]);
    }

    #[test]
    fn a_batch_sends_at_most_three_and_starts_the_cooldown() {
        let dir = std::env::temp_dir().join(format!("zalolite-kw-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let db = dir.join("native_history.db").to_string_lossy().into_owned();
        let mut state = KeywordState::default();
        *state.load(&db) = KeywordReplies::validated(true, false, 60, &[rule("giá", "ok")]).unwrap();
        let incoming: Vec<_> = (0..5).map(|n| (format!("u{n}"), false, "giá".to_string())).collect();
        assert_eq!(plan_replies(&mut state, &db, &incoming, 1).len(), 3);
        assert_eq!(plan_replies(&mut state, &db, &incoming[..1], 2).len(), 0);
        let saved: KeywordReplies = serde_json::from_slice(&std::fs::read(dir.join(SETTINGS_FILE)).unwrap()).unwrap();
        assert_eq!(saved.last_sent.len(), 3);
        let _ = std::fs::remove_dir_all(dir);
    }
}
