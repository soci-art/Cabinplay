// SPDX-FileCopyrightText: 2026 CabinPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// The app shell: three tabs (Carlink / CarLife / 设置).
// 日志不再是独立标签页：Carlink 与 CarLife 各自在导航栏右上角有橙色
// 日志入口、进各自的二级日志页，两边日志只管各自的、互不干扰。
// CarLife 与 Carlink 功能分开、各自独立。
// 主线：本机 CarPlay 会话（LocalCarPlaySession）出帧 → 蓝牙 UCar 配对 →
// 拿到 ServerInfo 后组网（UCarNetworkJoiner）→ CarLink（clink）把帧送上
// 车机、把车机触摸/按键回送本机会话。全程没有手填表单：车机地址入网后
// 取组主地址、本机 IP 按目标网段现取现验、配对码只用蓝牙卡那一个输入框、
// 热点凭据由 ServerInfo 带回后静默存下。

import SwiftUI
import Combine
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
    /// 免码连接失败后置真：蓝牙卡把输码框重新亮出来（车机多半把手机忘了）。
    @State private var pinEntryForced = false
    /// 本轮免码连接有没有到过出画（到过再断开是正常断开，不亮输码框）。
    @State private var pinlessReachedPlaying = false
    @State private var carLinkRunning = false
    @State private var netMonitor: NetworkChangeMonitor?
    /// 启动总超时：从点「连接车机」起算，超过这个时长还没出画就整轮放弃，
    /// 不再让用户对着「连接中」无限等（每轮内部重试仍受 30 秒预算约束）。
    @State private var startupWatchdog: DispatchWorkItem?

    // 分辨率改自动（不再有手动菜单）：阶梯从高往低，连接时先用这台
    // 车上次协商定案的档（存 UserDefaults），没有就从最高档起步；
    // 整轮协商都失败就自动降一档、本机 CarPlay 会话按新尺寸重开一
    // 次再试（WFD 声明、本机 CarPlay 请求、触控换算三处尺寸必须同
    // 源同值，见 abandonClinkAttempts 的降档分支）。targetSize 是当
    // 前档的生效值，只用于展示与启动参数，不再由用户选。
    private static let startupBudget: TimeInterval = 120
    private static let sizeLadder: [(Int, Int)] = [(1920, 1080), (1280, 720), (854, 480)]
    /// 画质档位（设置页）：auto / 1080 / 720 / 480。手动档只决定「起步
    /// 档」，协商失败仍按阶梯往下自动降，不会卡死在用户选的那一档。
    @AppStorage("cabinplay.sizeChoice") private var sizeChoice = "auto"
    /// 请求帧率：60 或 30。车机只解 30 的车把这里切 30，帧间隔更均匀。
    @AppStorage("cabinplay.fpsChoice") private var fpsChoice = 60
    @State private var sizeTierIndex = 0
    @State private var targetSize: (Int, Int) = (1920, 1080)

    // UCar 后段流程状态（全部自动推导，不再有手填项）。
    private enum JoinPhase: Equatable {
        case idle, joining, failed(String)
    }
    @State private var joinPhase: JoinPhase = .idle
    @State private var carLinkDetail = "先在蓝牙卡连接车机，后面的入网和 CarLink 都自动走"
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
    /// CarLife 的整套会话由根层持有：它的隐藏显示层要和 CarLink 一样
    /// 常驻窗口，切 tab 才不会把画中画的源摘掉。
    @StateObject private var carLifeSession = CarLifeSession()
    /// CarLink 的画中画保活开关（Carlink 页里改，和 CarLife 各管各的）。
    @AppStorage("cabinplay.pip.carLink") private var pipCarLink = true
    @Environment(\.scenePhase) private var scenePhase

    // clink 候选真连接试序＋被拒重试（流程内部行为，不受用户点按守卫影响）。
    // 参数：同候选原地重试间隔 2 秒、同候选最多 4 次、单次尝试 8 秒看门狗、
    // 含候选切换的总预算 30 秒。命中口径：状态走到协商（negotiating）或
    // 出画（playing）才算；只到配对认证就断的不算（14:03 就是这种）。
    /// CarLink 候选试序的状态机：候选/重试/看门狗/预算/命中判定都在它
    /// 里面（CarLinkFlow.swift），视图不再自己记这些账。
    @State private var clinkFlow = CarLinkFlow()
    @State private var clinkCallbacksWired = false

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                DashboardView(
                    localPhaseText: localSession.phase.text,
                    localPhaseFailed: localSession.phase.isFailed,
                    localStreaming: localSession.phase == .streaming,
                    localSessionRunning: localSession.isRunning,
                    onToggleCarPlay: { toggleLocalCarPlay() },
                    carLinkState: carLinkState,
                    carLinkRunning: carLinkRunning,
                    carLinkStatusText: carLinkStatusText,
                    carLinkDetail: carLinkDetail,
                    bleScanning: bleProbe.scanning,
                    bleSummary: bleProbe.lastFoundSummary ?? "还没发现车机——在车里打开车机的 CarLink，再点开始探测",
                    bleFound: bleProbe.foundDeviceId != nil,
                    blePaired: bleProbe.hasStoredToken || bleProbe.hasPairedRecord,
                    pinEntryForced: pinEntryForced,
                    blePhaseText: bleStageText,
                    keepAliveActive: localSession.keepAliveActive,
                    blePinField: $blePin,
                    currentSizeLabel: "\(targetSize.0)×\(targetSize.1)",
                    onDisconnectCarLink: { stopCarLink() },
                    onToggleBleProbe: { bleProbe.toggle() },
                    onConnectBle: { connectCarFlow() },
                    logLines: log,
                    onClearLog: { log.removeAll() }
                )
            }
            .tabItem {
                Label {
                    Text("Carlink")
                } icon: {
                    Image("TabCarlink")
                }
            }
            .tag(0)

            NavigationStack {
                CarLifeView(session: carLifeSession)
            }
            .tabItem {
                Label {
                    Text("CarLife")
                } icon: {
                    Image("TabCarlife")
                }
            }
            .tag(1)

            NavigationStack {
                SettingsView()
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
            ZStack {
                VideoSurface(decoder: decoder)
                    .opacity(0)
                    .allowsHitTesting(false)
                // CarLife 自己的显示层：只为画中画这条保活腿存在；放在根层
                // 才能跟着窗口一直挂着（放在 tab 内容里切页就会被摘掉）。
                VideoSurface(decoder: carLifeSession.decoder)
                    .opacity(0)
                    .allowsHitTesting(false)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            // 内存告警：只让本机解码/画中画这条路让路，车机画面与会话不动。
            appendLog("本机内存：系统告警——停画中画并清空解码积压，等下一个关键帧")
            pictureInPicture?.stop()
            decoder.reset()
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
        // 车机媒体键（蓝牙 AVRCP）→ CarPlay：音频走 A2DP 时，车机的播放/
        // 暂停/上一曲/下一曲是蓝牙媒体命令，不是 CarLink 的 UIBC 按键。
        MediaRemoteBridge.shared.install(for: localSession, log: { appendLog($0) })
        localSession.start(width: targetSize.0, height: targetSize.1, fps: fpsChoice,
                           addressOverride: addressOverride)
        if localSession.phase.isFailed {
            Haptics.error()
        }
    }

    /// 主页手动开关（连上 CarLink 后才显示）：只停/只开本机 CarPlay
    /// 会话，CarLink 连接保持不动；重开走与流程相同的 startLocalSession，
    /// 帧桥挂在会话/解码器上，会话回来画面自己续上。
    private func toggleLocalCarPlay() {
        if localSession.isRunning {
            stopLocalSession(reason: "用户手动关闭 CarPlay（CarLink 保持连接）")
        } else {
            startLocalSession()
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
        guard pipCarLink else {
            appendLog("画中画保活：Carlink 页里关掉了，本轮不拉起（静音音频这条腿照常）")
            return
        }
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
    /// B 方案（2026-11-27）：发起挪到入网之后，等待期不再 20 秒重启，
    /// 第一窗直接 35 秒，只观察不打断系统的回连。
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
        // B 方案：等待期只观察、不在中途重启。2026-11-27 实测 20 秒那次
        // 重启没有换来更早回连（系统仍在切网后整 30 秒才回连），所以第
        // 一窗直接放到 35 秒熔断线：回连了就收手，没回连才按反应式轮换
        // 重启一次（只此一次，不叠加中途重试）。轮换后的新身份仍按 20 秒
        // 一窗，最多 3 次。
        var waitSeconds = localRotatedThisFlow ? 20 : 35
        if !localRotatedThisFlow, let fuseStart = localFuseStartedAt {
            waitSeconds = max(1, Int((35 - Date().timeIntervalSince(fuseStart)).rounded()))
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

    // MARK: 连接车机总流程（B 方案：蓝牙先行 → 入网 → 在新网络上发起会话 + 无回连观察，clink 并行）

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
        armStartupDeadline()
        pinlessReachedPlaying = false
        appendLog("本机 CarPlay：本轮先用原设备标识连接（35 秒不回连再换新标识）")
        appendLog("连接车机：先走蓝牙写 ClientInfo（车机 30 秒窗口从蓝牙连上起算，不能先等本机 CarPlay），拿到 ServerInfo 后先入网、网络稳定后再在新网络上发起 CarPlay（B 方案：不再在旧网络预发起、不再切网重启）")
        bleProbe.connect(pin: blePin)
    }

    /// 分辨率自动协商的起步档：这台车上次协商定案的尺寸（按
    /// deviceId 存）就是这轮的起步档；没有记录就从阶梯最高档起。
    /// 每轮连接在 handleUCarServerInfo 开头调一次。
    private func prepareSizeTier(for deviceId: String?) {
        var tier = 0
        // 手动档优先：用户选了 720p 就从 720p 起步，协商失败仍按阶梯继续降。
        switch sizeChoice {
        case "1080": tier = 0
        case "720": tier = 1
        case "480": tier = 2
        default:
            if let deviceId,
               let saved = UserDefaults.standard.string(forKey: "cabinplay.provenSize.\(deviceId)"),
               let index = Self.sizeLadder.firstIndex(where: { "\($0.0)x\($0.1)" == saved }) {
                tier = index
            }
        }
        sizeTierIndex = tier
        targetSize = Self.sizeLadder[tier]
        if sizeChoice == "auto" {
            appendLog(tier == 0
                ? "分辨率自动协商：从最高档 \(targetSize.0)×\(targetSize.1) 起步，车机接受不了就自动降档"
                : "分辨率自动协商：这台车上次定案是 \(targetSize.0)×\(targetSize.1)，这轮从这一档起步")
        } else {
            appendLog("分辨率：手动档 \(targetSize.0)×\(targetSize.1)（设置页指定；协商失败仍会自动降档），请求 \(fpsChoice) fps")
        }
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
            if line.hasPrefix("CarLink 错误：") { clinkFlow.noteError(line) }
            appendLog(line)
        }
        core.onState = { state in
            carLinkState = state
            if state == .playing {
                pinlessReachedPlaying = true
                pinEntryForced = false
            }
            if state == .ended, bleProbe.flowUsesPairedRecord, !pinlessReachedPlaying {
                // 免码连没连上就结束了：多半是车机把手机忘了、临时要码——
                // 把输码框重新亮出来，用户输一次码重新配对即可。
                pinEntryForced = true
            }
            carLinkRunning = (state != .idle && state != .ended)
            if state == .negotiating || state == .playing {
                clinkFlow.noteHit()
            }
            if state == .playing {
                carLinkDetail = "车机 \(flowCarIP) · 本机 \(flowLocalIP) · 正在输出"
                appendLog(AudioDiagnostics.snapshot(width: targetSize.0, height: targetSize.1))
                appendLog(AudioDiagnostics.formatMatrix())
                appendLog(AudioDiagnostics.touchGeometry())
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
                if clinkFlow.isActive {
                    clinkFlow.noteSessionEnded()
                } else {
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

    /// 入网成功后进入候选试序：候选/重试/看门狗交给 CarLinkFlow，
    /// 这里只把「怎么启一次连接」和「放弃后怎么办」接给它。
    private func beginClinkAttempts(candidates: [String], localIP: String) {
        guard !candidates.isEmpty else {
            appendLog("CarLink 启动中止：没有车机地址候选")
            carLinkDetail = "启动失败：没有车机地址候选"
            return
        }
        wireCarLinkCallbacks()
        wireClinkFlowCallbacks()
        touchAnchorLogged = false
        // 触控换算固定居中模型（校准功能已整套撤销）：每轮试序开始
        // 时把模式推给核心一次，并清掉核心里可能残留的校准矩形。
        CarLinkCore.shared.applyTouchMode()
        flowLocalIP = localIP
        clinkFlow.begin(candidates: candidates, localIP: localIP)
    }

    /// 状态机回调只接一次：闭包内部改的都是 @State（有引用存储，视图
    /// 结构体被复制也不影响写回）。
    private func wireClinkFlowCallbacks() {
        let flow = clinkFlow
        flow.onLog = { appendLog($0) }
        flow.onDetail = { carLinkDetail = $0 }
        flow.onStop = { CarLinkCore.shared.stop() }
        flow.onHit = { _ in
            cancelStartupDeadline()
            // 协商定案的尺寸按车记下：下次连这台车直接从这一档起步。
            if let deviceId = bleProbe.foundDeviceId ?? lastCarDeviceId {
                UserDefaults.standard.set("\(targetSize.0)x\(targetSize.1)",
                                          forKey: "cabinplay.provenSize.\(deviceId)")
            }
        }
        flow.onAbandon = { reason, tried in
            handleClinkAbandon(reason: reason, tried: tried)
        }
        flow.onLocalInvalid = { _, detail in
            appendLog("CarLink 启动中止：\(detail)，不把空值/旧地址传给核心")
            carLinkDetail = "启动失败：本机地址已失效，重新走一遍连接流程"
        }
        flow.onAttempt = { carIP, localIP in
            attemptClink(carIP: carIP, localIP: localIP)
        }
    }

    /// 真启一次 clink：地址现取现验、配对码归一、尺寸/身份从这里传。
    private func attemptClink(carIP: String, localIP: String) -> CarLinkFlow.Outcome {
        guard UCarNetworkJoiner.isValidIPv4(carIP) else {
            return .failed("车机地址「\(carIP)」不是合法 IPv4")
        }
        let currentAddresses = ReceiverConfiguration.localIPv4Addresses()
        guard UCarNetworkJoiner.isValidIPv4(localIP), currentAddresses.contains(localIP) else {
            return .localAddressInvalid("本机地址「\(localIP.isEmpty ? "(空)" : localIP)」不是当前网卡上的真实地址（当前：\(currentAddresses.joined(separator: "、"))）")
        }
        flowCarIP = carIP
        // 配对码只用蓝牙卡那一个输入框的值；令牌免码轮次字段为空就传空串，
        // TCP 鉴权走已存配对（QUICK）。车机码不一定是 6 位（见过 4/8 位）。
        let pin = blePin.trimmingCharacters(in: .whitespaces)
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
        return started ? .started : .failed("clink 启动即失败")
    }

    /// 整轮放弃：阶梯下面还有档就降一档、本机 CarPlay 会话按新尺寸重开；
    /// 降无可降就停在这一档，把日志发回来。
    private func handleClinkAbandon(reason: String, tried: [String]) {
        guard sizeTierIndex + 1 < Self.sizeLadder.count else {
            appendLog("CarLink 全部候选与重试都失败了（\(reason)；试过 \(tried.joined(separator: "、"))）——这一轮停在这里，把日志发回来看")
            carLinkDetail = "连接失败：车机地址都试过了（\(reason)）"
            return
        }
        let oldSize = targetSize
        sizeTierIndex += 1
        targetSize = Self.sizeLadder[sizeTierIndex]
        appendLog("分辨率自动降档：\(oldSize.0)×\(oldSize.1) 这一档整轮没协商成（\(reason)），降到 \(targetSize.0)×\(targetSize.1) 再试——本机 CarPlay 会话按新尺寸重开一次，让声明/请求/触控三处尺寸对齐")
        if localSession.isRunning {
            stopLocalSession(reason: "分辨率自动降档，按新尺寸重开")
            startLocalSession()
            armLocalCallbackRetry()
        }
        beginClinkAttempts(candidates: tried, localIP: flowLocalIP)
    }

    /// 会话期网络监控：车机热点重启/换网后 clink 会对着旧地址发呆，
    /// 这里发现地址变了就停掉 clink，用新地址重走候选试序（各带看门狗）。
    private func startNetworkMonitorIfNeeded() {
        if netMonitor != nil { return }
        let monitor = NetworkChangeMonitor()
        monitor.start { signature in
            DispatchQueue.main.async {
                appendLog("网络变化：Wi-Fi 地址变为「\(signature.isEmpty ? "无" : signature)」")
                guard carLinkRunning || clinkFlow.isActive else { return }
                // 只认 Wi-Fi（en0）：蜂窝/VPN 接口出现不算换网，更不能拿它当本机地址。
                guard let local = ReceiverConfiguration.wifiIPv4Address(),
                      UCarNetworkJoiner.isValidIPv4(local) else {
                    appendLog("网络变化：Wi-Fi 当前没有地址（掉线或正在重连），先不动正在跑的会话")
                    return
                }
                guard local != flowLocalIP else {
                    appendLog("网络变化：Wi-Fi 地址没变（\(local)），忽略这次接口变化")
                    return
                }
                // 必须和车机同一 /24：否则用这个地址重连只会 8 秒超时×4。
                func prefix(_ ip: String) -> String {
                    ip.split(separator: ".").dropLast().joined(separator: ".")
                }
                guard UCarNetworkJoiner.isValidIPv4(flowCarIP),
                      prefix(local) == prefix(flowCarIP) else {
                    appendLog("网络变化：Wi-Fi 地址 \(local) 与车机 \(flowCarIP) 不在同一网段，不重连")
                    return
                }
                // 去抖：地址站稳 2 秒再做，避免 DHCP 过渡期的半成品地址触发重启。
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    guard ReceiverConfiguration.wifiIPv4Address() == local,
                          carLinkRunning || clinkFlow.isActive else { return }
                    appendLog("网络变化：Wi-Fi 地址稳定为 \(local)，停掉当前 CarLink 重走候选试序")
                    CarLinkCore.shared.stop()
                    carLinkState = .idle
                    carLinkRunning = false
                    flowLocalIP = local
                    beginClinkAttempts(candidates: clinkFlow.candidates, localIP: local)
                }
            }
        }
        netMonitor = monitor
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
        cancelStartupDeadline()
        clinkFlow.cancel()
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
        if clinkFlow.isActive {
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
        // 历史记录（已由 B 方案取代）：早期规律是「重启后第一次发起的会话
        // 才能成」，且入网之后新发起四次全败，所以当时把发起放在入网之前。
        // 2026-11-27 的日志证明那条路的代价是切网后 iOS 断线重连的 30 秒；
        // 现在的做法见下面 B 方案注释。
        // B 方案（先入网、再起会话）：以前是「旧网络先发起 → 入网 → 切网后
        // 按新地址重启接续」。2026-11-27 10:39 的日志量出这条路要 31 秒：
        // 切网让 iOS 走无线 CarPlay 的「断线重连」退避，10:39:50 切网、
        // 10:40:20 才回连（整 30 秒），中间 20 秒那次重启并没有让它变快。
        // 现在把会话发起挪到入网之后：网络不再中途变化，iOS 走「配件在
        // 当前网络出现」的正常连接路径，预期 1–5 秒回连。
        // 入网前若还有在跑的会话（上一轮残留），先停干净——留着它会被切网
        // 掐死，反而占掉这次唯一的发起机会。
        var flowInitiatedLocalSession = false
        if localSession.isRunning {
            appendLog("本机 CarPlay：入网前先把旧会话停干净（避免切网把这次发起机会掐死；入网完成后再在新网络发起）")
            stopLocalSession(reason: "连接车机：先入网，停掉入网前的旧会话")
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
            // 入网完成、地址已稳定：现在在车机网络上发起唯一那次 CarPlay。
            // 不再有「切网后接续」这一步——那是 30 秒等待的来源。
            appendLog("本机 CarPlay：入网完成（本机 \(result.localIP)），现在在车机网络上发起 CarPlay 会话（不再切网，避开 iOS 的断线重连退避）")
            flowInitiatedLocalSession = true
            startLocalSession()
            // 无回连观察挂上：第一窗 35 秒只观察，期间不重启；没回连才
            // 按反应式轮换（仅一次），轮换后按 20 秒一窗、最多 3 次。
            armLocalCallbackRetry()
            // 车机地址候选逐个启 clink 真连接试（被拒自动重试/换候选），
            // 与本机 CarPlay 接续并行，两边靠帧桥汇合。只用真连接试：
            // 57209 只认第一个连接，裸 TCP 试探会占掉唯一的鉴权名额，
            // 不做任何形式的预探测/扫网段（同网段发现已按此口径删除）。
            beginClinkAttempts(candidates: result.candidates, localIP: result.localIP)
        }
    }

    /// 启动总超时（默认 120 秒）：到点还没出画就整轮停掉，给一句能看懂的
    /// 结论。命中出画时由 onHit 撤表；用户断开时 stopCarLink 也会撤。
    private func armStartupDeadline() {
        cancelStartupDeadline()
        let work = DispatchWorkItem { [self] in
            startupWatchdog = nil
            guard !carLinkRunning, carLinkState != .playing else { return }
            appendLog("启动超时：\(Int(Self.startupBudget)) 秒内没出画，整轮放弃——检查车机是否停在 CarLink 界面、手机是否还连着车机 Wi-Fi")
            carLinkDetail = "启动超时：\(Int(Self.startupBudget)) 秒没出画，已放弃这一轮"
            stopCarLink()
        }
        startupWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.startupBudget, execute: work)
    }

    private func cancelStartupDeadline() {
        startupWatchdog?.cancel()
        startupWatchdog = nil
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
