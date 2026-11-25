// SPDX-FileCopyrightText: 2026 OpenXPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// IosMediaSink — the bridge between the CarPlay protocol engine and the Swift
// app. Frames arrive as Annex-B NAL units with the decoder configuration
// separate, which is exactly what VideoToolbox wants.

use crate::{OxpCallbacks, Result};
use carplay_airplay::{AudioFormat, AudioStreamId, MediaSink, MicrophoneConfig, VideoCodec};
use std::sync::{Arc, Mutex};

#[derive(Clone)]
pub struct IosMediaSink {
    callbacks: OxpCallbacks,
    recovery: Arc<Mutex<Vec<(u16, Arc<dyn Fn() + Send + Sync>)>>>,
}

impl IosMediaSink {
    pub fn new(callbacks: OxpCallbacks) -> Self {
        Self {
            callbacks,
            recovery: Arc::new(Mutex::new(Vec::new())),
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
        if let Some(cb) = self.callbacks.on_video_codec {
            cb(self.callbacks.context, kind, Self::codec_id(codec));
        }
        self.log(&format!("video codec {codec:?} on stream {kind}"));
        Ok(())
    }

    fn on_video_config(&self, kind: u16, codec_data: &[u8]) -> Result<()> {
        if let Some(cb) = self.callbacks.on_video_config {
            cb(self.callbacks.context, kind, codec_data.as_ptr(), codec_data.len());
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
