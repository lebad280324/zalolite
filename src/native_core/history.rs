//! Independent, account-scoped local history reads; never waits for network commands.

use super::*;
use std::sync::{Arc, Mutex};

/// Stable history boundary, ordered by timestamp and message ID.
#[derive(Clone, Debug, Deserialize, Serialize)]
pub(super) struct Cursor {
    pub timestamp: i64,
    pub id: String,
}

/// Immutable account metadata shared with the independent reader.
#[derive(Default)]
pub(super) struct ReadContext {
    pub generation: u64,
    pub account: String,
    pub db_path: String,
    pub threads: HashMap<String, Thread>,
    pub demo: bool,
}

/// A page delivered back to the worker for subsequent message actions.
pub(super) struct LoadedPage {
    pub generation: u64,
    pub thread: Thread,
}

/// A short metadata lease; no database or network operation holds this lock.
pub(super) type SharedContext = Arc<Mutex<ReadContext>>;

/// Start the bounded local read queue without retaining ownership of stdout.
///
/// # Errors
/// Returns an error if the reader thread cannot be created.
pub(super) fn start(
    context: SharedContext,
    output: mpsc::Sender<Value>,
    loaded: mpsc::UnboundedSender<LoadedPage>,
) -> Result<mpsc::Sender<Request>> {
    let output = output.downgrade();
    let (sender, mut receiver) = mpsc::channel::<Request>(8);
    std::thread::Builder::new().name("native-history-reader".into()).spawn(move || {
        let mut store: Option<(String, MessageStore)> = None;
        while let Some(request) = receiver.blocking_recv() {
            let Some(output) = output.upgrade() else { break; };
            let result = read_page(&context, &mut store, &request);
            let response = match result {
                Ok(Page { generation, account, thread, before, after, has_more }) => {
                    let current = context.lock().map(|c| c.generation == generation && c.account == account).unwrap_or(false);
                    if !current { Err(UserError("Tài khoản đã thay đổi. Hãy mở lại hội thoại.").into()) }
                    else {
                        let messages: Vec<_> = thread.messages.iter().map(|m| message_dto(m, &account)).collect();
                        let cursor = thread.messages.first().map(|m| Cursor { timestamp: m.ts, id: m.id.clone() });
                        let snapshot = bounded_event(json!({"id":request.id,"event":"message_page","data":{
                            "thread_id":thread.id,"account":account,"messages":messages,"has_more":has_more,
                            "before":before,"after":after,"cursor":cursor
                        }}));
                        if loaded.send(LoadedPage { generation, thread }).is_err() { break; }
                        if output.blocking_send(snapshot).is_err() { break; }
                        Ok(json!({}))
                    }
                }
                Err(error) => Err(error),
            };
            if output.blocking_send(terminal(&request, &response)).is_err() { break; }
        }
    })?;
    Ok(sender)
}

struct Page {
    generation: u64,
    account: String,
    thread: Thread,
    before: Option<Cursor>,
    after: Option<Cursor>,
    has_more: bool,
}

fn read_page(
    context: &SharedContext,
    store: &mut Option<(String, MessageStore)>,
    request: &Request,
) -> Result<Page> {
    let NativeIntent::Base(Command::LoadMessagePage {
        thread_id,
        is_group,
        before,
        after,
        limit,
    }) = &request.command
    else {
        bail!("unexpected history command");
    };
    let (generation, account, path, mut thread, demo) = {
        let context = context
            .lock()
            .map_err(|_| anyhow!("history context poisoned"))?;
        if context.account.is_empty() {
            return Err(UserError("Bạn cần đăng nhập trước.").into());
        }
        let thread = context
            .threads
            .get(thread_id)
            .filter(|t| t.is_group == *is_group)
            .cloned()
            .ok_or(UserError("Hội thoại không tồn tại hoặc đã thay đổi."))?;
        (
            context.generation,
            context.account.clone(),
            context.db_path.clone(),
            thread,
            context.demo,
        )
    };
    if before.is_some() && after.is_some() {
        return Err(UserError("Chỉ chọn một hướng tải lịch sử.").into());
    }
    let limit = (*limit).clamp(1, 100);
    if !demo {
        if store.as_ref().map(|s| &s.0) != Some(&path) {
            *store = Some((path.clone(), MessageStore::open(&path)?));
        }
        thread.messages.clear();
        let mut threads = vec![thread];
        let db = &store
            .as_ref()
            .ok_or_else(|| anyhow!("missing history store"))?
            .1;
        db.hydrate_loaded_threads_page(
            &mut threads,
            limit + 1,
            before.as_ref().map(|c| (c.timestamp, c.id.as_str())),
            after.as_ref().map(|c| (c.timestamp, c.id.as_str())),
        )?;
        thread = threads
            .pop()
            .ok_or_else(|| anyhow!("missing history thread"))?;
    } else {
        if let Some(c) = before {
            thread
                .messages
                .retain(|m| (m.ts, m.id.as_str()) < (c.timestamp, c.id.as_str()));
        }
        if let Some(c) = after {
            thread
                .messages
                .retain(|m| (m.ts, m.id.as_str()) > (c.timestamp, c.id.as_str()));
        }
        thread
            .messages
            .sort_by(|a, b| a.ts.cmp(&b.ts).then(a.id.cmp(&b.id)));
    }
    let has_more = thread.messages.len() > limit;
    if has_more {
        if after.is_some() {
            thread.messages.truncate(limit);
        } else {
            thread.messages.drain(..thread.messages.len() - limit);
        }
    }
    Ok(Page {
        generation,
        account,
        thread,
        before: before.clone(),
        after: after.clone(),
        has_more,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn live_updates_include_edits_to_older_rows_and_skip_unchanged_snapshots() {
        let (output, mut events) = mpsc::channel(16);
        let mut core = Core::new(true, output).unwrap();
        let mut thread = demo_threads().remove(0);
        thread.messages = (0..128)
            .map(|i| ChatMessage {
                id: format!("msg-{i:03}"),
                text: format!("Synthetic {i}"),
                ts: i,
                ..Default::default()
            })
            .collect();
        let id = thread.id.clone();
        core.threads = vec![thread];
        core.emit_message_updates(&id).await.unwrap();
        let mut total = 0;
        while let Ok(event) = events.try_recv() {
            total += event["data"]["messages"].as_array().unwrap().len();
        }
        assert_eq!(total, 128);
        core.emit_message_updates(&id).await.unwrap();
        assert!(events.try_recv().is_err());
        core.threads[0].messages[0].text = "Edited oldest message".into();
        core.emit_message_updates(&id).await.unwrap();
        let event = events.recv().await.unwrap();
        let rows = event["data"]["messages"].as_array().unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0]["id"], "msg-000");
    }

    #[tokio::test]
    async fn local_page_latency_benchmark_uses_only_synthetic_history() {
        let directory = std::env::temp_dir().join(format!(
            "native-history-bench-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir(&directory).unwrap();
        let path = directory.join("history.db").to_string_lossy().into_owned();
        let mut db = MessageStore::open(&path).unwrap();
        db.conn.execute_batch("BEGIN").unwrap();
        for i in 0..10_000 {
            db.upsert_message(&crate::store::StoredMessage {
                msg_id: format!("msg-{i:05}"),
                thread_id: "thread-1".into(),
                sender_id: "user-1".into(),
                sender_name: "Example".into(),
                text: format!("Synthetic message {i}"),
                msg_type: "text".into(),
                ts: i,
                is_outgoing: i % 2 == 0,
                raw_json: String::new(),
            })
            .unwrap();
        }
        db.conn.execute_batch("COMMIT").unwrap();
        drop(db);
        let context: SharedContext = Default::default();
        {
            let mut state = context.lock().unwrap();
            state.account = "fixture".into();
            state.db_path = path;
            state.threads.insert(
                "thread-1".into(),
                Thread {
                    id: "thread-1".into(),
                    ..Default::default()
                },
            );
        }
        let (output, mut events) = mpsc::channel(32);
        let (loaded, mut pages) = mpsc::unbounded_channel();
        let sender = start(context, output.clone(), loaded).unwrap();
        let mut timings = Vec::new();
        for i in 0..40 {
            let now = std::time::Instant::now();
            sender
                .send(Request {
                    id: format!("page-{i}"),
                    command: NativeIntent::Base(Command::LoadMessagePage {
                        thread_id: "thread-1".into(),
                        is_group: false,
                        before: None,
                        after: None,
                        limit: 50,
                    }),
                })
                .await
                .unwrap();
            let event = events.recv().await.unwrap();
            assert_eq!(event["data"]["messages"].as_array().unwrap().len(), 50);
            assert_eq!(events.recv().await.unwrap()["ok"], true);
            pages.recv().await.unwrap();
            timings.push(now.elapsed().as_secs_f64() * 1000.0);
        }
        timings.sort_by(f64::total_cmp);
        println!(
            "HISTORY_PAGE_BENCHMARK {}",
            json!({"task":"local_history_page","iterations":40,"dataset_messages":10000,"page_size":50,"min_ms":timings[0],"avg_ms":timings.iter().sum::<f64>()/40.0,"p50_ms":timings[20],"p95_ms":timings[38],"p99_ms":timings[39]})
        );
        drop(sender);
        drop(pages);
        drop(output);
        drop(events);
        // The reader owns the final connection until its input channel closes.
        for _ in 0..20 {
            if std::fs::remove_dir_all(&directory).is_ok() {
                return;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        panic!("synthetic history cleanup failed");
    }

    #[test]
    fn cursor_pages_keep_equal_timestamps_without_gaps_in_both_directions() {
        let mut store = MessageStore::open(":memory:").unwrap();
        for i in 0..7 {
            let row = crate::store::StoredMessage {
                msg_id: format!("msg-{i}"),
                thread_id: "thread-1".into(),
                sender_id: "user-1".into(),
                sender_name: "Example".into(),
                text: format!("Message {i}"),
                msg_type: "text".into(),
                ts: 1000,
                is_outgoing: false,
                raw_json: String::new(),
            };
            store.upsert_message(&row).unwrap();
        }
        let last = store.messages_before("thread-1", 3, None).unwrap();
        assert_eq!(
            last.iter().map(|m| m.msg_id.as_str()).collect::<Vec<_>>(),
            vec!["msg-4", "msg-5", "msg-6"]
        );
        let older = store
            .messages_before("thread-1", 3, Some((1000, "msg-4")))
            .unwrap();
        assert_eq!(
            older.iter().map(|m| m.msg_id.as_str()).collect::<Vec<_>>(),
            vec!["msg-1", "msg-2", "msg-3"]
        );
        let first = store
            .messages_before("thread-1", 3, Some((1000, "msg-1")))
            .unwrap();
        assert_eq!(first.len(), 1);
        assert_eq!(first[0].msg_id, "msg-0");
        let newer = store
            .messages_after("thread-1", 3, (1000, "msg-3"))
            .unwrap();
        assert_eq!(newer, last); // Stable message identity, including timestamp ties (INV-4).
        let plan:Vec<String> = store.conn.prepare("EXPLAIN QUERY PLAN SELECT msg_id FROM messages WHERE thread_id=?1 AND (ts,msg_id)<(?2,?3) ORDER BY ts DESC,msg_id DESC LIMIT 50").unwrap()
            .query_map(rusqlite::params!["thread-1",1000,"msg-4"],|r|r.get(3)).unwrap().map(Result::unwrap).collect();
        assert!(plan.iter().any(|s| s.contains("idx_thread_ts")), "{plan:?}");
    }

    #[tokio::test]
    async fn local_reader_finishes_without_the_network_command_loop_and_rejects_logout() {
        let mut thread = demo_threads().remove(0);
        thread.id = "thread-1".into();
        let context: SharedContext = Default::default();
        {
            let mut state = context.lock().unwrap();
            state.generation = 7;
            state.account = "demo".into();
            state.demo = true;
            state.threads.insert(thread.id.clone(), thread);
        }
        let (output, mut events) = mpsc::channel(32);
        let (loaded, _loaded_rx) = mpsc::unbounded_channel();
        let sender = start(context.clone(), output.clone(), loaded).unwrap();
        let request = Request {
            id: "page-one".into(),
            command: NativeIntent::Base(Command::LoadMessagePage {
                thread_id: "thread-1".into(),
                is_group: true,
                before: None,
                after: None,
                limit: 2,
            }),
        };
        sender.send(request.clone()).await.unwrap();
        let page = tokio::time::timeout(Duration::from_secs(1), events.recv())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(page["event"], "message_page");
        assert_eq!(page["data"]["messages"].as_array().unwrap().len(), 2);
        let done = events.recv().await.unwrap();
        assert_eq!(done["ok"], true);
        context.lock().unwrap().account.clear();
        sender.send(request).await.unwrap();
        let failed = events.recv().await.unwrap();
        assert_eq!(failed["event"], "result");
        assert_eq!(failed["ok"], false);
    }
}
