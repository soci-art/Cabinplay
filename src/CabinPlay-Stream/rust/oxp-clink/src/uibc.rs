// SPDX-FileCopyrightText: 2026 OpenXPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
// Created by riko chen on 2026-10-14

use crate::{
    model::*,
    protocol::json_object,
    require,
    trace::{now_nanos, ClinkTrace, ClinkTraceEvent},
    Result,
};
use std::{
    collections::BTreeMap,
    sync::{Arc, Mutex},
};

/// 按车校准出的画面区矩形：四边是触控面归一化坐标（原始触控点先按
/// 触控面尺寸归一化），即 CarPlay 画面在车机触控面上的真实位置。协
/// 议只报屏与画面区的尺寸、不报位置，居中假设对画面不居中的车（如
/// 左侧留自家边栏的 UNI-V）必然偏——校准就是把这个矩形实测出来。
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TouchCalibration {
    pub left: f64,
    pub right: f64,
    pub top: f64,
    pub bottom: f64,
}

/// 校准参数的来源，定锚日志据此区分，方便对账是哪一路在生效。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TouchCalSource {
    /// App 内置预置（目前只有车主本人的 UNI-V：实测照片＋车机声明
    /// 尺寸推算，见 Swift 侧 TouchCalibrationStore 的注释）。
    Preset,
    /// 用户在设置里用描边法校准出的。
    Manual,
}

impl TouchCalSource {
    pub fn label(self) -> &'static str {
        match self {
            TouchCalSource::Preset => "预置校准",
            TouchCalSource::Manual => "手动校准",
        }
    }
}

/// 触控换算模式：取证三档（直通/居中/按校准）已完成使命——车主
/// 实测居中模型最准并定稿，校准功能整套撤销。现行口径：默认就是
/// Centered，宿主 FFI 也已钉死居中，任何路径都回不到按校准/直
/// 通。Passthrough/Calibrated 两个变体只作核心内部的历史换算路
/// 径保留（各自有单测锚住行为），App 层不再能选中它们。
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum TouchMode {
    Passthrough,
    #[default]
    Centered,
    Calibrated,
}

impl TouchMode {
    pub fn label(self) -> &'static str {
        match self {
            TouchMode::Passthrough => "直通（不校正）",
            TouchMode::Centered => "居中模型",
            TouchMode::Calibrated => "按校准",
        }
    }
}

/// 触控校准的共享状态：宿主（FFI）持有、建会话时注入解码器，运行
/// 中可改（校准完成立刻生效，不必重开会话）。capture=true 是校准
/// 捕获中：解码器只吐触控面归一化的原始坐标、不做任何校正，上层
/// 据此记录用户点下的边；捕获期间不转发给 iOS 由上层自己拦。
#[derive(Default)]
pub struct TouchCalState {
    pub calibration: Option<(TouchCalibration, TouchCalSource)>,
    pub mode: TouchMode,
    pub capture: bool,
    /// 车机最近声明的几何（set_display_geometry 时回写）：宿主做校
    /// 准自检（矩形宽高比 vs videoDisplay 比例）时读。
    pub surface: Option<(u32, u32)>,
    pub visible: Option<(u32, u32)>,
}

/// Android track IDs retain stable slots 0 and 1; insertion order is significant.
pub struct UibcDecoder {
    origin: Origin,
    trace: Option<Arc<dyn ClinkTrace>>,
    session: u64,
    active: Vec<(u32, u8, (f64, f64))>,
    last_view_size: Option<(u32, u32)>,
    on_view_size: Option<Box<dyn Fn(u32, u32) + Send + Sync>>,
    on_diagnostic: Option<Box<dyn Fn(String) + Send + Sync>>,
    /// Head-unit geometry from the CONTROL configuration: surface (screen)
    /// size from fields 2/3 and the visible video display size from 5/6.
    display_surface: Option<(u32, u32)>,
    display_visible: Option<(u32, u32)>,
    anchor_reported: bool,
    touch_anchor_reported: bool,
    /// 按车校准的共享状态（宿主注入）；None 时行为与旧版逐位一致。
    cal_state: Option<Arc<Mutex<TouchCalState>>>,
    cal_anchor_signature: Option<String>,
    /// 逐笔触控日志的移动节流：按下/抬起逐笔必打，移动 200ms 内
    /// 只打一笔、其间合并的笔数记下来随下一笔带出——取证要逐笔
    /// 对账，又不能让拖动把日志刷爆（App 日志上限 400 行）。
    last_move_log_at: Option<std::time::Instant>,
    move_log_skipped: u64,
}
impl UibcDecoder {
    pub fn new(origin: Origin) -> Self {
        Self {
            origin,
            trace: None,
            session: 0,
            active: Vec::new(),
            last_view_size: None,
            on_view_size: None,
            on_diagnostic: None,
            display_surface: None,
            display_visible: None,
            anchor_reported: false,
            touch_anchor_reported: false,
            cal_state: None,
            cal_anchor_signature: None,
            last_move_log_at: None,
            move_log_skipped: 0,
        }
    }
    pub fn with_cal_state(mut self, state: Arc<Mutex<TouchCalState>>) -> Self {
        self.cal_state = Some(state);
        self
    }
    pub fn with_trace(mut self, trace: Arc<dyn ClinkTrace>, session: u64) -> Self {
        self.trace = Some(trace);
        self.session = session;
        self
    }
    fn input(
        &self,
        kind: &str,
        coordinates: Vec<(f64, f64)>,
        raw_coordinates: Vec<(i64, i64)>,
        stream_size: (u32, u32),
        view_size: Option<(u32, u32)>,
    ) {
        if let Some(trace) = &self.trace {
            trace.record(ClinkTraceEvent::Input {
                at_nanos: now_nanos(),
                session: self.session,
                kind: kind.into(),
                coordinates,
                raw_coordinates,
                stream_size: Some(stream_size),
                view_size,
            });
        }
    }
    pub fn with_view_size(
        mut self,
        on_view_size: impl Fn(u32, u32) + Send + Sync + 'static,
    ) -> Self {
        self.on_view_size = Some(Box::new(on_view_size));
        self
    }
    pub fn with_diagnostic(
        mut self,
        on_diagnostic: impl Fn(String) + Send + Sync + 'static,
    ) -> Self {
        self.on_diagnostic = Some(Box::new(on_diagnostic));
        self
    }
    fn diagnostic(&self, message: String) {
        if let Some(report) = &self.on_diagnostic {
            report(message);
        }
    }
    /// Feed the head-unit geometry declared in the CONTROL configuration:
    /// `surface` is the screen size (fields 2/3), `visible` the video
    /// display size (fields 5/6). The first time a visible size shows up,
    /// one anchor line goes to the diagnostic channel so a device log can
    /// be checked against the correction that will be applied.
    pub fn set_display_geometry(
        &mut self,
        surface: (u32, u32),
        visible: Option<(u32, u32)>,
    ) {
        if surface.0 > 0 && surface.1 > 0 {
            self.display_surface = Some(surface);
        }
        if let Some(visible) = visible {
            if visible.0 > 0 && visible.1 > 0 {
                self.display_visible = Some(visible);
            }
        }
        if let Some(state) = &self.cal_state {
            let mut state = state.lock().unwrap();
            if let Some(s) = self.display_surface {
                state.surface = Some(s);
            }
            if let Some(v) = self.display_visible {
                state.visible = Some(v);
            }
        }
        if !self.anchor_reported {
            if let (Some(s), Some(v)) = (self.display_surface, self.display_visible) {
                self.anchor_reported = true;
                let drift_x = (s.0 as f64 - v.0 as f64) / 2.0;
                let drift_y = (s.1 as f64 - v.1 as f64) / 2.0;
                self.diagnostic(format!(
                    "触控定锚：车机声明 screen {}×{}，videoDisplay {}×{}，校正 drift X {drift_x:.1}、Y {drift_y:.1}（原始坐标先减 drift 再按 videoDisplay 归一化；两尺寸相同则不校正、与旧行为一致）",
                    s.0, s.1, v.0, v.1
                ));
            }
        }
        self.report_calibration_anchor();
    }
    /// 本轮触控的换算方式标签（逐笔日志与定锚共用）：把「模式＋
    /// 校准来源」合成一句人话，日志里一眼看清这笔触控按哪一路算。
    fn conversion_label(
        snapshot: Option<(Option<(TouchCalibration, TouchCalSource)>, bool, TouchMode)>,
    ) -> String {
        match snapshot {
            Some((_, true, _)) => "校准捕获（原始直出、不转发）".into(),
            Some((_, false, TouchMode::Passthrough)) => "直通（不校正）".into(),
            Some((Some((_, source)), false, TouchMode::Calibrated)) => {
                format!("{}（画面区矩形）", source.label())
            }
            Some((None, false, TouchMode::Calibrated)) => {
                "居中模型（按校准档，但这台车没有校准记录）".into()
            }
            Some((_, false, TouchMode::Centered)) => "居中模型（设置指定）".into(),
            None => "居中模型（旧行为）".into(),
        }
    }

    /// 校准来源定锚：几何已知后、校准状态（参数、模式或捕获开关）
    /// 一有变化就打一行，说明这一轮触控到底按哪一路换算——直通／
    /// 居中模型／预置校准／手动校准（带矩形数值）在日志里可区分。
    fn report_calibration_anchor(&mut self) {
        let Some(state) = &self.cal_state else { return };
        let (calibration, capture, mode) = {
            let state = state.lock().unwrap();
            (state.calibration, state.capture, state.mode)
        };
        let signature = match (calibration, capture) {
            (Some((cal, source)), capture) => format!(
                "{source:?}|{:.4}|{:.4}|{:.4}|{:.4}|{capture}|{mode:?}",
                cal.left, cal.right, cal.top, cal.bottom
            ),
            (None, capture) => format!("none|{capture}|{mode:?}"),
        };
        if self.cal_anchor_signature.as_deref() == Some(signature.as_str()) {
            return;
        }
        if self.display_surface.is_none() {
            return;
        }
        self.cal_anchor_signature = Some(signature);
        match (mode, calibration) {
            (TouchMode::Passthrough, _) => self.diagnostic(
                "触控定锚：触控模式=直通（不做任何校正，原始坐标按触控面归一化后原样转发）"
                    .into(),
            ),
            (TouchMode::Centered, _) => self.diagnostic(
                "触控定锚：触控模式=居中模型（无视校准记录，按 screen 与 videoDisplay 的居中差换算）"
                    .into(),
            ),
            (TouchMode::Calibrated, Some((cal, source))) => self.diagnostic(format!(
                "触控定锚：校准来源={}，画面区矩形 left={:.4} right={:.4} top={:.4} bottom={:.4}（触控面归一化坐标），触控按此矩形换算",
                source.label(),
                cal.left,
                cal.right,
                cal.top,
                cal.bottom
            )),
            (TouchMode::Calibrated, None) => self.diagnostic(
                "触控定锚：校准来源=居中模型（这台车没有校准记录，按 screen 与 videoDisplay 的居中差换算）"
                    .into(),
            ),
        }
    }
    /// 原始触控坐标按触控面归一化（触控面未知时用流尺寸兜底——捕获
    /// 与应用走同一个归一化口径，校准结果自洽）。
    fn raw_norm(raw: i64, surface: Option<u32>, stream: u32) -> f64 {
        let denom = surface.filter(|s| *s > 0).unwrap_or(stream);
        (raw as f64 / denom as f64).clamp(0.0, 1.0)
    }
    /// 校准矩形内一轴的换算：矩形边 → 0/1。矩形退化（宽高过小）时回
    /// 落原值，绝不把整轴触控压到一条线上。
    fn cal_apply(value: f64, lo: f64, hi: f64) -> f64 {
        if hi - lo < 0.05 {
            return value.clamp(0.0, 1.0);
        }
        ((value - lo) / (hi - lo)).clamp(0.0, 1.0)
    }
    /// Normalize one raw coordinate. CarWith (the head unit's reference
    /// host) corrects every touch as `(raw - drift) * scale` with
    /// `drift = (surface - visible) / 2` per axis, because raw coordinates
    /// live in the head unit's screen space while the video occupies only
    /// the visible sub-rectangle. Fallback semantics are strict: without a
    /// trustworthy visible size, or when it equals the surface on this
    /// axis, the result is exactly the legacy `raw / stream_size`.
    fn correct(raw: i64, stream: u32, surface: Option<u32>, visible: Option<u32>) -> f64 {
        if let (Some(s), Some(v)) = (surface, visible) {
            if s > 0 && v > 0 && v != s {
                let drift = (s as f64 - v as f64) / 2.0;
                return ((raw as f64 - drift) / v as f64).clamp(0.0, 1.0);
            }
        }
        (raw as f64 / stream as f64).clamp(0.0, 1.0)
    }
    fn report_view_size(&mut self, size: Option<(u32, u32)>) {
        if size.is_none() || size == self.last_view_size {
            return;
        }
        self.last_view_size = size;
        if let Some(trace) = &self.trace {
            let (w, h) = size.unwrap();
            trace.record(ClinkTraceEvent::Link {
                at_nanos: now_nanos(),
                session: self.session,
                stage: "view_size".into(),
                fields: BTreeMap::from([
                    ("width".into(), w.to_string()),
                    ("height".into(), h.to_string()),
                ]),
            });
        }
        if let Some(report) = &self.on_view_size {
            let (width, height) = size.unwrap();
            report(width, height);
        }
    }
    pub fn release(&mut self) -> ControlEvent {
        self.active.clear();
        ControlEvent::Touch {
            screen: 0,
            contacts: Vec::new(),
            origin: self.origin.clone(),
        }
    }
    pub fn decode(
        &mut self,
        bytes: &[u8],
        stream_size: (u32, u32),
    ) -> Result<Option<ControlEvent>> {
        require(bytes.len() <= 65536, "invalid_uibc")?;
        let obj = json_object(bytes)?;
        require(obj.len() <= 128, "invalid_uibc")?;
        let number = |k: &str, default: Option<i64>| -> Result<i64> {
            match obj.get(k) {
                None => default.ok_or_else(|| format!("missing_{k}").into()),
                Some(v) => v.as_i64().ok_or_else(|| format!("invalid_{k}").into()),
            }
        };
        match number("type", None)? {
            2 => {
                let action = number("action", Some(0))?;
                let meta = number("metaState", Some(0))?;
                let code = number("keycode", None)?;
                require(
                    (0..=65535).contains(&code)
                        && (0..=2).contains(&action)
                        && (0..=0xffffffff).contains(&meta),
                    "invalid_uibc",
                )?;
                if self.trace.is_some() {
                    let dimension = |key: &str| {
                        obj.get(key)?
                            .as_i64()
                            .filter(|n| (1..=i32::MAX as i64).contains(n))
                            .map(|n| n as u32)
                    };
                    self.input(
                        match action {
                            0 => "key_down",
                            1 => "key_up",
                            _ => "key_multiple",
                        },
                        Vec::new(),
                        Vec::new(),
                        stream_size,
                        dimension("width").zip(dimension("height")),
                    );
                }
                return key(code as u16, action as u8, self.origin.clone());
            }
            1 => {}
            _ => return Ok(None),
        }
        let dimension = |key: &str| {
            obj.get(key)?
                .as_i64()
                .filter(|n| (1..=i32::MAX as i64).contains(n))
                .map(|n| n as u32)
        };
        let view_size = dimension("width").zip(dimension("height"));
        let count = number("count", None)?;
        let action = number("action", None)?;
        require(
            (0..=16).contains(&count) && (0..=65535).contains(&action),
            "invalid_uibc",
        )?;
        let masked = action & 255;
        let index = ((action >> 8) & 255) as usize;
        if masked == 3 {
            self.report_view_size(view_size);
            self.diagnostic("触控：车机报取消，全部触点抬起".into());
            if self.trace.is_some() {
                self.input(
                    "touch_cancel",
                    Vec::new(),
                    Vec::new(),
                    stream_size,
                    view_size,
                );
            }
            return Ok(Some(self.release()));
        }
        require(
            count > 0 && index < count as usize && [0, 1, 2, 5, 6].contains(&masked),
            "invalid_uibc",
        )?;
        let (w, h) = stream_size;
        require(w > 0 && h > 0, "invalid_video_size")?;
        // Touch geometry: the correction pair is the head unit's own
        // CONTROL declaration — surface from fields 2/3, visible from
        // fields 5/6. The message's own width/height is only the view
        // report (see report_view_size); it never feeds the correction.
        let surface = self.display_surface;
        let visible = self.display_visible;
        // 校准状态快照（每包读一次）：捕获中只吐原始坐标；模式决定
        // 换算路径——直通原样、居中强制 drift 模型、按校准有矩形用
        // 矩形没有回落居中（旧行为逐位不变）。
        let cal_snapshot = self.cal_state.as_ref().map(|state| {
            let state = state.lock().unwrap();
            (state.calibration, state.capture, state.mode)
        });
        let mut points = Vec::new();
        // 逐笔日志取第一点的原始/换算对（多点触控其余点同理换算）。
        let mut first_point: Option<(i64, i64, f64, f64)> = None;
        for n in 0..count {
            let track = number(&format!("trackID{n}"), None)?;
            require(
                (0..=0xffffffff).contains(&track)
                    && !points.iter().any(|(t, _)| *t == track as u32),
                "invalid_uibc_track",
            )?;
            let raw_x = number(&format!("x{n}"), None)?;
            let raw_y = number(&format!("y{n}"), None)?;
            let (x, y) = match cal_snapshot {
                Some((_, true, _)) | Some((_, false, TouchMode::Passthrough)) => (
                    Self::raw_norm(raw_x, surface.map(|s| s.0), w),
                    Self::raw_norm(raw_y, surface.map(|s| s.1), h),
                ),
                Some((Some((cal, _)), false, TouchMode::Calibrated)) => (
                    Self::cal_apply(
                        Self::raw_norm(raw_x, surface.map(|s| s.0), w),
                        cal.left,
                        cal.right,
                    ),
                    Self::cal_apply(
                        Self::raw_norm(raw_y, surface.map(|s| s.1), h),
                        cal.top,
                        cal.bottom,
                    ),
                ),
                _ => (
                    Self::correct(raw_x, w, surface.map(|s| s.0), visible.map(|v| v.0)),
                    Self::correct(raw_y, h, surface.map(|s| s.1), visible.map(|v| v.1)),
                ),
            };
            if n == 0 {
                first_point = Some((raw_x, raw_y, x, y));
                if !self.touch_anchor_reported {
                    self.touch_anchor_reported = true;
                    let model = Self::conversion_label(cal_snapshot);
                    self.diagnostic(format!(
                        "触控定锚：第一笔触控原始坐标 ({raw_x}, {raw_y})，校正后归一化 ({x:.4}, {y:.4})（触控面 {}，videoDisplay {}，换算方式：{model}）",
                        surface
                            .map(|s| format!("{}×{}", s.0, s.1))
                            .unwrap_or_else(|| "未知".into()),
                        visible
                            .map(|v| format!("{}×{}", v.0, v.1))
                            .unwrap_or_else(|| "未知".into()),
                    ));
                }
            }
            points.push((track as u32, (x, y)));
        }
        // 逐笔触控取证（为定模型取数）：按下/抬起逐笔必打原始→换
        // 算；移动 200ms 节流一笔、合并笔数随下一笔带出——关键样
        // 本（落点/抬点）一笔不丢，拖动又不至于刷爆日志。
        if let Some((raw_x, raw_y, x, y)) = first_point {
            let label = Self::conversion_label(cal_snapshot);
            let raw_nx = Self::raw_norm(raw_x, surface.map(|s| s.0), w);
            let raw_ny = Self::raw_norm(raw_y, surface.map(|s| s.1), h);
            match masked {
                2 => {
                    let now = std::time::Instant::now();
                    let due = self
                        .last_move_log_at
                        .is_none_or(|t| now.duration_since(t) >= std::time::Duration::from_millis(200));
                    if due {
                        self.last_move_log_at = Some(now);
                        let skipped = std::mem::take(&mut self.move_log_skipped);
                        self.diagnostic(format!(
                            "触控：原始 ({raw_x}, {raw_y})（归一化 ({raw_nx:.4}, {raw_ny:.4})）→ 换算后 ({x:.4}, {y:.4})，方式：{label}，动作：移动{}",
                            if skipped > 0 {
                                format!("（其间合并 {skipped} 笔移动）")
                            } else {
                                String::new()
                            }
                        ));
                    } else {
                        self.move_log_skipped += 1;
                    }
                }
                kind => {
                    let action = match kind {
                        0 | 5 => "按下",
                        1 | 6 => "抬起",
                        _ => "其他",
                    };
                    self.diagnostic(format!(
                        "触控：原始 ({raw_x}, {raw_y})（归一化 ({raw_nx:.4}, {raw_ny:.4})）→ 换算后 ({x:.4}, {y:.4})，方式：{label}，动作：{action}"
                    ));
                }
            }
        }
        let trace_points = if self.trace.is_some() {
            Some((
                points.iter().map(|(_, p)| *p).collect(),
                (0..count)
                    .map(|n| {
                        Ok((
                            number(&format!("x{n}"), None)?,
                            number(&format!("y{n}"), None)?,
                        ))
                    })
                    .collect::<Result<Vec<_>>>()?,
            ))
        } else {
            None
        };
        let lifted = if masked == 1 || masked == 6 {
            Some(points[index].0)
        } else {
            None
        };
        let mut contacts = Vec::new();
        let mut occupied: Vec<u8> = self.active.iter().map(|(_, s, _)| *s).collect();
        let old = std::mem::take(&mut self.active);
        for (track, slot, previous) in old {
            let p = points.iter().find(|(t, _)| *t == track).map(|(_, p)| *p);
            let pressed = Some(track) != lifted && p.is_some() && masked != 1;
            let p = p.unwrap_or(previous);
            contacts.push(TouchContact::new(slot, p.0, p.1, pressed)?);
            if pressed {
                self.active.push((track, slot, p));
            }
        }
        for (track, p) in points {
            if Some(track) != lifted
                && masked != 1
                && !self.active.iter().any(|(t, _, _)| *t == track)
            {
                if let Some(slot) = (0..=1).find(|s| !occupied.contains(s)) {
                    occupied.push(slot);
                    self.active.push((track, slot, p));
                    contacts.push(TouchContact::new(slot, p.0, p.1, true)?);
                }
            }
        }
        self.report_view_size(view_size);
        if let Some((points, raw)) = trace_points {
            self.input(
                match masked {
                    0 => "touch_down",
                    1 => "touch_up",
                    2 => "touch_move",
                    5 => "pointer_down",
                    _ => "pointer_up",
                },
                points,
                raw,
                stream_size,
                view_size,
            );
        }
        Ok(Some(ControlEvent::Touch {
            screen: 0,
            contacts,
            origin: self.origin.clone(),
        }))
    }
}
pub fn key(android_code: u16, action: u8, origin: Origin) -> Result<Option<ControlEvent>> {
    require(action <= 2, "invalid_key_action")?;
    let code = match android_code {
        3 => KeyCode::Home,
        4 => KeyCode::Back,
        23 | 66 => KeyCode::Select,
        19 => KeyCode::KnobUp,
        20 => KeyCode::KnobDown,
        21 => KeyCode::KnobLeft,
        22 => KeyCode::KnobRight,
        85 => KeyCode::PlayPause,
        87 => KeyCode::Next,
        88 => KeyCode::Previous,
        231 => KeyCode::Voice,
        _ => return Ok(None),
    };
    Ok(if action == 2 {
        None
    } else {
        Some(ControlEvent::Key {
            code,
            down: action == 0,
            origin,
        })
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn origin() -> Origin {
        Origin {
            output_id: "test".into(),
            client_id: "hu".into(),
        }
    }

    fn touch_body(x: i64, y: i64, view: Option<(u32, u32)>) -> Vec<u8> {
        let view = match view {
            Some((w, h)) => format!(r#","width":{w},"height":{h}"#),
            None => String::new(),
        };
        format!(
            r#"{{"type":1,"count":1,"action":0,"trackID0":7,"x0":{x},"y0":{y}{view}}}"#
        )
        .into_bytes()
    }

    fn first_contact(event: Option<ControlEvent>) -> (f64, f64) {
        match event {
            Some(ControlEvent::Touch { contacts, .. }) => {
                assert_eq!(contacts.len(), 1);
                (contacts[0].x, contacts[0].y)
            }
            other => panic!("expected a touch event, got {other:?}"),
        }
    }

    /// CarWith's correction: drift = (surface - visible) / 2 per axis,
    /// normalized = (raw - drift) / visible. X axis has surface == visible
    /// here, so it must stay on the legacy path.
    #[test]
    fn drift_correction_matches_carwith_formula() {
        let mut decoder = UibcDecoder::new(origin());
        decoder.set_display_geometry((1920, 1080), Some((1920, 960)));
        let body = touch_body(960, 540, Some((1920, 1080)));
        let (x, y) = first_contact(decoder.decode(&body, (1920, 1080)).unwrap());
        assert_eq!(x, 960.0 / 1920.0);
        assert_eq!(y, (540.0 - 60.0) / 960.0);
    }

    /// A differing view report in the message must not engage the
    /// correction: only the CONTROL pair (2/3 vs 5/6) counts. This mirrors
    /// the transport test where the head unit reports several view sizes
    /// while its declared screen and video display sizes are equal.
    #[test]
    fn message_view_size_does_not_engage_correction() {
        let mut decoder = UibcDecoder::new(origin());
        decoder.set_display_geometry((1532, 1013), Some((1532, 1013)));
        let body = touch_body(640, 360, Some((1814, 1200)));
        let (x, y) = first_contact(decoder.decode(&body, (1280, 720)).unwrap());
        assert_eq!(x, 640.0 / 1280.0);
        assert_eq!(y, 360.0 / 720.0);
    }

    /// No geometry at all: output must be bitwise the legacy raw/stream.
    #[test]
    fn no_geometry_is_legacy_behavior() {
        let mut decoder = UibcDecoder::new(origin());
        let body = touch_body(333, 111, None);
        let (x, y) = first_contact(decoder.decode(&body, (1280, 720)).unwrap());
        assert_eq!(x, 333.0 / 1280.0);
        assert_eq!(y, 111.0 / 720.0);
    }

    /// Visible == surface (the UNI-V geometry measured on device): the
    /// correction must not engage, output stays the legacy raw/stream.
    #[test]
    fn equal_sizes_do_not_engage_correction() {
        let mut decoder = UibcDecoder::new(origin());
        decoder.set_display_geometry((1280, 720), Some((1280, 720)));
        let body = touch_body(640, 360, Some((1280, 720)));
        let (x, y) = first_contact(decoder.decode(&body, (1280, 720)).unwrap());
        assert_eq!(x, 640.0 / 1280.0);
        assert_eq!(y, 360.0 / 720.0);
    }

    /// Per-car calibration (the UNI-V preset shape: picture flush right,
    /// full height on a 1920×720 surface): the rect edges map to 0/1 and
    /// the rect center maps to 0.5, replacing the centered drift model.
    /// The mode is named explicitly: the TouchMode default changed from
    /// Calibrated to Centered when calibration was retired app-side,
    /// and this test anchors the Calibrated path itself, not the default.
    #[test]
    fn calibration_rect_maps_edges_and_center() {
        let state = Arc::new(Mutex::new(TouchCalState {
            calibration: Some((
                TouchCalibration {
                    left: 120.0 / 1920.0,
                    right: 1.0,
                    top: 0.0,
                    bottom: 1.0,
                },
                TouchCalSource::Preset,
            )),
            mode: TouchMode::Calibrated,
            capture: false,
            ..Default::default()
        }));
        let mut decoder = UibcDecoder::new(origin()).with_cal_state(state);
        decoder.set_display_geometry((1920, 720), Some((1800, 720)));
        let (x, y) = first_contact(
            decoder
                .decode(&touch_body(120, 360, None), (1800, 720))
                .unwrap(),
        );
        assert_eq!((x, y), (0.0, 0.5));
        let (x, y) = first_contact(
            decoder
                .decode(&touch_body(1020, 360, None), (1800, 720))
                .unwrap(),
        );
        assert_eq!((x, y), (0.5, 0.5));
        let (x, y) = first_contact(
            decoder
                .decode(&touch_body(1920, 720, None), (1800, 720))
                .unwrap(),
        );
        assert_eq!((x, y), (1.0, 1.0));
    }

    /// Passthrough mode (取证档): even with a calibration on file the
    /// raw surface-normalized coordinates go out unchanged, so one
    /// session can A/B the models against identical taps.
    #[test]
    fn passthrough_mode_passes_raw_coordinates() {
        let state = Arc::new(Mutex::new(TouchCalState {
            calibration: Some((
                TouchCalibration {
                    left: 0.0625,
                    right: 1.0,
                    top: 0.0,
                    bottom: 1.0,
                },
                TouchCalSource::Preset,
            )),
            mode: TouchMode::Passthrough,
            capture: false,
            ..Default::default()
        }));
        let mut decoder = UibcDecoder::new(origin()).with_cal_state(state);
        decoder.set_display_geometry((1920, 720), Some((1800, 720)));
        let (x, y) = first_contact(
            decoder
                .decode(&touch_body(480, 180, None), (1800, 720))
                .unwrap(),
        );
        assert_eq!((x, y), (0.25, 0.25));
    }

    /// Centered mode (取证档): a calibration on file is ignored and
    /// the centered drift model applies — (1020-60)/1800, not the
    /// preset rect's 0.5.
    #[test]
    fn centered_mode_ignores_calibration() {
        let state = Arc::new(Mutex::new(TouchCalState {
            calibration: Some((
                TouchCalibration {
                    left: 120.0 / 1920.0,
                    right: 1.0,
                    top: 0.0,
                    bottom: 1.0,
                },
                TouchCalSource::Preset,
            )),
            mode: TouchMode::Centered,
            capture: false,
            ..Default::default()
        }));
        let mut decoder = UibcDecoder::new(origin()).with_cal_state(state);
        decoder.set_display_geometry((1920, 720), Some((1800, 720)));
        let (x, y) = first_contact(
            decoder
                .decode(&touch_body(1020, 360, None), (1800, 720))
                .unwrap(),
        );
        assert_eq!((x, y), ((1020.0 - 60.0) / 1800.0, 0.5));
    }

    /// Capture mode (calibration in progress): coordinates pass through
    /// as raw surface-normalized values even when a calibration exists,
    /// so the host records the user's actual edge taps.
    #[test]
    fn capture_mode_passes_raw_coordinates() {
        let state = Arc::new(Mutex::new(TouchCalState {
            calibration: Some((
                TouchCalibration {
                    left: 0.0625,
                    right: 1.0,
                    top: 0.0,
                    bottom: 1.0,
                },
                TouchCalSource::Manual,
            )),
            capture: true,
            ..Default::default()
        }));
        let mut decoder = UibcDecoder::new(origin()).with_cal_state(state);
        decoder.set_display_geometry((1920, 720), Some((1800, 720)));
        let (x, y) = first_contact(
            decoder
                .decode(&touch_body(480, 180, None), (1800, 720))
                .unwrap(),
        );
        assert_eq!((x, y), (0.25, 0.25));
    }
}
