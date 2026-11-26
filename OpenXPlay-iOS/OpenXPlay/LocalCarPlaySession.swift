// SPDX-FileCopyrightText: 2026 OpenXPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// LocalCarPlaySession — 本机 CarPlay 会话编排（整合自 CarWithin 的同机模式）：
// 起 NativeReceiver（7001 端口）→ 监听就绪后 SameDeviceProbe 发布虚拟配件
// 端点走 iAP2 认证/识别 → iPhone 的 CarPlay 栈回连本 App → 媒体帧一路喂
// 本机预览、一路经 LocalCarPlayBridge 推给车机（CarLink）。
//
// 身份用 CabinPlay 自带的那套：包内 certificate.p7b + 转换出的 leaf.cer /
// private.x963，AccessoryIdentity 初始化时自验配对，错了当场报错。
// Wi-Fi 名/密码是 StartSession 时告诉 iOS 的凭据：只有本轮车机会话刚
// 带回的新鲜凭据才许用车机网络名，其余时候用当前网络身份——旧的车机
// DIRECT- 名指向的网络早已消失，拿它启动会把当前 Wi-Fi 顶掉。

import Foundation
import Combine

final class LocalCarPlaySession: ObservableObject {
    enum Phase: Equatable {
        case idle
        case starting
        case listening
        case linking
        case negotiating
        case streaming
        case failed(String)

        var text: String {
            switch self {
            case .idle: return "未启动"
            case .starting: return "正在启动…"
            case .listening: return "接收端已就绪，正在发布本机配件…"
            case .linking: return "正在和系统建立 CarPlay 链路…"
            case .negotiating: return "系统已回连，正在协商会话…"
            case .streaming: return "CarPlay 已出画"
            case .failed(let reason): return "启动失败：\(reason)"
            }
        }

        var isFailed: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var controlConnected = false
    /// 本轮会话启动时绑定的本机地址（入网切网后上层据此判断要不要重开会话）。
    private(set) var boundAddress: String?
    /// 首个画面样本真正送入本机显示层的时刻（「已出画」的判定点，原版口径）。
    @Published private(set) var firstDisplayedAt: Date?

    var onLog: ((String) -> Void)?
    /// 本机预览帧（已在主线程）：喂 VideoDecoder 显示。
    var onPreviewFrame: ((Data, VideoCodec) -> Void)?
    var onPreviewConfig: ((Data, VideoCodec) -> Void)?

    let bridge = LocalCarPlayBridge()

    private let receiver = NativeReceiver()
    private let sameDevice = SameDeviceProbe()
    /// CarWithin 式保活：静音音频循环播放撑住 `audio` 后台模式，让会话
    /// 在回桌面/锁屏后不被系统挂起（实现文件与 CarWithin 原版逐字一致，
    /// CarPlayAudio 侧已有 holdsAudioSession 协调）。会话运行期间生效。
    private let keepAlive = BackgroundKeepAlive()
    @Published private(set) var keepAliveActive = false
    private var identity: AccessoryIdentity?
    private var configuration: ReceiverConfiguration?
    private var startParams: (width: Int, height: Int, fps: Int)?
    private var addressWatch: DispatchWorkItem?
    private var previewSets: VideoParameterSets?

    // MARK: Wi-Fi 凭据（车机热点）与新鲜度

    static var savedSSID: String {
        get { UserDefaults.standard.string(forKey: "cabinplay.wifiSSID") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "cabinplay.wifiSSID") }
    }
    static var savedPassword: String {
        get { UserDefaults.standard.string(forKey: "cabinplay.wifiPassword") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "cabinplay.wifiPassword") }
    }

    /// 本进程的启动标识：凭据只有在本进程内、由本轮车机会话存入时才算
    /// 「新鲜」。App 重启后上轮存的 DIRECT- 名一律过期——车机每轮会话
    /// 现编一个新网络名，旧名指向的网络早已消失，拿它启动本机 CarPlay
    /// 会让系统去连死网络、把当前 Wi-Fi 顶掉（真机实测）。
    private static let processBootID = UUID().uuidString
    private static var credsSavedAt: TimeInterval {
        get { UserDefaults.standard.double(forKey: "cabinplay.wifiCredsSavedAt") }
        set { UserDefaults.standard.set(newValue, forKey: "cabinplay.wifiCredsSavedAt") }
    }
    private static var credsBootID: String {
        get { UserDefaults.standard.string(forKey: "cabinplay.wifiCredsBootID") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "cabinplay.wifiCredsBootID") }
    }
    private static var credsFreshFlag: Bool {
        get { UserDefaults.standard.bool(forKey: "cabinplay.wifiCredsFresh") }
        set { UserDefaults.standard.set(newValue, forKey: "cabinplay.wifiCredsFresh") }
    }

    /// 本轮车机会话刚带回的凭据是否还新鲜：本进程存入、且车机会话
    /// 尚未结束（结束时由上层调 invalidateCarCredentials 作废）。
    static var carCredentialsFresh: Bool {
        credsFreshFlag && credsBootID == processBootID && !savedSSID.isEmpty
    }

    /// ServerInfo 带回车机网络凭据时走这里存：打时间戳＋本进程标记，
    /// 并标为新鲜。只有新鲜凭据才许报进本机 CarPlay 的启动配置。
    static func storeCarCredentials(ssid: String, password: String?) {
        savedSSID = ssid
        if let password { savedPassword = password }
        credsSavedAt = Date().timeIntervalSince1970
        credsBootID = processBootID
        credsFreshFlag = true
    }

    /// 车机会话结束（断开/会话终了/入网失败）时作废新鲜标记：存下的
    /// DIRECT- 名从此不许再被本机 CarPlay 启动引用。
    static func invalidateCarCredentials() {
        credsFreshFlag = false
    }

    /// 读到过的「当前基础设施网络」名（非车机临时 DIRECT- 网络）：系统
    /// 读不到当前 SSID 时，用它当本机 CarPlay 的当前网络身份。
    private static var lastInfraSSID: String {
        get { UserDefaults.standard.string(forKey: "cabinplay.lastInfraSSID") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "cabinplay.lastInfraSSID") }
    }
    private static var lastInfraPassword: String {
        get { UserDefaults.standard.string(forKey: "cabinplay.lastInfraPassword") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "cabinplay.lastInfraPassword") }
    }

    /// 选本机 CarPlay 启动时报给系统的 Wi-Fi 身份，来源按可信度排序，
    /// 选了哪种打日志：
    /// 1. 本轮车机会话刚带回且仍新鲜的凭据（车机流程内重启专用）；
    /// 2. 系统此刻读到的当前网络名（读到顺手记下，非 DIRECT- 才记）；
    /// 3. 上次记下的基础设施网络名；
    /// 4. 此前存下、且不是车机临时 DIRECT- 名的凭据；
    /// 5. 都没有 → 返回 nil，宁可不启动也不拿失效的 DIRECT- 名毒害。
    private func pickWiFiIdentity() -> (ssid: String, password: String, source: String)? {
        if Self.carCredentialsFresh {
            return (Self.savedSSID, Self.savedPassword,
                    "本轮车机会话刚带回的凭据（新鲜）")
        }
        if let live = UCarNetworkJoiner.currentSSID(), !live.isEmpty {
            let password = live == Self.savedSSID ? Self.savedPassword
                : (live == Self.lastInfraSSID ? Self.lastInfraPassword : "")
            if !live.hasPrefix("DIRECT-") {
                Self.lastInfraSSID = live
                if live == Self.savedSSID { Self.lastInfraPassword = Self.savedPassword }
            }
            return (live, password, "系统读到的当前网络")
        }
        if !Self.lastInfraSSID.isEmpty {
            return (Self.lastInfraSSID, Self.lastInfraPassword,
                    "上次记下的当前网络（系统此刻读不到 SSID）")
        }
        if !Self.savedSSID.isEmpty, !Self.savedSSID.hasPrefix("DIRECT-") {
            return (Self.savedSSID, Self.savedPassword,
                    "此前存下的网络凭据（非车机临时网络）")
        }
        return nil
    }

    var isRunning: Bool {
        switch phase {
        case .idle, .failed: return false
        default: return true
        }
    }

    // MARK: 启停

    func start(width: Int, height: Int, fps: Int) {
        guard !isRunning else { return }
        startParams = (width, height, fps)
        bridge.setFPS(Double(fps))
        let loadedIdentity: AccessoryIdentity
        do {
            loadedIdentity = try AccessoryIdentityStore.loadFromBundle()
        } catch {
            phase = .failed("身份材料不可用")
            onLog?("本机 CarPlay：身份加载失败——\(error.localizedDescription)。包内应有 CabinPlay 自带身份转换出的 leaf.cer / private.x963 与 certificate.p7b，配对自验没过就说明转换或文件不对")
            return
        }
        identity = loadedIdentity
        guard let address = ReceiverConfiguration.wifiIPv4Address()
                ?? LocalNetwork.ipv4Addresses().first else {
            phase = .failed("拿不到本机地址")
            onLog?("本机 CarPlay：拿不到本机 Wi-Fi 地址——先连上车机热点（或任意 Wi-Fi）再启动")
            return
        }
        // Wi-Fi 身份按可信度选（见 pickWiFiIdentity）：只有本轮车机会话
        // 刚带回的新鲜凭据才许用车机 DIRECT- 名；其余情况一律用当前网
        // 络身份，绝不拿失效的旧 DIRECT- 名启动（系统会去连那个早已消
        // 失的网络、把当前 Wi-Fi 顶掉）。
        guard let wifi = pickWiFiIdentity() else {
            phase = .failed("没有可用的 Wi-Fi 名称")
            onLog?("本机 CarPlay：启动中止——存下的只有已失效的车机临时网络名，当前网络名又读不到。先连上一个 Wi-Fi，或先走一次车机连接流程再启动")
            return
        }
        var config = ReceiverConfiguration(
            name: "CabinPlay",
            address: address,
            ssid: wifi.ssid,
            password: wifi.password,
            deviceID: ReceiverConfiguration.persistentDeviceID())
        config.port = 7001
        config.width = width
        config.height = height
        config.maxFPS = fps
        config.videoCodec = .h264
        do {
            try config.validate()
        } catch {
            phase = .failed(error.localizedDescription)
            onLog?("本机 CarPlay：配置没过校验——\(error.localizedDescription)")
            return
        }
        configuration = config
        boundAddress = address
        wireCallbacks()
        phase = .starting
        onLog?("本机 CarPlay：启动中——本机地址 \(address):7001，画面 \(width)×\(height) @\(fps)，Wi-Fi「\(wifi.ssid)」(来源：\(wifi.source))")
        // 保活在请求 CarPlay 之前、还在前台时开启（CarWithin 原版口径：
        // 等退到后台再开可能来不及）。开启失败只记日志，不拦会话启动。
        keepAlive.onLog = { [weak self] in self?.onLog?("本机 CarPlay：\($0)") }
        keepAliveActive = keepAlive.start()
        receiver.start(configuration: config, identity: loadedIdentity)
        watchStartupAddress(expected: address)
    }

    /// 所有停止路径统一走这里并打明原因，别再出现无原因的「已停止」。
    func stop(reason: String = "用户手动停止") {
        addressWatch?.cancel()
        addressWatch = nil
        sameDevice.stop()
        receiver.stop()
        keepAlive.stop()
        keepAliveActive = false
        phase = .idle
        controlConnected = false
        boundAddress = nil
        firstDisplayedAt = nil
        previewSets = nil
        onLog?("本机 CarPlay：已停止（原因：\(reason)）")
    }

    /// 启动期间 Wi-Fi 地址变了（切网/热点重连）就用新地址自动重开一次会话。
    private func watchStartupAddress(expected: String) {
        addressWatch?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning, !self.controlConnected else { return }
            let now = ReceiverConfiguration.wifiIPv4Address()
            if let now, now != expected {
                self.onLog?("本机 CarPlay：因地址变化重开：旧 \(expected) → 新 \(now)（启动期间切了网络）")
                let params = self.startParams ?? (1280, 720, 30)
                self.sameDevice.stop()
                self.receiver.stop()
                self.phase = .idle
                self.start(width: params.width, height: params.height, fps: params.fps)
                return
            }
            self.watchStartupAddress(expected: expected)
        }
        addressWatch = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: item)
    }

    private func wireCallbacks() {
        receiver.onLog = { [weak self] in self?.onLog?("本机 CarPlay：\($0)") }
        sameDevice.onLog = { [weak self] in self?.onLog?("本机 CarPlay：\($0)") }
        bridge.onLog = { [weak self] in self?.onLog?($0) }
        receiver.onListening = { [weak self] port in
            guard let self, var config = self.configuration, let identity = self.identity else { return }
            config.port = port
            self.configuration = config
            self.phase = .linking
            self.onLog?("本机 CarPlay：接收端已在 \(port) 端口就绪，开始发布本机配件端点")
            self.sameDevice.start(configuration: config, identity: identity)
        }
        sameDevice.onFinished = { [weak self] message in
            guard let self else { return }
            if self.isRunning {
                self.phase = .failed(message)
            }
        }
        receiver.onControlConnected = { [weak self] in
            guard let self else { return }
            self.controlConnected = true
            self.phase = .negotiating
            self.sameDevice.didConnectControl()
        }
        receiver.onFailure = { [weak self] in
            guard let self, self.isRunning else { return }
            self.phase = .failed("接收端失败，原因看日志")
        }
        receiver.onCarUIRequested = { [weak self] in
            self?.onLog?("本机 CarPlay：用户点了 CarPlay 主屏上的车按钮（requestUI）")
        }
        receiver.onVideoAccessUnit = { [weak self] data, codec in
            guard let self else { return }
            // 注意：收到 AU 不等于出画（32 字节的配置包也走这里）。「已出画」
            // 改由预览显示层首帧 enqueue 成功后经 previewDidDisplayFirstFrame 置位。
            self.bridge.append(data, codec: codec)
        }
        receiver.onVideo = { [weak self] data, codec in
            guard let self else { return }
            // 本机预览：逐帧吸收参数集，凑齐/变化时先给解码器配置，再喂帧。
            var sets = (self.previewSets?.codec == codec)
                ? (self.previewSets ?? VideoParameterSets(codec: codec))
                : VideoParameterSets(codec: codec)
            var changed = false
            if let units = try? AnnexB.units(in: data) {
                for unit in units where sets.absorb(unit) { changed = true }
            }
            self.previewSets = sets
            if changed, sets.isComplete,
               let record = try? sets.decoderConfigurationRecord() {
                self.onPreviewConfig?(record, codec)
            }
            self.onPreviewFrame?(data, codec)
        }
    }

    // MARK: 触摸/按键回送（车机 → 本机 CarPlay 会话）

    func touchesFromCarLink(pressed: Bool, x: Double, y: Double) {
        if pressed {
            receiver.touches(source: "carlink", [TouchPoint(id: 0, x: x, y: y)])
        } else {
            receiver.touches(source: "carlink", [])
        }
    }

    /// clink 按键码（oxp-core KeyCode）：0 主页 1 返回 2 选择 3 旋钮左 4 旋钮右
    /// 7 播放暂停 8 下一首 9 上一首 10 语音；按下时才发（press 内部自带抬起）。
    func keyFromCarLink(code: UInt32, down: Bool) {
        guard down else { return }
        let control: CarPlayControl?
        switch code {
        case 0: control = .home
        case 1: control = .back
        case 2: control = .select
        case 3: control = .knobPrevious
        case 4: control = .knobNext
        case 7: control = .playPause
        case 8: control = .next
        case 9: control = .previous
        case 10: control = .siri
        default: control = nil
        }
        if let control {
            receiver.press(control)
        } else {
            onLog?("车机按键：收到键码 \(code)，暂时没有对应的 CarPlay 动作，先记下")
        }
    }

    /// 预览显示层把首个画面样本真正 enqueue 成功后由 ContentView 回调：
    /// 到这一步才置「已出画」（原版口径——首帧送入显示层才算，收到 AU 不算）。
    func previewDidDisplayFirstFrame() {
        guard isRunning, firstDisplayedAt == nil else { return }
        firstDisplayedAt = Date()
        phase = .streaming
        onLog?("本机 CarPlay：首帧已送入显示层，画面开始流动")
    }

    /// 预览显示层解码失败恢复时请求关键帧（接收端内部有节流与多次重试）。
    func previewNeedsKeyFrame(reason: String) {
        receiver.requestKeyFrame(reason: "本机预览恢复：\(reason)")
    }

    /// CarLink 进入出画时由 ContentView 调用：桥补配置 + 请求关键帧。
    func carLinkPlayingChanged(_ playing: Bool) {
        bridge.setClinkPlaying(playing) { [weak self] in
            self?.receiver.requestKeyFrame(reason: "CarLink 进入出画")
        }
    }
}
