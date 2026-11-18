//! Read-only bridge that lets a local AI assistant (Codex, Claude) read conversations the user
//! chose to share, over the Model Context Protocol on stdio (`ctdozlite-core --mcp`).
//!
//! The Zalolite app writes `ai_bridge.json` in its data directory: whether sharing is on, which
//! account, and which conversations. Every tool call re-reads that file, so a change in Settings
//! applies at once. The bridge opens the account's message store read-only, never touches the
//! session or the network, and cannot send anything.

use std::io::{BufRead, Write};
use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};
use chrono::{Local, NaiveDate, TimeZone};
use rusqlite::{params, Connection, OpenFlags};
use serde::Deserialize;
use serde_json::{json, Value};

pub const CONFIG_FILE: &str = "ai_bridge.json";
const PROTOCOL_VERSION: &str = "2025-06-18";
const DEFAULT_LIMIT: i64 = 300;
const MAX_LIMIT: i64 = 2000;
const MAX_TEXT: usize = 4000;

/// One conversation the user shared.
#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
pub struct SharedConversation {
    pub id: String,
    #[serde(default)]
    pub is_group: bool,
    #[serde(default)]
    pub name: String,
}

/// `ai_bridge.json`, written by the app.
#[derive(Clone, Debug, Default, Deserialize)]
pub struct BridgeConfig {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub account: String,
    #[serde(default)]
    pub owner_name: String,
    #[serde(default)]
    pub conversations: Vec<SharedConversation>,
}

impl BridgeConfig {
    fn shared(&self, id: &str) -> Option<&SharedConversation> {
        self.conversations.iter().find(|c| c.id == id)
    }
}

/// Serve MCP over stdin/stdout until the client closes the pipe.
pub fn run_stdio(data_dir: &Path) -> Result<()> {
    let stdin = std::io::stdin();
    let mut stdout = std::io::stdout().lock();
    for line in stdin.lock().lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        if let Some(reply) = handle_line(data_dir, &line) {
            writeln!(stdout, "{reply}")?;
            stdout.flush()?;
        }
    }
    Ok(())
}

/// One JSON-RPC message in, at most one reply out (notifications get none).
pub fn handle_line(data_dir: &Path, line: &str) -> Option<String> {
    let Ok(request) = serde_json::from_str::<Value>(line) else {
        return Some(json!({"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}).to_string());
    };
    let id = request.get("id").cloned()?;
    let method = request.get("method").and_then(Value::as_str).unwrap_or_default();
    let params = request.get("params").cloned().unwrap_or(Value::Null);
    let result = match method {
        "initialize" => Ok(json!({
            "protocolVersion": params.get("protocolVersion").and_then(Value::as_str).unwrap_or(PROTOCOL_VERSION),
            "capabilities": {"tools": {"listChanged": false}},
            "serverInfo": {"name": "zalolite", "version": env!("CARGO_PKG_VERSION")},
            "instructions": "Đọc tin nhắn Zalo trong các hội thoại người dùng đã chia sẻ trong Zalolite (Cài đặt → Trợ lý AI). Gọi list_conversations trước để lấy conversation_id. Chỉ đọc; không gửi được tin nhắn."
        })),
        "ping" => Ok(json!({})),
        "tools/list" => Ok(json!({"tools": tool_definitions()})),
        "tools/call" => Ok(call_tool(data_dir, &params)),
        _ => Err((-32601, format!("Method not found: {method}"))),
    };
    Some(match result {
        Ok(result) => json!({"jsonrpc":"2.0","id":id,"result":result}),
        Err((code, message)) => json!({"jsonrpc":"2.0","id":id,"error":{"code":code,"message":message}}),
    }
    .to_string())
}

fn tool_definitions() -> Value {
    json!([
        {
            "name": "list_conversations",
            "description": "Liệt kê các hội thoại Zalo người dùng cho phép trợ lý đọc, kèm số tin và thời điểm tin cuối.",
            "inputSchema": {"type": "object", "properties": {}, "additionalProperties": false},
            "annotations": {"readOnlyHint": true}
        },
        {
            "name": "read_messages",
            "description": "Đọc tin nhắn của một hội thoại đã chia sẻ theo thứ tự thời gian. Dùng days (số ngày gần nhất) hoặc since/until (YYYY-MM-DD hoặc YYYY-MM-DD HH:MM, giờ máy).",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "conversation_id": {"type": "string", "description": "id từ list_conversations"},
                    "days": {"type": "number", "description": "Số ngày gần nhất, ví dụ 3"},
                    "since": {"type": "string"},
                    "until": {"type": "string"},
                    "limit": {"type": "integer", "description": "Tối đa số tin (mặc định 300, tối đa 2000); lấy các tin mới nhất trong khoảng"}
                },
                "required": ["conversation_id"],
                "additionalProperties": false
            },
            "annotations": {"readOnlyHint": true}
        },
        {
            "name": "search_messages",
            "description": "Tìm tin nhắn chứa từ khóa trong các hội thoại đã chia sẻ (hoặc một hội thoại).",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "query": {"type": "string"},
                    "conversation_id": {"type": "string"},
                    "days": {"type": "number"},
                    "limit": {"type": "integer", "description": "Mặc định 100, tối đa 2000"}
                },
                "required": ["query"],
                "additionalProperties": false
            },
            "annotations": {"readOnlyHint": true}
        }
    ])
}

fn call_tool(data_dir: &Path, params: &Value) -> Value {
    let name = params.get("name").and_then(Value::as_str).unwrap_or_default();
    let args = params.get("arguments").cloned().unwrap_or_else(|| json!({}));
    let outcome = load_config(data_dir).and_then(|config| match name {
        "list_conversations" => list_conversations(data_dir, &config),
        "read_messages" => read_messages(data_dir, &config, &args),
        "search_messages" => search_messages(data_dir, &config, &args),
        other => bail!("Không có công cụ {other}"),
    });
    match outcome {
        Ok(text) => json!({"content": [{"type": "text", "text": text}]}),
        Err(error) => json!({"content": [{"type": "text", "text": error.to_string()}], "isError": true}),
    }
}

/// The app's sharing settings; refuses when sharing is off or nothing is shared.
pub fn load_config(data_dir: &Path) -> Result<BridgeConfig> {
    let text = std::fs::read_to_string(data_dir.join(CONFIG_FILE))
        .map_err(|_| anyhow::anyhow!("Zalolite chưa bật chia sẻ với trợ lý AI. Mở Zalolite → Cài đặt → Trợ lý AI."))?;
    let config: BridgeConfig = serde_json::from_str(&text).context("Cấu hình chia sẻ của Zalolite không hợp lệ")?;
    if !config.enabled {
        bail!("Người dùng đang tắt chia sẻ với trợ lý AI trong Zalolite.");
    }
    if config.account.is_empty() || !config.account.bytes().all(|b| b.is_ascii_digit()) {
        bail!("Zalolite chưa chọn tài khoản để chia sẻ.");
    }
    if config.conversations.is_empty() {
        bail!("Chưa có hội thoại nào được chia sẻ. Mở Zalolite → Cài đặt → Trợ lý AI để chọn.");
    }
    Ok(config)
}

fn open_store(data_dir: &Path, config: &BridgeConfig) -> Result<Connection> {
    let path: PathBuf = data_dir.join("accounts").join(&config.account).join("native_history.db");
    let connection = Connection::open_with_flags(&path, OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX)
        .context("Chưa mở được lịch sử tin nhắn của Zalolite")?;
    connection.busy_timeout(std::time::Duration::from_secs(5))?;
    Ok(connection)
}

fn list_conversations(data_dir: &Path, config: &BridgeConfig) -> Result<String> {
    let store = open_store(data_dir, config)?;
    let mut lines = vec![format!("{} hội thoại được chia sẻ:", config.conversations.len())];
    for conversation in &config.conversations {
        let (count, last): (i64, Option<i64>) = store.query_row(
            "SELECT COUNT(*), MAX(ts) FROM messages WHERE thread_id = ?1",
            params![conversation.id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )?;
        lines.push(format!(
            "- {} ({}) · conversation_id: {} · {} tin · tin cuối: {}",
            display_name(conversation),
            if conversation.is_group { "nhóm" } else { "cá nhân" },
            conversation.id,
            count,
            last.map(format_time).unwrap_or_else(|| "chưa có".into())
        ));
    }
    Ok(lines.join("\n"))
}

fn read_messages(data_dir: &Path, config: &BridgeConfig, args: &Value) -> Result<String> {
    let id = args.get("conversation_id").and_then(Value::as_str).unwrap_or_default();
    let conversation = config
        .shared(id)
        .context("Hội thoại này chưa được chia sẻ với trợ lý. Gọi list_conversations để xem các hội thoại được phép.")?;
    let (from, to) = time_window(args)?;
    let limit = limit(args, DEFAULT_LIMIT);
    let store = open_store(data_dir, config)?;
    let mut statement = store.prepare(
        "SELECT sender_id, sender_name, text, msg_type, ts, is_outgoing FROM messages
         WHERE thread_id = ?1 AND ts >= ?2 AND ts <= ?3 ORDER BY ts DESC LIMIT ?4",
    )?;
    let mut rows: Vec<Row> = statement
        .query_map(params![conversation.id, from, to, limit], Row::from_sql)?
        .collect::<rusqlite::Result<_>>()?;
    rows.reverse();
    let mut lines = vec![format!(
        "{} — {} tin{}",
        display_name(conversation),
        rows.len(),
        if rows.len() as i64 == limit { " (đã giới hạn; dùng since/until hoặc limit để đọc thêm)" } else { "" }
    )];
    lines.extend(rows.iter().map(|row| row.line(conversation, config)));
    Ok(lines.join("\n"))
}

fn search_messages(data_dir: &Path, config: &BridgeConfig, args: &Value) -> Result<String> {
    let query = args.get("query").and_then(Value::as_str).unwrap_or_default().trim();
    if query.is_empty() {
        bail!("Cần từ khóa cần tìm.");
    }
    let scope: Vec<&SharedConversation> = match args.get("conversation_id").and_then(Value::as_str) {
        Some(id) => vec![config.shared(id).context("Hội thoại này chưa được chia sẻ với trợ lý.")?],
        None => config.conversations.iter().collect(),
    };
    let (from, to) = time_window(args)?;
    let limit = limit(args, 100);
    let store = open_store(data_dir, config)?;
    let pattern = format!("%{}%", query.replace('\\', "\\\\").replace('%', "\\%").replace('_', "\\_"));
    let mut found = Vec::new();
    for conversation in scope {
        let mut statement = store.prepare(
            "SELECT sender_id, sender_name, text, msg_type, ts, is_outgoing FROM messages
             WHERE thread_id = ?1 AND ts >= ?2 AND ts <= ?3 AND text LIKE ?4 ESCAPE '\\' ORDER BY ts DESC LIMIT ?5",
        )?;
        let rows = statement.query_map(params![conversation.id, from, to, pattern, limit], Row::from_sql)?;
        for row in rows {
            let row = row?;
            found.push((row.ts, format!("[{}] {}", display_name(conversation), row.line(conversation, config))));
        }
    }
    found.sort_by(|a, b| b.0.cmp(&a.0));
    found.truncate(limit as usize);
    let mut lines = vec![format!("{} kết quả cho \"{query}\"", found.len())];
    lines.extend(found.into_iter().map(|(_, line)| line));
    Ok(lines.join("\n"))
}

struct Row {
    sender_id: String,
    sender_name: String,
    text: String,
    msg_type: String,
    ts: i64,
    outgoing: bool,
}

impl Row {
    fn from_sql(row: &rusqlite::Row<'_>) -> rusqlite::Result<Self> {
        Ok(Self {
            sender_id: row.get::<_, Option<String>>(0)?.unwrap_or_default(),
            sender_name: row.get::<_, Option<String>>(1)?.unwrap_or_default(),
            text: row.get::<_, Option<String>>(2)?.unwrap_or_default(),
            msg_type: row.get::<_, Option<String>>(3)?.unwrap_or_default(),
            ts: row.get::<_, Option<i64>>(4)?.unwrap_or_default(),
            outgoing: row.get::<_, Option<i64>>(5)?.unwrap_or_default() != 0,
        })
    }

    /// `2026-11-17 14:47 | Tên: nội dung`
    fn line(&self, conversation: &SharedConversation, config: &BridgeConfig) -> String {
        let sender = if self.outgoing {
            if config.owner_name.is_empty() { "Tôi (chủ tài khoản)".to_string() } else { format!("{} (chủ tài khoản)", config.owner_name) }
        } else if !self.sender_name.trim().is_empty() {
            self.sender_name.trim().to_string()
        } else if !conversation.is_group {
            display_name(conversation)
        } else {
            format!("Thành viên …{}", &self.sender_id[self.sender_id.len().saturating_sub(4)..])
        };
        let mut text = self.text.trim().replace('\n', " ⏎ ");
        if text.is_empty() {
            text = format!("[{}]", if self.msg_type.is_empty() { "tin không có chữ" } else { &self.msg_type });
        }
        if text.chars().count() > MAX_TEXT {
            text = text.chars().take(MAX_TEXT).collect::<String>() + "…";
        }
        format!("{} | {sender}: {text}", format_time(self.ts))
    }
}

fn display_name(conversation: &SharedConversation) -> String {
    if conversation.name.trim().is_empty() { conversation.id.clone() } else { conversation.name.trim().to_string() }
}

fn limit(args: &Value, default: i64) -> i64 {
    args.get("limit").and_then(Value::as_i64).unwrap_or(default).clamp(1, MAX_LIMIT)
}

/// Inclusive `[from, to]` in epoch milliseconds from `days`, `since` and `until`.
pub fn time_window(args: &Value) -> Result<(i64, i64)> {
    let now = Local::now().timestamp_millis();
    let mut from = 0;
    if let Some(days) = args.get("days").and_then(Value::as_f64) {
        if days > 0.0 {
            from = now - (days * 86_400_000.0) as i64;
        }
    }
    if let Some(since) = args.get("since").and_then(Value::as_str) {
        from = from.max(parse_local(since, false)?);
    }
    let to = match args.get("until").and_then(Value::as_str) {
        Some(until) => parse_local(until, true)?,
        None => i64::MAX,
    };
    Ok((from, to))
}

/// `YYYY-MM-DD` (start or end of that day) or `YYYY-MM-DD HH:MM`, in the Mac's time zone.
fn parse_local(text: &str, end_of_day: bool) -> Result<i64> {
    let text = text.trim().replace('T', " ");
    let naive = if let Ok(time) = chrono::NaiveDateTime::parse_from_str(&text, "%Y-%m-%d %H:%M") {
        time
    } else {
        let date = NaiveDate::parse_from_str(&text, "%Y-%m-%d").with_context(|| format!("Ngày không hợp lệ: {text} (dùng YYYY-MM-DD)"))?;
        if end_of_day { date.and_hms_opt(23, 59, 59) } else { date.and_hms_opt(0, 0, 0) }.context("Ngày không hợp lệ")?
    };
    Ok(Local.from_local_datetime(&naive).earliest().context("Giờ không hợp lệ")?.timestamp_millis())
}

fn format_time(ts: i64) -> String {
    Local.timestamp_millis_opt(ts).single().map(|t| t.format("%Y-%m-%d %H:%M").to_string()).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> PathBuf {
        // Tests run in parallel and `random_hex` is clock-seeded, so a counter keeps each fixture's folder apart.
        static NEXT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!("ai_bridge_{}_{}_{}", std::process::id(), n, crate::param_cipher::random_hex(6)));
        let account = dir.join("accounts/123");
        std::fs::create_dir_all(&account).unwrap();
        let store = crate::store::MessageStore::open(account.join("native_history.db").to_str().unwrap()).unwrap();
        drop(store);
        let db = Connection::open(account.join("native_history.db")).unwrap();
        let now = Local::now().timestamp_millis();
        for (id, thread, sender, name, text, ts, out) in [
            ("1", "111", "111", "", "Mai gửi báo giá nhé", now - 3_600_000, 0),
            ("2", "111", "123", "Tôi", "Ok mình gửi trước 10h", now - 1_800_000, 1),
            ("3", "999", "999", "", "Tin riêng tư", now - 600_000, 0),
            ("4", "222", "555", "Lan", "Chốt đơn 50 hộp", now - 400 * 86_400_000, 0),
        ] {
            db.execute(
                "INSERT INTO messages (msg_id, thread_id, sender_id, sender_name, text, msg_type, ts, is_outgoing, raw_json) VALUES (?1,?2,?3,?4,?5,'webchat',?6,?7,'')",
                params![id, thread, sender, name, text, ts, out],
            )
            .unwrap();
        }
        std::fs::write(
            dir.join(CONFIG_FILE),
            r#"{"enabled":true,"account":"123","owner_name":"Bá","conversations":[{"id":"111","is_group":false,"name":"Ngọc"},{"id":"222","is_group":true,"name":"Kinh doanh"}]}"#,
        )
        .unwrap();
        dir
    }

    fn call(dir: &Path, tool: &str, args: Value) -> Value {
        let line = json!({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":tool,"arguments":args}}).to_string();
        serde_json::from_str::<Value>(&handle_line(dir, &line).unwrap()).unwrap()["result"].clone()
    }

    fn text(result: &Value) -> String {
        result["content"][0]["text"].as_str().unwrap().to_string()
    }

    #[test]
    fn initialize_and_tool_list_follow_mcp() {
        let dir = fixture();
        let init: Value = serde_json::from_str(&handle_line(&dir, r#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#).unwrap()).unwrap();
        assert_eq!(init["result"]["protocolVersion"], "2025-03-26");
        assert!(handle_line(&dir, r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#).is_none());
        let tools: Value = serde_json::from_str(&handle_line(&dir, r#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#).unwrap()).unwrap();
        assert_eq!(tools["result"]["tools"].as_array().unwrap().len(), 3);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn reads_only_shared_conversations_in_time_order() {
        let dir = fixture();
        let result = call(&dir, "read_messages", json!({"conversation_id": "111", "days": 1}));
        let body = text(&result);
        assert!(body.contains("Ngọc: Mai gửi báo giá nhé"));
        assert!(body.contains("Bá (chủ tài khoản): Ok mình gửi trước 10h"));
        assert!(body.find("báo giá").unwrap() < body.find("trước 10h").unwrap());
        let denied = call(&dir, "read_messages", json!({"conversation_id": "999"}));
        assert_eq!(denied["isError"], true);
        assert!(!text(&denied).contains("riêng tư"));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn search_never_reaches_unshared_threads_and_respects_days() {
        let dir = fixture();
        assert!(text(&call(&dir, "search_messages", json!({"query": "riêng"}))).starts_with("0 kết quả"));
        assert!(text(&call(&dir, "search_messages", json!({"query": "Chốt"}))).contains("[Kinh doanh]"));
        assert!(text(&call(&dir, "search_messages", json!({"query": "Chốt", "days": 30}))).starts_with("0 kết quả"));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn sharing_off_refuses_every_tool() {
        let dir = fixture();
        std::fs::write(dir.join(CONFIG_FILE), r#"{"enabled":false,"account":"123","conversations":[{"id":"111"}]}"#).unwrap();
        assert_eq!(call(&dir, "list_conversations", json!({}))["isError"], true);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn dates_parse_in_local_time() {
        let (from, to) = time_window(&json!({"since": "2026-11-14", "until": "2026-11-14"})).unwrap();
        assert_eq!(to - from, 86_399_000);
        assert!(time_window(&json!({"since": "14/11"})).is_err());
    }
}
