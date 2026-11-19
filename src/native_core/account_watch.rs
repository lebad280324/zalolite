//! Unread counts of the other accounts on this Mac while one account is active (re-notes/77).
//!
//! Only the active account keeps a socket. Every few minutes each other saved account sends one
//! read-only `get-last-msgs` preview request with its own saved session, the request Zalo PC makes
//! at startup. The reply is applied to an in-memory copy of that account's saved conversation list
//! with the same live merge the core uses, and the unread total is reported to the UI. Nothing of
//! the other account is written: no session refresh, no message store, no thread cache.

use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};
use serde_json::{json, Value};

use crate::chat::{self, Thread};
use crate::session::{Session, SessionStatus};

/// Seconds between two checks of the same account.
pub(super) const INTERVAL_SECS: u64 = 180;

/// Saved accounts other than `active`, as listed by their `accounts/<uin>.json` session files.
pub(super) fn other_accounts(base: &Path, active: &str) -> Vec<String> {
    let Ok(entries) = std::fs::read_dir(base.join("accounts")) else { return Vec::new() };
    let mut accounts: Vec<String> = entries
        .flatten()
        .filter_map(|entry| {
            let path = entry.path();
            (path.extension().and_then(|e| e.to_str()) == Some("json")).then_some(())?;
            let uin = path.file_stem()?.to_str()?.to_owned();
            (!uin.is_empty() && uin.len() <= 32 && uin.bytes().all(|b| b.is_ascii_digit()) && uin != active).then_some(uin)
        })
        .collect();
    accounts.sort();
    accounts
}

fn account_dir(uin: &str) -> PathBuf {
    Path::new("accounts").join(uin)
}

/// Unread total the way the native UI badges it: unread messages in conversations that are neither
/// muted nor hidden, one for a conversation only marked unread.
pub(super) fn unread_total(threads: &[Thread]) -> (usize, usize) {
    let mut messages = 0;
    let mut conversations = 0;
    for thread in threads.iter().filter(|t| !t.presentation.hidden && !t.unread.is_muted()) {
        let count = thread.unread.count().max(usize::from(thread.unread.marked_unread));
        if count > 0 {
            messages += count;
            conversations += 1;
        }
    }
    (messages, conversations)
}

/// Applies a `get-last-msgs` reply to a copy of the saved conversations and counts what is unread.
///
/// The saved list carries read points but no messages, so a message read on the phone after this
/// account was last open here would look unread again. Only messages sent after `since_ms` (when
/// the list was saved) are added to the unread messages the list already had.
pub(super) fn count_with_previews(saved: &[Thread], reply: &Value, since_ms: i64) -> (usize, usize) {
    let mut threads = saved.to_vec();
    chat::merge_live_previews(&mut threads, reply);
    for thread in &mut threads {
        let before = saved.iter().find(|t| t.id == thread.id).map(|t| t.unread.unread_ids.clone()).unwrap_or_default();
        let recent: std::collections::HashSet<String> = thread
            .messages
            .iter()
            .filter(|m| crate::clock::normalize_ts_ms(m.ts) > since_ms)
            .map(|m| m.id.clone())
            .collect();
        thread.unread.unread_ids.retain(|id| before.contains(id) || recent.contains(id));
    }
    unread_total(&threads)
}

/// One check of one account. The result is an event payload for the UI.
pub(super) async fn check(uin: String) -> Value {
    let checked_at = crate::login::unix_now() * 1000;
    match check_inner(&uin).await {
        Ok((messages, conversations)) => json!({
            "uin": uin, "count": messages, "conversations": conversations, "checked_at": checked_at
        }),
        Err(error) => {
            let expired = error
                .downcast_ref::<crate::session::SessionError>()
                .is_some_and(|_| SessionStatus::from_error(&error) == SessionStatus::Expired)
                || error.to_string().contains("expired");
            json!({"uin": uin, "error": if expired { "expired" } else { "unavailable" }, "checked_at": checked_at})
        }
    }
}

async fn check_inner(uin: &str) -> Result<(usize, usize)> {
    let session_path = Path::new("accounts").join(format!("{uin}.json"));
    let threads_path = account_dir(uin).join("native_threads.json");
    let (session, saved, since_ms) = tokio::task::spawn_blocking({
        let session_path = session_path.clone();
        move || -> Result<(Session, Vec<Thread>, i64)> {
            let mut session = Session::new(false, false, false)?;
            session.load_from_file(&session_path.to_string_lossy())?;
            let saved: Vec<Thread> = std::fs::read(&threads_path)
                .ok()
                .and_then(|bytes| serde_json::from_slice(&bytes).ok())
                .unwrap_or_default();
            // When the list was last written, i.e. when this account was last connected here.
            let since_ms = std::fs::metadata(&threads_path)
                .and_then(|m| m.modified())
                .ok()
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map_or(0, |d| d.as_millis() as i64);
            Ok((session, saved, since_ms))
        }
    })
    .await??;
    if session.login.as_ref().is_none_or(|login| login.uin != uin) || session.is_expired_marked() {
        bail!("expired");
    }
    let reply = tokio::time::timeout(std::time::Duration::from_secs(20), chat::get_last_msgs(&session, &[]))
        .await
        .context("timeout")??;
    if let Some(code) = reply.get("error_code").and_then(Value::as_i64) {
        if code != 0 {
            return Err(crate::session::SessionError::new(code, "get-last-msgs").into());
        }
    }
    Ok(count_with_previews(&saved, &reply, since_ms))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn thread(id: &str, seen: &str) -> Thread {
        let mut thread = Thread { id: id.into(), name: id.into(), ..Default::default() };
        thread.unread.last_seen_id = Some(seen.into());
        thread
    }

    #[test]
    fn muted_hidden_and_read_conversations_do_not_count() {
        let mut a = thread("1", "10");
        a.unread.unread_ids.insert("11".into());
        a.unread.unread_ids.insert("12".into());
        let mut muted = thread("2", "10");
        muted.unread.unread_ids.insert("13".into());
        muted.unread.muted = true;
        let mut hidden = thread("3", "10");
        hidden.unread.unread_ids.insert("14".into());
        hidden.presentation.hidden = true;
        let mut marked = thread("4", "10");
        marked.unread.marked_unread = true;
        assert_eq!(unread_total(&[a, muted, hidden, marked]), (3, 2));
    }

    #[test]
    fn other_accounts_skips_the_active_one_and_non_accounts() {
        let dir = std::env::temp_dir().join(format!("zalolite-watch-{}-{}", std::process::id(), crate::login::unix_now()));
        std::fs::create_dir_all(dir.join("accounts")).unwrap();
        for name in ["111.json", "222.json", "notes.json", "333.txt"] {
            std::fs::write(dir.join("accounts").join(name), "{}").unwrap();
        }
        let found = other_accounts(&dir, "111");
        std::fs::remove_dir_all(&dir).ok();
        assert_eq!(found, vec!["222".to_string()]);
    }

    #[test]
    fn only_messages_after_the_saved_list_add_to_its_unread() {
        let mut known = thread("u1", "50");
        known.unread.unread_ids.insert("60".into());
        let reply = json!({"data":{"msgs":[
            {"idTo":"u1","messages":[
                {"msgId":"70","content":"đã đọc trên điện thoại","ts":1_795_000_000_000_i64,"uidFrom":"u1"},
                {"msgId":"80","content":"tin mới","ts":1_795_000_300_000_i64,"uidFrom":"u1"},
                {"msgId":"81","content":"tin của mình","ts":1_795_000_300_001_i64,"uidFrom":"0"}
            ]},
            {"idTo":"u2","messages":[{"msgId":"90","content":"người mới nhắn","ts":1_795_000_400_000_i64,"uidFrom":"u2"}]}
        ]}});
        // Saved between 70 and 80: 70 predates it, 80 and 90 arrived later; 81 is our own.
        assert_eq!(count_with_previews(&[known], &reply, 1_795_000_100_000), (3, 2));
    }
}
