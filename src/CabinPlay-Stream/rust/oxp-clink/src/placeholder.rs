// SPDX-FileCopyrightText: 2026 OpenXPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
// Created by riko chen on 2026-10-14

use crate::{model::*, require, Result};
use oxp_media::{
    nal::{self, Format},
    AvcConfig, HevcConfig,
};
use std::sync::Arc;
pub trait PlaceholderVideo: Send + Sync {
    fn format(&self) -> &VideoFormat;
    fn frames(&self) -> &[Arc<[u8]>];
    fn fps(&self) -> u32;
}

/// 占位片备齐的尺寸，与应用层自动分辨率阶梯一一对应。占位帧不是可有
/// 可无的填充：车机进入「已连接，正在输出」后、本机 CarPlay 还没回连
/// 的等待期里，链路上唯一的画面数据就是占位帧——2026-11-26 真机实
/// 证，1080p 协商下没有对应尺寸的占位片、整段等待期零帧，车机在输
/// 出开始正好 10 秒时以 vehicle_channel_closed 关掉通道；而 720p 轮
/// 靠占位帧喂着，干等 30 秒车机也不关。所以阶梯每一档都必须有同尺
/// 寸占位片，协商定案后按协商尺寸选片。
pub const PLACEHOLDER_SIZES: [(u32, u32); 3] = [(1920, 1080), (1280, 720), (854, 480)];

fn avc_clip_bytes(width: u32, height: u32) -> Option<&'static [u8]> {
    Some(match (width, height) {
        (1920, 1080) => include_bytes!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../kotlin/clink/src/main/resources/placeholder-1920x1080.h264"
        )),
        (1280, 720) => include_bytes!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../kotlin/clink/src/main/resources/placeholder-1280x720.h264"
        )),
        (854, 480) => include_bytes!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../kotlin/clink/src/main/resources/placeholder-854x480.h264"
        )),
        _ => return None,
    })
}

fn hevc_clip_bytes(width: u32, height: u32) -> Option<&'static [u8]> {
    Some(match (width, height) {
        (1920, 1080) => include_bytes!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../kotlin/clink/src/main/resources/placeholder-1920x1080.h265"
        )),
        (1280, 720) => include_bytes!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../kotlin/clink/src/main/resources/placeholder-1280x720.h265"
        )),
        (854, 480) => include_bytes!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../kotlin/clink/src/main/resources/placeholder-854x480.h265"
        )),
        _ => return None,
    })
}

pub struct BundledPlaceholderVideo {
    format: VideoFormat,
    frames: Vec<Arc<[u8]>>,
}
impl BundledPlaceholderVideo {
    pub fn new() -> Result<Self> {
        Ok(Self::load(1280, 720)?.ok_or("missing_placeholder_asset")?)
    }
    /// Loads the bundled clip for one ladder size; `None` when no asset
    /// is bundled for that size.
    pub fn load(width: u32, height: u32) -> Result<Option<Self>> {
        let Some(clip) = avc_clip_bytes(width, height) else {
            return Ok(None);
        };
        let units = nal::units(clip, Format::AnnexB)?;
        let sps = units.iter().find(|n| n[0] & 31 == 7).ok_or("missing_sps")?;
        let pps = units.iter().find(|n| n[0] & 31 == 8).ok_or("missing_pps")?;
        let config = AvcConfig::from_parameter_sets(sps, pps)?;
        let format = VideoFormat::create(0, VideoCodec::H264, config.into(), Some(30.0))?;
        require(
            (format.width, format.height) == (width, height),
            "placeholder_size_mismatch",
        )?;
        let mut frames = Vec::new();
        let mut current = Vec::new();
        for n in units {
            let t = n[0] & 31;
            if t == 9 && !current.is_empty() {
                frames.push(Arc::from(std::mem::take(&mut current)));
            }
            if [1, 5, 6].contains(&t) {
                current.extend_from_slice(&(n.len() as u32).to_be_bytes());
                current.extend_from_slice(n);
            }
        }
        if !current.is_empty() {
            frames.push(Arc::from(current));
        }
        require(
            frames.len() == 30 && nal::is_key_frame(&frames[0], VideoCodec::H264, Format::Avcc)?,
            "invalid_placeholder",
        )?;
        Ok(Some(Self { format, frames }))
    }
}
impl PlaceholderVideo for BundledPlaceholderVideo {
    fn format(&self) -> &VideoFormat {
        &self.format
    }
    fn frames(&self) -> &[Arc<[u8]>] {
        &self.frames
    }
    fn fps(&self) -> u32 {
        30
    }
}

/// Strips emulation-prevention bytes (00 00 03 → 00 00) from a NAL
/// payload, yielding the RBSP.
fn rbsp(payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(payload.len());
    let mut zeros = 0;
    for &b in payload {
        if zeros >= 2 && b == 3 {
            zeros = 0;
            continue;
        }
        out.push(b);
        zeros = if b == 0 { zeros + 1 } else { 0 };
    }
    out
}

pub struct BundledHevcPlaceholderVideo {
    format: VideoFormat,
    frames: Vec<Arc<[u8]>>,
}
impl BundledHevcPlaceholderVideo {
    pub fn new() -> Result<Self> {
        Ok(Self::load(1280, 720)?.ok_or("missing_placeholder_asset")?)
    }
    /// Loads the bundled clip for one ladder size; `None` when no asset
    /// is bundled for that size.
    pub fn load(width: u32, height: u32) -> Result<Option<Self>> {
        let Some(clip) = hevc_clip_bytes(width, height) else {
            return Ok(None);
        };
        let units = nal::units(clip, Format::AnnexB)?;
        // hvcC tail past the general profile/tier/level block: reserved
        // fields and four-byte NAL lengths, as in the original clip.
        let mut config = vec![
            1, 1, 0x60, 0, 0, 0, 0x90, 0, 0, 0, 0, 0, 93, 0xf0, 0, 0xfc, 0xfd, 0xf8, 0xf8, 0, 0,
            0x0f, 3,
        ];
        // The general profile/tier/level block (hvcC bytes 1..13) has the
        // same layout as the SPS RBSP's block at the same offset, so copy
        // it from this clip's own SPS instead of hardcoding it: the old
        // literal (Main, compatibility 0x60000000, level 3.1) only ever
        // described the 720p clip — the 1080p clip is level 4, and a
        // hardcoded 3.1 would leave the config contradicting its SPS.
        let sps = units
            .iter()
            .find(|n| (n[0] >> 1) & 63 == 33)
            .ok_or("missing_hevc_parameter_set")?;
        let sps_rbsp = rbsp(&sps[2..]);
        require(sps_rbsp.len() >= 13, "invalid_hevc_placeholder_sps")?;
        config[1..13].copy_from_slice(&sps_rbsp[1..13]);
        for kind in 32..=34 {
            let n = units
                .iter()
                .find(|n| (n[0] >> 1) & 63 == kind)
                .ok_or("missing_hevc_parameter_set")?;
            config.push(0x80 | kind);
            config.extend_from_slice(&1u16.to_be_bytes());
            config.extend_from_slice(&(n.len() as u16).to_be_bytes());
            config.extend_from_slice(n);
        }
        let format = VideoFormat::create(0, VideoCodec::H265, config.into(), Some(30.0))?;
        require(
            (format.width, format.height) == (width, height),
            "placeholder_size_mismatch",
        )?;
        let mut frames = Vec::new();
        let mut current = Vec::new();
        for n in units {
            if (n[0] >> 1) & 63 <= 31 {
                require(n.len() >= 3, "invalid_hevc_placeholder_slice")?;
                // first_slice_segment_in_pic_flag starts a picture without an AUD.
                if n[2] & 0x80 != 0 && !current.is_empty() {
                    frames.push(Arc::from(std::mem::take(&mut current)));
                }
                current.extend_from_slice(&(n.len() as u32).to_be_bytes());
                current.extend_from_slice(n);
            }
        }
        if !current.is_empty() {
            frames.push(Arc::from(current));
        }
        require(
            frames.len() == 30 && nal::is_key_frame(&frames[0], VideoCodec::H265, Format::Avcc)?,
            "invalid_hevc_placeholder",
        )?;
        Ok(Some(Self { format, frames }))
    }
}
impl PlaceholderVideo for BundledHevcPlaceholderVideo {
    fn format(&self) -> &VideoFormat {
        &self.format
    }
    fn frames(&self) -> &[Arc<[u8]>] {
        &self.frames
    }
    fn fps(&self) -> u32 {
        30
    }
}

/// One selected placeholder clip plus its parsed codec config, ready
/// for the muxer.
pub enum SelectedPlaceholder<'a> {
    Avc {
        video: &'a BundledPlaceholderVideo,
        config: &'a AvcConfig,
    },
    Hevc {
        video: &'a BundledHevcPlaceholderVideo,
        config: &'a HevcConfig,
    },
}
impl SelectedPlaceholder<'_> {
    pub fn video(&self) -> &dyn PlaceholderVideo {
        match self {
            Self::Avc { video, .. } => *video,
            Self::Hevc { video, .. } => *video,
        }
    }
}

struct AvcEntry {
    video: BundledPlaceholderVideo,
    config: AvcConfig,
}
struct HevcEntry {
    video: BundledHevcPlaceholderVideo,
    config: HevcConfig,
}

/// Every bundled placeholder (all ladder sizes, both codecs) with its
/// config pre-parsed, so the media worker can pick the clip matching
/// the negotiated mode each session.
pub struct PlaceholderSet {
    avc: Vec<AvcEntry>,
    hevc: Vec<HevcEntry>,
}
impl PlaceholderSet {
    pub fn new() -> Result<Self> {
        let mut avc = Vec::new();
        let mut hevc = Vec::new();
        for (width, height) in PLACEHOLDER_SIZES {
            let video = BundledPlaceholderVideo::load(width, height)?
                .ok_or("missing_placeholder_asset")?;
            let config = AvcConfig::parse(&video.format().config)?;
            avc.push(AvcEntry { video, config });
            let video = BundledHevcPlaceholderVideo::load(width, height)?
                .ok_or("missing_placeholder_asset")?;
            let config = HevcConfig::parse(&video.format().config)?;
            hevc.push(HevcEntry { video, config });
        }
        Ok(Self { avc, hevc })
    }
    /// The clip whose size equals the negotiated mode, or `None` when
    /// the mode is not one of the bundled sizes (the worker then skips
    /// placeholder frames and relies on live frames only).
    pub fn select(
        &self,
        codec: VideoCodec,
        width: u32,
        height: u32,
    ) -> Option<SelectedPlaceholder<'_>> {
        match codec {
            VideoCodec::H264 => self
                .avc
                .iter()
                .find(|e| (e.video.format.width, e.video.format.height) == (width, height))
                .map(|e| SelectedPlaceholder::Avc {
                    video: &e.video,
                    config: &e.config,
                }),
            VideoCodec::H265 => self
                .hevc
                .iter()
                .find(|e| (e.video.format.width, e.video.format.height) == (width, height))
                .map(|e| SelectedPlaceholder::Hevc {
                    video: &e.video,
                    config: &e.config,
                }),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn set_loads_every_ladder_size_in_both_codecs() {
        let set = PlaceholderSet::new().unwrap();
        for (width, height) in PLACEHOLDER_SIZES {
            for codec in [VideoCodec::H264, VideoCodec::H265] {
                let selected = set
                    .select(codec, width, height)
                    .unwrap_or_else(|| panic!("no placeholder for {codec:?} {width}x{height}"));
                let video = selected.video();
                assert_eq!((video.format().width, video.format().height), (width, height));
                assert_eq!(video.frames().len(), 30);
            }
        }
    }

    #[test]
    fn select_unknown_size_is_none() {
        let set = PlaceholderSet::new().unwrap();
        assert!(set.select(VideoCodec::H264, 640, 360).is_none());
        assert!(set.select(VideoCodec::H265, 640, 360).is_none());
        assert!(set.select(VideoCodec::H264, 1920, 720).is_none());
    }

    #[test]
    fn hevc_config_level_matches_each_clips_sps() {
        // The hvcC level byte is copied from each clip's own SPS: the
        // 720p/480p clips are level 3.1 (93), the 1080p clip is level 4
        // (120) — a hardcoded 93 for all three was the old template.
        let set = PlaceholderSet::new().unwrap();
        for (width, height, level) in [(1920, 1080, 120), (1280, 720, 93), (854, 480, 93)] {
            match set.select(VideoCodec::H265, width, height).unwrap() {
                SelectedPlaceholder::Hevc { config, .. } => {
                    assert_eq!(config.level, level, "{width}x{height}");
                    assert_eq!((config.width, config.height), (width, height));
                }
                _ => panic!("expected HEVC selection for {width}x{height}"),
            }
        }
    }

    #[test]
    fn avc_config_dimensions_match_each_size() {
        let set = PlaceholderSet::new().unwrap();
        for (width, height) in PLACEHOLDER_SIZES {
            match set.select(VideoCodec::H264, width, height).unwrap() {
                SelectedPlaceholder::Avc { config, .. } => {
                    assert_eq!((config.width, config.height), (width, height));
                }
                _ => panic!("expected AVC selection for {width}x{height}"),
            }
        }
    }
}
