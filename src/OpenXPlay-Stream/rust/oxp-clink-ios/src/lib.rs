// SPDX-FileCopyrightText: 2026 OpenXPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// oxp-clink-ios — CarLink client for the iOS app.
//
// The direction is "we connect to the head unit": the iPhone joins the car's
// Carlink Wi-Fi, connects to the head unit's CarLink services, pairs with the
// code shown on the car screen, then pushes H.264 and receives touches.
// All of that already lives in OpenXPlay-Stream's oxp-clink crate; this crate
// only adds the C ABI and the in-memory PIN/trust plumbing.
//
// Frames arrive from oxp-ios (the CarPlay receiver) as raw bytes, so the two
// static libraries never share Rust types.

#![allow(unused_imports, dead_code, clippy::too_many_arguments)]

use oxp_clink::protocol::AuthIdentity;
use oxp_clink::session::SessionOptions;
use oxp_clink::{
    ClinkAddresses, ClinkListener, ClinkOutput, ClinkState, ClinkStatistics, PinProvider,
    StaticClinkLink, TrustStore,
};
use oxp_core::model::{
    ControlEvent, Origin, OutputCapabilities, OutputHost, OutputStats, SessionPhase, SessionState,
    VideoCodec, VideoFormat, VideoFrame,
};
use std::collections::HashMap;
use std::ffi::{c_char, c_void, CStr};
use std::net::Ipv4Addr;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

// ---------------------------------------------------------------------------
// C ABI types
// ---------------------------------------------------------------------------

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ClinkCallbacks {
    pub context: *mut c_void,
    /// see `ClinkStateCode`
    pub on_state: Option<extern "C" fn(*mut c_void, u16)>,
    pub on_error: Option<extern "C" fn(*mut c_void, *const u8, usize)>,
    /// screen, x (0..1), y (0..1), pressed
    pub on_touch: Option<extern "C" fn(*mut c_void, u32, f64, f64, u8)>,
    /// head-unit key code, down
    pub on_key: Option<extern "C" fn(*mut c_void, u32, u8)>,
    pub on_log: Option<extern "C" fn(*mut c_void, *const u8, usize)>,
}

unsafe impl Send for ClinkCallbacks {}
unsafe impl Sync for ClinkCallbacks {}

/// Values must match `ClinkState` in Swift.
pub const CLINK_STATE_IDLE: u16 = 0;
pub const CLINK_STATE_CONNECTING: u16 = 1;
pub const CLINK_STATE_AUTHENTICATING: u16 = 2;
pub const CLINK_STATE_NEGOTIATING: u16 = 3;
pub const CLINK_STATE_PLAYING: u16 = 4;
pub const CLINK_STATE_ENDED: u16 = 5;

// ---------------------------------------------------------------------------
// PIN / trust
// ---------------------------------------------------------------------------

struct Pin {
    digits: Mutex<Option<String>>,
}

impl PinProvider for Pin {
    fn request_pin(&self, _head_unit_id: &str) -> Option<String> {
        self.digits.lock().unwrap().clone()
    }
    fn confirm_pairing(&self, _: &str) -> bool {
        true
    }
    fn pin_incorrect(&self, head_unit_id: &str) {
        log(&format!("配对码被拒绝：{head_unit_id}"));
    }
}

struct MemoryTrust {
    directory: Option<std::path::PathBuf>,
    identity: Mutex<Option<AuthIdentity>>,
    peers: Mutex<HashMap<String, Vec<u8>>>,
}

impl MemoryTrust {
    fn new(directory: Option<String>) -> Self {
        let directory = directory.map(std::path::PathBuf::from);
        if let Some(dir) = &directory {
            let _ = std::fs::create_dir_all(dir);
        }
        let trust = Self {
            directory,
            identity: Mutex::new(None),
            peers: Mutex::new(HashMap::new()),
        };
        trust.restore();
        trust
    }

    fn identity_path(&self) -> Option<std::path::PathBuf> {
        self.directory.as_ref().map(|d| d.join("clink-identity.bin"))
    }

    fn peer_path(&self, head_unit_id: &str) -> Option<std::path::PathBuf> {
        self.directory.as_ref().map(|d| {
            let safe: String = head_unit_id
                .chars()
                .map(|c| if c.is_ascii_alphanumeric() || c == '.' || c == '-' { c } else { '_' })
                .collect();
            d.join(format!("peer-{safe}.key"))
        })
    }

    fn restore(&self) {
        if let Some(path) = self.identity_path() {
            if let Ok(bytes) = std::fs::read(&path) {
                // On-disk form: raw P-256 scalar (32 bytes) || public key (64).
                if bytes.len() == 96 {
                    if let Ok(identity) =
                        AuthIdentity::from_scalar_bytes(&bytes[..32], &bytes[32..])
                    {
                        *self.identity.lock().unwrap() = Some(identity);
                    }
                }
            }
        }
    }
}

impl TrustStore for MemoryTrust {
    fn load_identity(&self) -> oxp_clink::Result<Option<AuthIdentity>> {
        Ok(self.identity.lock().unwrap().clone())
    }
    fn save_identity(&self, identity: &AuthIdentity) -> oxp_clink::Result<()> {
        *self.identity.lock().unwrap() = Some(identity.clone());
        if let Some(path) = self.identity_path() {
            // Persist scalar(32) || public(64) = 96 bytes, matching restore().
            // (Previously this wrote the PKCS#8 DER blob, which is longer than
            // 32 bytes, so restore() could never rebuild the identity and
            // every launch silently minted a fresh one, breaking QUICK.)
            let mut bytes = Vec::with_capacity(96);
            bytes.extend_from_slice(&identity.scalar_bytes());
            bytes.extend_from_slice(&identity.public_key());
            let _ = std::fs::write(path, bytes);
        }
        Ok(())
    }
    fn load_peer_key(&self, head_unit_id: &str) -> oxp_clink::Result<Option<Vec<u8>>> {
        if let Some(key) = self.peers.lock().unwrap().get(head_unit_id).cloned() {
            return Ok(Some(key));
        }
        if let Some(path) = self.peer_path(head_unit_id) {
            if let Ok(bytes) = std::fs::read(path) {
                self.peers
                    .lock()
                    .unwrap()
                    .insert(head_unit_id.to_string(), bytes.clone());
                return Ok(Some(bytes));
            }
        }
        Ok(None)
    }
    fn save_peer_key(&self, head_unit_id: &str, key: &[u8]) -> oxp_clink::Result<()> {
        self.peers
            .lock()
            .unwrap()
            .insert(head_unit_id.to_string(), key.to_vec());
        if let Some(path) = self.peer_path(head_unit_id) {
            let _ = std::fs::write(path, key);
        }
        Ok(())
    }
    fn forget_peer(&self, head_unit_id: &str) -> oxp_clink::Result<()> {
        self.peers.lock().unwrap().remove(head_unit_id);
        if let Some(path) = self.peer_path(head_unit_id) {
            let _ = std::fs::remove_file(path);
        }
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Callbacks into Swift
// ---------------------------------------------------------------------------

static CALLBACKS: OnceLock<Mutex<Option<ClinkCallbacks>>> = OnceLock::new();

fn callbacks_slot() -> &'static Mutex<Option<ClinkCallbacks>> {
    CALLBACKS.get_or_init(|| Mutex::new(None))
}

fn state_code(state: ClinkState) -> u16 {
    match state {
        ClinkState::Connecting => CLINK_STATE_CONNECTING,
        ClinkState::Authenticating => CLINK_STATE_AUTHENTICATING,
        ClinkState::Negotiating => CLINK_STATE_NEGOTIATING,
        ClinkState::Playing => CLINK_STATE_PLAYING,
        ClinkState::Ended => CLINK_STATE_ENDED,
    }
}

fn emit_state(code: u16) {
    if let Some(cb) = *callbacks_slot().lock().unwrap() {
        if let Some(f) = cb.on_state {
            f(cb.context, code);
        }
    }
}

fn log(text: &str) {
    if let Some(cb) = *callbacks_slot().lock().unwrap() {
        if let Some(f) = cb.on_log {
            f(cb.context, text.as_ptr(), text.len());
        } else if let Some(f) = cb.on_error {
            f(cb.context, text.as_ptr(), text.len());
        }
    }
    eprintln!("[clink] {text}");
}

fn emit_error(text: &str) {
    if let Some(cb) = *callbacks_slot().lock().unwrap() {
        if let Some(f) = cb.on_error {
            f(cb.context, text.as_ptr(), text.len());
            return;
        }
    }
    eprintln!("[clink][error] {text}");
}

struct Listener {
    cb: ClinkCallbacks,
}

impl ClinkListener for Listener {
    fn state(&self, state: ClinkState) {
        if let Some(f) = self.cb.on_state {
            f(self.cb.context, state_code(state));
        }
    }
    fn error(&self, message: &str) {
        if let Some(f) = self.cb.on_error {
            f(self.cb.context, message.as_ptr(), message.len());
        }
    }
    fn diagnostic(&self, message: &str) {
        if let Some(f) = self.cb.on_log {
            f(self.cb.context, message.as_ptr(), message.len());
        }
    }
    fn statistics(&self, stats: ClinkStatistics) {
        let text = format!(
            "Carlink 统计：帧 {} 字节 {} 丢弃 {} {}×{}",
            stats.live_frames, stats.live_bytes, stats.dropped_frames, stats.width, stats.height
        );
        if let Some(f) = self.cb.on_log {
            f(self.cb.context, text.as_ptr(), text.len());
        }
    }
}

struct Sink {
    cb: ClinkCallbacks,
}

impl OutputHost for Sink {
    fn capabilities(&self, _caps: OutputCapabilities) {}
    fn control(&self, event: ControlEvent) {
        match event {
            ControlEvent::Touch { screen, contacts, .. } => {
                if let (Some(first), Some(f)) = (contacts.first(), self.cb.on_touch) {
                    f(self.cb.context, screen, first.x, first.y, if first.pressed { 1 } else { 0 });
                }
            }
            ControlEvent::Key { code, down, .. } => {
                if let Some(f) = self.cb.on_key {
                    let raw = code as u16 as u32;
                    f(self.cb.context, raw, if down { 1 } else { 0 });
                }
            }
            _ => {}
        }
    }
    fn stats(&self, _stats: OutputStats) {}
}

// ---------------------------------------------------------------------------
// Process state
// ---------------------------------------------------------------------------

struct Running {
    output: Arc<ClinkOutput>,
    format_pushed: AtomicBool,
    session_fed: AtomicBool,
    convert_errors: AtomicU64,
}

static RUNNING: OnceLock<Mutex<Option<Arc<Running>>>> = OnceLock::new();

fn running() -> &'static Mutex<Option<Arc<Running>>> {
    RUNNING.get_or_init(|| Mutex::new(None))
}

fn cstr(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(ptr) }.to_str().ok().map(str::to_owned)
}

// ---------------------------------------------------------------------------
// Phone identity presented to the head unit (set by Swift before clink_start)
// ---------------------------------------------------------------------------

struct PhoneIdentity {
    device_id: String,
    model: String,
    product_name: String,
}

static PHONE_IDENTITY: OnceLock<Mutex<PhoneIdentity>> = OnceLock::new();

fn phone_identity() -> &'static Mutex<PhoneIdentity> {
    PHONE_IDENTITY.get_or_init(|| {
        Mutex::new(PhoneIdentity {
            device_id: "OpenXPlay-iOS".to_string(),
            model: "OpenXPlay".to_string(),
            product_name: "CabinPlay".to_string(),
        })
    })
}

/// Set the identity the next clink_start presents in the auth request:
/// field 7 id (same persistent id the BLE ClientInfo uses), field 8 model
/// (market name), field 11 productName. Call before clink_start.
#[no_mangle]
pub extern "C" fn clink_set_identity(
    device_id: *const c_char,
    model: *const c_char,
    product_name: *const c_char,
) {
    let mut slot = phone_identity().lock().unwrap();
    if let Some(v) = cstr(device_id) {
        if !v.is_empty() {
            slot.device_id = v;
        }
    }
    if let Some(v) = cstr(model) {
        if !v.is_empty() {
            slot.model = v;
        }
    }
    if let Some(v) = cstr(product_name) {
        if !v.is_empty() {
            slot.product_name = v;
        }
    }
}

/// Connect to the head unit's CarLink service.
/// Returns 0 on success, negative on error (details arrive through `on_error`).
#[no_mangle]
pub extern "C" fn clink_start(
    head_unit_ipv4: *const c_char,
    local_ipv4: *const c_char,
    pin: *const c_char,
    state_dir: *const c_char,
    width: u32,
    height: u32,
    callbacks: ClinkCallbacks,
) -> i32 {
    let Some(head) = cstr(head_unit_ipv4) else { return -1 };
    let Some(local) = cstr(local_ipv4) else { return -1 };

    *callbacks_slot().lock().unwrap() = Some(callbacks);

    if running().lock().unwrap().is_some() {
        return -2;
    }

    let head: Ipv4Addr = match head.parse() {
        Ok(v) => v,
        Err(e) => {
            emit_error(&format!("车机地址不合法：{e}"));
            return -3;
        }
    };
    let local: Ipv4Addr = match local.parse() {
        Ok(v) => v,
        Err(e) => {
            emit_error(&format!("本机地址不合法：{e}"));
            return -3;
        }
    };

    let link = StaticClinkLink(ClinkAddresses::new(head, local));
    let pin_value = cstr(pin);
    let output = ClinkOutput::new(
        Arc::new(link),
        Arc::new(Pin {
            digits: Mutex::new(pin_value),
        }),
        Arc::new(MemoryTrust::new(cstr(state_dir))),
    );

    let output = match output {
        Ok(o) => o,
        Err(e) => {
            emit_error(&format!("创建 CarLink 会话失败：{e}"));
            return -4;
        }
    };

    let identity = phone_identity().lock().unwrap();
    let options = SessionOptions {
        picture_size: Some((width.max(320), height.max(240))),
        device_id: identity.device_id.clone(),
        device_name: identity.model.clone(),
        work_modes: Some(781),
        product_name: Some(identity.product_name.clone()),
        ..Default::default()
    };
    drop(identity);

    let output = match output
        .with_options(options)
        .map(|o| o.with_listener(Arc::new(Listener { cb: callbacks })))
    {
        Ok(o) => o,
        Err(e) => {
            emit_error(&format!("会话参数不合法：{e}"));
            return -4;
        }
    };

    if let Err(e) = output.open(Arc::new(Sink { cb: callbacks }) as Arc<dyn OutputHost>) {
        emit_error(&format!("连接车机失败：{e}"));
        return -5;
    }

    *running().lock().unwrap() = Some(Arc::new(Running {
        output: Arc::new(output),
        format_pushed: AtomicBool::new(false),
        session_fed: AtomicBool::new(false),
        convert_errors: AtomicU64::new(0),
    }));
    log("CarLink 会话已建立");
    0
}

/// Feed the decoder configuration once per stream (AVCDecoderConfigurationRecord / hvcC).
#[no_mangle]
pub extern "C" fn clink_push_config(
    screen: u32,
    codec: u32,
    config: *const u8,
    length: usize,
    fps: f64,
) -> i32 {
    let Some(running) = running().lock().unwrap().clone() else { return -1 };
    if config.is_null() || length == 0 {
        return -2;
    }
    let bytes = unsafe { std::slice::from_raw_parts(config, length) };
    // 喂输入会话：原版宿主 oxp-bin 的契约是先 on_session(Active)、帧打
    // 同一个 session id 才过核心入口围栏。iOS 整合此前把这一步漏了，
    // FFI 又没有这个入口，核心的 input_session 永远是 None，每一帧都
    // 在围栏处被静默丢弃。帧的 session 在 clink_push_frame 里写死 1，
    // 这里对齐喂 1；推配置是帧流开始前的必经点（没推配置帧进不来），
    // 在这里喂最贴近原版「会话先行」的顺序。on_session 在核心里对同
    // id+Active 幂等，重复推配置不会反复重置队列。
    if !running.session_fed.swap(true, Ordering::AcqRel) {
        log("帧桥：已向核心喂输入会话（id 1，Active），帧的 session 与此对齐");
    }
    running.output.on_session(&SessionState {
        id: 1,
        phase: SessionPhase::Active,
        reason: None,
    });
    let codec = if codec == 2 { VideoCodec::H265 } else { VideoCodec::H264 };
    let format = match VideoFormat::create(
        screen,
        codec,
        Arc::from(bytes.to_vec().into_boxed_slice()),
        Some(fps.max(1.0)),
    ) {
        Ok(f) => f,
        Err(e) => {
            emit_error(&format!("视频格式不合法：{e}"));
            return -3;
        }
    };
    running
        .output
        .on_video_format(screen, Some(Arc::new(format)));
    running.format_pushed.store(true, Ordering::Release);
    0
}

/// Push one Annex-B frame (converted to AVCC before it enters the core:
/// the core muxer only accepts length-prefixed frames).
#[no_mangle]
pub extern "C" fn clink_push_frame(
    screen: u32,
    data: *const u8,
    length: usize,
    pts_us: i64,
    key_frame: i32,
) -> i32 {
    let Some(running) = running().lock().unwrap().clone() else { return -1 };
    if data.is_null() || length == 0 || !running.format_pushed.load(Ordering::Acquire) {
        return -2;
    }
    let bytes = unsafe { std::slice::from_raw_parts(data, length) };
    // 核心封装器只吃 AVCC（4 字节长度前缀），帧桥喂的是 Annex-B，进
    // 核心前先转。转失败计数打日志并报错返回，绝不把坏帧静默塞进
    // 去——未转的 Annex-B 会在封装器里触发 NAL 长度错误，经 mux()?
    // 冒泡打死媒体线程整轮。
    let avcc = match oxp_media::nal::annex_b_to_avcc(bytes) {
        Ok(v) => v,
        Err(e) => {
            let total = running.convert_errors.fetch_add(1, Ordering::Relaxed) + 1;
            if total == 1 || total % 300 == 0 {
                log(&format!(
                    "帧桥：Annex-B 转 AVCC 失败（{e}），累计 {total} 次，这一帧不送"
                ));
            }
            return -4;
        }
    };
    running.output.on_video_frame(VideoFrame {
        screen,
        session: 1,
        data: Arc::from(avcc.into_boxed_slice()),
        pts_us,
        key_frame: key_frame != 0,
        received_at_nanos: 0,
    });
    0
}

#[no_mangle]
pub extern "C" fn clink_stop() -> i32 {
    let mut guard = running().lock().unwrap();
    match guard.take() {
        Some(running) => {
            running.output.close();
            let _ = running.output.await_closed(std::time::Duration::from_secs(3));
            log("CarLink 会话已关闭");
            emit_state(CLINK_STATE_IDLE);
            0
        }
        None => -1,
    }
}

#[no_mangle]
pub extern "C" fn clink_is_running() -> i32 {
    if running().lock().unwrap().is_some() { 1 } else { 0 }
}
