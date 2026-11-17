//! Phone message sync v2 (`cmd 590`) shaped like Zalo PC 26.11.10 (re-notes/70).
//!
//! Zalo PC asks the phone for one partition per conversation, named `oneone/<globalId>` or
//! `group/<globalId>`, never for an empty partition. Each request has its own key pair, a
//! `syncId`, and an `ussidx` counter within the user's sync session. The phone answers with
//! `upload_batch` events; every downloaded batch is a run of length-prefixed records: the first
//! establishes the session (metadata), the rest are messages decrypted with that session.
//!
//! This module keeps one working folder per request (`sync_v2/<syncId>/`) for its keys and
//! session, maps partitions back to Zalolite threads, and writes a diagnostics log without
//! secrets, URLs or message content (`phone_sync.log`).

use std::collections::HashMap;
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Instant;

use anyhow::{Context, Result};
use serde_json::{json, Value};

use crate::chat::{self, Thread};
use crate::history_sync::{self, ParsedProtoMsg};
use crate::session::Session;
use crate::store::{MessageStore, StoredMessage};

/// `yo.a` in Zalo PC: no per-partition message limit.
pub const NO_LIMIT: i64 = 2_147_483_647;
/// Upper bound of the timestamp range (`Number.MAX_SAFE_INTEGER`).
pub const MAX_TS: i64 = 9_007_199_254_740_991;
/// `transferBatchSize` in Zalo PC's session manager.
pub const TRANSFER_BATCH_SIZE: u32 = 2000;
/// Conversations per request; Zalo PC chunks its conversation list the same way.
pub const PARTITIONS_PER_REQUEST: usize = 50;
const LOG_FILE: &str = "phone_sync.log";
const LOG_LIMIT: u64 = 1 << 20;

/// One conversation the phone is asked for.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PlannedPartition {
    pub partition: String,
    pub thread_id: String,
    pub is_group: bool,
    pub global_id: String,
}

/// The conversations to request, plus `globalId → userId` for naming senders.
#[derive(Clone, Debug, Default)]
pub struct SyncPlan {
    pub partitions: Vec<PlannedPartition>,
    pub senders: HashMap<String, String>,
    /// Threads left out because no global id is known (Zalo PC drops these too).
    pub skipped: usize,
}

/// `oneone/<globalId>` or `group/<globalId>` (`aSMs` in Zalo PC).
pub fn partition_name(global_id: &str, is_group: bool) -> String {
    format!("{}/{global_id}", if is_group { "group" } else { "oneone" })
}

fn plain_group_id(id: &str) -> &str {
    id.trim_start_matches("group_").trim_start_matches(['g', 'G'])
}

/// Build the request plan from the thread list, in the list's order (most recent first).
pub fn plan_partitions(
    threads: &[Thread],
    friends: &HashMap<String, String>,
    groups: &HashMap<String, String>,
    send2me_id: &str,
) -> SyncPlan {
    let mut plan = SyncPlan {
        senders: friends.iter().map(|(uid, gid)| (gid.clone(), uid.clone())).collect(),
        ..SyncPlan::default()
    };
    let mut seen = std::collections::HashSet::new();
    for thread in threads {
        if thread.id.is_empty() || thread.id == send2me_id || !seen.insert((thread.id.clone(), thread.is_group)) {
            continue;
        }
        let global = if thread.is_group { groups.get(plain_group_id(&thread.id)) } else { friends.get(&thread.id) };
        match global {
            Some(global_id) => plan.partitions.push(PlannedPartition {
                partition: partition_name(global_id, thread.is_group),
                thread_id: thread.id.clone(),
                is_group: thread.is_group,
                global_id: global_id.clone(),
            }),
            None => plan.skipped += 1,
        }
    }
    plan
}

/// Fetch the global ids for friends and for the groups in `threads`.
pub async fn build_plan(s: &Session, threads: &[Thread]) -> Result<SyncPlan> {
    let friends = chat::get_friend_global_ids(s).await?;
    let group_ids: Vec<String> = threads.iter().filter(|t| t.is_group).map(|t| plain_group_id(&t.id).to_string()).collect();
    let mut groups = HashMap::new();
    for chunk in group_ids.chunks(50) {
        let (info, _) = chat::fetch_group_profiles(s, chunk).await?;
        for (grid, value) in info {
            let global = match value.get("globalId") {
                Some(Value::String(g)) if !g.is_empty() => g.clone(),
                Some(Value::Number(n)) => n.to_string(),
                _ => continue,
            };
            groups.insert(grid, global);
        }
    }
    let send2me = s.login.as_ref().map(|l| l.send2me_id.clone()).unwrap_or_default();
    let plan = plan_partitions(threads, &friends, &groups, &send2me);
    log(&format!(
        "plan: friends_with_global_id={} groups_with_global_id={} partitions={} skipped={}",
        friends.len(),
        groups.len(),
        plan.partitions.len(),
        plan.skipped
    ));
    Ok(plan)
}

/// The SyncFull request body for one chunk of partitions (`requestSync` in Zalo PC).
pub fn request_payload(
    sync_id: &str,
    ik_pub: &str,
    ek_pub: &str,
    temp_key: &str,
    device_name: &str,
    partitions: &[PlannedPartition],
    ussidx: u32,
) -> Value {
    let queries: Vec<Value> = partitions
        .iter()
        .map(|p| json!({"partition": p.partition, "from": 0, "to": MAX_TS, "limit": NO_LIMIT}))
        .collect();
    json!({
        "syncId": sync_id,
        "syncType": 0,
        "ek": ek_pub,
        "ik": ik_pub,
        "toDevice": 0,
        "tempKey": temp_key,
        "deviceName": device_name,
        "req": {"type": "message", "priority": 1, "queries": queries, "batchSize": TRANSFER_BATCH_SIZE},
        "ver": 1,
        "ussidx": ussidx
    })
}

// ---- Request registry ----------------------------------------------------------------------

struct Request {
    dir: PathBuf,
    /// partition name → (thread id, is group, partner global id)
    partitions: HashMap<String, (String, bool, String)>,
    senders: Arc<HashMap<String, String>>,
    pending: Vec<String>,
    created: Instant,
    batches: usize,
    imported: usize,
    last_activity: Option<Instant>,
    last_seen: bool,
}

/// Progress of one request, read by the orchestrating sync loop.
#[derive(Clone, Copy, Debug)]
pub struct RequestState {
    pub batches: usize,
    pub imported: usize,
    pub last_activity: Option<Instant>,
    pub last_seen: bool,
}

fn registry() -> &'static Mutex<HashMap<String, Request>> {
    static REQUESTS: OnceLock<Mutex<HashMap<String, Request>>> = OnceLock::new();
    REQUESTS.get_or_init(|| Mutex::new(HashMap::new()))
}

/// The owner's own global id, learned from 1-1 partitions (the sender that is not the partner).
fn own_global_id() -> &'static Mutex<String> {
    static OWN: OnceLock<Mutex<String>> = OnceLock::new();
    OWN.get_or_init(|| Mutex::new(String::new()))
}

/// Folder that holds every request's working folder, under the account data directory.
pub fn root_dir() -> PathBuf {
    PathBuf::from("sync_v2")
}

pub fn request_state(sync_id: &str) -> Option<RequestState> {
    let requests = registry().lock().ok()?;
    requests.get(sync_id).map(|r| RequestState {
        batches: r.batches,
        imported: r.imported,
        last_activity: r.last_activity,
        last_seen: r.last_seen,
    })
}

/// Send one SyncFull request for `chunk`; returns its sync id.
pub fn send_request(s: &Session, chunk: &[PlannedPartition], ussidx: u32, senders: Arc<HashMap<String, String>>) -> Result<String> {
    let sync_id = crate::param_cipher::random_hex(32);
    let dir = root_dir().join(&sync_id);
    std::fs::create_dir_all(&dir).context("không tạo được thư mục đồng bộ")?;
    let keys = history_sync::generate_sync_v2_keys_in(&dir)
        .context("không tạo được khoá đồng bộ (thiếu Node.js hoặc Zalo PC)")?;
    let temp_key = history_sync::latest_mobile_temp_key();
    let payload = request_payload(&sync_id, &keys.ik_pub, &keys.ek_pub, &temp_key, &s.computer_name, chunk, ussidx);
    let partitions = chunk
        .iter()
        .map(|p| (p.partition.clone(), (p.thread_id.clone(), p.is_group, p.global_id.clone())))
        .collect();
    if let Ok(mut requests) = registry().lock() {
        requests.insert(
            sync_id.clone(),
            Request {
                dir,
                partitions,
                senders,
                pending: Vec::new(),
                created: Instant::now(),
                batches: 0,
                imported: 0,
                last_activity: None,
                last_seen: false,
            },
        );
    }
    let woke = crate::socket::send_mobile_wakeup(&sync_id);
    let sent = crate::socket::send_sync_message_ws_request(&payload);
    log(&format!(
        "request: sync={} ussidx={ussidx} partitions={} temp_key={} wakeup_sent={woke} request_sent={sent}",
        short(&sync_id),
        chunk.len(),
        !temp_key.is_empty()
    ));
    if !sent {
        anyhow::bail!("WebSocket chưa sẵn sàng; chưa gửi được yêu cầu đồng bộ");
    }
    Ok(sync_id)
}

/// Forget every request and delete its keys and session.
pub fn finish_all() {
    if let Ok(mut requests) = registry().lock() {
        for (_, request) in requests.drain() {
            let _ = std::fs::remove_dir_all(&request.dir);
        }
    }
    let _ = std::fs::remove_dir(root_dir());
}

// ---- Batch import --------------------------------------------------------------------------

/// What one downloaded batch contained.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct BatchOutcome {
    pub meta_records: usize,
    pub message_records: usize,
    pub failed_records: usize,
    pub imported: usize,
    pub unknown_partitions: usize,
    pub deferred: bool,
}

/// Download, decrypt and store one `upload_batch`. A message batch that arrives before the
/// metadata of its request is kept and retried once the session exists.
pub async fn import_batch(s: &Session, sync_id: &str, url: &str, is_last: bool, db_path: &str) -> Result<BatchOutcome> {
    let Some(sync_id) = resolve_sync_id(sync_id) else {
        log(&format!("batch: unknown sync={} host={}", short(sync_id), host(url)));
        anyhow::bail!("gói đồng bộ không thuộc yêu cầu nào đang chạy");
    };
    let mut total = import_one(s, &sync_id, url, db_path).await?;
    if let Ok(mut requests) = registry().lock() {
        if let Some(request) = requests.get_mut(&sync_id) {
            request.last_seen |= is_last;
        }
    }
    if !total.deferred && total.meta_records > 0 {
        // The session now exists: replay batches that came first.
        let pending = registry()
            .lock()
            .ok()
            .and_then(|mut r| r.get_mut(&sync_id).map(|req| std::mem::take(&mut req.pending)))
            .unwrap_or_default();
        for earlier in pending {
            match import_one(s, &sync_id, &earlier, db_path).await {
                Ok(outcome) => total.imported += outcome.imported,
                Err(error) => log(&format!("batch: replay failed sync={} error={error}", short(&sync_id))),
            }
        }
    }
    Ok(total)
}

fn resolve_sync_id(sync_id: &str) -> Option<String> {
    let requests = registry().lock().ok()?;
    if requests.contains_key(sync_id) {
        return Some(sync_id.to_string());
    }
    // Events without a sync id belong to the newest request.
    requests.iter().max_by_key(|(_, r)| r.created).map(|(id, _)| id.clone())
}

async fn import_one(s: &Session, sync_id: &str, url: &str, db_path: &str) -> Result<BatchOutcome> {
    let (dir, partitions, senders) = {
        let requests = registry().lock().map_err(|_| anyhow::anyhow!("registry poisoned"))?;
        let request = requests.get(sync_id).context("yêu cầu đồng bộ đã kết thúc")?;
        (request.dir.clone(), request.partitions.clone(), request.senders.clone())
    };
    let bytes = download(s, url).await?;
    let had_session = dir.join("sync_v2_session.bin").is_file();
    let input = dir.join(format!("batch_{}.bin", crate::param_cipher::random_hex(6)));
    let output = input.with_extension("plain");
    std::fs::write(&input, &bytes)?;
    let helper_dir = dir.clone();
    let (input_arg, output_arg) = (input.clone(), output.clone());
    let run = tokio::task::spawn_blocking(move || {
        history_sync::run_sync_v2_helper_in(&helper_dir, &["decrypt-batch".as_ref(), input_arg.as_os_str(), output_arg.as_os_str()])
    })
    .await??;
    let _ = std::fs::remove_file(&input);
    let plain = std::fs::read(&output).unwrap_or_default();
    let _ = std::fs::remove_file(&output);
    if !run.status.success() {
        log(&format!("batch: decrypt failed sync={} bytes={}", short(sync_id), bytes.len()));
        anyhow::bail!("không giải mã được gói đồng bộ");
    }
    let records = split_plain_records(&plain);
    let mut outcome = BatchOutcome {
        meta_records: records.iter().filter(|(kind, _)| *kind == 1).count(),
        message_records: records.iter().filter(|(kind, _)| *kind == 2).count(),
        ..BatchOutcome::default()
    };
    let summary: Value = serde_json::from_slice(&run.stdout).unwrap_or(Value::Null);
    outcome.failed_records = summary.get("failed").and_then(Value::as_u64).unwrap_or(0) as usize;
    if records.is_empty() && outcome.failed_records > 0 && !had_session {
        if let Ok(mut requests) = registry().lock() {
            if let Some(request) = requests.get_mut(sync_id) {
                request.pending.push(url.to_string());
            }
        }
        outcome.deferred = true;
        log(&format!("batch: deferred until metadata sync={} bytes={}", short(sync_id), bytes.len()));
        return Ok(outcome);
    }

    let uin = s.login.as_ref().map(|l| l.uin.clone()).unwrap_or_default();
    let my_name = s.login.as_ref().map(|l| l.display_name.clone()).unwrap_or_else(|| "Tôi".into());
    let mut rows = Vec::new();
    for (_, body) in &records {
        let decoded = decompress(body);
        for part in history_sync::parse_sync_chunk(&decoded).unwrap_or_default() {
            match partitions.get(&part.id) {
                Some((thread_id, is_group, partner)) => rows.extend(to_stored_messages(
                    thread_id, *is_group, partner, part.messages, &senders, &uin, &my_name,
                )),
                None if part.messages.is_empty() => {}
                None => outcome.unknown_partitions += 1,
            }
        }
    }
    let target = db_path.to_string();
    outcome.imported = tokio::task::spawn_blocking(move || -> Result<usize> {
        let mut store = MessageStore::open(&target)?;
        let mut added = 0;
        for row in &rows {
            if store.upsert_message(row).unwrap_or(false) {
                added += 1;
            }
        }
        Ok(added)
    })
    .await??;
    if let Ok(mut requests) = registry().lock() {
        if let Some(request) = requests.get_mut(sync_id) {
            request.batches += 1;
            request.imported += outcome.imported;
            request.last_activity = Some(Instant::now());
        }
    }
    log(&format!(
        "batch: sync={} bytes={} meta={} messages={} failed={} imported={} unknown_partitions={}",
        short(sync_id),
        bytes.len(),
        outcome.meta_records,
        outcome.message_records,
        outcome.failed_records,
        outcome.imported,
        outcome.unknown_partitions
    ));
    Ok(outcome)
}

/// [`import_batch`] into the signed-in account's store, refreshing the legacy thread cache
/// (egui client).
pub async fn import_batch_for_account(s: &Session, sync_id: &str, url: &str, is_last: bool) -> Result<usize> {
    let uin = s.login.as_ref().map(|l| l.uin.clone()).unwrap_or_default();
    let db_path = crate::store::db_path_for_account(&uin);
    let outcome = import_batch(s, sync_id, url, is_last, &db_path).await?;
    let mut cached = chat::load_threads_cache();
    MessageStore::open(&db_path)?.hydrate_threads(&mut cached, 50)?;
    chat::save_threads_cache(&cached);
    Ok(outcome.imported)
}

async fn download(s: &Session, url: &str) -> Result<Vec<u8>> {
    let uin = s.login.as_ref().map(|l| l.uin.clone()).unwrap_or_default();
    let sek = s.zpw_sek.clone().unwrap_or_default();
    let response = s
        .http
        .get(url)
        .header("Cookie", format!("zpw_sek={sek}; zpw_uin={uin}"))
        .header("User-Agent", "ZaloPC-win32-26.10.11")
        .send()
        .await?;
    if !response.status().is_success() {
        log(&format!("batch: download HTTP {} host={}", response.status().as_u16(), host(url)));
        anyhow::bail!("không tải được gói đồng bộ (HTTP {})", response.status().as_u16());
    }
    Ok(response.bytes().await?.to_vec())
}

/// Split the helper's `u8 kind | u32 LE length | bytes` output.
pub fn split_plain_records(bytes: &[u8]) -> Vec<(u8, Vec<u8>)> {
    let mut records = Vec::new();
    let mut offset = 0;
    while offset + 5 <= bytes.len() {
        let kind = bytes[offset];
        let len = u32::from_le_bytes([bytes[offset + 1], bytes[offset + 2], bytes[offset + 3], bytes[offset + 4]]) as usize;
        let start = offset + 5;
        if start + len > bytes.len() {
            break;
        }
        records.push((kind, bytes[start..start + len].to_vec()));
        offset = start + len;
    }
    records
}

fn decompress(body: &[u8]) -> Vec<u8> {
    if body.starts_with(&[0x28, 0xB5, 0x2F, 0xFD]) {
        if let Ok(plain) = zstd::decode_all(std::io::Cursor::new(body)) {
            return plain;
        }
    }
    body.to_vec()
}

/// Turn one partition's messages into stored rows for `thread_id`.
///
/// Senders are global ids: in a 1-1 partition the partner's global id means incoming and any
/// other sender is the owner (remembered for group partitions); in a group, friends are named
/// by their `userId`.
pub fn to_stored_messages(
    thread_id: &str,
    is_group: bool,
    partner_global_id: &str,
    messages: Vec<ParsedProtoMsg>,
    senders: &HashMap<String, String>,
    uin: &str,
    my_name: &str,
) -> Vec<StoredMessage> {
    if !is_group {
        if let Some(own) = messages.iter().map(|m| m.sender_id.as_str()).find(|s| !s.is_empty() && *s != partner_global_id) {
            if let Ok(mut known) = own_global_id().lock() {
                if known.is_empty() {
                    *known = own.to_string();
                }
            }
        }
    }
    let own = own_global_id().lock().map(|o| o.clone()).unwrap_or_default();
    messages
        .into_iter()
        .filter(|m| m.timestamp > 0)
        .map(|m| {
            let is_outgoing = if is_group {
                !own.is_empty() && m.sender_id == own
            } else {
                m.sender_id != partner_global_id
            };
            let sender_id = if is_outgoing {
                uin.to_string()
            } else if is_group {
                senders.get(&m.sender_id).cloned().unwrap_or_else(|| m.sender_id.clone())
            } else {
                thread_id.to_string()
            };
            let msg_id = if !m.global_id.is_empty() && m.global_id != "0" { m.global_id.clone() } else { m.client_id.to_string() };
            let (msg_type, text) = history_sync::mobile_message_label(m.msg_type as i64, m.content.trim());
            StoredMessage {
                msg_id,
                thread_id: thread_id.to_string(),
                sender_id,
                sender_name: if is_outgoing { my_name.to_string() } else { String::new() },
                text,
                msg_type,
                ts: m.timestamp as i64,
                is_outgoing,
                raw_json: String::new(),
            }
        })
        .collect()
}

// ---- Diagnostics ---------------------------------------------------------------------------

/// Append one line to `phone_sync.log` in the data directory. Callers pass counts, flags and
/// short id prefixes only: never keys, cookies, URLs or message content.
pub fn log(line: &str) {
    let path = Path::new(LOG_FILE);
    if std::fs::metadata(path).map(|m| m.len() > LOG_LIMIT).unwrap_or(false) {
        let _ = std::fs::rename(path, Path::new("phone_sync.log.1"));
    }
    if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(file, "{} {line}", chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ"));
    }
}

/// First 8 characters of an id, enough to correlate log lines.
pub fn short(id: &str) -> &str {
    id.get(..8).unwrap_or(id)
}

/// Host of a download URL; the path and query may carry access tokens and are never logged.
pub fn host(url: &str) -> String {
    reqwest::Url::parse(url).ok().and_then(|u| u.host_str().map(str::to_string)).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn thread(id: &str, is_group: bool) -> Thread {
        Thread { id: id.into(), is_group, ..Default::default() }
    }

    #[test]
    fn partitions_use_global_ids_and_skip_unknown_threads() {
        let friends = HashMap::from([("111".to_string(), "g-a".to_string())]);
        let groups = HashMap::from([("222".to_string(), "g-b".to_string())]);
        let threads = [thread("111", false), thread("222", true), thread("333", false), thread("cloud", false), thread("111", false)];
        let plan = plan_partitions(&threads, &friends, &groups, "cloud");
        let names: Vec<_> = plan.partitions.iter().map(|p| p.partition.as_str()).collect();
        assert_eq!(names, ["oneone/g-a", "group/g-b"]);
        assert_eq!(plan.skipped, 1);
        assert_eq!(plan.senders.get("g-a").map(String::as_str), Some("111"));
    }

    #[test]
    fn request_never_contains_an_empty_partition() {
        let chunk = [PlannedPartition { partition: "oneone/g-a".into(), thread_id: "111".into(), is_group: false, global_id: "g-a".into() }];
        let body = request_payload("sid", "ik", "ek", "tk", "Mac", &chunk, 3);
        let query = &body["req"]["queries"][0];
        assert_eq!(query["partition"], "oneone/g-a");
        assert_eq!(query["limit"], NO_LIMIT);
        assert_eq!(body["req"]["type"], "message");
        assert_eq!(body["req"]["batchSize"], TRANSFER_BATCH_SIZE);
        assert_eq!(body["ussidx"], 3);
    }

    #[test]
    fn helper_output_records_split_in_order() {
        let mut bytes = vec![1, 2, 0, 0, 0, b'm', b'e'];
        bytes.extend([2, 3, 0, 0, 0, b'a', b'b', b'c']);
        bytes.extend([2, 9, 0, 0, 0]); // truncated record is dropped
        assert_eq!(split_plain_records(&bytes), vec![(1, b"me".to_vec()), (2, b"abc".to_vec())]);
    }

    fn proto(sender: &str, id: &str, ts: u64, text: &str) -> ParsedProtoMsg {
        ParsedProtoMsg { sender_id: sender.into(), global_id: id.into(), timestamp: ts, content: text.into(), msg_type: 1, ..Default::default() }
    }

    #[test]
    fn one_to_one_direction_follows_the_partner_global_id() {
        let rows = to_stored_messages(
            "111", false, "g-partner",
            vec![proto("g-partner", "5", 10, "chào"), proto("g-me", "6", 11, "hi")],
            &HashMap::new(), "999", "Tôi",
        );
        assert_eq!(rows.len(), 2);
        assert!(!rows[0].is_outgoing);
        assert_eq!(rows[0].sender_id, "111");
        assert!(rows[1].is_outgoing);
        assert_eq!(rows[1].sender_id, "999");
        assert_eq!(rows[1].thread_id, "111");
    }

    #[test]
    fn group_senders_are_named_by_user_id() {
        let senders = HashMap::from([("g-friend".to_string(), "444".to_string())]);
        let rows = to_stored_messages("222", true, "g-group", vec![proto("g-friend", "7", 12, "x")], &senders, "999", "Tôi");
        assert_eq!(rows[0].sender_id, "444");
        assert!(!rows[0].is_outgoing);
    }

    #[test]
    fn friend_global_ids_come_from_getfriends_rows() {
        let resp = json!({"data": [
            {"userId": "111", "globalId": "G1", "displayName": "A"},
            {"userId": "222", "displayName": "no global id"},
            {"userId": 333, "globalId": 999}
        ]});
        let ids = chat::friend_global_ids(&resp);
        assert_eq!(ids.len(), 2);
        assert_eq!(ids["111"], "G1");
        assert_eq!(ids["333"], "999");
    }

    #[test]
    fn phone_message_types_get_readable_labels() {
        assert_eq!(history_sync::mobile_message_label(1, " chào "), ("webchat".into(), "chào".into()));
        assert_eq!(history_sync::mobile_message_label(3, "{\"href\":1}"), ("chat.photo".into(), "[Hình ảnh]".into()));
        assert_eq!(history_sync::mobile_message_label(10, ""), ("chat.sticker".into(), "[Nhãn dán]".into()));
    }

    #[test]
    fn log_helpers_never_expose_paths_or_full_ids() {
        assert_eq!(host("https://f.example.com/a/b?token=secret"), "f.example.com");
        assert_eq!(short("0123456789abcdef"), "01234567");
    }
}
