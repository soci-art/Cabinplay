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
// Wi-Fi 名/密码是 StartSession 时告诉 iOS 的凭据：优先用蓝牙 ServerInfo
// 自动带回并存下的车机热点，连接表里也能手动改。

import Foundation

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
    @Published private(set) var firstFrameAt: Date?

    var onLog: ((String) -> Void)?
    /// 本机预览帧（已在主线程）：喂 VideoDecoder 显示。
    var onPreviewFrame: ((Data, VideoCodec) -> Void)?
    var onPreviewConfig: ((Data, VideoCodec) -> Void)?

    let bridge = LocalCarPlayBridge()

    private let receiver = NativeReceiver()
    private let sameDevice = SameDeviceProbe()
    private var identity: AccessoryIdentity?
    private var configuration: ReceiverConfiguration?
    private var startParams: (width: Int, height: Int, fps: Int)?
    private var addressWatch: DispatchWorkItem?
    private var previewSets: VideoParameterSets?

    // MARK: Wi-Fi 凭据（车机热点）

    static var savedSSID: String {
        get { UserDefaults.standard.string(forKey: "cabinplay.wifiSSID") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "cabinplay.wifiSSID") }
    }
    static var savedPassword: String {
        get { UserDefaults.standard.string(forKey: "cabinplay.wifiPassword") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "cabinplay.wifiPassword") }
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
        var config = ReceiverConfiguration(
            name: "CabinPlay",
            address: address,
            ssid: Self.savedSSID,
            password: Self.savedPassword,
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
        wireCallbacks()
        phase = .starting
        onLog?("本机 CarPlay：启动中——本机地址 \(address):7001，画面 \(width)×\(height) @\(fps)，Wi-Fi「\(Self.savedSSID)」")
        receiver.start(configuration: config, identity: loadedIdentity)
        watchStartupAddress(expected: address)
    }

    func stop() {
        addressWatch?.cancel()
        addressWatch = nil
        sameDevice.stop()
        receiver.stop()
        phase = .idle
        controlConnected = false
        firstFrameAt = nil
        previewSets = nil
        onLog?("本机 CarPlay：已停止")
    }

    /// 启动期间 Wi-Fi 地址变了（切网/热点重连）就用新地址自动重开一次会话。
    private func watchStartupAddress(expected: String) {
        addressWatch?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning, !self.controlConnected else { return }
            let now = ReceiverConfiguration.wifiIPv4Address()
            if let now, now != expected {
                self.onLog?("本机 CarPlay：启动期间本机地址从 \(expected) 变成了 \(now)（切了网络），用新地址重开会话")
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
            if self.firstFrameAt == nil {
                self.firstFrameAt = Date()
                DispatchQueue.main.async { [weak self] in
                    self?.phase = .streaming
                    self?.onLog?("本机 CarPlay：首帧已到，画面开始流动")
                }
            }
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

    /// CarLink 进入出画时由 ContentView 调用：桥补配置 + 请求关键帧。
    func carLinkPlayingChanged(_ playing: Bool) {
        bridge.setClinkPlaying(playing) { [weak self] in
            self?.receiver.requestKeyFrame(reason: "CarLink 进入出画")
        }
    }
}
