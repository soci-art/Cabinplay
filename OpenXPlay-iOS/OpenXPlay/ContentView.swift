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
                    keepAliveActive: localSession.keepAliveActive,
                    blePinField: $blePin,
                    selectedSize: targetSize,
                    onToggleLocalSession: { localSession.isRunning ? stopLocalSession() : startLocalSession() },
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

    private func stopLocalSession(reason: String = "用户在驾驶舱点停") {
        localSession.stop(reason: reason)
        decoder.reset()
        hasVideo = false
    }

    // MARK: 连接车机总流程（顺序：蓝牙先行 → 入网前停旧会话 → 入网 → 本机 CarPlay 一次启动 + clink 并行）

    /// 点「连接车机」的总入口：第一件事就是走蓝牙写 ClientInfo。车机
    /// 的 30 秒看门狗从蓝牙连上那刻起算，而蓝牙在扫描发现车机时就已
    /// 连上——先等本机 CarPlay 建立会把窗口吃光（14:56 实测：等满
    /// 15 秒才写 ClientInfo，写出后 8 秒无回执、蓝牙被车机断开；旧
    /// 流程连上立刻写、回执 <1 秒必成）。蓝牙这段只要一两秒，先走
    /// 完；拿到 ServerInfo 后先在旧网络上把正在跑的本机 CarPlay 干净
    /// 停掉、再入网，入网落稳后本机 CarPlay 一次启动到位、clink 试
    /// 序同时开始（见 handleUCarServerInfo），两边靠帧桥兜底汇合。
    private func connectCarFlow() {
        appendLog("连接车机：先走蓝牙写 ClientInfo（车机 30 秒窗口从蓝牙连上起算，不能先等本机 CarPlay），拿到 ServerInfo 后先停旧会话再入网，入网后一次启动本机 CarPlay")
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

    /// UCar：BLE 拿到 ServerInfo 后的整段自动流程——静默存凭据 → 还
    /// 在旧网络上时先把正在跑的本机 CarPlay 干净停掉 → 组网
    /// （UCarNetworkJoiner）→ 入网落稳后本机 CarPlay 一次启动到位、
    /// 同时现取现验启 clink 鉴权。用户不再需要点任何东西。
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
        // 入网切网会把旧网络上的连接整段掐断：本机 CarPlay 会话若正
        // 在旧网络上跑（尤其已出画），被切网中途掐死后系统侧会把它
        // 记成卡死——之后按新地址重开、乃至手动再开，iOS 都不回连
        // （1532 实证）；而 1530 里首个会话还没建立就被换掉、重开即
        // 成，差别就在旧会话是否已建立。所以顺序定死：入网之前，先
        // 趁还在旧网络上把会话干净停掉（走既有 stop 路径、同步停
        // 完）；没在跑也不在旧网络上先启——那等于再造一个跨网重开。
        let stoppedForJoin = localSession.isRunning
        if stoppedForJoin {
            appendLog("本机 CarPlay：连接车机要先入网切网——趁还在旧网络上，先把正在跑的本机 CarPlay 干净停掉，入网后再一次启动到位")
            stopLocalSession(reason: "连接车机：入网切网前先停掉")
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
                if stoppedForJoin {
                    appendLog("本机 CarPlay：入网失败，入网前停掉的会话保持停止（手动点「启动 CarPlay」可恢复）")
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
            // 入网落稳，本机 CarPlay 现在一次启动到位：凭据是本轮刚带
            // 回的新鲜车机凭据、地址就是入网后的地址，不存在跨网重
            // 开。仅剩的兜底：入网期间用户手动启动过、且还绑在旧地址
            // 上，才重开一次对齐新地址。
            if localSession.isRunning, localSession.boundAddress != result.localIP {
                appendLog("本机 CarPlay：入网期间被手动启动且还绑在旧地址 \(localSession.boundAddress ?? "?") 上，重开一次对齐新地址 \(result.localIP)")
                stopLocalSession(reason: "入网后对齐新地址重开")
                startLocalSession()
            } else if !localSession.isRunning {
                appendLog("本机 CarPlay：入网完成，现在启动本机 CarPlay（一次到位，不再跨网重开）")
                startLocalSession()
            }
            // 车机地址候选逐个启 clink 真连接试（被拒自动重试/换候选），
            // 与本机 CarPlay 启动并行，两边靠帧桥汇合。
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
