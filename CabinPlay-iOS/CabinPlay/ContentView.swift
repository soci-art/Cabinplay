// SPDX-FileCopyrightText: 2026 CabinPlay.org
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
struct CabinPlayApp: App {
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
    @State private var netMonitor: NetworkChangeMonitor?

    // 分辨率改自动（不再有手动菜单）：阶梯从高往低，连接时先用这台
    // 车上次协商定案的档（存 UserDefaults），没有就从最高档起步；
    // 整轮协商都失败就自动降一档、本机 CarPlay 会话按新尺寸重开一
    // 次再试（WFD 声明、本机 CarPlay 请求、触控换算三处尺寸必须同
    // 源同值，见 abandonClinkAttempts 的降档分支）。targetSize 是当
    // 前档的生效值，只用于展示与启动参数，不再由用户选。
    private static let sizeLadder: [(Int, Int)] = [(1920, 1080), (1280, 720), (854, 480)]
    @State private var sizeTierIndex = 0
    @State private var targetSize: (Int, Int) = (1920, 1080)

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
    /// 无回连重试是否正挂着（arm 置真、收手/取消/用尽置假）：车机会
    /// 话在出画前结束时，靠它判定要不要连待发重试一并止损。
    @State private var localRetryArmed = false
    /// 反应式轮换熔断的起算点：arm 的那一刻＝接续发起（切网后按新
    /// 地址重发 StartSession）。从这里算约 35 秒仍无回连才换新设
    /// 备标识（RECONNECT-WAIT-DIFF 定案：回连延迟是双峰的——约 1
    /// 秒或约 30 秒，35 秒刚越过慢峰；连接开头不再预轮换）。
    @State private var localFuseStartedAt: Date?
    /// 本轮车机会话是否已重打过触控定锚（出画打一次，beginClinkAttempts
    /// 与会话结束时复位）。
    @State private var touchAnchorLogged = false

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
                    currentSizeLabel: "\(targetSize.0)×\(targetSize.1)",
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
                SettingsView()
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

    /// 上次连过的车机 deviceId（ServerInfo 到手时落盘）。
    private var lastCarDeviceId: String? {
        let value = UserDefaults.standard.string(forKey: "cabinplay.lastCarDeviceId")
        return (value?.isEmpty == false) ? value : nil
    }

    // MARK: 本机 CarPlay 会话

    private func startLocalSession(addressOverride: String? = nil) {
        decoder.reset()
        localSession.start(width: targetSize.0, height: targetSize.1, fps: 60,
                           addressOverride: addressOverride)
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

    /// 接续/启动后挂上：每轮等 20 秒仍无控制回连，就停掉以同凭据同
    /// 地址重新发起，最多共 3 次尝试。检查窗从 8/12 秒改长到统一 20
    /// 秒（2026-11-26 晚定版）：1731/1649 两轮真机回连分别在发起后
    /// 约 30/31 秒才到（中间隔着重开），8/12 秒的短窗只会把等待切成
    /// 一次次全量重开、平白扰动系统；而等待期车机那头有占位帧喂着
    /// （每档都有同尺寸占位片），干等不会把车机会话等死——1824 轮车
    /// 机 10 秒关通道的真因是 1080p 没占位片可喂、不是等太久。只重
    /// 发从没回连过的发起——没回连过的发起不占「重启后第一次机
    /// 会」；一旦回连（controlConnected）立刻收手，之后绝不再碰这个
    /// 会话的生命周期（帧桥汇合、clink 重连都不许动它）。3 次都无回
    /// 连就停手并打人话日志：这个系统一轮里只要有会话真正跑过又结
    /// 束，新的就再也发起不起来，非重启手机不可。
    ///
    /// 身份轮换改反应式（RECONNECT-WAIT-DIFF 定案）：arm 的这一刻
    /// 就是接续发起，熔断从这里起算——约 35 秒仍无回连才停会话、
    /// 换新 deviceID、重开（保险丝，不是主路径：回连延迟双峰，约
    /// 1 秒或约 30 秒，35 秒刚越过慢峰，正常慢轮次不会误触发）。
    /// 连接开头不再预轮换（connectCarFlow 已撤）：先用原标识连，
    /// 系统状态好时同身份 1 秒回连、慢时约 30 秒，都轮不到换。
    private func armLocalCallbackRetry() {
        localRetryGeneration += 1
        localAttemptCount = 1
        localRotatedThisFlow = false
        localRetryArmed = true
        localFuseStartedAt = Date()
        scheduleLocalCallbackCheck(generation: localRetryGeneration)
    }

    private func scheduleLocalCallbackCheck(generation: Int) {
        localRetryWork?.cancel()
        // 本轮检查窗：常规 20 秒（定版依据见 armLocalCallbackRetry
        // 的注释）；但未轮换时下一检查点不许越过 35 秒熔断线——把
        // 窗收短到熔断点，让熔断在约 35 秒准时触发，而不是拖到
        // 40 秒那次常规检查。在排期这一刻定格，日志如实对账。
        var waitSeconds = 20
        if !localRotatedThisFlow, let fuseStart = localFuseStartedAt {
            let remaining = 35 - Date().timeIntervalSince(fuseStart)
            if remaining < 20 {
                waitSeconds = max(1, Int(remaining.rounded()))
            }
        }
        let item = DispatchWorkItem {
            guard generation == localRetryGeneration else { return }
            if localSession.controlConnected || localSession.phase == .streaming {
                localRetryArmed = false
                appendLog("本机 CarPlay：已回连，自动重试收手——会话就此跑下去，流程内不再动它")
                if !localRotatedThisFlow, let fuseStart = localFuseStartedAt {
                    appendLog("本机 CarPlay：本轮同身份直接连上，从接续发起算回连共等了约 \(Int(Date().timeIntervalSince(fuseStart).rounded())) 秒")
                }
                return
            }
            // 反应式轮换熔断（跨轮上层触发，优先于次数逻辑）：接续
            // 发起后约 35 秒仍无回连——停会话（停稳才换，运行中换
            // 身份会让同一会话前后不一致）、换新 deviceID、用新身
            // 份重新发起；新身份再走同样的 20 秒×3 次重试与最终提
            // 示。触发即取消本检查链的后续同身份重试（下面 return
            // 前不再排期，startLocalSessionAfterAddressWait 会按新
            // 身份重新排期）。
            if !localRotatedThisFlow, let fuseStart = localFuseStartedAt,
               Date().timeIntervalSince(fuseStart) >= 35 {
                localRotatedThisFlow = true
                localAttemptCount = 1
                appendLog("本机 CarPlay：35 秒没等到回连，按反应式轮换换新设备标识重试（先停会话、换标识、用新身份重新发起）")
                stopLocalSession(reason: "连接车机：反应式轮换，先停会话")
                ReceiverConfiguration.rotatePersistentDeviceID()
                appendLog("本机 CarPlay：已换新设备标识（避开系统里卡住的旧记录），用新身份重新发起")
                startLocalSessionAfterAddressWait(generation: generation)
                return
            }
            guard localAttemptCount < 3 else {
                localRetryArmed = false
                appendLog("本机 CarPlay：自动重试满 3 次，还是没有回连——仍不行就只能重启手机后再点一次「连接车机」")
                return
            }
            localAttemptCount += 1
            appendLog("本机 CarPlay：发起后 \(waitSeconds) 秒没等到系统回连，自动重试（第 \(localAttemptCount) 次/共 3 次，同凭据同地址重新发起）")
            restartLocalSessionAfterAddressWait(generation: generation,
                                                reason: "连接车机：无回连自动重试")
        }
        localRetryWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(waitSeconds), execute: item)
    }

    private func cancelLocalCallbackRetry() {
        localRetryGeneration += 1
        localRetryWork?.cancel()
        localRetryWork = nil
        localRetryArmed = false
    }

    /// 无回连重开的前半：停掉会话，再走等地址启动（轮换分支自己已
    /// 经停过会话、换完身份，直接调后半即可）。
    private func restartLocalSessionAfterAddressWait(generation: Int, reason: String) {
        stopLocalSession(reason: reason)
        startLocalSessionAfterAddressWait(generation: generation)
    }

    /// 等地址启动：切网后 en0 地址会先消失约 9 秒才落新地址，旧做法
    /// 重开时一次性即时读、零容错，落进空窗就直接判死
    /// （PLACEHOLDER-TIMING-DIFF 第 3 节）。现在按入网步的节奏 1.5
    /// 秒一探、最多约 10 秒等地址回来再 start；仍空则用流程已知的
    /// 本机地址（flowLocalIP，接续成功时记下的那个）兜底启动——会
    /// 话自己的启动期地址看门狗会在地址落稳后按真地址重开对齐；
    /// 两者皆无才按失败处理并打人话日志。generation 守卫保证流程
    /// 已换轮/已断开时不会乱入。
    private func startLocalSessionAfterAddressWait(generation: Int) {
        var probes = 0
        func attempt() {
            guard generation == localRetryGeneration else { return }
            if ReceiverConfiguration.wifiIPv4Address() != nil {
                if probes > 0 {
                    appendLog("本机 CarPlay：等了约 \(Int(Double(probes) * 1.5)) 秒，en0 地址回来了，按真地址重新发起")
                }
                startLocalSession()
                scheduleLocalCallbackCheck(generation: generation)
                return
            }
            probes += 1
            if probes <= 7 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { attempt() }
                return
            }
            if !flowLocalIP.isEmpty {
                appendLog("本机 CarPlay：等了约 10 秒 en0 地址还没回来，用流程已知的本机地址 \(flowLocalIP) 兜底启动（地址落稳后会话会自己对齐）")
                startLocalSession(addressOverride: flowLocalIP)
                scheduleLocalCallbackCheck(generation: generation)
            } else {
                appendLog("本机 CarPlay：等了约 10 秒还是读不到本机地址，也没有流程已知的地址可兜底——这一轮先停在这里，连上车机网络或任意 Wi-Fi 后再点一次「连接车机」")
            }
        }
        attempt()
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
        // 轮换改反应式（RECONNECT-WAIT-DIFF 定案）：连接开头不再因
        // 上次会话标记预轮换——实证表明等约 30 秒与身份无关（没轮
        // 换的轮次同样等 31 秒），预轮换只是白烧新身份、往系统设置
        // 里堆同名车辆条目。先用原标识连：系统状态好约 1 秒回连、
        // 残留未清约 30 秒回连；真楔住时由接续发起后约 35 秒的熔
        // 断换新标识兜底（见 scheduleLocalCallbackCheck）。标记的读
        // 写点不动：连上照落、stop 照落，只是不再作轮换依据。
        appendLog("本机 CarPlay：本轮先用原设备标识连接（35 秒不回连再换新标识）")
        appendLog("连接车机：先走蓝牙写 ClientInfo（车机 30 秒窗口从蓝牙连上起算，不能先等本机 CarPlay），拿到 ServerInfo 后先在当前网络发起 CarPlay 会话、再入网，切网后接续")
        bleProbe.connect(pin: blePin)
    }

    /// 分辨率自动协商的起步档：这台车上次协商定案的尺寸（按
    /// deviceId 存）就是这轮的起步档；没有记录就从阶梯最高档起。
    /// 每轮连接在 handleUCarServerInfo 开头调一次。
    private func prepareSizeTier(for deviceId: String?) {
        var tier = 0
        if let deviceId,
           let saved = UserDefaults.standard.string(forKey: "cabinplay.provenSize.\(deviceId)"),
           let index = Self.sizeLadder.firstIndex(where: { "\($0.0)x\($0.1)" == saved }) {
            tier = index
        }
        sizeTierIndex = tier
        targetSize = Self.sizeLadder[tier]
        appendLog(tier == 0
            ? "分辨率自动协商：从最高档 \(targetSize.0)×\(targetSize.1) 起步，车机接受不了就自动降档"
            : "分辨率自动协商：这台车上次定案是 \(targetSize.0)×\(targetSize.1)，这轮从这一档起步")
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
        let dir = base.appendingPathComponent("CabinPlay/clink", isDirectory: true)
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
                appendLog(AudioDiagnostics.snapshot(width: targetSize.0, height: targetSize.1))
                startNetworkMonitorIfNeeded()
                // 触控定锚防丢：每轮车机会话出画后重打一行（声明几何
                // ＋当前换算方式）——日志从会话中段导出时，开头那份
                // 定锚会被 400 行上限滚掉，这一行为中段导出兜底。
                if !touchAnchorLogged {
                    touchAnchorLogged = true
                    CarLinkCore.shared.logTouchAnchor()
                }
                // UCar 顺序（CarWith 实证）：57209 鉴权成功之后才经 BLE
                // …103 回告本机地址。BLE 若已被车机 30 秒看门狗断开，
                // writeClientAddress 内部会打日志说明，不卡主流程。
                bleProbe.writeClientAddress(localIP: flowLocalIP)
            }
            if state == .ended {
                touchAnchorLogged = false
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
                    // 止损：车机会话在出画前就结束、而无回连重试还挂着
                    // 时，待发的重试必须一并取消——1824 实证：车机会
                    // 话 :24 已结束，第 3 次重试还拖到 :46 拿已存凭据
                    // （陈旧的「WDNMD」）兜底启动，对着已经关掉通道的
                    // 车机空发。取消后 generation 守卫会让正在等地址
                    // 的兜底启动也自行作废。已出画的会话结束不走这
                    // 里（那是正常断开，凭据作废就够了）；用户主动断
                    // 开时 stopCarLink 已先取消重试，armed 为假、不会
                    // 误报。
                    if localRetryArmed, !localSession.controlConnected,
                       localSession.phase != .streaming {
                        cancelLocalCallbackRetry()
                        carLinkDetail = "车机会话已结束，请重新连接"
                        appendLog("UCar 连接：车机会话在出画前已结束，待发的本机 CarPlay 重试已取消（不再用已存凭据兜底启动）")
                        appendLog("车机会话已结束，请重新连接")
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
        touchAnchorLogged = false
        // 触控换算固定居中模型（校准功能已整套撤销）：每轮试序开
        // 始时把模式推给核心一次，并清掉核心里可能残留的校准矩形。
        CarLinkCore.shared.applyTouchMode()
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
        // 车机的配对码不一定是 6 位（见过 4/8 位）：只取数字，4–8 位都认，
        // 不在范围才走「已存配对免码」。
        let digits = pin.filter { $0.isNumber }
        let clinkPin = (4...8).contains(digits.count) ? digits : ""
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

    /// 会话期网络监控：车机热点重启/换网后 clink 会对着旧地址发呆，
    /// 这里发现地址变了就停掉 clink，用新地址重走候选试序（各带看门狗）。
    private func startNetworkMonitorIfNeeded() {
        if netMonitor != nil { return }
        let monitor = NetworkChangeMonitor()
        monitor.start { signature in
            DispatchQueue.main.async {
                appendLog("网络变化：当前网卡地址变为 [\(signature)]")
                guard carLinkRunning || clinkLoopActive else { return }
                let current = ReceiverConfiguration.localIPv4Addresses()
                guard let local = current.first(where: { UCarNetworkJoiner.isValidIPv4($0) }) else {
                    appendLog("网络变化：拿不到可用的本机地址，暂不重连")
                    return
                }
                appendLog("网络变化：停掉当前 CarLink，用新地址 \(local) 重走候选试序")
                CarLinkCore.shared.stop()
                carLinkState = .idle
                carLinkRunning = false
                flowLocalIP = local
                beginClinkAttempts(candidates: clinkCandidates, localIP: local)
            }
        }
        netMonitor = monitor
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
        // 协商定案的尺寸按车记下：下次连这台车直接从这一档起步，
        // 不必每轮都从最高档往下试。
        if let deviceId = bleProbe.foundDeviceId ?? lastCarDeviceId {
            UserDefaults.standard.set("\(targetSize.0)x\(targetSize.1)",
                                      forKey: "cabinplay.provenSize.\(deviceId)")
        }
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
        // 分辨率自动降档：这一档整轮协商都没成、阶梯下面还有档——降
        // 一档再整轮试。本机 CarPlay 会话按新尺寸重开一次（协商定案
        // 后对齐尺寸的那一次重开）：不重开的话 WFD 声明会降、本机
        // CarPlay 还按旧尺寸出帧，三处尺寸长期不一致，触控必偏。
        if sizeTierIndex + 1 < Self.sizeLadder.count {
            let oldSize = targetSize
            sizeTierIndex += 1
            targetSize = Self.sizeLadder[sizeTierIndex]
            appendLog("分辨率自动降档：\(oldSize.0)×\(oldSize.1) 这一档整轮没协商成（\(reason)），降到 \(targetSize.0)×\(targetSize.1) 再试——本机 CarPlay 会话按新尺寸重开一次，让声明/请求/触控三处尺寸对齐")
            if localSession.isRunning {
                stopLocalSession(reason: "分辨率自动降档，按新尺寸重开")
                startLocalSession()
                armLocalCallbackRetry()
            }
            beginClinkAttempts(candidates: clinkCandidates, localIP: flowLocalIP)
            return
        }
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
        // 本机 CarPlay 会话也一并收尾，走统一的 stopLocalSession：以前
        // 这里只停车机链路，会话本体被留在原地、最后由原生侧事件通道
        // 自行关闭收场，不经过 LocalCarPlaySession.stop()，预轮换标记
        // 的 stop 写点被整条绕过（ROTATION-MARKER-DIFF 实锤）。标记现
        // 已在连上时就落下，这里再收尾是让会话干净结束（停画中画＋
        // 会话 stop＋解码器复位，都在 stopLocalSession 里，别重复做）。
        stopLocalSession(reason: "用户断开车机")
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
        // 认出是哪台车：deviceId 落盘（设置页校准/预置命中要用），
        // 分辨率阶梯按这台车上次的定案档起步——放在防重复守卫之后、
        // 预发起之前，重复的 ServerInfo 不会把正在跑的尺寸重置掉。
        if let deviceId = bleProbe.foundDeviceId {
            UserDefaults.standard.set(deviceId, forKey: "cabinplay.lastCarDeviceId")
        }
        prepareSizeTier(for: bleProbe.foundDeviceId)
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
            // 无回连自动重试挂上：接续后每轮等 20 秒仍无回连就同凭
            // 据同地址重新发起，最多共 3 次；回连即收手。
            armLocalCallbackRetry()
            // 车机地址候选逐个启 clink 真连接试（被拒自动重试/换候选），
            // 与本机 CarPlay 接续并行，两边靠帧桥汇合。
            beginClinkAttempts(candidates: result.candidates, localIP: result.localIP)
        }
    }

    private func appendLog(_ line: String) {
        let stamp = DateFormatter.logFormatter.string(from: Date())
        log.append("[\(stamp)] \(line)")
        if log.count > 1200 { log.removeFirst(log.count - 1200) }
    }
}

extension DateFormatter {
    static let logFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
