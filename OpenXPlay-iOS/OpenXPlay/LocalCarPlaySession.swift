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
import CoreLocation

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
    /// 因等定位授权而挂起的本次启动：授权结果回来后自动续启，不让
    /// 用户再点一次。stop() 会把它清掉，清掉后授权回调不再续启。
    private var pendingSSIDStart: (address: String, identity: AccessoryIdentity)?
    private var addressWatch: DispatchWorkItem?
    private var noCallbackHintWork: DispatchWorkItem?
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

    /// 设置页展示记住的 Wi-Fi 名时读这个。
    static var rememberedInfraSSID: String { lastInfraSSID }

    /// 设置页手填兜底：用户拒绝定位授权时，把当前 Wi-Fi 名手填进来
    /// 写进同一个记住槽，本机 CarPlay 就能用它启动。手填没有密码。
    static func rememberInfraSSIDManually(_ ssid: String) {
        lastInfraSSID = ssid
        lastInfraPassword = ""
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
        if let wifi = pickWiFiIdentity() {
            beginStart(address: address, identity: loadedIdentity, wifi: wifi)
            return
        }
        // 一个可用名字都没有：多半是卡在「读当前网络名」这一步——iOS
        // 没有定位授权时 CNCopy/fetchCurrent 都读不到当前 SSID（真机
        // 实证：在家 Wi-Fi 连着也报无名可启）。按授权状态分流：未决
        // 定就先要授权、授权后自动续启；已被拒绝就说人话拒启。
        resolveWiFiIdentityThenStart(address: address, identity: loadedIdentity)
    }

    /// 身份选定后真正拉起接收端（start 直启与授权续启共用）。
    private func beginStart(address: String, identity loadedIdentity: AccessoryIdentity,
                            wifi: (ssid: String, password: String, source: String)) {
        let params = startParams ?? (1280, 720, 30)
        let width = params.width, height = params.height, fps = params.fps
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
        // 保活不在这里开：它一开就抢先激活音频会话（SoloAmbient），而
        // 今天卡 StartSession 的轮次（14:25/14:31/14:56）全都开了保活、
        // 出画的轮次（13:08/14:20）都没开——时机嫌疑最大。改为首帧送入
        // 显示层（previewDidDisplayFirstFrame）之后才开启。
        // 注：CarWithin 原版是在会话启动前就开的（其源码注释称等退到
        // 后台再开可能抢不到音频会话；保活文件本身与原版逐字一致）。
        // 本版按真机对账故意改晚做一次对照：若复验仍卡 StartSession，
        // 说明不是保活时机的事，再按原版口径改回。
        keepAlive.onLog = { [weak self] in self?.onLog?("本机 CarPlay：\($0)") }
        receiver.start(configuration: config, identity: loadedIdentity)
        watchStartupAddress(expected: address)
        scheduleNoCallbackHint()
    }

    /// 可信度链一个可用 Wi-Fi 名都没选出来时的分流处理：
    /// - 未决定：先打一句大白话说明，再请求定位授权；授权通过后立刻
    ///   fetchCurrent 读名、记下（非 DIRECT- 才记），自动续启本次启动，
    ///   不让用户再点一次；
    /// - 已拒绝/受限制：用一句话说清原因拒启，并指路设置页手填兜底；
    /// - 已授权却仍读不到：保留原拒启口径（多半是真没连 Wi-Fi）。
    private func resolveWiFiIdentityThenStart(address: String, identity loadedIdentity: AccessoryIdentity) {
        switch WiFiNameAccess.authorizationStatus {
        case .notDetermined:
            pendingSSIDStart = (address, loadedIdentity)
            phase = .starting
            onLog?("本机 CarPlay：读不到当前 Wi-Fi 的名字——iOS 规定读这个名字要先拿到定位权限。接下来系统会弹框问你，这个权限只用来读当前连着的 Wi-Fi 叫什么名字，不记录你的位置。点「允许」后会自动继续启动，不用再点一次")
            WiFiNameAccess.shared.requestAuthorization { [weak self] status in
                self?.handleAuthorizationResult(status)
            }
        case .denied, .restricted:
            phase = .failed("没拿到定位授权，读不到当前 Wi-Fi 的名字")
            onLog?("本机 CarPlay：启动中止——定位授权没开，读不到当前 Wi-Fi 的名字。可以去系统设置给 CabinPlay 开定位权限，或在设置页手填当前 Wi-Fi 名称，填了就能启动")
        default:
            phase = .failed("没有可用的 Wi-Fi 名称")
            onLog?("本机 CarPlay：启动中止——定位授权已拿到，但当前网络名还是读不到，存下的又只有已失效的车机临时网络名。先连上一个 Wi-Fi，或在设置页手填当前 Wi-Fi 名称")
        }
    }

    /// 定位授权结果回来：通过就读名续启，没通过就说人话拒启。
    /// 期间用户若已点停（pendingSSIDStart 被 stop 清掉），不再续启。
    private func handleAuthorizationResult(_ status: CLAuthorizationStatus) {
        guard pendingSSIDStart != nil else { return }
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            onLog?("本机 CarPlay：定位授权已允许，正在读当前 Wi-Fi 的名字…")
            WiFiNameAccess.fetchCurrentSSID { [weak self] fetched in
                guard let self, let pending = self.pendingSSIDStart else { return }
                self.pendingSSIDStart = nil
                if let fetched {
                    self.onLog?("本机 CarPlay：读到当前 Wi-Fi 名「\(fetched)」")
                    if !fetched.hasPrefix("DIRECT-") {
                        Self.lastInfraSSID = fetched
                        if fetched == Self.savedSSID { Self.lastInfraPassword = Self.savedPassword }
                    }
                } else {
                    self.onLog?("本机 CarPlay：授权拿到了，但 fetchCurrent 还是没读到当前 Wi-Fi 名（可能暂时没连上 Wi-Fi）")
                }
                if let wifi = self.pickWiFiIdentity() {
                    self.beginStart(address: pending.address, identity: pending.identity, wifi: wifi)
                } else if let fetched {
                    let password = fetched == Self.savedSSID ? Self.savedPassword : ""
                    self.beginStart(address: pending.address, identity: pending.identity,
                                    wifi: (fetched, password, "定位授权后读到的当前网络"))
                } else {
                    self.phase = .failed("没有可用的 Wi-Fi 名称")
                    self.onLog?("本机 CarPlay：启动中止——授权后仍读不到当前 Wi-Fi 名，也没有别的可用名字。在设置页手填当前 Wi-Fi 名称就能启动")
                }
            }
        default:
            pendingSSIDStart = nil
            phase = .failed("没拿到定位授权，读不到当前 Wi-Fi 的名字")
            onLog?("本机 CarPlay：定位授权没给，读不到当前 Wi-Fi 的名字，本次启动中止。可以去系统设置给 CabinPlay 开定位权限，或在设置页手填当前 Wi-Fi 名称，填了就能启动")
        }
    }

    /// 所有停止路径统一走这里并打明原因，别再出现无原因的「已停止」。
    func stop(reason: String = "用户手动停止") {
        pendingSSIDStart = nil
        addressWatch?.cancel()
        addressWatch = nil
        noCallbackHintWork?.cancel()
        noCallbackHintWork = nil
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
        // 会话出画后才开启后台保活（时机定案见 beginStart 的注释）：
        // 静音音频不再抢在 StartSession 之前激活音频会话。开启失败只
        // 记日志（keepAlive.start 内部会打），不影响会话本身。
        if !keepAliveActive {
            keepAliveActive = keepAlive.start()
            onLog?("本机 CarPlay：会话出画后开启后台保活（回桌面/锁屏靠它撑住会话）")
        }
    }

    /// StartSession 发出后久等不到系统回连时打一行大白话提示（0x4301
    /// 约每 3 秒重发一次，15 秒没回连就是重发 ≥4 次）：只提示、不停
    /// 会话——残留会话卡住时重启手机通常能清掉，它自己接上也会继续。
    private func scheduleNoCallbackHint() {
        noCallbackHintWork?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning, !self.controlConnected else { return }
            self.onLog?("本机 CarPlay：系统 CarPlay 一直没回连——今天连失败多次时系统里可能卡了残留会话，重启手机后再试通常能恢复（会话没停，它自己接上会继续走）")
        }
        noCallbackHintWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: item)
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
