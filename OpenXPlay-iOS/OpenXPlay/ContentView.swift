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
        return view
    }

    func updateUIView(_ view: PreviewHostView, context: Context) {
        if decoder.layer !== view.displayLayer {
            decoder.attachLayer(view.displayLayer)
        }
    }
}

struct ContentView: View {
    @StateObject private var bleProbe = BleProbe()
    @StateObject private var localSession = LocalCarPlaySession()
    @State private var decoder = VideoDecoder()
    @State private var log: [String] = []
    @State private var tab = 0
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

    // 本机 CarPlay 无回连自动重试（只在连接车机流程里、接续/启动后挂上）：
    // 约 12 秒没等到控制回连就停掉以同凭据同地址重新发起，最多共 3 次。
    // 只重发「从没回连过」的发起——真机规律：重启后第一次发起的会话才
    // 能成，一旦有会话真正跑起来又结束，之后的新会话再也起不来，直到
    // 下次重启（1548/1532 实证）；而没接上的发起不占这次机会（1510 空
    // 密码那次根本没回连，后面 1525/1527 照样能成）。接续成功出画后立
    // 刻收手，流程内绝不再碰这个会话的生命周期。
    @State private var localRetryWork: DispatchWorkItem?
    @State private var localRetryGeneration = 0
    @State private var localAttemptCount = 0
    /// 本轮连接内是否已用过身份轮换（同身份重试用尽后的第二道杠杆）：
    /// 每轮 arm 时复位，轮换后新身份再走一遍同样的 3 次重试上限。
    @State private var localRotatedThisFlow = false

    /// 画中画保活（与静音音频保活并存的第二条腿）：懒创建——控制器要在
    /// 预览托管层接管完成后（首帧时）建，建早了内容源会指着占位层。
    @State private var pictureInPicture: CarPlayPictureInPicture?
    @Environment(\.scenePhase) private var scenePhase

    // clink 候选真连接试序＋被拒重试（流程内部行为，不受用户点按守卫影响）。
    // 参数：同候选原地重试间隔 2 秒、同候选最多 4 次、单次尝试 8 秒看门狗、
    // 含候选切换的总预算 30 秒。命中口径：状态走到协商（negotiating）或
    // 出画（playing）才算；只到配对认证就断的不算（14:03 就是这种）。
    private static let clinkMaxAttemptsPerCandidate = 4
    private static let clinkRetryGap: TimeInterval = 2.0
    private static let clinkAttemptTimeout: TimeInterval = 8.0
    private static let clinkLoopBudget: TimeInterval = 30.0
    @State private var clinkCandidates: [String] = []
    @State private var clinkCandidateIndex = 0
    @State private var clinkAttemptsOnCandidate = 0
    @State private var clinkLoopDeadline: Date?
    @State private var clinkLoopActive = false
    @State private var clinkAttemptHit = false
    @State private var clinkAttemptSettled = true
    @State private var clinkLastError = ""
    @State private var clinkCallbacksWired = false
    @State private var clinkRetryWork: DispatchWorkItem?
    @State private var clinkWatchdogWork: DispatchWorkItem?

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                DashboardView(
                    localPhaseText: localSession.phase.text,
                    localPhaseFailed: localSession.phase.isFailed,
                    localStreaming: localSession.phase == .streaming,
                    carLinkState: carLinkState,
                    carLinkRunning: carLinkRunning,
                    carLinkStatusText: carLinkStatusText,
                    carLinkDetail: carLinkDetail,
                    bleScanning: bleProbe.scanning,
                    bleSummary: bleProbe.lastFoundSummary ?? "还没发现车机——在车里打开车机的 CarLink，再点开始探测",
                    bleFound: bleProbe.foundDeviceId != nil,
                    bleHasToken: bleProbe.hasStoredToken,
                    blePhaseText: bleStageText,
                    keepAliveActive: localSession.keepAliveActive,
                    blePinField: $blePin,
                    selectedSize: targetSize,
                    onSelectSize: { setSize($0, $1) },
                    onDisconnectCarLink: { stopCarLink() },
                    onToggleBleProbe: { bleProbe.toggle() },
                    onConnectBle: { connectCarFlow() }
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
        // 预览的离屏承接：界面上不再显示本机预览（只看车机屏），但显示层
        // 本身是帧管线的承重件——首帧入队靠它置「已出画」、出画后保活
        // 靠它触发、画中画的内容源也是它。所以托管视图保留在根层背景
        // 里：全尺寸、透明、不可点，层一直在窗口内正常入队渲染，只是不
        // 给人看。摘掉它帧路会断，勿删。
        .background {
            VideoSurface(decoder: decoder)
                .opacity(0)
                .allowsHitTesting(false)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .inactive:
                // 离场兜底：出画时已主动拉起过画中画，这里再给系统一次
                // 自动拉起的机会（原版 willResignActive 同款兜底）。
                if localSession.isRunning { pipController()?.awaitAutomaticStart() }
            case .active:
                pipController()?.returnedToForeground()
            default:
                break
            }
        }
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
                localSession.previewDidDisplayFirstFrame()
                // 画中画保活：出画后（与静音保活同一时机）主动拉起一次；
                // 控制器懒创建，到这一刻托管层早已接管、内容源有效。
                startPictureInPicture()
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
        localSession.start(width: targetSize.0, height: targetSize.1, fps: 30)
        if localSession.phase.isFailed {
            Haptics.error()
        }
    }

    private func stopLocalSession(reason: String = "流程停止本机 CarPlay 会话") {
        // 会话停了画中画保活也停（静音保活由会话自己关）。
        pictureInPicture?.stop()
        localSession.stop(reason: reason)
        decoder.reset()
    }

    // MARK: 画中画保活

    /// 懒创建画中画控制器：内容源是解码器的托管显示层，必须等预览视图
    /// 把层接管过去之后建（onAppear 时序不保证），所以拖到首帧才建。
    private func pipController() -> CarPlayPictureInPicture? {
        if let pictureInPicture { return pictureInPicture }
        let pip = CarPlayPictureInPicture(surface: decoder)
        pip.onLog = { appendLog($0) }
        pictureInPicture = pip
        return pip
    }

    /// 出画后主动拉起画中画，并打开系统自动拉起（离场时由系统接管）。
    private func startPictureInPicture() {
        guard let pip = pipController() else { return }
        pip.setAutomatic(true)
        _ = pip.start()
    }

    // MARK: 本机 CarPlay 无回连自动重试（连接车机流程专用）

    /// 接续/启动后挂上：约 12 秒仍无控制回连，就停掉以同凭据同地址重新
    /// 发起，最多共 3 次尝试。只重发从没回连过的发起——没回连过的发起
    /// 不占「重启后第一次机会」；一旦回连（controlConnected）立刻收手，
    /// 之后绝不再碰这个会话的生命周期（帧桥汇合、clink 重连都不许动
    /// 它）。3 次都无回连就停手并打人话日志：这个系统一轮里只要有会话
    /// 真正跑过又结束，新的就再也发起不起来，非重启手机不可。
    private func armLocalCallbackRetry() {
        localRetryGeneration += 1
        localAttemptCount = 1
        localRotatedThisFlow = false
        scheduleLocalCallbackCheck(generation: localRetryGeneration)
    }

    private func scheduleLocalCallbackCheck(generation: Int) {
        localRetryWork?.cancel()
        let item = DispatchWorkItem {
            guard generation == localRetryGeneration else { return }
            if localSession.controlConnected || localSession.phase == .streaming {
                appendLog("本机 CarPlay：已回连，自动重试收手——会话就此跑下去，流程内不再动它")
                return
            }
            guard localAttemptCount < 3 else {
                // 同身份 3 次用尽：先走身份轮换这道杠杆——停会话（已完全
                // 停稳才换，运行中换身份会让同一会话前后不一致）、换新
                // deviceID、用新身份重新发起，新身份再走同样的 3 次上限。
                // 系统按 deviceID 记账，换了等于换台新车、没有楔住的旧账。
                if !localRotatedThisFlow {
                    localRotatedThisFlow = true
                    localAttemptCount = 1
                    appendLog("本机 CarPlay：同身份自动重试 3 次都没有回连——停下会话，换新设备标识再试一轮")
                    stopLocalSession(reason: "连接车机：换设备标识重试，先停会话")
                    ReceiverConfiguration.rotatePersistentDeviceID()
                    appendLog("本机 CarPlay：已换新设备标识（避开系统里卡住的旧记录），用新身份重新发起")
                    startLocalSession()
                    scheduleLocalCallbackCheck(generation: generation)
                } else {
                    appendLog("本机 CarPlay：换了新设备标识也重试满 3 次，还是没有回连——这一轮已经换身份重试过了，仍不行就只能重启手机后再点一次「连接车机」")
                }
                return
            }
            localAttemptCount += 1
            appendLog("本机 CarPlay：发起后 12 秒没等到系统回连，自动重试（第 \(localAttemptCount) 次/共 3 次，同凭据同地址重新发起）")
            stopLocalSession(reason: "连接车机：无回连自动重试")
            startLocalSession()
            scheduleLocalCallbackCheck(generation: generation)
        }
        localRetryWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: item)
    }

    private func cancelLocalCallbackRetry() {
        localRetryGeneration += 1
        localRetryWork?.cancel()
        localRetryWork = nil
    }

    // MARK: 连接车机总流程（顺序：蓝牙先行 → 旧网络上预发起会话 → 入网 → 切网后接续 + 无回连自动重试，clink 并行）

    /// 点「连接车机」的总入口：第一件事就是走蓝牙写 ClientInfo。车机
    /// 的 30 秒看门狗从蓝牙连上那刻起算，而蓝牙在扫描发现车机时就已
    /// 连上——先等本机 CarPlay 建立会把窗口吃光（14:56 实测：等满
    /// 15 秒才写 ClientInfo，写出后 8 秒无回执、蓝牙被车机断开；旧
    /// 流程连上立刻写、回执 <1 秒必成）。蓝牙这段只要一两秒，先走
    /// 完；拿到 ServerInfo 后、入网之前，先在当前（旧）网络上把本机
    /// CarPlay 会话发起（1530 唯一成功的形状：切网前发起的谈话、切网
    /// 后被接续完成），再入网；地址一切过来按新地址重开接续、重发
    /// StartSession，clink 试序同时开始（见 handleUCarServerInfo）。
    private func connectCarFlow() {
        // 预轮换：上次会话真正连上过又结束（标记在会话停止时落下），
        // 系统侧那本旧账多半已经楔住——先换新设备标识再发起，跳过注定
        // 失败的同身份等待。新会话连上后标记自动清除。
        if LocalCarPlaySession.preRotationPending {
            ReceiverConfiguration.rotatePersistentDeviceID()
            appendLog("本机 CarPlay：已换新设备标识（避开系统里卡住的旧记录）——上次会话连上过又结束了，这次先换标识再连接")
        }
        appendLog("连接车机：先走蓝牙写 ClientInfo（车机 30 秒窗口从蓝牙连上起算，不能先等本机 CarPlay），拿到 ServerInfo 后先在当前网络发起 CarPlay 会话、再入网，切网后接续")
        bleProbe.connect(pin: blePin)
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

    /// clink 回调只接一次线：状态既驱动界面，也喂候选试序的成败判定。
    private func wireCarLinkCallbacks() {
        guard !clinkCallbacksWired else { return }
        clinkCallbacksWired = true
        let core = CarLinkCore.shared
        core.onLog = { line in
            if line.hasPrefix("CarLink 错误：") { clinkLastError = line }
            appendLog(line)
        }
        core.onState = { state in
            carLinkState = state
            carLinkRunning = (state != .idle && state != .ended)
            if state == .negotiating || state == .playing {
                markClinkAttemptHit(state)
            }
            if state == .playing {
                carLinkDetail = "车机 \(flowCarIP) · 本机 \(flowLocalIP) · 正在输出"
                // UCar 顺序（CarWith 实证）：57209 鉴权成功之后才经 BLE
                // …103 回告本机地址。BLE 若已被车机 30 秒看门狗断开，
                // writeClientAddress 内部会打日志说明，不卡主流程。
                bleProbe.writeClientAddress(localIP: flowLocalIP)
            }
            if state == .ended {
                if clinkLoopActive && !clinkAttemptHit && !clinkAttemptSettled {
                    settleClinkAttemptFailure(reason: clinkLastError.isEmpty
                        ? "会话刚启动就结束（没走到协商）" : clinkLastError)
                } else if !clinkLoopActive {
                    carLinkDetail = "会话已结束：车机 \(flowCarIP) · 本机 \(flowLocalIP)"
                    // 车机会话到此终了：这轮带回的车机网络凭据随之失效，
                    // 不许再被下一次本机 CarPlay 启动引用（旧 DIRECT- 名
                    // 指向的网络已经不存在）。
                    if LocalCarPlaySession.carCredentialsFresh {
                        LocalCarPlaySession.invalidateCarCredentials()
                        appendLog("UCar 连接：车机会话已结束，本轮车机网络凭据已作废（下次启动本机 CarPlay 不再用这个网络名）")
                    }
                }
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
    }

    /// 入网成功后进入候选试序：按入网给的顺序逐个启 clink 真连接试。
    private func beginClinkAttempts(candidates: [String], localIP: String) {
        guard !candidates.isEmpty else {
            appendLog("CarLink 启动中止：没有车机地址候选")
            carLinkDetail = "启动失败：没有车机地址候选"
            return
        }
        wireCarLinkCallbacks()
        cancelClinkLoopWork()
        clinkCandidates = candidates
        clinkCandidateIndex = 0
        clinkAttemptsOnCandidate = 0
        clinkLoopDeadline = Date().addingTimeInterval(Self.clinkLoopBudget)
        clinkLoopActive = true
        clinkAttemptHit = false
        flowLocalIP = localIP
        appendLog("CarLink 候选试序开始：\(candidates.joined(separator: " → "))——逐个用真连接试（同候选被拒先原地重试，间隔 \(Int(Self.clinkRetryGap)) 秒、最多 \(Self.clinkMaxAttemptsPerCandidate) 次；含切换总预算 \(Int(Self.clinkLoopBudget)) 秒）")
        runClinkAttempt()
    }

    /// 启 clink 前现取现验：车机/本机都必须是合法 IPv4，且本机地址必须
    /// 是当前某个网卡上真实存在的地址（13:24 实测：空串/旧地址直达 Rust
    /// 报 invalid IPv4 address syntax）。
    private func runClinkAttempt() {
        guard clinkLoopActive, !clinkAttemptHit else { return }
        if let deadline = clinkLoopDeadline, Date() > deadline {
            abandonClinkAttempts(reason: "\(Int(Self.clinkLoopBudget)) 秒重试预算用完")
            return
        }
        let carIP = clinkCandidates[clinkCandidateIndex]
        let localIP = flowLocalIP
        flowCarIP = carIP
        clinkAttemptsOnCandidate += 1
        clinkAttemptSettled = false
        clinkLastError = ""
        guard UCarNetworkJoiner.isValidIPv4(carIP) else {
            settleClinkAttemptFailure(reason: "车机地址「\(carIP)」不是合法 IPv4")
            return
        }
        let currentAddresses = ReceiverConfiguration.localIPv4Addresses()
        guard UCarNetworkJoiner.isValidIPv4(localIP), currentAddresses.contains(localIP) else {
            // 本机地址失效是全局问题，换候选也没用，整轮放弃。
            appendLog("CarLink 启动中止：本机地址「\(localIP.isEmpty ? "(空)" : localIP)」不是当前网卡上的真实地址（当前：\(currentAddresses.joined(separator: "、"))），不把空值/旧地址传给核心")
            carLinkDetail = "启动失败：本机地址已失效，重新走一遍连接流程"
            clinkLoopActive = false
            return
        }
        carLinkDetail = "车机 \(carIP) · 本机 \(localIP) · 连接中（候选 \(clinkCandidateIndex + 1)/\(clinkCandidates.count) 第 \(clinkAttemptsOnCandidate) 次）"
        appendLog("CarLink 真连接试候选 \(carIP)（候选 \(clinkCandidateIndex + 1)/\(clinkCandidates.count)，本候选第 \(clinkAttemptsOnCandidate)/\(Self.clinkMaxAttemptsPerCandidate) 次）")
        // 配对码只用蓝牙卡那一个输入框的值；令牌免码轮次字段为空就传空串，
        // TCP 鉴权走已存配对（QUICK）。
        let pin = blePin.trimmingCharacters(in: .whitespaces)
        let clinkPin = pin.count == 6 ? pin : ""
        let started = CarLinkCore.shared.start(headUnit: carIP, local: localIP,
                                    pin: clinkPin, stateDir: clinkStateDirectory,
                                    width: UInt32(targetSize.0), height: UInt32(targetSize.1),
                                    deviceID: BleProbe.persistentPhoneId(),
                                    model: BleProbe.deviceMarketName())
        appendLog(started
            ? "CarLink 已启动：车机 \(carIP)，本机 \(localIP)，配对码 \(clinkPin.isEmpty ? "走已存配对（免码）" : "用蓝牙卡输的码")"
            : "CarLink 启动失败")
        guard started else {
            settleClinkAttemptFailure(reason: "clink 启动即失败")
            return
        }
        // 单次尝试看门狗：迟迟走不到协商、也不结束，就停掉算失败，
        // 别把 30 秒预算耗在一次干等上。先置 settled 再停 core——停的
        // 过程中 core 可能同步回 .ended，回调看到 settled 就不会重复判。
        let watchdog = DispatchWorkItem { [self] in
            guard clinkLoopActive, !clinkAttemptHit, !clinkAttemptSettled else { return }
            clinkAttemptSettled = true
            clinkWatchdogWork = nil
            appendLog("CarLink 候选 \(carIP) 本次尝试 \(Int(Self.clinkAttemptTimeout)) 秒没走到协商，停掉算失败")
            CarLinkCore.shared.stop()
            decideAfterClinkFailure(reason: "\(Int(Self.clinkAttemptTimeout)) 秒没走到协商（超时）")
        }
        clinkWatchdogWork = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.clinkAttemptTimeout, execute: watchdog)
    }

    /// 命中：状态走到协商/出画，这个候选就是车机地址，试序结束。
    private func markClinkAttemptHit(_ state: CarLinkCore.State) {
        guard clinkLoopActive, !clinkAttemptHit else { return }
        clinkAttemptHit = true
        clinkAttemptSettled = true
        clinkWatchdogWork?.cancel()
        clinkWatchdogWork = nil
        clinkLoopActive = false
        appendLog("CarLink 候选 \(flowCarIP) 命中（状态已到「\(state.text)」）——车机地址定为 \(flowCarIP)")
    }

    /// 本次尝试判失败的入口：置 settled、撤看门狗，再走统一决策。
    private func settleClinkAttemptFailure(reason: String) {
        guard clinkLoopActive, !clinkAttemptHit, !clinkAttemptSettled else { return }
        clinkAttemptSettled = true
        clinkWatchdogWork?.cancel()
        clinkWatchdogWork = nil
        decideAfterClinkFailure(reason: reason)
    }

    /// 失败决策（settled 已置位）：同候选先原地重试（间隔 2 秒、最多
    /// 4 次），用满再换下一个候选；候选与预算都用完才整轮放弃。
    private func decideAfterClinkFailure(reason: String) {
        let candidate = clinkCandidates[clinkCandidateIndex]
        appendLog("CarLink 候选 \(candidate) 第 \(clinkAttemptsOnCandidate) 次没成：\(reason)")
        if let deadline = clinkLoopDeadline, Date() > deadline {
            abandonClinkAttempts(reason: "\(Int(Self.clinkLoopBudget)) 秒重试预算用完")
            return
        }
        if clinkAttemptsOnCandidate < Self.clinkMaxAttemptsPerCandidate {
            appendLog("CarLink \(Int(Self.clinkRetryGap)) 秒后原地重试候选 \(candidate)（车机鉴权口可能刚被占/还没重开）")
            scheduleClinkNext(after: Self.clinkRetryGap) { runClinkAttempt() }
        } else if clinkCandidateIndex + 1 < clinkCandidates.count {
            let next = clinkCandidates[clinkCandidateIndex + 1]
            appendLog("CarLink 候选 \(candidate) 重试 \(Self.clinkMaxAttemptsPerCandidate) 次都没成，换下一个候选 \(next)")
            clinkCandidateIndex += 1
            clinkAttemptsOnCandidate = 0
            scheduleClinkNext(after: 1.0) { runClinkAttempt() }
        } else {
            abandonClinkAttempts(reason: "所有候选都试满了")
        }
    }

    private func scheduleClinkNext(after delay: TimeInterval, _ action: @escaping () -> Void) {
        clinkRetryWork?.cancel()
        let work = DispatchWorkItem { action() }
        clinkRetryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func abandonClinkAttempts(reason: String) {
        guard clinkLoopActive else { return }
        clinkLoopActive = false
        cancelClinkLoopWork()
        appendLog("CarLink 全部候选与重试都失败了（\(reason)；试过 \(clinkCandidates.joined(separator: "、"))）——这一轮停在这里，把日志发回来看")
        carLinkDetail = "连接失败：车机地址都试过了（\(reason)）"
    }

    private func cancelClinkLoopWork() {
        clinkRetryWork?.cancel()
        clinkRetryWork = nil
        clinkWatchdogWork?.cancel()
        clinkWatchdogWork = nil
    }

    private func stopCarLink() {
        joiner.cancel()
        joinGeneration += 1
        joinPhase = .idle
        // 用户主动断开：流程挂着的无回连自动重试一并取消。
        cancelLocalCallbackRetry()
        // 用户主动断开 = 车机会话结束，本轮车机网络凭据作废。
        if LocalCarPlaySession.carCredentialsFresh {
            LocalCarPlaySession.invalidateCarCredentials()
            appendLog("UCar 连接：已断开，本轮车机网络凭据已作废")
        }
        // 候选试序一并停：撤掉待发的重试与看门狗，别在用户断开后又自己启。
        clinkLoopActive = false
        clinkAttemptSettled = true
        cancelClinkLoopWork()
        CarLinkCore.shared.stop()
        carLinkRunning = false
        carLinkState = .idle
        localSession.carLinkPlayingChanged(false)
        carLinkDetail = "已断开"
        appendLog("CarLink 已断开")
    }

    /// UCar：BLE 拿到 ServerInfo 后的整段自动流程——静默存凭据 →
    /// 在当前（旧）网络上先把本机 CarPlay 会话发起 → 组网
    /// （UCarNetworkJoiner）→ 地址一切过来按新地址重开接续、重发
    /// StartSession，同时现取现验启 clink 鉴权，并挂上无回连自动重
    /// 试。用户不再需要点任何东西。
    private func handleUCarServerInfo(_ info: UCarServerInfo) {
        // 热点凭据静默存下并标为本轮新鲜（打时间戳＋本进程标记）：只许
        // 本轮车机会话内、本机 CarPlay 重开时用；会话结束即作废，绝不
        // 留给下一次单独启动拿旧 DIRECT- 名去连死网络。
        if let ssid = info.ssid, !ssid.isEmpty {
            LocalCarPlaySession.storeCarCredentials(ssid: ssid, password: info.psk)
            appendLog("UCar 连接：车机网络「\(ssid)」的凭据已静默存下并标为本轮新鲜（只在本轮车机会话内供本机 CarPlay 重开时用）")
        }
        if carLinkRunning {
            appendLog("UCar 连接：CarLink 已在跑，这份 ServerInfo 不重复启流程")
            return
        }
        if clinkLoopActive {
            appendLog("UCar 连接：CarLink 正在逐个候选真连接尝试中，这份 ServerInfo 不重复启流程")
            return
        }
        if joinPhase == .joining {
            appendLog("UCar 连接：组网已在进行中，这份 ServerInfo 不重复触发")
            return
        }
        // 本轮唯一的机会先占住，别在链条中间浪费掉。真机规律（与全
        // 部日志吻合）：重启后第一次发起的 CarPlay 会话才能成；一旦
        // 有会话真正跑起来又结束，之后的新会话再也起不来，直到下次
        // 重启（1548 重启后 #1 出画、被停后 #2/#3 全败；1532 同理且
        // 卡死带到下一轮）。而入网切到车机 DIRECT- 网络之后「新发
        // 起」从没成过（四次全败，含上一版先停后入网再一次启动）；
        // 唯一成功（1530）是切网「之前」就发起的谈话：StartSession
        // 用本轮新鲜车机凭据在旧网络上先发出去、没等到回连，地址一
        // 切过来接收端按新地址重开、重发 StartSession，iOS 立刻回
        // 连并全程出画。所以顺序定死：入网之前先把会话发起在旧网络
        // 上，中间不插入任何会真正建立又结束的会话。
        var flowInitiatedLocalSession = false
        if localSession.isRunning {
            if localSession.controlConnected || localSession.phase == .streaming {
                // 正在出画/已建立：留着它会被切网中途掐死、同样卡死，
                // 唯一可走的路是先干净停掉、再立刻重新发起。
                appendLog("本机 CarPlay：会话正在出画——先停掉，马上在当前网络重新发起，切网后接续（发起机会只有重启后这一次，不能让它被切网掐死）")
                stopLocalSession(reason: "连接车机：停掉已出画会话以便重新发起接续")
                startLocalSession()
                flowInitiatedLocalSession = true
            } else {
                // 已发起、还没回连：这就是正在谈的那次机会，留着它，
                // 切网后靠地址重开接续，不要重启它。
                appendLog("本机 CarPlay：会话已发起、正在等系统回连——留着这次谈话，切网后接续，不重启它")
            }
        } else {
            appendLog("本机 CarPlay：先在当前网络发起 CarPlay 会话，切网后接续（用本轮车机凭据「\(info.ssid ?? "?")」，这是本轮唯一的那次发起）")
            startLocalSession()
            flowInitiatedLocalSession = true
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
                if flowInitiatedLocalSession, localSession.isRunning, !localSession.controlConnected {
                    // 本轮流程刚发起的会话还没回连过：停掉它不占重启
                    // 后的发起机会，留着它只会挂在已作废的凭据上空等。
                    stopLocalSession(reason: "连接车机：入网失败，停掉刚发起的会话")
                    appendLog("本机 CarPlay：入网失败，刚发起的会话已停掉（它还没回连过，不占发起机会）")
                }
                // 入网没成 = 这轮车机会话未成立，刚存的凭据一并作废。
                if LocalCarPlaySession.carCredentialsFresh {
                    LocalCarPlaySession.invalidateCarCredentials()
                    appendLog("UCar 连接：入网失败，本轮车机网络凭据已作废")
                }
                return
            }
            joinPhase = .idle
            flowLocalIP = result.localIP
            carLinkDetail = "本机 \(result.localIP) · 正在连接车机"
            // 切网后接续：切网前发起的那次谈话还在等回连、且还绑在旧
            // 地址上，就按新地址重开接续——同凭据重启接收端、重发
            // StartSession，这正是 1530 成的那一步。会话内的启动期地
            // 址看门狗可能已先一步重开对齐（boundAddress 已是新地
            // 址），那就不重复动它。已回连/出画的会话是终点：绝不再
            // 停它、重开它（帧桥汇合、clink 那边都不碰它的生命周期）。
            if localSession.isRunning, !localSession.controlConnected,
               localSession.boundAddress != result.localIP {
                appendLog("本机 CarPlay：切网后接续——会话还绑在旧地址 \(localSession.boundAddress ?? "?")，按新地址 \(result.localIP) 重开、重发 StartSession（凭据不变）")
                stopLocalSession(reason: "连接车机：切网后按新地址接续重开")
                startLocalSession()
            } else if localSession.isRunning {
                appendLog("本机 CarPlay：切网后接续已就位（会话已在新地址上或已回连），不重复动它")
            } else {
                // 极端兜底：预发起的会话不知为何没在跑，现在补发起。
                appendLog("本机 CarPlay：入网完成，会话没在跑，兜底现在发起（用本轮车机凭据）")
                startLocalSession()
            }
            // 无回连自动重试挂上：接续后约 12 秒仍无回连就同凭据同地
            // 址重新发起，最多共 3 次；回连即收手。
            armLocalCallbackRetry()
            // 车机地址候选逐个启 clink 真连接试（被拒自动重试/换候选），
            // 与本机 CarPlay 接续并行，两边靠帧桥汇合。
            beginClinkAttempts(candidates: result.candidates, localIP: result.localIP)
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
