// SPDX-FileCopyrightText: 2026 OpenXPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// The app shell: three tabs （驾驶舱 / 日志 / 设置）.
// 主线：本机 CarPlay 会话（LocalCarPlaySession）出帧 → 蓝牙 UCar 配对 →
// 拿到 ServerInfo 后组网（UCarNetworkJoiner）→ CarLink（clink）把帧送上
// 车机、把车机触摸/按键回送本机会话。全程没有手填表单：车机地址入网后
// 取组主地址、本机 IP 按目标网段现取现验、配对码只用蓝牙卡那一个输入框、
// 热点凭据由 ServerInfo 带回后静默存下。

import SwiftUI
import AVFoundation
import UIKit

@main
struct OpenXPlayApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    UIApplication.shared.isIdleTimerDisabled = true
                }
        }
    }
}

/// 预览宿主视图：显示层就是视图的后备层（layerClass），frame 由 UIKit
/// 布局自动跟随视图——照 CarWithin 原版 H264Surface 的托管方式。之前用
/// 游离 AVSampleBufferDisplayLayer 当子层、手写同步 frame，可能停在零
/// 尺寸（enqueue 全成功、层无报错、肉眼纯黑，诊断 B1 头号嫌疑）。
final class PreviewHostView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
    var onWindowChange: ((Bool) -> Void)?
    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChange?(window != nil)
    }
}

struct VideoSurface: UIViewRepresentable {
    let decoder: VideoDecoder

    func makeUIView(context: Context) -> PreviewHostView {
        let view = PreviewHostView()
        view.backgroundColor = .black
        decoder.attachLayer(view.displayLayer)
        view.onWindowChange = { [weak decoder] inWindow in
            decoder?.logHostWindow(inWindow)
        }
        decoder.logHostGeometry(bounds: view.bounds)
        return view
    }

    func updateUIView(_ view: PreviewHostView, context: Context) {
        if decoder.layer !== view.displayLayer {
            decoder.attachLayer(view.displayLayer)
        }
        decoder.logHostGeometry(bounds: view.bounds)
    }
}

struct ContentView: View {
    @StateObject private var bleProbe = BleProbe()
    @StateObject private var localSession = LocalCarPlaySession()
    @State private var decoder = VideoDecoder()
    @State private var log: [String] = []
    @State private var tab = 0
    @State private var hasVideo = false
    @State private var blePin = ""
    @State private var carLinkState = CarLinkCore.State.idle
    @State private var carLinkRunning = false
    @State private var targetSize: (Int, Int) = (1280, 720)

    // UCar 后段流程状态（全部自动推导，不再有手填项）。
    private enum JoinPhase: Equatable {
        case idle, joining, failed(String)
    }
    @State private var joinPhase: JoinPhase = .idle
    @State private var carLinkDetail = "先在蓝牙卡输配对码连接车机，后面的入网和 CarLink 都自动走"
    @State private var flowCarIP = ""
    @State private var flowLocalIP = ""
    @State private var joiner = UCarNetworkJoiner()
    @State private var joinGeneration = 0

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                DashboardView(
                    localPhaseText: localSession.phase.text,
                    localPhaseFailed: localSession.phase.isFailed,
                    localRunning: localSession.isRunning,
                    localStreaming: localSession.phase == .streaming,
                    hasVideo: hasVideo,
                    decoder: decoder,
                    carLinkState: carLinkState,
                    carLinkRunning: carLinkRunning,
                    carLinkStatusText: carLinkStatusText,
                    carLinkDetail: carLinkDetail,
                    bleScanning: bleProbe.scanning,
                    bleSummary: bleProbe.lastFoundSummary ?? "还没发现车机——在车里打开车机的 CarLink，再点开始探测",
                    bleFound: bleProbe.foundDeviceId != nil,
                    bleHasToken: bleProbe.hasStoredToken,
                    blePhaseText: bleStageText,
                    blePinField: $blePin,
                    selectedSize: targetSize,
                    onToggleLocalSession: { localSession.isRunning ? stopLocalSession() : startLocalSession() },
                    onSelectSize: { setSize($0, $1) },
                    onDisconnectCarLink: { stopCarLink() },
                    onToggleBleProbe: { bleProbe.toggle() },
                    onConnectBle: { bleProbe.connect(pin: blePin) }
                )
                .navigationTitle("驾驶舱")
            }
            .tabItem { Label("驾驶舱", systemImage: "gauge.with.dots.needle.33percent") }
            .tag(0)

            NavigationStack {
                LogView(lines: log, onClear: { log.removeAll() })
                    .navigationTitle("日志")
            }
            .tabItem { Label("日志", systemImage: "doc.text") }
            .tag(1)

            NavigationStack {
                SettingsView(
                    selectedSize: targetSize,
                    onSelectSize: { setSize($0, $1) }
                )
                .navigationTitle("设置")
            }
            .tabItem { Label("设置", systemImage: "gearshape") }
            .tag(2)
        }
        .tint(.sunsetAccent)
        .onAppear {
            bleProbe.onLog = { appendLog($0) }
            bleProbe.onServerInfo = { handleUCarServerInfo($0) }
            localSession.onLog = { appendLog($0) }
            localSession.onPreviewConfig = { record, codec in
                decoder.configure(codec: codec == .h265 ? 2 : 1, config: record)
                appendLog("本机预览：解码配置已就绪（\(codec.displayName)，\(record.count) 字节）")
            }
            decoder.onLog = { appendLog($0) }
            decoder.onKeyframeNeeded = { reason in
                localSession.previewNeedsKeyFrame(reason: reason)
            }
            decoder.onFirstFrameEnqueued = {
                if !hasVideo { hasVideo = true }
                localSession.previewDidDisplayFirstFrame()
            }
            localSession.onPreviewFrame = { data, _ in
                decoder.append(data, ptsNanos: UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000))
            }
            joiner.onLog = { appendLog($0) }
            joiner.onStatus = { carLinkDetail = $0 }
        }
    }

    // MARK: 本机 CarPlay 会话

    private func startLocalSession() {
        decoder.reset()
        hasVideo = false
        localSession.start(width: targetSize.0, height: targetSize.1, fps: 30)
        if localSession.phase.isFailed {
            Haptics.error()
        }
    }

    private func stopLocalSession() {
        localSession.stop()
        decoder.reset()
        hasVideo = false
    }

    private func setSize(_ width: Int, _ height: Int) {
        targetSize = (width, height)
        appendLog("输出尺寸将使用 \(width)×\(height)（本机 CarPlay 与 CarLink 共用，下次启动会话时生效）")
    }

    // MARK: 连接卡阶段文案（蓝牙前段 + CarLink 后段合并）

    private var bleStageText: String {
        switch carLinkState {
        case .connecting: return "蓝牙已通，正在连车机服务…"
        case .authenticating: return "蓝牙已通，正在和车机配对鉴权…"
        case .negotiating: return "鉴权已过，正在协商画面（分辨率/帧率）…"
        case .playing: return "已出画：画面正在送往车机"
        case .ended: return "会话已结束，停在最后一步看日志"
        case .idle: return bleProbe.flowPhaseText
        }
    }

    /// CarLink 状态卡的大字状态：入网阶段优先，其次 CarLink 客户端状态。
    private var carLinkStatusText: String {
        switch joinPhase {
        case .joining: return "入网中…"
        case .failed(let reason): return "失败：\(reason)"
        case .idle: return carLinkState.text
        }
    }

    // MARK: CarLink（clink）

    private var clinkStateDirectory: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("OpenXPlay/clink", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    /// 启 clink 前现取现验：车机/本机都必须是合法 IPv4，且本机地址必须
    /// 是当前某个网卡上真实存在的地址（13:24 实测：空串/旧地址直达 Rust
    /// 报 invalid IPv4 address syntax）。
    private func startCarLink() {
        let carIP = flowCarIP
        let localIP = flowLocalIP
        guard UCarNetworkJoiner.isValidIPv4(carIP) else {
            appendLog("CarLink 启动中止：车机地址「\(carIP)」不是合法 IPv4，不往下传")
            carLinkDetail = "启动失败：车机地址不合法"
            return
        }
        let currentAddresses = ReceiverConfiguration.localIPv4Addresses()
        guard UCarNetworkJoiner.isValidIPv4(localIP), currentAddresses.contains(localIP) else {
            appendLog("CarLink 启动中止：本机地址「\(localIP.isEmpty ? "(空)" : localIP)」不是当前网卡上的真实地址（当前：\(currentAddresses.joined(separator: "、"))），不把空值/旧地址传给核心")
            carLinkDetail = "启动失败：本机地址已失效，重新走一遍连接流程"
            return
        }
        // 配对码只用蓝牙卡那一个输入框的值；令牌免码轮次字段为空就传空串，
        // TCP 鉴权走已存配对（QUICK）。
        let pin = blePin.trimmingCharacters(in: .whitespaces)
        let clinkPin = pin.count == 6 ? pin : ""
        let core = CarLinkCore.shared
        core.onLog = { appendLog($0) }
        core.onState = { state in
            carLinkState = state
            carLinkRunning = (state != .idle && state != .ended)
            if state == .playing {
                carLinkDetail = "车机 \(carIP) · 本机 \(localIP) · 正在输出"
                // UCar 顺序（CarWith 实证）：57209 鉴权成功之后才经 BLE
                // …103 回告本机地址。BLE 若已被车机 30 秒看门狗断开，
                // writeClientAddress 内部会打日志说明，不卡主流程。
                bleProbe.writeClientAddress(localIP: localIP)
            }
            if state == .ended {
                carLinkDetail = "会话已结束：车机 \(carIP) · 本机 \(localIP)"
            }
            // 帧桥：进入出画才推帧（补配置+请求关键帧），离开即停推。
            localSession.carLinkPlayingChanged(state == .playing)
        }
        core.onTouch = { _, x, y, pressed in
            localSession.touchesFromCarLink(pressed: pressed, x: x, y: y)
        }
        core.onKey = { code, down in
            localSession.keyFromCarLink(code: code, down: down)
        }
        carLinkRunning = core.start(headUnit: carIP, local: localIP,
                                    pin: clinkPin, stateDir: clinkStateDirectory,
                                    width: UInt32(targetSize.0), height: UInt32(targetSize.1),
                                    deviceID: BleProbe.persistentPhoneId(),
                                    model: BleProbe.deviceMarketName())
        appendLog(carLinkRunning
            ? "CarLink 已启动：车机 \(carIP)，本机 \(localIP)，配对码 \(clinkPin.isEmpty ? "走已存配对（免码）" : "用蓝牙卡输的码")"
            : "CarLink 启动失败")
        if !carLinkRunning {
            carLinkDetail = "启动失败：车机 \(carIP) · 本机 \(localIP)"
        }
    }

    private func stopCarLink() {
        joiner.cancel()
        joinGeneration += 1
        joinPhase = .idle
        CarLinkCore.shared.stop()
        carLinkRunning = false
        carLinkState = .idle
        localSession.carLinkPlayingChanged(false)
        carLinkDetail = "已断开"
        appendLog("CarLink 已断开")
    }

    /// UCar：BLE 拿到 ServerInfo 后的整段自动流程——静默存凭据 → 组网
    /// （UCarNetworkJoiner）→ 入网后本机 CarPlay 会话按新地址重开 →
    /// 现取现验启 clink 鉴权。用户不再需要点任何东西。
    private func handleUCarServerInfo(_ info: UCarServerInfo) {
        // 热点凭据静默存下供本机 CarPlay 会话用（不再有手填界面）。
        if let ssid = info.ssid, !ssid.isEmpty {
            LocalCarPlaySession.savedSSID = ssid
            if let psk = info.psk {
                LocalCarPlaySession.savedPassword = psk
            }
            appendLog("UCar 连接：车机网络「\(ssid)」的凭据已静默存下，本机 CarPlay 启动时用它告诉系统走哪个网络")
        }
        if carLinkRunning {
            appendLog("UCar 连接：CarLink 已在跑，这份 ServerInfo 不重复启流程")
            return
        }
        if joinPhase == .joining {
            appendLog("UCar 连接：组网已在进行中，这份 ServerInfo 不重复触发")
            return
        }
        joinPhase = .joining
        carLinkDetail = "入网中：加入车机网络「\(info.ssid ?? "?")」"
        joinGeneration += 1
        let generation = joinGeneration
        joiner.join(ssid: info.ssid, psk: info.psk, bleCarIP: info.ipAddress) { result in
            guard generation == joinGeneration else {
                appendLog("UCar 入网：这一轮组网结果已过期（流程被新一轮接管），丢弃")
                return
            }
            guard let result else {
                joinPhase = .failed("入网失败")
                return
            }
            joinPhase = .idle
            flowCarIP = result.carIP
            flowLocalIP = result.localIP
            carLinkDetail = "车机 \(result.carIP) · 本机 \(result.localIP) · 正在鉴权"
            // 入网换了本机 IP：本机 CarPlay 会话还绑在旧地址上就重开一次
            // （单 Wi-Fi 接口的必经之路，不是故障）。
            if localSession.isRunning, localSession.boundAddress != result.localIP {
                appendLog("本机 CarPlay：入网后本机地址从 \(localSession.boundAddress ?? "?") 变成了 \(result.localIP)，用新地址重开会话")
                stopLocalSession()
                startLocalSession()
            }
            startCarLink()
        }
    }

    private func appendLog(_ line: String) {
        let stamp = DateFormatter.logFormatter.string(from: Date())
        log.append("[\(stamp)] \(line)")
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }
}

extension DateFormatter {
    static let logFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
