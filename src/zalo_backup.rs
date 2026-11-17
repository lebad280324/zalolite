//! Streaming import of the official Zalo PC export (`backup_zalo_*.zl.zip`).
//!
//! The container is documented in `re-notes/49_zalo_pc_export_container.md`:
//! an AES-256-CBC stream over a tar archive whose `database/` folder holds
//! newline-delimited JSON rows. Media bodies are skipped by seeking, so the
//! archive size does not bound the import.

use std::collections::HashMap;
use std::fs::File;
use std::io::{self, BufRead, BufReader, Read, Seek, SeekFrom};
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};

use aes::cipher::inout::InOutBuf;
use aes::cipher::{BlockDecryptMut, KeyIvInit};
use anyhow::{bail, Context, Result};
use md5::Md5;
use rusqlite::{params, OptionalExtension};
use sha2::{Digest, Sha256};

use crate::store::{MessageStore, StoredMessage, StoredThread};

mod local_key;
pub mod media;

type Aes256CbcDec = cbc::Decryptor<aes::Aes256>;

const BLOCK: u64 = 16;
const TAR_BLOCK: u64 = 512;
const FIRST_FILL: usize = 64 * 1024;
const MAX_FILL: usize = 1024 * 1024;
const MAX_META_BYTES: u64 = 1024 * 1024;
const MAX_LINE_BYTES: usize = 16 * 1024 * 1024;
const BATCH_ROWS: usize = 5_000;

/// Set by the command reader so a long import stops at its next batch boundary.
pub static IMPORT_CANCEL: AtomicBool = AtomicBool::new(false);

/// Failure the person can act on; the wording is safe to show in the UI.
#[derive(Debug)]
pub struct BackupError(pub &'static str);
impl std::fmt::Display for BackupError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(self.0)
    }
}
impl std::error::Error for BackupError {}

/// Outcome of one archive import. Counts are rows, never message content.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct BackupReport {
    pub threads_imported: usize,
    pub messages_imported: usize,
    pub messages_seen: usize,
    pub lines_skipped: usize,
    pub database_files: usize,
    pub legacy_encrypted_files: usize,
    pub entries_skipped: usize,
    pub cancelled: bool,
}

/// Container revision, chosen by Zalo from the file extension.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum ContainerVersion {
    /// `.zip`: Node `createDecipher`, key and IV derived with `EVP_BytesToKey` (MD5).
    V1,
    /// `.zl.zip`: explicit IV `"zie" + key_source[..13]`.
    V2,
}

impl ContainerVersion {
    /// Returns the revision for a file name, or `None` when it is not a Zalo export.
    pub fn from_path(path: &Path) -> Option<Self> {
        let name = path.file_name()?.to_str()?.to_ascii_lowercase();
        if name.ends_with(".zl.zip") {
            Some(Self::V2)
        } else if name.ends_with(".zip") {
            Some(Self::V1)
        } else {
            None
        }
    }
}

/// Derives the AES key and IV exactly as the shipped exporter does.
///
/// # Errors
/// Fails when the account data key is too short to form a V2 IV.
fn derive_key_iv(data_key: &str, version: ContainerVersion) -> Result<([u8; 32], [u8; 16])> {
    let key: [u8; 32] = Sha256::digest(data_key.as_bytes()).into();
    match version {
        ContainerVersion::V2 => {
            let prefix = data_key.as_bytes();
            if prefix.len() < 13 {
                bail!(BackupError(
                    "Khóa dữ liệu của tài khoản không hợp lệ. Hãy đăng nhập lại rồi thử nhập."
                ));
            }
            let mut iv = [0u8; 16];
            iv[..3].copy_from_slice(b"zie");
            iv[3..].copy_from_slice(&prefix[..13]);
            Ok((key, iv))
        }
        ContainerVersion::V1 => {
            // OpenSSL EVP_BytesToKey, MD5, one round, no salt; the password is the SHA-256 digest.
            let d1 = Md5::digest(key);
            let d2 = Md5::new().chain_update(d1).chain_update(key).finalize();
            let d3 = Md5::new().chain_update(d2).chain_update(key).finalize();
            let mut derived = [0u8; 32];
            derived[..16].copy_from_slice(&d1);
            derived[16..].copy_from_slice(&d2);
            Ok((derived, d3.into()))
        }
    }
}

/// Select a key only after its first tar header validates. The PC export key is the
/// `dkey` returned to a PC-type `getLoginInfo` (re-notes/71); a key Zalo PC left in its
/// Local Storage on this Mac is the fallback.
#[cfg_attr(any(test, not(target_os = "macos")), allow(unused_variables))]
pub(crate) fn resolve_export_key(path: &Path, data_key: &str, own_uid: &str) -> Result<String> {
    let version = ContainerVersion::from_path(path)
        .context(BackupError("Định dạng sao lưu không được hỗ trợ."))?;
    let valid = |candidate: &str| -> bool {
        let Ok((key, iv)) = derive_key_iv(candidate, version) else {
            return false;
        };
        let Ok(mut reader) = CbcReader::open(path, key, iv) else {
            return false;
        };
        let mut header = [0u8; 512];
        reader.read_exact(&mut header).is_ok() && checksum_matches(&header)
    };
    if valid(data_key) {
        return Ok(data_key.to_owned());
    }
    #[cfg(all(target_os = "macos", not(test)))]
    if let Some(home) = std::env::var_os("HOME") {
        let directory = std::path::PathBuf::from(home)
            .join("Library/Application Support/ZaloData/Partitions/zalo/Local Storage/leveldb");
        for candidate in local_key::candidates(&directory, own_uid) {
            if valid(&candidate) {
                return Ok(candidate);
            }
        }
    }
    Err(BackupError("Không mở được tệp sao lưu bằng khóa của tài khoản đang đăng nhập. Hãy chắc tệp được xuất từ chính tài khoản này trong Zalo PC và đã xuất xong, rồi thử lại.").into())
}

/// Sequential plaintext view of the CBC stream that can jump over file bodies.
struct CbcReader {
    file: File,
    key: [u8; 32],
    iv: [u8; 16],
    cipher_len: u64,
    /// Ciphertext offset of the next block to read from `file`.
    cipher_pos: u64,
    cipher: Aes256CbcDec,
    buffer: Vec<u8>,
    start: usize,
    end: usize,
    next_fill: usize,
}

impl CbcReader {
    fn open(path: &Path, key: [u8; 32], iv: [u8; 16]) -> Result<Self> {
        let file = File::open(path).context(BackupError("Không mở được tệp sao lưu."))?;
        let cipher_len = file.metadata()?.len();
        if cipher_len < TAR_BLOCK || cipher_len % BLOCK != 0 {
            bail!(BackupError(
                "Tệp sao lưu chưa hoàn chỉnh hoặc không phải bản xuất dữ liệu của Zalo."
            ));
        }
        Ok(Self {
            file,
            key,
            iv,
            cipher_len,
            cipher_pos: 0,
            cipher: Aes256CbcDec::new(&key.into(), &iv.into()),
            buffer: vec![0; MAX_FILL],
            start: 0,
            end: 0,
            next_fill: FIRST_FILL,
        })
    }

    /// Plaintext offset of the next byte `read` returns.
    fn position(&self) -> u64 {
        self.cipher_pos - (self.end - self.start) as u64
    }

    fn fill(&mut self) -> io::Result<()> {
        let remaining = self.cipher_len - self.cipher_pos;
        let want = remaining.min(self.next_fill as u64) as usize;
        self.start = 0;
        self.end = 0;
        if want == 0 {
            return Ok(());
        }
        self.file.read_exact(&mut self.buffer[..want])?;
        self.cipher_pos += want as u64;
        let (blocks, _) = InOutBuf::from(&mut self.buffer[..want]).into_chunks();
        self.cipher.decrypt_blocks_inout_mut(blocks);
        self.end = want;
        if self.cipher_pos == self.cipher_len {
            // Lenient PKCS#7: a tar stream already ends in zero blocks.
            let pad = self.buffer[want - 1] as usize;
            if (1..=16).contains(&pad)
                && self.buffer[want - pad..want]
                    .iter()
                    .all(|b| *b as usize == pad)
            {
                self.end = want - pad;
            }
        }
        self.next_fill = (self.next_fill * 4).min(MAX_FILL);
        Ok(())
    }

    /// Moves forward without decrypting the skipped blocks.
    fn skip(&mut self, mut count: u64) -> io::Result<()> {
        let buffered = (self.end - self.start) as u64;
        if count <= buffered {
            self.start += count as usize;
            return Ok(());
        }
        count -= buffered;
        let target = self.cipher_pos + count;
        if target > self.cipher_len {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "archive entry exceeds file",
            ));
        }
        let block_start = target - target % BLOCK;
        // CBC only needs the preceding ciphertext block to resume.
        let mut iv = self.iv;
        if block_start >= BLOCK {
            self.file.seek(SeekFrom::Start(block_start - BLOCK))?;
            self.file.read_exact(&mut iv)?;
        } else {
            self.file.seek(SeekFrom::Start(0))?;
        }
        self.cipher = Aes256CbcDec::new(&self.key.into(), &iv.into());
        self.cipher_pos = block_start;
        self.start = 0;
        self.end = 0;
        self.next_fill = FIRST_FILL;
        let inside = (target - block_start) as usize;
        if inside > 0 {
            self.fill()?;
            if self.end < inside {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "archive entry exceeds file",
                ));
            }
            self.start = inside;
        }
        Ok(())
    }
}

impl Read for CbcReader {
    fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
        if self.start == self.end {
            self.fill()?;
            if self.end == 0 {
                return Ok(0);
            }
        }
        let count = out.len().min(self.end - self.start);
        out[..count].copy_from_slice(&self.buffer[self.start..self.start + count]);
        self.start += count;
        Ok(count)
    }
}

struct TarEntry {
    path: String,
    size: u64,
    kind: u8,
}

fn field_text(bytes: &[u8]) -> String {
    let end = bytes.iter().position(|b| *b == 0).unwrap_or(bytes.len());
    String::from_utf8_lossy(&bytes[..end]).into_owned()
}

fn field_number(bytes: &[u8]) -> Option<u64> {
    if bytes.first().is_some_and(|b| b & 0x80 != 0) {
        // GNU base-256 for sizes beyond the octal field.
        let mut value = u64::from(bytes[0] & 0x7f);
        for byte in &bytes[1..] {
            value = value.checked_mul(256)?.checked_add(u64::from(*byte))?;
        }
        return Some(value);
    }
    let text = field_text(bytes);
    let text = text.trim();
    if text.is_empty() {
        return Some(0);
    }
    u64::from_str_radix(text, 8).ok()
}

fn checksum_matches(header: &[u8; 512]) -> bool {
    let Some(expected) = field_number(&header[148..156]) else {
        return false;
    };
    let sum: u64 = header
        .iter()
        .enumerate()
        .map(|(index, byte)| {
            if (148..156).contains(&index) {
                32
            } else {
                u64::from(*byte)
            }
        })
        .sum();
    sum == expected
}

/// Reads the next header, folding pax and GNU long-name records into the entry.
fn next_entry(reader: &mut CbcReader, first: bool) -> Result<Option<TarEntry>> {
    let mut path_override: Option<String> = None;
    let mut size_override: Option<u64> = None;
    loop {
        let mut header = [0u8; 512];
        match reader.read_exact(&mut header) {
            Ok(()) => {}
            Err(error) if error.kind() == io::ErrorKind::UnexpectedEof && !first => {
                return Ok(None)
            }
            Err(error) => return Err(error.into()),
        }
        if header.iter().all(|byte| *byte == 0) {
            return Ok(None);
        }
        if !checksum_matches(&header) {
            if first {
                bail!(BackupError(
                    "Header sao lưu không hợp lệ: khóa xuất dữ liệu chưa phù hợp hoặc tệp chưa hoàn chỉnh."
                ));
            }
            bail!(BackupError(
                "Tệp sao lưu bị hỏng giữa chừng. Hãy xuất lại từ Zalo."
            ));
        }
        let size = field_number(&header[124..136]).context(BackupError(
            "Tệp sao lưu bị hỏng giữa chừng. Hãy xuất lại từ Zalo.",
        ))?;
        let kind = header[156];
        let padded = size.div_ceil(TAR_BLOCK) * TAR_BLOCK;
        match kind {
            b'x' | b'L' => {
                if size > MAX_META_BYTES {
                    bail!(BackupError("Tệp sao lưu chứa tên tệp không hợp lệ."));
                }
                let mut body = vec![0u8; size as usize];
                reader.read_exact(&mut body)?;
                reader.skip(padded - size)?;
                if kind == b'L' {
                    path_override = Some(field_text(&body));
                } else {
                    for (key, value) in pax_records(&body) {
                        match key.as_str() {
                            "path" => path_override = Some(value),
                            "size" => size_override = value.parse().ok(),
                            _ => {}
                        }
                    }
                }
            }
            b'g' | b'K' => reader.skip(padded)?,
            _ => {
                let name = field_text(&header[..100]);
                let prefix = if &header[257..262] == b"ustar" {
                    field_text(&header[345..500])
                } else {
                    String::new()
                };
                let path = path_override.take().unwrap_or(if prefix.is_empty() {
                    name
                } else {
                    format!("{prefix}/{name}")
                });
                return Ok(Some(TarEntry {
                    path,
                    size: size_override.take().unwrap_or(size),
                    kind,
                }));
            }
        }
    }
}

fn pax_records(body: &[u8]) -> Vec<(String, String)> {
    let mut records = Vec::new();
    let mut rest = body;
    while let Some(space) = rest.iter().position(|byte| *byte == b' ') {
        let Some(length) = std::str::from_utf8(&rest[..space])
            .ok()
            .and_then(|text| text.parse::<usize>().ok())
        else {
            break;
        };
        if length <= space + 1 || length > rest.len() {
            break;
        }
        let record = &rest[space + 1..length];
        let record = record.strip_suffix(b"\n").unwrap_or(record);
        if let Some(equals) = record.iter().position(|byte| *byte == b'=') {
            records.push((
                String::from_utf8_lossy(&record[..equals]).into_owned(),
                String::from_utf8_lossy(&record[equals + 1..]).into_owned(),
            ));
        }
        rest = &rest[length..];
    }
    records
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Table {
    Message,
    Conversation,
    LegacyEncrypted,
}

/// Classifies `<uid>/ZaloDownloads/database/<uid>_z<table>.<ext>`.
fn database_table(path: &str) -> Option<Table> {
    let lower = path.to_ascii_lowercase();
    let name = lower.rsplit('/').next()?;
    let (stem, extension) = name.rsplit_once('.')?;
    let table = stem.rsplit_once("_z")?.1;
    match extension {
        "zb" => Some(Table::LegacyEncrypted),
        "zdb" if table == "message" => Some(Table::Message),
        "zdb" if table == "conversation" => Some(Table::Conversation),
        _ => None,
    }
}

fn text_of(value: Option<&serde_json::Value>) -> String {
    match value {
        Some(serde_json::Value::String(text)) => text.clone(),
        Some(serde_json::Value::Number(number)) => number.to_string(),
        _ => String::new(),
    }
}

/// Strips Zalo's group prefix so imported rows join the live thread of the same group.
fn conversation_identity(raw: &str) -> (String, bool) {
    match raw.strip_prefix('g') {
        Some(rest) if !rest.is_empty() && rest.bytes().all(|byte| byte.is_ascii_digit()) => {
            (rest.to_owned(), true)
        }
        _ => (raw.to_owned(), false),
    }
}

/// Wording for an exported group membership event, as Zalo shows it.
fn membership_line(row: &serde_json::Value) -> Option<String> {
    let info = row.get("eventInfo")?;
    let names: Vec<String> = info
        .get("updateMembers")?
        .as_array()?
        .iter()
        .filter_map(|member| member.get("dName").and_then(|v| v.as_str()).map(str::to_owned))
        .filter(|name| !name.trim().is_empty())
        .collect();
    if names.is_empty() {
        return None;
    }
    let members = names.join(", ");
    let source = info
        .get("source")
        .and_then(|source| source.get("dName"))
        .and_then(|v| v.as_str())
        .filter(|name| !name.trim().is_empty());
    let line = match (text_of(row.get("act")).as_str(), source) {
        ("join", Some(source)) if !names.iter().any(|n| n == source) => format!("{members} được {source} thêm vào nhóm"),
        ("join", _) => format!("{members} đã tham gia nhóm"),
        ("add", Some(source)) => format!("{source} đã thêm {members} vào nhóm"),
        ("leave", _) => format!("{members} đã rời khỏi nhóm"),
        ("remove", Some(source)) => format!("{source} đã xóa {members} khỏi nhóm"),
        _ => return None,
    };
    Some(line)
}

/// Maps one exported message row; `None` when it carries no conversation or content.
fn message_from_row(row: &serde_json::Value, own_uid: &str) -> Option<StoredMessage> {
    let conversation = {
        let user_id = text_of(row.get("userId"));
        if user_id.is_empty() {
            text_of(row.get("toUid"))
        } else {
            user_id
        }
    };
    let payload = row.get("message").filter(|value| !value.is_null())?;
    if conversation.is_empty() {
        return None;
    }
    let (thread_id, _) = conversation_identity(&conversation);
    let from_uid = text_of(row.get("fromUid"));
    let is_outgoing = from_uid.is_empty() || from_uid == "0" || from_uid == own_uid;
    let kind = match row.get("msgType") {
        Some(serde_json::Value::Number(number)) => number.as_i64().unwrap_or(1),
        Some(serde_json::Value::String(text)) => text.parse().unwrap_or(match text.as_str() {
            "chat.photo" => 2,
            "chat.sticker" => 4,
            "chat.recommended" | "chat.link" => 6,
            "chat.video.msg" | "chat.video" => 18,
            "share.file" => 19,
            _ => 1,
        }),
        _ => 1,
    };
    let structured = !payload.is_string();
    let raw = match payload {
        serde_json::Value::String(text) => text.clone(),
        other => other.to_string(),
    };
    let (mut text, mut meta) = crate::store::zalo_pc_text_and_meta(&raw, kind);
    if structured && text == raw {
        // An unrecognised attachment must not surface its raw JSON as message text.
        text = "[Nội dung không hỗ trợ]".into();
    }
    if let Some(card) = meta.get("card").filter(|card| card["kind"] == "call") {
        text = crate::chat::call_text(
            card["duration"].as_i64().unwrap_or(0),
            card["video"].as_bool().unwrap_or(false),
            card["missed"].as_bool().unwrap_or(false),
            is_outgoing,
        );
    }
    // Group membership events (`msgType -4`) carry only member names as their message.
    if kind == -4 {
        if let Some(line) = membership_line(row) {
            text = line;
            meta.insert("card".into(), serde_json::json!({"kind":"notice"}));
        }
    }
    match row.get("quote") {
        Some(serde_json::Value::String(quote)) if !quote.is_empty() => {
            meta.insert("quote".into(), serde_json::Value::String(quote.clone()));
        }
        Some(quote @ serde_json::Value::Object(_)) => {
            meta.insert("quote".into(), serde_json::Value::String(quote.to_string()));
        }
        _ => {}
    }
    let timestamp = match row.get("sendDttm") {
        Some(serde_json::Value::Number(number)) => number.as_i64().unwrap_or(0),
        Some(serde_json::Value::String(text)) => text.parse().unwrap_or(0),
        _ => 0,
    };
    let message_id = {
        let id = text_of(row.get("msgId"));
        if id.is_empty() {
            text_of(row.get("cliMsgId"))
        } else {
            id
        }
    };
    if message_id.is_empty() {
        return None;
    }
    let display_name = text_of(row.get("dName"));
    Some(StoredMessage {
        msg_id: message_id,
        thread_id,
        sender_id: if is_outgoing { "0".into() } else { from_uid },
        sender_name: if !display_name.is_empty() {
            display_name
        } else if is_outgoing {
            "Tôi".into()
        } else {
            String::new()
        },
        text,
        msg_type: match kind {
            2 => "chat.photo",
            4 => "chat.sticker",
            6 => "chat.link",
            18 => "chat.video",
            19 => "chat.file",
            _ => "chat.text",
        }
        .into(),
        ts: timestamp,
        is_outgoing,
        raw_json: if meta.is_empty() {
            String::new()
        } else {
            serde_json::Value::Object(meta).to_string()
        },
    })
}

#[derive(Default)]
struct ThreadSummary {
    is_group: bool,
    last_ts: i64,
    peer_name: Option<String>,
}

/// Imports message rows from a Zalo PC export into `db_path`.
///
/// `progress` receives a fraction in `0.0..=1.0` and the rows read so far.
///
/// # Errors
/// Returns a [`BackupError`] for a wrong account key, a truncated or corrupt
/// archive, or an export without message data; other errors are I/O or SQLite.
/// Read-only survey of an export: entry counts and bytes by folder, a few media paths, and how the
/// message rows refer to their attachments (`localPath`). Used to plan the media import.
pub fn inspect_export(path: &Path, data_key: &str, own_uid: &str) -> Result<serde_json::Value> {
    let version = ContainerVersion::from_path(path)
        .context(BackupError("Hãy chọn tệp .zl.zip do Zalo xuất ra."))?;
    let selected_key = resolve_export_key(path, data_key, own_uid)?;
    let (key, iv) = derive_key_iv(&selected_key, version)?;
    let mut reader = CbcReader::open(path, key, iv)?;
    let mut folders: std::collections::BTreeMap<String, (u64, u64)> = Default::default();
    let mut samples = Vec::new();
    let mut local_paths = Vec::new();
    let mut rows_with_local = 0u64;
    let mut first = true;
    let mut line = Vec::new();
    while let Some(entry) = next_entry(&mut reader, first)? {
        first = false;
        let padding = entry.size.div_ceil(TAR_BLOCK) * TAR_BLOCK - entry.size;
        let folder = entry.path.split('/').take(3).collect::<Vec<_>>().join("/");
        let slot = folders.entry(folder).or_default();
        slot.0 += 1;
        slot.1 += entry.size;
        let is_message = matches!(entry.kind, b'0' | 0) && matches!(database_table(&entry.path), Some(Table::Message));
        if !is_message && samples.len() < 12 && entry.size > 0 && !entry.path.contains("/database/") {
            samples.push(serde_json::json!({"path": entry.path, "size": entry.size}));
        }
        if is_message {
            let mut rows = BufReader::with_capacity(MAX_FILL, (&mut reader).take(entry.size));
            loop {
                line.clear();
                if (&mut rows).take(MAX_LINE_BYTES as u64 + 1).read_until(b'\n', &mut line)? == 0 {
                    break;
                }
                if let Ok(row) = serde_json::from_slice::<serde_json::Value>(line.strip_suffix(b"\n").unwrap_or(&line)) {
                    let local = text_of(row.get("localPath"));
                    if !local.is_empty() {
                        rows_with_local += 1;
                        if local_paths.len() < 8 {
                            local_paths.push(serde_json::json!({"msgType": row.get("msgType"), "localPath": local}));
                        }
                    }
                }
            }
            let unread = rows.get_ref().limit();
            drop(rows);
            reader.skip(unread + padding)?;
        } else {
            reader.skip(entry.size + padding)?;
        }
    }
    let folders: Vec<_> = folders
        .into_iter()
        .map(|(name, (count, bytes))| serde_json::json!({"folder": name, "entries": count, "bytes": bytes}))
        .collect();
    Ok(serde_json::json!({"folders": folders, "media_samples": samples, "rows_with_local_path": rows_with_local, "local_path_samples": local_paths}))
}

/// Read-only survey of message payload shapes: per `msgType`, how often each key signature and
/// `action` occurs, with redacted samples (strings cut to 10 characters). Diagnostic only.
pub fn survey_message_shapes(path: &Path, data_key: &str, own_uid: &str, thread: Option<&str>) -> Result<serde_json::Value> {
    fn redact(value: &serde_json::Value, depth: usize) -> serde_json::Value {
        match value {
            serde_json::Value::String(text) => {
                let trimmed = text.trim();
                if depth < 3 && trimmed.starts_with('{') {
                    if let Ok(inner) = serde_json::from_str::<serde_json::Value>(trimmed) {
                        return serde_json::json!({"<json>": redact(&inner, depth + 1)});
                    }
                }
                serde_json::Value::String(text.chars().take(10).collect())
            }
            serde_json::Value::Object(map) => serde_json::Value::Object(
                map.iter().map(|(k, v)| (k.clone(), redact(v, depth + 1))).collect(),
            ),
            serde_json::Value::Array(items) => serde_json::Value::Array(items.iter().take(3).map(|v| redact(v, depth + 1)).collect()),
            other => other.clone(),
        }
    }
    let version = ContainerVersion::from_path(path).context(BackupError("Hãy chọn tệp .zl.zip do Zalo xuất ra."))?;
    let selected_key = resolve_export_key(path, data_key, own_uid)?;
    let (key, iv) = derive_key_iv(&selected_key, version)?;
    let mut reader = CbcReader::open(path, key, iv)?;
    let mut shapes: std::collections::BTreeMap<String, (u64, Vec<serde_json::Value>)> = Default::default();
    let mut first = true;
    let mut line = Vec::new();
    while let Some(entry) = next_entry(&mut reader, first)? {
        first = false;
        let padding = entry.size.div_ceil(TAR_BLOCK) * TAR_BLOCK - entry.size;
        let is_message = matches!(entry.kind, b'0' | 0) && matches!(database_table(&entry.path), Some(Table::Message));
        if !is_message {
            reader.skip(entry.size + padding)?;
            continue;
        }
        let mut rows = BufReader::with_capacity(MAX_FILL, (&mut reader).take(entry.size));
        loop {
            line.clear();
            if (&mut rows).take(MAX_LINE_BYTES as u64 + 1).read_until(b'\n', &mut line)? == 0 {
                break;
            }
            let Ok(row) = serde_json::from_slice::<serde_json::Value>(line.strip_suffix(b"\n").unwrap_or(&line)) else { continue };
            let conversation = { let id = text_of(row.get("userId")); if id.is_empty() { text_of(row.get("toUid")) } else { id } };
            if let Some(wanted) = thread {
                if conversation_identity(&conversation).0 != wanted { continue; }
            }
            let payload = row.get("message").cloned().unwrap_or_default();
            let parsed = match &payload {
                serde_json::Value::String(text) => serde_json::from_str::<serde_json::Value>(text.trim()).unwrap_or(serde_json::Value::Null),
                other => other.clone(),
            };
            let signature = match &parsed {
                serde_json::Value::Object(map) => {
                    let action = map.get("action").and_then(|v| v.as_str()).unwrap_or("");
                    format!("{}|{}|{}", text_of(row.get("msgType")), action, map.keys().cloned().collect::<Vec<_>>().join(","))
                }
                _ => format!("{}|<text>", text_of(row.get("msgType"))),
            };
            let slot = shapes.entry(signature).or_default();
            slot.0 += 1;
            if slot.1.len() < 2 && !parsed.is_object() {
                let filled: serde_json::Map<String, serde_json::Value> = row.as_object().map(|m| m.iter()
                    .filter(|(_, v)| !(v.is_null() || v.as_str() == Some("") || v.as_array().is_some_and(|a| a.is_empty()) || v.as_object().is_some_and(|o| o.is_empty())))
                    .map(|(k, v)| (k.clone(), redact(v, 0))).collect()).unwrap_or_default();
                slot.1.push(serde_json::Value::Object(filled));
            }
            if slot.1.len() < 2 && parsed.is_object() {
                let mut sample = serde_json::Map::new();
                for key in ["msgType", "subType", "type"] { if let Some(v) = row.get(key) { sample.insert(key.into(), v.clone()); } }
                sample.insert("row_keys".into(), serde_json::json!(row.as_object().map(|m| m.keys().cloned().collect::<Vec<_>>())));
                sample.insert("message".into(), redact(&parsed, 0));
                slot.1.push(serde_json::Value::Object(sample));
            }
        }
        let unread = rows.get_ref().limit();
        drop(rows);
        reader.skip(unread + padding)?;
    }
    Ok(serde_json::Value::Array(shapes.into_iter().map(|(sig, (n, samples))| serde_json::json!({"signature": sig, "count": n, "samples": samples})).collect()))
}

pub fn import_zalo_export(
    path: &Path,
    data_key: &str,
    own_uid: &str,
    db_path: &str,
    mut progress: impl FnMut(f64, usize),
) -> Result<BackupReport> {
    let version = ContainerVersion::from_path(path)
        .context(BackupError("Hãy chọn tệp .zl.zip do Zalo xuất ra."))?;
    let selected_key = resolve_export_key(path, data_key, own_uid)?;
    let (key, iv) = derive_key_iv(&selected_key, version)?;
    let mut reader = CbcReader::open(path, key, iv)?;
    let total = reader.cipher_len.max(1);
    let mut store = MessageStore::open(db_path)?;
    let mut report = BackupReport::default();
    let mut threads: HashMap<String, ThreadSummary> = HashMap::new();
    let mut first = true;
    let mut line = Vec::new();
    while let Some(entry) = next_entry(&mut reader, first)? {
        first = false;
        let padding = entry.size.div_ceil(TAR_BLOCK) * TAR_BLOCK - entry.size;
        let table = if matches!(entry.kind, b'0' | 0) {
            database_table(&entry.path)
        } else {
            None
        };
        match table {
            Some(Table::Message) => {
                report.database_files += 1;
                let entry_start = reader.position();
                let mut rows = BufReader::with_capacity(MAX_FILL, (&mut reader).take(entry.size));
                let mut pending = 0usize;
                store.conn.execute_batch("BEGIN")?;
                let outcome = (|| -> Result<()> {
                    loop {
                        line.clear();
                        // A bounded read keeps one malformed row from exhausting memory.
                        let read = (&mut rows)
                            .take(MAX_LINE_BYTES as u64 + 1)
                            .read_until(b'\n', &mut line)?;
                        if read == 0 {
                            return Ok(());
                        }
                        if line.len() > MAX_LINE_BYTES && line.last() != Some(&b'\n') {
                            report.lines_skipped += 1;
                            let mut sink = Vec::new();
                            loop {
                                sink.clear();
                                let more = (&mut rows)
                                    .take(MAX_LINE_BYTES as u64)
                                    .read_until(b'\n', &mut sink)?;
                                if more == 0 || sink.last() == Some(&b'\n') {
                                    break;
                                }
                            }
                            continue;
                        }
                        let trimmed = line.strip_suffix(b"\n").unwrap_or(&line);
                        if trimmed.iter().all(u8::is_ascii_whitespace) {
                            continue;
                        }
                        report.messages_seen += 1;
                        let message = serde_json::from_slice::<serde_json::Value>(trimmed)
                            .ok()
                            .and_then(|row| {
                                let (_, is_group) = conversation_identity(&{
                                    let id = text_of(row.get("userId"));
                                    if id.is_empty() {
                                        text_of(row.get("toUid"))
                                    } else {
                                        id
                                    }
                                });
                                message_from_row(&row, own_uid).map(|message| (message, is_group))
                            });
                        let Some((message, is_group)) = message else {
                            report.lines_skipped += 1;
                            continue;
                        };
                        let summary = threads.entry(message.thread_id.clone()).or_default();
                        summary.is_group |= is_group;
                        summary.last_ts = summary.last_ts.max(message.ts);
                        if !is_group
                            && !message.is_outgoing
                            && summary.peer_name.is_none()
                            && !message.sender_name.is_empty()
                        {
                            summary.peer_name = Some(message.sender_name.clone());
                        }
                        if store.upsert_message(&message)? {
                            report.messages_imported += 1;
                        }
                        pending += 1;
                        if pending >= BATCH_ROWS {
                            pending = 0;
                            store.conn.execute_batch("COMMIT; BEGIN")?;
                            let consumed =
                                entry_start + (entry.size - rows.get_ref().limit()).min(entry.size);
                            progress(consumed as f64 / total as f64, report.messages_seen);
                            if IMPORT_CANCEL.load(Ordering::Relaxed) {
                                report.cancelled = true;
                                return Ok(());
                            }
                        }
                    }
                })();
                store.conn.execute_batch(if outcome.is_ok() {
                    "COMMIT"
                } else {
                    "ROLLBACK"
                })?;
                outcome?;
                if report.cancelled {
                    break;
                }
                // Drain whatever the row reader left, then realign to the next header.
                let unread = rows.get_ref().limit();
                drop(rows);
                reader.skip(unread + padding)?;
            }
            Some(Table::LegacyEncrypted) => {
                report.legacy_encrypted_files += 1;
                reader.skip(entry.size + padding)?;
            }
            // Conversation rows carry counters only, never names; live threads supply those.
            Some(Table::Conversation) | None => {
                report.entries_skipped += 1;
                reader.skip(entry.size + padding)?;
            }
        }
        progress(
            reader.position() as f64 / total as f64,
            report.messages_seen,
        );
        if IMPORT_CANCEL.load(Ordering::Relaxed) {
            report.cancelled = true;
            break;
        }
    }
    if first {
        bail!(BackupError("Tệp sao lưu trống."));
    }
    store.conn.execute_batch("BEGIN")?;
    let saved = (|| -> Result<()> {
        for (thread_id, summary) in &threads {
            let existing: Option<String> = store
                .conn
                .query_row(
                    "SELECT name FROM threads WHERE thread_id = ?1",
                    params![thread_id],
                    |row| row.get(0),
                )
                .optional()?;
            // A name already known to this account is never replaced by a guess.
            let name = match existing.filter(|name| !name.is_empty()) {
                Some(name) => name,
                None => summary.peer_name.clone().unwrap_or_else(|| {
                    if summary.is_group {
                        format!("Nhóm {thread_id}")
                    } else {
                        format!("Người dùng {thread_id}")
                    }
                }),
            };
            store.upsert_thread(&StoredThread {
                thread_id: thread_id.clone(),
                name,
                is_group: summary.is_group,
                last_ts: summary.last_ts,
            })?;
        }
        Ok(())
    })();
    store
        .conn
        .execute_batch(if saved.is_ok() { "COMMIT" } else { "ROLLBACK" })?;
    saved?;
    report.threads_imported = threads.len();
    if report.database_files == 0 && !report.cancelled {
        if report.legacy_encrypted_files > 0 {
            bail!(BackupError(
                "Bản sao lưu dùng định dạng cũ (.zb) chưa được hỗ trợ. Hãy xuất lại bằng Zalo bản mới."
            ));
        }
        bail!(BackupError(
            "Tệp sao lưu không chứa tin nhắn. Hãy chọn mục Tin nhắn khi xuất dữ liệu từ Zalo."
        ));
    }
    Ok(report)
}

#[cfg(test)]
mod tests {
    use super::*;
    use aes::cipher::{block_padding::Pkcs7, BlockEncryptMut};

    fn tar_header(path: &str, size: u64, kind: u8) -> [u8; 512] {
        let mut header = [0u8; 512];
        let (prefix, name) = match path.len() > 100 {
            true => path.split_at(path[..path.len() - 1].rfind('/').unwrap()),
            false => ("", path),
        };
        let name = name.trim_start_matches('/');
        header[..name.len()].copy_from_slice(name.as_bytes());
        header[100..107].copy_from_slice(b"0000644");
        header[124..135].copy_from_slice(format!("{size:011o}").as_bytes());
        header[156] = kind;
        header[257..263].copy_from_slice(b"ustar\0");
        header[345..345 + prefix.len()].copy_from_slice(prefix.as_bytes());
        header[148..156].copy_from_slice(b"        ");
        let sum: u32 = header.iter().map(|byte| u32::from(*byte)).sum();
        header[148..155].copy_from_slice(format!("{sum:06o}\0").as_bytes());
        header
    }

    fn append(archive: &mut Vec<u8>, path: &str, body: &[u8]) {
        archive.extend_from_slice(&tar_header(path, body.len() as u64, b'0'));
        archive.extend_from_slice(body);
        archive.resize(archive.len().div_ceil(512) * 512, 0);
    }

    fn write_export(
        directory: &Path,
        name: &str,
        data_key: &str,
        archive: &[u8],
    ) -> std::path::PathBuf {
        let version = ContainerVersion::from_path(Path::new(name)).unwrap();
        let (key, iv) = derive_key_iv(data_key, version).unwrap();
        let mut buffer = archive.to_vec();
        buffer.resize(archive.len() + 16, 0);
        let encrypted = cbc::Encryptor::<aes::Aes256>::new(&key.into(), &iv.into())
            .encrypt_padded_mut::<Pkcs7>(&mut buffer, archive.len())
            .unwrap();
        let path = directory.join(name);
        std::fs::write(&path, encrypted).unwrap();
        path
    }

    fn scratch(label: &str) -> std::path::PathBuf {
        let directory =
            std::env::temp_dir().join(format!("ctdo-zalo-backup-{label}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&directory);
        std::fs::create_dir_all(&directory).unwrap();
        directory
    }

    fn sample_archive(rows: usize) -> Vec<u8> {
        let mut archive = Vec::new();
        // A media body larger than one fill exercises the seek path between entries.
        append(
            &mut archive,
            "1000/ZaloDownloads/picture/sample.jpg",
            &vec![7u8; 300_000],
        );
        let long = format!(
            "1000/ZaloDownloads/file/{}/{}.bin",
            "d".repeat(80),
            "n".repeat(60)
        );
        append(&mut archive, &long, &[1, 2, 3]);
        let mut messages = String::new();
        for index in 0..rows {
            messages.push_str(
                &serde_json::json!({
                    "userId": if index % 2 == 0 { "2000" } else { "g3000" },
                    "msgId": format!("m{index}"), "cliMsgId": format!("c{index}"),
                    "fromUid": if index % 3 == 0 { "0" } else { "2000" }, "toUid": "2000",
                    "dName": if index % 3 == 0 { "" } else { "Người thử" },
                    "msgType": 1, "sendDttm": (1_700_000_000_000i64 + index as i64).to_string(),
                    "message": format!("Tin thử {index}"),
                })
                .to_string(),
            );
            messages.push('\n');
        }
        messages.push_str("{broken\n");
        messages.push_str(&serde_json::json!({"userId":"2000","msgId":"photo","fromUid":"2000","msgType":2,"sendDttm":1_700_000_100_000i64,
            "message":{"oriUrl":"https://example.invalid/a.jpg","thumbUrl":"https://example.invalid/t.jpg"}}).to_string());
        append(
            &mut archive,
            "1000/ZaloDownloads/database/1000_zmessage.zdb",
            messages.as_bytes(),
        );
        append(
            &mut archive,
            "1000/ZaloDownloads/database/1000_zconversation.zdb",
            b"{\"userId\":\"2000\",\"numMsg\":3}\n",
        );
        archive.extend_from_slice(&[0u8; 1024]);
        archive
    }

    #[test]
    fn media_import_copies_resources_links_messages_and_skips_repeats() {
        let directory = scratch("media");
        let mut archive = Vec::new();
        let photo = vec![7u8; 3000];
        append(&mut archive, "1000/ZaloDownloads/resource/2000/picture/1700000000000_2000_2000_aa.jxl", &photo);
        append(&mut archive, "1000/ZaloDownloads/resource/2000/picture/.rescache", b"index");
        append(&mut archive, "1000/ZaloDownloads/file/0123456789abcdef0123456789abcdef", b"duplicate");
        append(&mut archive, "1000/ZaloDownloads/resource/2000/file/1700000100000_1000_2000", b"%PDF-1.4");
        let mut messages = String::new();
        messages.push_str(&serde_json::json!({"userId":"2000","msgId":"photo-1","fromUid":"2000","msgType":2,"sendDttm":1_700_000_001_000i64,
            "message":{"href":"https://example.invalid/p.jpg","thumb":"https://example.invalid/p.jpg"}}).to_string());
        messages.push('\n');
        messages.push_str(&serde_json::json!({"userId":"2000","msgId":"file-1","fromUid":"1000","msgType":19,"sendDttm":1_700_000_100_400i64,
            "message":{"title":"Bao_cao.pdf","href":"https://example.invalid/f"}}).to_string());
        messages.push('\n');
        append(&mut archive, "1000/ZaloDownloads/database/1000_zmessage.zdb", messages.as_bytes());
        let path = write_export(&directory, "backup_zalo_02_01_2026.zl.zip", "0123456789abcdef0123", &archive);
        let database = directory.join("history.db");
        let database = database.to_str().unwrap();
        import_zalo_export(&path, "0123456789abcdef0123", "1000", database, |_, _| {}).unwrap();
        let media_root = directory.join("media");
        let report = media::import_zalo_media(&path, "0123456789abcdef0123", "1000", database, &media_root, |_, _| {}).unwrap();
        assert_eq!(report.files_written, 2, "only resource/ bodies are copied; file/ repeats them");
        assert_eq!(report.messages_linked, 2);
        assert_eq!(std::fs::read(media_root.join("resource/2000/picture/1700000000000_2000_2000_aa.jxl")).unwrap(), photo);
        // The document gets its extension back from the message's file name.
        assert!(media_root.join("resource/2000/file/1700000100000_1000_2000.pdf").exists());
        let store = MessageStore::open(database).unwrap();
        let linked: String = store.conn.query_row("SELECT raw_json FROM messages WHERE msg_id = 'photo-1'", [], |row| row.get(0)).unwrap();
        assert!(linked.contains("1700000000000_2000_2000_aa.jxl"), "{linked}");
        let again = media::import_zalo_media(&path, "0123456789abcdef0123", "1000", database, &media_root, |_, _| {}).unwrap();
        assert_eq!(again.files_written, 0, "a repeat import copies nothing");
        assert_eq!(again.files_already_present, 2);
        assert_eq!(again.messages_linked, 2);
        let _ = std::fs::remove_dir_all(directory);
    }

    #[test]
    fn imports_rows_across_skipped_media_and_is_idempotent() {
        let directory = scratch("import");
        let path = write_export(
            &directory,
            "backup_zalo_01_01_2026.zl.zip",
            "0123456789abcdef0123",
            &sample_archive(12_001),
        );
        let database = directory.join("history.db");
        let database = database.to_str().unwrap();
        let mut last = 0.0;
        let report = import_zalo_export(
            &path,
            "0123456789abcdef0123",
            "1000",
            database,
            |fraction, _| {
                assert!(fraction >= last && fraction <= 1.0);
                last = fraction;
            },
        )
        .unwrap();
        assert_eq!(report.messages_imported, 12_002);
        assert_eq!(report.lines_skipped, 1);
        assert_eq!(report.threads_imported, 2);
        assert_eq!(report.database_files, 1);
        let store = MessageStore::open(database).unwrap();
        let (group, name): (i64, String) = store
            .conn
            .query_row(
                "SELECT is_group, name FROM threads WHERE thread_id = '3000'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!((group, name.as_str()), (1, "Nhóm 3000"));
        let peer: String = store
            .conn
            .query_row(
                "SELECT name FROM threads WHERE thread_id = '2000'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(peer, "Người thử");
        let (kind, outgoing): (String, i64) = store
            .conn
            .query_row(
                "SELECT msg_type, is_outgoing FROM messages WHERE msg_id = 'photo'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!((kind.as_str(), outgoing), ("chat.photo", 0));
        drop(store);
        let again =
            import_zalo_export(&path, "0123456789abcdef0123", "1000", database, |_, _| {}).unwrap();
        assert_eq!(again.messages_imported, 0);
        assert_eq!(again.messages_seen, report.messages_seen);
        let _ = std::fs::remove_dir_all(directory);
    }

    #[test]
    fn wrong_account_key_and_truncated_files_fail_without_writing() {
        let directory = scratch("reject");
        let path = write_export(
            &directory,
            "backup.zl.zip",
            "0123456789abcdef0123",
            &sample_archive(10),
        );
        let database = directory.join("history.db");
        let database = database.to_str().unwrap();
        let error = import_zalo_export(
            &path,
            "another-account-key-000",
            "1000",
            database,
            |_, _| {},
        )
        .unwrap_err();
        assert!(error.downcast_ref::<BackupError>().is_some());
        let count: i64 = MessageStore::open(database)
            .unwrap()
            .conn
            .query_row("SELECT COUNT(*) FROM messages", [], |row| row.get(0))
            .unwrap();
        assert_eq!(count, 0);
        let bytes = std::fs::read(&path).unwrap();
        let truncated = directory.join("cut.zl.zip");
        std::fs::write(&truncated, &bytes[..bytes.len() - 7]).unwrap();
        assert!(import_zalo_export(
            &truncated,
            "0123456789abcdef0123",
            "1000",
            database,
            |_, _| {}
        )
        .is_err());
        assert!(import_zalo_export(&path, "short", "1000", database, |_, _| {}).is_err());
        let _ = std::fs::remove_dir_all(directory);
    }

    #[test]
    fn legacy_container_and_media_only_exports_are_distinguished() {
        let directory = scratch("legacy");
        let v1 = write_export(
            &directory,
            "backup_zalo_old.zip",
            "0123456789abcdef0123",
            &sample_archive(3),
        );
        let database = directory.join("history.db");
        let database = database.to_str().unwrap();
        assert_eq!(
            import_zalo_export(&v1, "0123456789abcdef0123", "1000", database, |_, _| {})
                .unwrap()
                .messages_imported,
            4
        );
        let mut media_only = Vec::new();
        append(
            &mut media_only,
            "1000/ZaloDownloads/picture/a.jpg",
            &[9u8; 2048],
        );
        media_only.extend_from_slice(&[0u8; 1024]);
        let path = write_export(
            &directory,
            "media.zl.zip",
            "0123456789abcdef0123",
            &media_only,
        );
        assert!(
            import_zalo_export(&path, "0123456789abcdef0123", "1000", database, |_, _| {}).is_err()
        );
        assert_eq!(conversation_identity("g123"), ("123".into(), true));
        assert_eq!(conversation_identity("guest"), ("guest".into(), false));
        let _ = std::fs::remove_dir_all(directory);
    }
}
