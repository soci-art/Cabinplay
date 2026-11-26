// SPDX-FileCopyrightText: 2026 OpenXPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// IosMediaSink — the bridge between the CarPlay protocol engine and the Swift
// app. Frames arrive as Annex-B NAL units with the decoder configuration
// separate, which is exactly what VideoToolbox wants.

use crate::{OxpCallbacks, Result};
use carplay_airplay::{AudioFormat, AudioStreamId, MediaSink, MicrophoneConfig, VideoCodec};
use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::{Arc, Mutex};

// CarLink output (oxp-clink-ios, linked from the Stream workspace). Frames cross
// the boundary as raw bytes, so the two static libraries never share Rust types.
extern "C" {
    fn clink_is_running() -> i32;
    fn clink_push_config(screen: u32, codec: u32, config: *const u8, length: usize, fps: f64) -> i32;
    fn clink_push_frame(screen: u32, data: *const u8, length: usize, pts_us: i64, key_frame: i32) -> i32;
}

fn annexb_has_keyframe(bytes: &[u8]) -> bool {
    // NAL unit type 5 (IDR) in H.264, 19/20 (IDR) in HEVC.
    let mut i = 0;
    while i + 4 < bytes.len() {
        if bytes[i] == 0 && bytes[i + 1] == 0 && (bytes[i + 2] == 1 || (bytes[i + 2] == 0 && bytes[i + 3] == 1)) {
            let header_at = if bytes[i + 2] == 1 { i + 3 } else { i + 4 };
            if header_at < bytes.len() {
                let header = bytes[header_at];
                // H.264: (header & 0x1f) == 5; HEVC: (header >> 1) & 0x3f in {19,20}
                if header & 0x80 == 0 {
                    let h264 = header & 0x1f == 5;
                    let hevc = matches!((header >> 1) & 0x3f, 19 | 20);
                    if h264 || hevc {
                        return true;
                    }
                }
            }
        }
        i += 1;
    }
    false
}

#[derive(Clone)]
pub struct IosMediaSink {
    callbacks: OxpCallbacks,
    recovery: Arc<Mutex<Vec<(u16, Arc<dyn Fn() + Send + Sync>)>>>,
    codec_id: Arc<AtomicI32>,
}

impl IosMediaSink {
    pub fn new(callbacks: OxpCallbacks) -> Self {
        Self {
            callbacks,
            recovery: Arc::new(Mutex::new(Vec::new())),
            codec_id: Arc::new(AtomicI32::new(1)),
        }
    }

    fn codec_id(codec: VideoCodec) -> u32 {
        match codec {
            VideoCodec::H264 => 1,
            VideoCodec::H265 => 2,
        }
    }

    fn state(&self, text: &str) {
        if let Some(cb) = self.callbacks.on_state {
            cb(self.callbacks.context, text.as_ptr(), text.len());
        }
    }

    fn log(&self, text: &str) {
        if let Some(cb) = self.callbacks.on_log {
            cb(self.callbacks.context, text.as_ptr(), text.len());
        }
    }
}

impl MediaSink for IosMediaSink {
    fn on_video_codec(&self, kind: u16, codec: VideoCodec) -> Result<()> {
        let id = Self::codec_id(codec);
        self.codec_id.store(id as i32, Ordering::Release);
        if let Some(cb) = self.callbacks.on_video_codec {
            cb(self.callbacks.context, kind, id);
        }
        self.log(&format!("video codec {codec:?} on stream {kind}"));
        Ok(())
    }

    fn on_video_config(&self, kind: u16, codec_data: &[u8]) -> Result<()> {
        if let Some(cb) = self.callbacks.on_video_config {
            cb(self.callbacks.context, kind, codec_data.as_ptr(), codec_data.len());
        }
        unsafe {
            if clink_is_running() == 1 {
                let codec = self.codec_id.load(Ordering::Acquire).max(1) as u32;
                let _ = clink_push_config(kind as u32, codec, codec_data.as_ptr(), codec_data.len(), 30.0);
            }
        }
        self.log(&format!("video config {kind}: {} bytes", codec_data.len()));
        Ok(())
    }

    fn on_video_frame(
        &self,
        kind: u16,
        nalu_bytes: &[u8],
        sender_nanos: u64,
        _arrival_nanos: u64,
    ) -> Result<()> {
        if let Some(cb) = self.callbacks.on_video_frame {
            cb(
                self.callbacks.context,
                kind,
                nalu_bytes.as_ptr(),
                nalu_bytes.len(),
                sender_nanos,
            );
        }
        unsafe {
            if clink_is_running() == 1 {
                let key = if annexb_has_keyframe(nalu_bytes) { 1 } else { 0 };
                let _ = clink_push_frame(
                    kind as u32,
                    nalu_bytes.as_ptr(),
                    nalu_bytes.len(),
                    (sender_nanos / 1_000) as i64,
                    key,
                );
            }
        }
        Ok(())
    }

    fn set_video_recovery_handler(&self, kind: u16, handler: Arc<dyn Fn() + Send + Sync>) {
        let mut guard = self.recovery.lock().unwrap();
        guard.retain(|(k, _)| *k != kind);
        guard.push((kind, handler));
    }

    fn on_screen_stream_active(&self, kind: u16, active: bool) {
        self.state(&format!(
            "{}screen {kind}",
            if active { "active " } else { "inactive " }
        ));
    }

    fn on_audio_started(
        &self,
        _id: &AudioStreamId,
        format: &AudioFormat,
        _first_sample: u32,
    ) -> Result<()> {
        let json = format!(
            "{{\"codec\":\"{:?}\",\"sampleRate\":{},\"channels\":{},\"type\":\"{}\"}}",
            format.codec, format.sample_rate, format.channels, format.audio_type
        );
        if let Some(cb) = self.callbacks.on_audio_format {
            cb(self.callbacks.context, json.as_ptr(), json.len());
        }
        Ok(())
    }

    fn on_audio_rtp(
        &self,
        _id: &AudioStreamId,
        _format: &AudioFormat,
        rtp: &[u8],
        sample: u32,
    ) -> Result<()> {
        if let Some(cb) = self.callbacks.on_audio_rtp {
            cb(self.callbacks.context, rtp.as_ptr(), rtp.len(), sample);
        }
        Ok(())
    }

    fn on_audio_stopped(&self, _id: &AudioStreamId) -> Result<()> {
        Ok(())
    }

    fn on_microphone_started(&self, _id: &AudioStreamId, _config: &MicrophoneConfig) -> Result<()> {
        Ok(())
    }

    fn on_microphone_stopped(&self, _id: &AudioStreamId) -> Result<()> {
        Ok(())
    }

    fn on_iap_message(&self, bytes: &[u8]) -> Result<()> {
        let _ = bytes;
        Ok(())
    }
}
