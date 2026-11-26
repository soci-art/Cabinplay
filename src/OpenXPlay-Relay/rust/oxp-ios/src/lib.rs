// SPDX-FileCopyrightText: 2026 OpenXPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// oxp-ios — the OpenXPlay CarPlay receiver core, built for iOS.
//
// It reuses the exact protocol crates the relay runs on Linux/Android
// (`carplay-airplay`, `carplay-iap2`) and the relay's portable AirPlay server
// host (`server.rs`, copied from direlay-linux/src/linux_air_play_server.rs).
// The Linux-only pieces (Bluetooth iAP2 start, nmcli, systemd) are left out:
// on an iPhone the app itself is the accessory, and the phone's CarPlay stack
// connects to this listener over the Wi-Fi the phone has joined.
//
// The Swift app talks to it through the C ABI at the bottom of this file.

#![allow(unused_imports, unused_variables, dead_code, clippy::too_many_arguments)]

use std::collections::HashMap;
use std::ffi::{c_char, c_void, CStr, CString};
use std::net::Ipv4Addr;
use std::sync::{Arc, Mutex, OnceLock};

/// Fallible protocol/platform operation; malformed data and I/O errors propagate.
pub type Result<T> = std::io::Result<T>;

pub use carplay_airplay::*;
pub use carplay_airplay::AirPlayContact;
pub use carplay_iap2::mfi::MfiAuthenticator;
pub use carplay_iap2::mfi::local_mfi_authentication_client::LocalMfiAuthenticationClient;

/// Thread spawning, the one platform hook the portable host needs.
pub mod platform {
    use std::thread::JoinHandle;

    pub fn spawn_worker(name: &str, body: Box<dyn FnOnce() + Send>) -> std::io::Result<JoinHandle<()>> {
        std::thread::Builder::new()
            .name(name.to_string())
            .spawn(body)
    }
}

/// Monotonic nanosecond clock used in session bookkeeping.
pub fn monotonic_nanos() -> u128 {
    use std::time::Instant;
    static BASE: OnceLock<Instant> = OnceLock::new();
    let start = *BASE.get_or_init(Instant::now);
    start.elapsed().as_nanos()
}

pub mod server;
pub mod sink;

pub use server::{BindAddress, LinuxAirPlayServer, LinuxStreamTransport};
pub use sink::IosMediaSink;

// ---------------------------------------------------------------------------
// Pairing store (the relay persists this itself; here it lives in memory and
// is mirrored to a file by the Swift layer when it wants to)
// ---------------------------------------------------------------------------

#[derive(Default)]
struct MemoryPairings(Mutex<HashMap<String, [u8; 32]>>);

impl PairingStore for MemoryPairings {
    fn save(&self, identifier: &str, long_term_public_key: &[u8; 32]) -> Result<()> {
        self.0
            .lock()
            .unwrap()
            .insert(identifier.to_string(), *long_term_public_key);
        Ok(())
    }

    fn get(&self, identifier: &str) -> Result<Option<[u8; 32]>> {
        Ok(self.0.lock().unwrap().get(identifier).copied())
    }

    fn clear(&self) -> Result<()> {
        self.0.lock().unwrap().clear();
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Listener: forwards lifecycle events to the Swift app
// ---------------------------------------------------------------------------

struct IosListener {
    callbacks: OxpCallbacks,
}

impl IosListener {
    fn emit(&self, positive: bool, message: &str) {
        let text = if positive {
            message.to_string()
        } else {
            format!("error: {message}")
        };
        let bytes = text.as_bytes();
        if let Some(cb) = self.callbacks.on_state {
            cb(self.callbacks.context, bytes.as_ptr(), bytes.len());
        }
    }
}

impl AirPlaySessionListener for IosListener {
    fn on_transport_error(&self, message: &str) {
        self.emit(false, message);
    }
    fn on_authentication_failed(&self, _session: &AirPlaySession) {
        self.emit(false, "mfi authentication failed");
    }
    fn on_startup_milestone(&self, _session: &AirPlaySession, name: &str) {
        self.emit(true, name);
    }
    fn on_tcp_accepted(&self, _event: AirPlayTcpAccepted) {
        self.emit(true, "tcp-accepted");
    }
    fn on_device_info(&self, _session: &AirPlaySession, _info: &AirPlayDeviceInfo) {
        self.emit(true, "device-info");
    }
    fn on_host_ui_requested(&self, _session: &AirPlaySession) {
        self.emit(true, "host-ui");
    }
}

// ---------------------------------------------------------------------------
// Process state
// ---------------------------------------------------------------------------

struct Running {
    server: Arc<LinuxAirPlayServer>,
}

static RUNNING: OnceLock<Mutex<Option<Running>>> = OnceLock::new();

/// The engine bound to the most recent CarPlay session, used to inject touches
/// that arrive from the head unit through the CarLink output.
static ACTIVE_ENGINE: OnceLock<Mutex<Option<Arc<CarPlayMediaEngine>>>> = OnceLock::new();

fn active_engine() -> &'static Mutex<Option<Arc<CarPlayMediaEngine>>> {
    ACTIVE_ENGINE.get_or_init(|| Mutex::new(None))
}

fn running() -> &'static Mutex<Option<Running>> {
    RUNNING.get_or_init(|| Mutex::new(None))
}

/// Callbacks handed to Rust from Swift; kept for the process lifetime.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct OxpCallbacks {
    pub context: *mut c_void,
    /// stream kind, codec id (1 = H.264, 2 = HEVC)
    pub on_video_codec: Option<extern "C" fn(*mut c_void, u16, u32)>,
    /// stream kind, AVCDecoderConfigurationRecord / hvcC
    pub on_video_config: Option<extern "C" fn(*mut c_void, u16, *const u8, usize)>,
    /// stream kind, Annex-B NAL units, sender nanoseconds
    pub on_video_frame: Option<extern "C" fn(*mut c_void, u16, *const u8, usize, u64)>,
    /// audio config plist bytes
    pub on_audio_format: Option<extern "C" fn(*mut c_void, *const u8, usize)>,
    /// RTP packet bytes, sample index
    pub on_audio_rtp: Option<extern "C" fn(*mut c_void, *const u8, usize, u32)>,
    /// positive milestone, or "error: …"
    pub on_state: Option<extern "C" fn(*mut c_void, *const u8, usize)>,
    pub on_log: Option<extern "C" fn(*mut c_void, *const u8, usize)>,
}

unsafe impl Send for OxpCallbacks {}
unsafe impl Sync for OxpCallbacks {}

// ---------------------------------------------------------------------------
// Identity helpers
// ---------------------------------------------------------------------------

fn read_identity(dir: &str) -> Result<(Vec<u8>, Vec<u8>)> {
    let key = std::fs::read(format!("{dir}/identity.pk8")).map_err(|e| {
        std::io::Error::new(e.kind(), format!("identity.pk8: {e}"))
    })?;
    let cert = std::fs::read(format!("{dir}/certificate.p7b")).map_err(|e| {
        std::io::Error::new(e.kind(), format!("certificate.p7b: {e}"))
    })?;
    Ok((key, cert))
}

/// The AirPlay pairing identity (ed25519) is separate from the MFi identity.
/// It is generated once and stored beside the MFi files so a paired iPhone
/// keeps trusting this accessory across launches.
fn load_or_create_pairing_identity(dir: &str) -> Result<AirPlayIdentity> {
    let path = format!("{dir}/airplay-identity.txt");
    if let Ok(text) = std::fs::read_to_string(&path) {
        let lines: Vec<&str> = text.lines().collect();
        if lines.len() >= 4 && lines[0] == "v1" {
            let private_key = decode_hex32(lines[1])?;
            let public_key = decode_hex32(lines[2])?;
            return Ok(AirPlayIdentity {
                private_key,
                public_key,
                pairing_id: lines[3].to_string(),
            });
        }
    }
    let identity = AirPlayIdentity::generate()?;
    let text = format!(
        "v1\n{}\n{}\n{}\n",
        encode_hex(&identity.private_key),
        encode_hex(&identity.public_key),
        identity.pairing_id
    );
    let _ = std::fs::write(&path, text);
    Ok(identity)
}

fn encode_hex(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        out.push_str(&format!("{b:02x}"));
    }
    out
}

fn decode_hex32(text: &str) -> Result<[u8; 32]> {
    let text = text.trim();
    if text.len() != 64 {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "airplay-identity.txt: expected 64 hex characters",
        ));
    }
    let mut out = [0u8; 32];
    for i in 0..32 {
        out[i] = u8::from_str_radix(&text[i * 2..i * 2 + 2], 16)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e.to_string()))?;
    }
    Ok(out)
}

// ---------------------------------------------------------------------------
// C ABI
// ---------------------------------------------------------------------------

fn cstr(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(ptr) }
        .to_str()
        .ok()
        .map(|s| s.to_string())
}

/// Start the receiver. Returns 0 on success, negative on failure; the reason
/// arrives through `on_state` as an `error: …` string.
#[no_mangle]
pub extern "C" fn oxp_start(
    identity_dir: *const c_char,
    device_id: *const c_char,
    bt_mac: *const c_char,
    width: u32,
    height: u32,
    fps: u32,
    port: u16,
    callbacks: OxpCallbacks,
) -> i32 {
    let Some(dir) = cstr(identity_dir) else { return -1 };
    let device_id = cstr(device_id).unwrap_or_else(|| "02:00:00:00:00:01".to_string());
    let bt_mac = cstr(bt_mac).unwrap_or_else(|| "02:00:00:00:00:01".to_string());

    let mut guard = running().lock().unwrap();
    if guard.is_some() {
        return -2;
    }

    match start_inner(&dir, &device_id, &bt_mac, width, height, fps, port, callbacks) {
        Ok(server) => {
            *guard = Some(Running { server });
            0
        }
        Err(e) => {
            let msg = format!("error: {e}");
            if let Some(cb) = callbacks.on_state {
                cb(callbacks.context, msg.as_ptr(), msg.len());
            }
            -3
        }
    }
}

fn start_inner(
    dir: &str,
    device_id: &str,
    bt_mac: &str,
    width: u32,
    height: u32,
    fps: u32,
    port: u16,
    callbacks: OxpCallbacks,
) -> Result<Arc<LinuxAirPlayServer>> {
    let (key, cert) = read_identity(dir)?;
    let mfi_client = LocalMfiAuthenticationClient::from_identity(&key, &cert)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e.to_string()))?;
    let mfi: Arc<dyn MfiAuthenticator> = Arc::new(mfi_client);

    let identity = Arc::new(load_or_create_pairing_identity(dir)?);
    let pairings: Arc<dyn PairingStore> = Arc::new(MemoryPairings::default());

    let mut config = AirPlayConfig::linux_receiver(device_id.to_string(), bt_mac.to_string());
    config.device_name = "CabinPlay".to_string();
    config.model = "CabinPlay".to_string();
    config.manufacturer = "CabinPlay".to_string();
    config.port = if port == 0 { 7000 } else { port };
    config.main = AirPlayDisplayConfig::new(width.max(640), height.max(360));
    config.main.fps = fps.max(30);
    config.microphone = true;

    let address = BindAddress::new(Ipv4Addr::UNSPECIFIED.into(), 0);
    let transport: Arc<dyn StreamTransport> = Arc::new(LinuxStreamTransport::new(address));

    let sink: Arc<dyn MediaSink> = Arc::new(IosMediaSink::new(callbacks));
    // Used when a session arrives without the factory; the factory below is the
    // normal path and binds each session to its own transport.
    let engine_for_handler: Arc<CarPlayMediaEngine> =
        Arc::new(CarPlayMediaEngine::new(sink.clone(), transport.clone(), true));
    let media_handler: Arc<dyn AirPlayMediaHandler> = engine_for_handler;

    let factory_sink = sink.clone();
    let factory: server::MediaFactory = Arc::new(move |control, session_transport| {
        let _ = control;
        let engine = Arc::new(CarPlayMediaEngine::new(
            factory_sink.clone(),
            session_transport,
            true,
        ));
        *active_engine().lock().unwrap() = Some(engine.clone());
        engine
    });

    let listener: Arc<dyn AirPlaySessionListener> = Arc::new(IosListener { callbacks });

    let server = Arc::new(
        LinuxAirPlayServer::new(
            address,
            config,
            identity,
            pairings,
            mfi,
            media_handler,
            listener,
            transport,
        )
        .with_media_factory(factory),
    );
    server.start()?;
    Ok(server)
}

/// Stop the receiver and release its threads.
#[no_mangle]
pub extern "C" fn oxp_stop() -> i32 {
    let mut guard = running().lock().unwrap();
    if let Some(running) = guard.take() {
        let _ = running.server.close();
        0
    } else {
        -1
    }
}

/// Whether a receiver is running.
#[no_mangle]
pub extern "C" fn oxp_is_running() -> i32 {
    if running().lock().unwrap().is_some() { 1 } else { 0 }
}

/// Inject a touch from the head unit (CarLink UIBC) into the current CarPlay
/// session. Coordinates are normalised 0..1, as CarLink reports them.
#[no_mangle]
pub extern "C" fn oxp_touch(screen: u32, x: f64, y: f64, pressed: u32) -> i32 {
    use carplay_airplay::InputEvents;
    let engine = active_engine().lock().unwrap().clone();
    let Some(engine) = engine else { return -1 };
    let contact = AirPlayContact {
        id: 0,
        x: x.clamp(0.0, 1.0),
        y: y.clamp(0.0, 1.0),
        down: pressed != 0,
    };
    match engine.touch(screen as u16, &[contact]) {
        Ok(true) => 0,
        Ok(false) => -2,
        Err(e) => {
            eprintln!("[oxp-ios] touch failed: {e}");
            -3
        }
    }
}

/// Inject a hardware key from the head unit (CarLink) into the current CarPlay
/// session. `code` is passed through as the CarPlay/HID key code.
#[no_mangle]
pub extern "C" fn oxp_key(code: u32, down: u32) -> i32 {
    use carplay_airplay::InputEvents;
    let engine = active_engine().lock().unwrap().clone();
    let Some(engine) = engine else { return -1 };
    match engine.key(code as u16, down != 0) {
        Ok(true) => 0,
        Ok(false) => -2,
        Err(e) => {
            eprintln!("[oxp-ios] key failed: {e}");
            -3
        }
    }
}

/// Free-form log from Swift into the same channel as Rust logs.
#[no_mangle]
pub extern "C" fn oxp_log(ptr: *const c_char) {
    if let Some(line) = cstr(ptr) {
        eprintln!("[oxp-ios] {line}");
    }
}
