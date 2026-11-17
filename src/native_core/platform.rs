//! Owned call, phone-sync, backup and media-resource adapters for the native UI.

use crate::{
    chat::{self, Thread},
    session::Session,
    store::MessageStore,
};
use anyhow::{bail, Context, Result};
use base64::Engine;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

/// Individually typed native platform intents; there is no arbitrary action escape hatch.
#[derive(Clone, Deserialize, Serialize)]
#[serde(tag = "command", rename_all = "snake_case")]
pub(super) enum PlatformCommand {
    StartCall {
        thread_id: String,
        #[serde(default)]
        is_group: bool,
        #[serde(default)]
        is_video: bool,
    },
    AnswerCall {
        accept: bool,
        #[serde(default)]
        cam_start_off: bool,
    },
    SetCallMedia {
        is_on_mic: bool,
        is_on_cam: bool,
    },
    EndCall,
    SyncPhone {
        #[serde(default = "yes")]
        send_phone_prompt: bool,
    },
    CancelPhoneSync,
    ExportBackup {
        path: String,
    },
    DataUsage,
    ClearCache,
    DownloadMedia {
        url: String,
        file_name: String,
        directory: String,
    },
    CancelDownload,
    ListMediaDevices,
    SelectMediaDevices {
        microphone: String,
        camera: String,
    },
}
fn yes() -> bool {
    true
}
impl PlatformCommand {
    pub(super) fn name(&self) -> &'static str {
        match self {
            Self::StartCall { .. } => "start_call",
            Self::AnswerCall { .. } => "answer_call",
            Self::SetCallMedia { .. } => "set_call_media",
            Self::EndCall => "end_call",
            Self::SyncPhone { .. } => "sync_phone",
            Self::CancelPhoneSync => "cancel_phone_sync",
            Self::ExportBackup { .. } => "export_backup",
            Self::DataUsage => "data_usage",
            Self::ClearCache => "clear_cache",
            Self::DownloadMedia { .. } => "download_media",
            Self::CancelDownload => "cancel_download",
            Self::ListMediaDevices => "list_media_devices",
            Self::SelectMediaDevices { .. } => "select_media_devices",
        }
    }
}
/// Names exposed by the ready event, all backed by a concrete operation.
pub(super) fn commands() -> &'static [&'static str] {
    &[
        "start_call",
        "answer_call",
        "set_call_media",
        "end_call",
        "sync_phone",
        "cancel_phone_sync",
        "export_backup",
        "data_usage",
        "clear_cache",
        "download_media",
        "cancel_download",
        "list_media_devices",
        "select_media_devices",
    ]
}

/// Account-bound changes return to the owning actor before its snapshots are republished.
pub(super) enum PlatformUpdate {
    Threads {
        account: String,
        threads: Vec<Thread>,
    },
}

struct NativeCall {
    bridge: crate::call::CallBridge,
    stop: Arc<AtomicBool>,
}
impl Drop for NativeCall {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
    }
}

/// A session owns these background operations and aborts them before account changes.
pub(super) struct PlatformState {
    call: Option<NativeCall>,
    sync: Option<tokio::task::JoinHandle<()>>,
    imports: Vec<tokio::task::JoinHandle<()>>,
    download: Option<tokio::task::JoinHandle<()>>,
    download_id: Option<String>,
    updates: mpsc::UnboundedSender<PlatformUpdate>,
    received_batches: std::collections::HashSet<String>,
    import_lock: Arc<tokio::sync::Mutex<()>>,
    sync_until: Option<Instant>,
}
impl PlatformState {
    pub(super) fn new() -> (Self, mpsc::UnboundedReceiver<PlatformUpdate>) {
        let (updates, rx) = mpsc::unbounded_channel();
        (
            Self {
                call: None,
                sync: None,
                imports: Vec::new(),
                download: None,
                download_id: None,
                updates,
                received_batches: Default::default(),
                import_lock: Arc::new(tokio::sync::Mutex::new(())),
                sync_until: None,
            },
            rx,
        )
    }
    /// Abort every owned task before the session is replaced or the parent exits.
    pub(super) fn stop(&mut self) {
        self.call = None;
        crate::history_sync::PHONE_SYNC_CANCEL.store(true, Ordering::Release);
        if let Some(task) = self.sync.take() {
            task.abort();
        }
        if let Some(task) = self.download.take() {
            task.abort();
        }
        self.download_id = None;
        for task in self.imports.drain(..) {
            task.abort();
        }
        self.received_batches.clear();
        self.sync_until = None;
        crate::history_sync::clear_sync_keys();
        crate::history_sync::set_last_mobile_sync_status(None);
        crate::phone_sync_v2::finish_all();
    }

    /// Execute a platform intent using only the current session and explicitly owned store.
    pub(super) async fn execute(
        &mut self,
        command: &PlatformCommand,
        session: &Session,
        threads: &[Thread],
        db_path: &str,
        output: mpsc::Sender<Value>,
        demo: bool,
    ) -> Result<Value> {
        if session.login.is_none() && !demo {
            bail!(super::UserError("Bạn cần đăng nhập trước."));
        }
        if demo {
            return match command {
                PlatformCommand::DataUsage => Ok(
                    json!({"media_bytes":0,"cache_bytes":0,"system_bytes":0,"total_bytes":0,"available_bytes":null}),
                ),
                PlatformCommand::ListMediaDevices => Ok(
                    json!({"microphones":[],"cameras":[],"selected_microphone":"","selected_camera":"","output":"Thiết bị mặc định"}),
                ),
                PlatformCommand::CancelPhoneSync
                | PlatformCommand::EndCall
                | PlatformCommand::CancelDownload => Ok(json!({"cancelled":true})),
                _ => Err(super::UserError(
                    "Chế độ minh họa không truy cập thiết bị, tệp hoặc tài khoản thật.",
                )
                .into()),
            };
        }
        let account = account(session)?;
        match command {
            PlatformCommand::StartCall {thread_id,is_group,is_video} => {
                let thread = threads.iter().find(|t|t.id==*thread_id && t.is_group==*is_group)
                    .ok_or(super::UserError("Hội thoại không còn tồn tại. Hãy làm mới danh sách."))?;
                if *is_video && !tokio::task::spawn_blocking(crate::media::is_ffmpeg_available).await? {
                    bail!(super::UserError("Gọi video cần ffmpeg để thu và giải mã hình ảnh. Chưa tìm thấy ffmpeg trên máy."));
                }
                let call=self.ensure_call(session,output.clone())?;
                if !call.bridge.is_running() { bail!(super::UserError("Bộ xử lý cuộc gọi đã dừng. Hãy mở lại ứng dụng.")); }
                call.bridge.make_call(thread_id,&thread.name,thread.avatar.as_deref(),*is_video,*is_group);
                emit(&output,"call_state",json!({"state":"preparing","partner_name":thread.name,"is_video":is_video}));
                Ok(json!({"queued":true}))
            },
            PlatformCommand::AnswerCall{accept,cam_start_off} => {
                let call=self.call.as_ref().ok_or(super::UserError("Không có cuộc gọi đến."))?;
                if !call.bridge.is_running() { bail!(super::UserError("Cuộc gọi đã kết thúc.")); }
                call.bridge.answer_call(*accept,*cam_start_off); Ok(json!({"queued":true}))
            },
            PlatformCommand::SetCallMedia{is_on_mic,is_on_cam} => {
                let call=self.call.as_ref().ok_or(super::UserError("Không có cuộc gọi đang hoạt động."))?;
                if !call.bridge.is_running() { bail!(super::UserError("Cuộc gọi đã kết thúc.")); }
                call.bridge.set_media_state(*is_on_mic,*is_on_cam);Ok(json!({"queued":true}))
            },
            PlatformCommand::EndCall => {
                if let Some(call)=&self.call { call.bridge.end_call(); }
                Ok(json!({"queued":true}))
            },
            PlatformCommand::SyncPhone{send_phone_prompt} => {
                if self.sync.as_ref().is_some_and(|task|!task.is_finished()) { bail!(super::UserError("Một lần đồng bộ đang chạy.")); }
                crate::history_sync::PHONE_SYNC_CANCEL.store(false,Ordering::Release);
                self.sync_until = Some(Instant::now() + Duration::from_secs(900));
                self.received_batches.clear();
                let session=session.clone(); let mut snapshot=threads.to_vec();let path=db_path.to_string();
                let updates=self.updates.clone();let prompt=*send_phone_prompt;
                self.sync=Some(tokio::spawn(async move {
                    let polling=tokio::sync::Mutex::new(chat::PollState::default());
                    let progress=output.clone();
                    let operation=crate::history_sync::sync_phone_messages_to(&session,&polling,&mut snapshot,prompt,&path,false,move |fraction,_| {
                        // Legacy progress may include remote status text; emit only controlled copy.
                        let message=if fraction<0.22 {"Đang chờ xác nhận trên điện thoại…"} else if fraction<0.7 {"Đang nhận tin nhắn…"} else {"Đang lưu lịch sử đã nhận…"};
                        emit(&progress,"sync_progress",json!({"progress":fraction,"message":message}));
                    });
                    let result=tokio::time::timeout(Duration::from_secs(900),operation).await;
                    match result {
                        Ok(Ok((added,count)))=> {
                            let cancelled=crate::history_sync::PHONE_SYNC_CANCEL.load(Ordering::Acquire);
                            let _=updates.send(PlatformUpdate::Threads{account,threads:snapshot});
                            emit(&output,"sync_finished",json!({"added":added,"threads":count,"cancelled":cancelled,
                                "message":"Đã nhận dữ liệu khả dụng. Số lượng này có thể gồm Cloud và nhóm; chưa chứng minh toàn bộ lịch sử điện thoại đã chuyển."}));
                        },
                        _=> emit(&output,"sync_finished",json!({"added":0,"threads":0,"cancelled":false,"error":"Chưa đồng bộ được. Hãy kiểm tra điện thoại và thử lại."})),
                    }
                }));
                Ok(json!({"started":true}))
            },
            PlatformCommand::CancelPhoneSync => {
                crate::history_sync::PHONE_SYNC_CANCEL.store(true,Ordering::Release);
                if let Some(task)=self.sync.take(){task.abort();}
                for task in self.imports.drain(..){task.abort();}
                if let Some(key)=crate::history_sync::get_sync_public_key() {
                    let _=tokio::time::timeout(Duration::from_secs(3),chat::cancel_phone_sync(session,&key)).await;
                }
                crate::history_sync::clear_sync_keys();
                emit(&output,"sync_finished",json!({"added":0,"threads":0,"cancelled":true}));
                Ok(json!({"cancelling":true}))
            },
            PlatformCommand::ExportBackup{path} => {
                let source=db_path.to_string();let destination=path.clone();
                tokio::task::spawn_blocking(move || export_backup(&source,&destination)).await?
            },
            PlatformCommand::DataUsage => {
                let path=db_path.to_string();tokio::task::spawn_blocking(move || data_usage(&path)).await?
            },
            PlatformCommand::ClearCache => {
                let path=db_path.to_string();tokio::task::spawn_blocking(move || clear_cache(&path)).await?
            },
            PlatformCommand::DownloadMedia{url,file_name,directory} => {
                if self.download.as_ref().is_some_and(|task|!task.is_finished()){bail!(super::UserError("Một tệp đang được tải. Hãy chờ hoặc hủy lần tải trước."));}
                validate_media_url(url,threads)?;
                let name=safe_file_name(file_name)?;let dir=PathBuf::from(directory);
                if !dir.is_absolute() || !dir.is_dir(){bail!(super::UserError("Thư mục lưu không hợp lệ."));}
                let destination=dir.join(&name);
                if destination.exists(){bail!(super::UserError("Tệp đã tồn tại. Hãy chọn thư mục khác hoặc đổi tên tệp cũ."));}
                let client=session.http.clone();let url=url.clone();let display_name=name.clone();
                let job_id=crate::param_cipher::random_hex(12);
                self.download_id=Some(job_id.clone());
                let response_id=job_id.clone();
                self.download=Some(tokio::spawn(async move {
                    let generation=crate::media_resources::RequestGeneration::default();let ticket=generation.capture();
                    emit(&output,"download_progress",json!({"job_id":job_id,"progress":0,"message":"Đang tải tệp…","file_name":display_name}));
                    let result=tokio::time::timeout(Duration::from_secs(100),crate::media_resources::stream_original(&client,&url,&destination,&generation,ticket)).await;
                    match result {
                        Ok(Ok(_))=>emit(&output,"download_finished",json!({"job_id":job_id,"path":destination.to_string_lossy(),"file_name":display_name,"cancelled":false})),
                        _=>emit(&output,"download_finished",json!({"job_id":job_id,"file_name":display_name,"error":"Không tải được tệp. Kiểm tra kết nối rồi thử lại.","cancelled":false})),
                    }
                }));
                Ok(json!({"started":true,"job_id":response_id}))
            },
            PlatformCommand::CancelDownload => {
                if let Some(task)=self.download.take(){task.abort();}
                emit(&output,"download_finished",json!({"job_id":self.download_id.take(),"cancelled":true}));Ok(json!({"cancelling":true}))
            },
            PlatformCommand::ListMediaDevices => tokio::task::spawn_blocking(|| {
                let (mics,cameras)=crate::media::list_media_devices(true);
                json!({"microphones":mics,"cameras":cameras,"selected_microphone":crate::media::selected_mic_device(),"selected_camera":crate::media::selected_camera_device(),"output":"Thiết bị mặc định"})
            }).await.map_err(Into::into),
            PlatformCommand::SelectMediaDevices{microphone,camera} => {
                let mic=microphone.clone();let cam=camera.clone();
                tokio::task::spawn_blocking(move || -> Result<Value> {
                    let(mics,cams)=crate::media::list_media_devices(false);
                    if (!mic.is_empty()&&!mics.contains(&mic)) || (!cam.is_empty()&&!cams.contains(&cam)){bail!(super::UserError("Thiết bị đã ngắt kết nối. Hãy tải lại danh sách."));}
                    crate::media::set_selected_mic_device(&mic);crate::media::set_selected_camera_device(&cam);
                    Ok(json!({"selected_microphone":mic,"selected_camera":cam}))
                }).await?
            },
        }
    }

    fn ensure_call(
        &mut self,
        session: &Session,
        output: mpsc::Sender<Value>,
    ) -> Result<&NativeCall> {
        if self.call.is_none() {
            self.call = Some(native_call(session.clone(), output)?);
        }
        self.call.as_ref().context("call adapter unavailable")
    }

    /// Forward authenticated control frames without transmitting keys or raw payloads to Swift.
    pub(super) fn handle_control(
        &mut self,
        payload: &Value,
        session: &Session,
        threads: &[Thread],
        db_path: &str,
        output: mpsc::Sender<Value>,
        demo: bool,
    ) {
        if demo || session.login.is_none() {
            return;
        }
        let data = payload.get("data").unwrap_or(payload);
        for control in crate::call::extract_voip_controls(data) {
            if let Ok(call) = self.ensure_call(session, output.clone()) {
                call.bridge.handle_control_event(control);
            }
        }
        for control in chat::extract_mobile_sync_controls(data) {
            use chat::MobileSyncControlEvent::*;
            if !matches!(control, SyncV2Batch { .. }) {
                crate::phone_sync_v2::log(&format!("event: {}", control.kind()));
            }
            match control {
                TransferAfterLogin { temp_key } => {
                    crate::history_sync::set_latest_mobile_temp_key(&temp_key)
                }
                WaitingConfirmOnPhone { .. } => crate::history_sync::set_last_mobile_sync_status(
                    Some("Đang chờ xác nhận trên điện thoại".into()),
                ),
                UserConfirmed => crate::history_sync::set_last_mobile_sync_status(Some(
                    "Điện thoại đã xác nhận đồng bộ".into(),
                )),
                UserRejected => crate::history_sync::set_last_mobile_sync_status(Some(
                    "Điện thoại đã từ chối đồng bộ".into(),
                )),
                MobileBusyRestoring => crate::history_sync::set_last_mobile_sync_status(Some(
                    "Điện thoại đang bận khôi phục".into(),
                )),
                BackupReady {
                    url, encrypted_key, ..
                } => self.import_batch(
                    session,
                    threads,
                    db_path,
                    output.clone(),
                    url,
                    Some(encrypted_key),
                    0,
                ),
                SyncV2Batch {
                    url, sync_id, batch_type, is_last,
                } => {
                    crate::phone_sync_v2::log(&format!(
                        "event: upload_batch sync={} type={batch_type} last={is_last} host={}",
                        crate::phone_sync_v2::short(&sync_id),
                        crate::phone_sync_v2::host(&url)
                    ));
                    self.import_v2_batch(session, threads, db_path, output.clone(), url, sync_id, is_last)
                }
            }
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn import_v2_batch(
        &mut self,
        session: &Session,
        threads: &[Thread],
        db_path: &str,
        output: mpsc::Sender<Value>,
        url: String,
        sync_id: String,
        is_last: bool,
    ) {
        // Ignore unsolicited batches when the user has not started a sync.
        if self.sync_until.map_or(true, |deadline| Instant::now() >= deadline) || self.received_batches.contains(&url) {
            return;
        }
        let Ok(parsed) = reqwest::Url::parse(&url) else { return };
        let Some(host) = parsed.host_str() else { return };
        if parsed.scheme() != "https"
            || !crate::endpoints::MOBILE_BACKUP_DOMAINS.iter().any(|domain| host == *domain || host.ends_with(&format!(".{domain}")))
        {
            crate::phone_sync_v2::log(&format!("event: batch rejected host={host}"));
            return;
        }
        if self.received_batches.len() >= 4096 {
            return;
        }
        self.received_batches.insert(url.clone());
        let session = session.clone();
        let path = db_path.to_string();
        let mut snapshot = threads.to_vec();
        let updates = self.updates.clone();
        let Ok(account) = account(&session) else { return };
        self.imports.retain(|task| !task.is_finished());
        let import_lock = self.import_lock.clone();
        self.imports.push(tokio::spawn(async move {
            let _import_guard = import_lock.lock().await;
            match crate::phone_sync_v2::import_batch(&session, &sync_id, &url, is_last, &path).await {
                Ok(outcome) if outcome.imported > 0 => {
                    let target = path.clone();
                    if let Ok(Ok(restored)) = tokio::task::spawn_blocking(move || -> Result<_> {
                        MessageStore::open(&target)?.hydrate_threads(&mut snapshot, 2000)?;
                        Ok(snapshot)
                    })
                    .await
                    {
                        let _ = updates.send(PlatformUpdate::Threads { account, threads: restored });
                    }
                    emit(&output, "sync_progress", json!({"progress":0.6,"message":format!("Đã nhận {} tin nhắn từ điện thoại", outcome.imported)}));
                }
                Ok(_) => {}
                Err(error) => {
                    crate::phone_sync_v2::log(&format!("batch: failed ({error})"));
                    emit(&output, "sync_progress", json!({"progress":0.5,"message":"Chưa giải mã được một gói đồng bộ. Dữ liệu đã lưu vẫn được giữ."}));
                }
            }
        }));
    }

    fn import_batch(
        &mut self,
        session: &Session,
        threads: &[Thread],
        db_path: &str,
        output: mpsc::Sender<Value>,
        url: String,
        key: Option<String>,
        kind: u8,
    ) {
        // Ignore unsolicited transfer containers when the user has not started a sync.
        if self
            .sync_until
            .map_or(true, |deadline| Instant::now() >= deadline)
            || self.received_batches.contains(&url)
        {
            return;
        }
        let Ok(parsed) = reqwest::Url::parse(&url) else {
            return;
        };
        let Some(host) = parsed.host_str() else {
            return;
        };
        if parsed.scheme() != "https"
            || !crate::endpoints::MOBILE_BACKUP_DOMAINS
                .iter()
                .any(|domain| host == *domain || host.ends_with(&format!(".{domain}")))
        {
            return;
        }
        if self.received_batches.len() >= 128 {
            return;
        }
        self.received_batches.insert(url.clone());
        let session = session.clone();
        let path = db_path.to_string();
        let mut snapshot = threads.to_vec();
        let updates = self.updates.clone();
        let Ok(account) = account(&session) else {
            return;
        };
        self.imports.retain(|task| !task.is_finished());
        let import_lock = self.import_lock.clone();
        self.imports.push(tokio::spawn(async move{
            let _import_guard=import_lock.lock().await;
            let result=if let Some(key)=key {
                crate::history_sync::import_mobile_backup_container_to(&session,&url,&key,&path).await
            }else if kind==2 {
                crate::history_sync::import_sync_v2_meta(&session,&url).await.map(|_|0)
            }else if kind==1 {
                crate::history_sync::import_sync_v2_messages_to(&session,&url,&path).await
            }else{return;};
            match result{
                Ok(added)=>{
                    if kind!=2{
                        let target=path.clone();
                        if let Ok(Ok(restored))=tokio::task::spawn_blocking(move||->Result<_>{MessageStore::open(&target)?.hydrate_threads(&mut snapshot,2000)?;Ok(snapshot)}).await{
                            let _=updates.send(PlatformUpdate::Threads{account,threads:restored});
                        }
                    }
                    crate::history_sync::set_last_mobile_sync_status(Some(format!("Đã nhận gói đồng bộ thành công: {added} tin nhắn")));
                    emit(&output,"sync_progress",json!({"progress":0.85,"message":format!("Đã nhập {added} tin nhắn từ gói điện thoại")}));
                },
                Err(_)=>emit(&output,"sync_progress",json!({"progress":0.5,"message":"Chưa giải mã được một gói đồng bộ. Dữ liệu đã lưu vẫn được giữ."})),
            }
        }));
    }
}
impl Drop for PlatformState {
    fn drop(&mut self) {
        self.stop();
    }
}

fn emit(output: &mpsc::Sender<Value>, event: &str, data: Value) {
    let value = json!({"event":event,"data":data});
    if let Err(mpsc::error::TrySendError::Full(value)) = output.try_send(value) {
        // Frames and progress coalesce under backpressure. State/completion events
        // remain reliable on their owning runtime or the dedicated call thread.
        if matches!(event, "call_frame" | "sync_progress" | "download_progress") {
            return;
        }
        if let Ok(runtime) = tokio::runtime::Handle::try_current() {
            let output = output.clone();
            runtime.spawn(async move {
                // A closed UI pipe means its owning application has stopped.
                let _ = output.send(value).await;
            });
        } else {
            // This path belongs only to the dedicated call event adapter thread.
            let _ = output.blocking_send(value);
        }
    }
}
fn account(session: &Session) -> Result<String> {
    session
        .login
        .as_ref()
        .map(|login| login.uin.clone())
        .filter(|uin| !uin.is_empty())
        .context("missing account")
}

fn native_call(session: Session, output: mpsc::Sender<Value>) -> Result<NativeCall> {
    let account = account(&session)?;
    let (sender, receiver) = std::sync::mpsc::channel();
    let context = eframe::egui::Context::default();
    let bridge = crate::call::CallBridge::spawn(
        Arc::new(tokio::sync::Mutex::new(session)),
        crate::gui::GuiTx::new(sender, context.clone()),
        context,
    );
    let stop = Arc::new(AtomicBool::new(false));
    let stopped = stop.clone();
    std::thread::Builder::new().name("native-call-events".into()).spawn(move||{
        let mut last_local=Instant::now()-Duration::from_secs(1);let mut last_remote=last_local;
        while !stopped.load(Ordering::Acquire){
            let event=match receiver.recv_timeout(Duration::from_millis(100)){Ok(event)=>event,Err(std::sync::mpsc::RecvTimeoutError::Timeout)=>continue,Err(_)=>break};
            if stopped.load(Ordering::Acquire) { break; }
            use crate::gui::GuiEvent;
            match event{
                GuiEvent::CallStateChanged(state)=>emit(&output,"call_state",json!({"account":account,"state":state})),
                GuiEvent::IncomingCall{call_id,caller_id,caller_name,is_video,is_group}=>emit(&output,"incoming_call",json!({"account":account,"call_id":call_id,"caller_id":caller_id,"caller_name":caller_name,"is_video":is_video,"is_group":is_group})),
                GuiEvent::CallRejected{..}=>emit(&output,"call_error",json!({"account":account,"message":"Cuộc gọi không kết nối được hoặc đã bị từ chối."})),
                GuiEvent::StickerImageReady{key,image} if key.starts_with("call_")=>{
                    let local=key.contains("local");let last=if local{&mut last_local}else{&mut last_remote};
                    if last.elapsed()<Duration::from_millis(180){continue;}*last=Instant::now();
                    if image.size[0].saturating_mul(image.size[1])>1920*1080{continue;}
                    let rgba:Vec<u8>=image.pixels.iter().flat_map(|pixel|pixel.to_array()).collect();
                    let mut png=std::io::Cursor::new(Vec::new());
                    if image::write_buffer_with_format(&mut png,&rgba,image.size[0] as u32,image.size[1] as u32,image::ColorType::Rgba8,image::ImageFormat::Png).is_ok(){
                        let bytes=png.into_inner();if bytes.len()<1024*1024{emit(&output,"call_frame",json!({"account":account,"image_base64":base64::engine::general_purpose::STANDARD.encode(bytes),"is_local":local}));}
                    }
                },
                _=>{}
            }
        }
    })?;
    Ok(NativeCall { bridge, stop })
}

fn safe_file_name(name: &str) -> Result<String> {
    let name = name.trim();
    if name.is_empty()
        || name.len() > 240
        || name
            .chars()
            .any(|c| c.is_control() || matches!(c, '/' | '\\' | ':'))
        || matches!(name, "." | "..")
    {
        bail!(super::UserError("Tên tệp không hợp lệ."));
    }
    Ok(name.into())
}
fn validate_media_url(url: &str, threads: &[Thread]) -> Result<()> {
    let parsed =
        reqwest::Url::parse(url).map_err(|_| super::UserError("Địa chỉ tệp không hợp lệ."))?;
    if !matches!(parsed.scheme(), "http" | "https")
        || !parsed.username().is_empty()
        || parsed.password().is_some()
    {
        bail!(super::UserError("Địa chỉ tệp không hợp lệ."));
    }
    let host = parsed
        .host_str()
        .ok_or(super::UserError("Địa chỉ tệp không hợp lệ."))?;
    if host.eq_ignore_ascii_case("localhost")
        || host.parse::<std::net::IpAddr>().is_ok_and(|ip| match ip {
            std::net::IpAddr::V4(ip) => {
                ip.is_private() || ip.is_loopback() || ip.is_unspecified() || ip.is_link_local()
            }
            std::net::IpAddr::V6(ip) => ip.is_loopback() || ip.is_unspecified(),
        })
    {
        bail!(super::UserError("Địa chỉ tải tệp không được hỗ trợ."));
    }
    if !threads
        .iter()
        .flat_map(|thread| &thread.messages)
        .any(|message| {
            message.link_url.as_deref() == Some(url)
                || message.link_thumb.as_deref() == Some(url)
                || message.sticker_image_url().as_deref() == Some(url)
        })
    {
        bail!(super::UserError(
            "Tệp không thuộc nội dung hội thoại đã tải."
        ));
    }
    Ok(())
}

fn export_backup(source: &str, destination: &str) -> Result<Value> {
    let destination = PathBuf::from(destination);
    if !destination.is_absolute()
        || destination.exists()
        || !matches!(
            destination.extension().and_then(|x| x.to_str()),
            Some("db" | "sqlite" | "sqlite3")
        )
    {
        bail!(super::UserError(
            "Chọn tên tệp SQLite mới để lưu bản sao lịch sử."
        ));
    }
    let parent = destination.parent().context("missing backup directory")?;
    if !parent.is_dir() {
        bail!(super::UserError("Thư mục sao lưu không tồn tại."));
    }
    let temporary = parent.join(format!(
        ".ctdo-backup-{}.sqlite",
        crate::param_cipher::random_hex(8)
    ));
    let operation = (|| -> Result<Value> {
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        drop(options.open(&temporary)?);
        let connection = rusqlite::Connection::open_with_flags(
            source,
            rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
        )?;
        connection.busy_timeout(Duration::from_secs(5))?;
        let count: i64 =
            connection.query_row("SELECT COUNT(*) FROM messages", [], |row| row.get(0))?;
        connection.execute(
            "VACUUM main INTO ?1",
            [temporary.to_string_lossy().as_ref()],
        )?;
        std::fs::File::open(&temporary)?.sync_all()?;
        // Publish without overwriting an unrelated file that appeared after the dialog.
        std::fs::hard_link(&temporary, &destination)?;
        Ok(json!({"path":destination.to_string_lossy(),"messages":count,"format":"sqlite"}))
    })();
    let _ = std::fs::remove_file(&temporary);
    operation
}
fn owned_directory(db_path: &str) -> Result<PathBuf> {
    let db = PathBuf::from(db_path);
    let parent = db.parent().context("missing account directory")?;
    if parent.as_os_str().is_empty() || parent == Path::new(".") {
        bail!("account directory required");
    }
    Ok(parent.to_path_buf())
}
fn tree_bytes(path: &Path, depth: usize, budget: &mut usize) -> Result<u64> {
    if !path.exists() {
        return Ok(0);
    }
    if depth > 12 || *budget == 0 {
        bail!("directory scan limit reached");
    }
    *budget -= 1;
    let meta = std::fs::symlink_metadata(path)?;
    if meta.file_type().is_symlink() {
        return Ok(0);
    }
    if meta.is_file() {
        return Ok(meta.len());
    }
    let mut total = 0u64;
    for entry in std::fs::read_dir(path)? {
        total = total.saturating_add(tree_bytes(&entry?.path(), depth + 1, budget)?);
    }
    Ok(total)
}
/// The data folder that holds `accounts/<uin>/`; the worker runs inside it.
fn data_root(account: &Path) -> PathBuf {
    match account.parent() {
        Some(accounts) if accounts.file_name().is_some_and(|name| name == "accounts") => accounts
            .parent()
            .filter(|root| !root.as_os_str().is_empty())
            .map(Path::to_path_buf)
            .unwrap_or_else(|| PathBuf::from(".")),
        _ => account.to_path_buf(),
    }
}

/// Sizes by kind for the whole data folder, like Zalo's "Quản lý dữ liệu". It used to measure only
/// the active account's folder, missing sticker and preview caches and the other accounts.
fn data_usage(db_path: &str) -> Result<Value> {
    let account = owned_directory(db_path)?;
    let root = data_root(&account);
    let mut budget = 200_000;
    let mut size = |path: PathBuf| tree_bytes(&path, 0, &mut budget);
    let media = size(root.join("previews"))? + size(account.join("downloads"))? + size(account.join("media"))?;
    let cache = size(root.join("stickers_cache"))?
        + size(root.join("cache"))?
        + size(account.join("cache"))?
        + size(account.join("media_cache"))?;
    let current = account.file_name().map(|name| name.to_string_lossy().to_string()).unwrap_or_default();
    let mut other_accounts = 0u64;
    if root != account {
        if let Ok(entries) = std::fs::read_dir(root.join("accounts")) {
            for entry in entries.flatten() {
                let name = entry.file_name().to_string_lossy().to_string();
                let owner = name.split(['.', '_']).next().unwrap_or_default();
                if !current.is_empty() && owner != current {
                    other_accounts += size(entry.path())?;
                }
            }
        }
    }
    let total = size(root)?;
    Ok(json!({
        "media_bytes": media,
        "cache_bytes": cache,
        "other_accounts_bytes": other_accounts,
        "system_bytes": total.saturating_sub(media + cache + other_accounts),
        "total_bytes": total,
        "available_bytes": null
    }))
}
fn clear_cache(db_path: &str) -> Result<Value> {
    let account = owned_directory(db_path)?;
    let root = data_root(&account);
    let mut removed = 0u64;
    // Sticker art and other caches are fetched again when needed; history and downloads are kept.
    for path in [account.join("cache"), account.join("media_cache"), root.join("cache"), root.join("stickers_cache")] {
        if !path.exists() {
            continue;
        }
        let meta = std::fs::symlink_metadata(&path)?;
        if !meta.is_dir() || meta.file_type().is_symlink() {
            bail!("invalid cache directory");
        }
        let mut budget = 100_000;
        removed += tree_bytes(&path, 0, &mut budget)?;
        std::fs::remove_dir_all(&path)?;
    }
    Ok(json!({"removed_bytes":removed}))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn temporary() -> PathBuf {
        let path = std::env::temp_dir().join(format!(
            "ctdo-platform-{}",
            crate::param_cipher::random_hex(8)
        ));
        std::fs::create_dir(&path).unwrap();
        path
    }
    #[test]
    fn data_usage_counts_the_whole_folder_by_kind() {
        let root = temporary();
        let write = |rel: &str, len: usize| {
            let path = root.join(rel);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, vec![0u8; len]).unwrap();
        };
        write("accounts/111/native_history.db", 1000);
        write("accounts/222/native_history.db", 300);
        write("accounts/222.json", 20);
        write("stickers_cache/pack.json", 200);
        write("previews/a.docx", 400);
        write("session.json", 10);
        let usage = data_usage(root.join("accounts/111/native_history.db").to_str().unwrap()).unwrap();
        assert_eq!(usage["media_bytes"], 400);
        assert_eq!(usage["cache_bytes"], 200);
        assert_eq!(usage["other_accounts_bytes"], 320);
        assert_eq!(usage["total_bytes"], 1930);
        assert_eq!(usage["system_bytes"], 1010);
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn backup_is_consistent_and_does_not_replace_an_existing_file() {
        let dir = temporary();
        let source = dir.join("source.sqlite");
        let target = dir.join("copy.sqlite");
        let store = MessageStore::open(source.to_str().unwrap()).unwrap();
        store.conn.execute("INSERT INTO threads(thread_id,name,is_group,last_ts) VALUES('thread-1','Example',0,1)",[]).unwrap();
        export_backup(source.to_str().unwrap(), target.to_str().unwrap()).unwrap();
        let backup = rusqlite::Connection::open(&target).unwrap();
        assert_eq!(
            backup
                .query_row(
                    "SELECT name FROM threads WHERE thread_id='thread-1'",
                    [],
                    |row| row.get::<_, String>(0)
                )
                .unwrap(),
            "Example"
        );
        assert!(export_backup(source.to_str().unwrap(), target.to_str().unwrap()).is_err());
        drop(backup);
        drop(store);
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn clearing_cache_keeps_history_and_downloaded_originals() {
        let dir = temporary();
        std::fs::create_dir(dir.join("cache")).unwrap();
        std::fs::create_dir(dir.join("downloads")).unwrap();
        std::fs::write(dir.join("cache/preview"), b"cache").unwrap();
        std::fs::write(dir.join("native_history.db"), b"history").unwrap();
        std::fs::write(dir.join("downloads/original"), b"original").unwrap();
        let result = clear_cache(dir.join("native_history.db").to_str().unwrap()).unwrap();
        assert_eq!(result["removed_bytes"], 5);
        assert_eq!(
            std::fs::read(dir.join("native_history.db")).unwrap(),
            b"history"
        );
        assert!(dir.join("downloads/original").exists());
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn unsafe_download_names_and_unbound_urls_are_rejected() {
        for name in ["../session.json", "a/b", "..", "a\\b", ""] {
            assert!(safe_file_name(name).is_err());
        }
        assert!(validate_media_url("http://127.0.0.1/file", &[]).is_err());
        assert!(validate_media_url("https://example.com/file", &[]).is_err());
    }
    #[tokio::test]
    async fn demo_never_opens_devices_or_files() {
        let (mut state, _) = PlatformState::new();
        let (output, _) = mpsc::channel(8);
        let session = Session::new(false, false, false).unwrap();
        assert!(state
            .execute(
                &PlatformCommand::ExportBackup {
                    path: "/should-not-exist.sqlite".into()
                },
                &session,
                &[],
                "",
                output.clone(),
                true
            )
            .await
            .is_err());
        let devices = state
            .execute(
                &PlatformCommand::ListMediaDevices,
                &session,
                &[],
                "",
                output,
                true,
            )
            .await
            .unwrap();
        assert_eq!(devices["microphones"], json!([]));
    }
}
