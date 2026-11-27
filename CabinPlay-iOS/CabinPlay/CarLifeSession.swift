// SPDX-FileCopyrightText: 2026 CabinPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// CarLife 会话：和 CarLink 完全独立的一套。
//
// 自己持有一个本机 CarPlay 会话 + 一个 CarLife 输出；把 CarPlay 的画面、
// 触控、按键、关键帧请求接到 CarLife 那条链路上。CarLink 那边的状态、
// 入网流程、触控居中模型一概不碰。
//
// 音频：CarLife 协议没有音频通道，声音必须留本机（蓝牙 A2DP 到车机）。
// 所以这里启动时明确把「车机在放声音」的标记清掉，让本机解码出声。
//
// 保活：与 CarLink 两条腿同源——出画（首帧真正进显示层）后拉起静音
// 音频保活，并把解码层的画面交给画中画做第二条腿；停止时两条一起收。

import Foundation
import Combine
import Network

final class CarLifeSession: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var status = "未启动"
    @Published private(set) var logLines: [String] = []
    /// 步骤状态（页面上的逐步打勾）。
    @Published private(set) var networkReady = false
    @Published private(set) var listening = false
    @Published private(set) var peerConnected = false
    @Published private(set) var streaming = false
    @Published private(set) var pausedByCar = false
    @Published private(set) var keepAliveActive = false
    /// 需要用户动手的提示（权限/端口/蓝牙）。
    @Published private(set) var hint: String?

    /// 画面解码器：只服务于画中画这条保活腿，不改 CarLife 直发车机的主路径。
    let decoder = VideoDecoder()

    private let local = LocalCarPlaySession()
    private let output = CarLifeOutput()
    private var pip: CarPlayPictureInPicture?
    private var wired = false
    private var monitor: NWPathMonitor?
    private var pathWasReady = false
    private var startedAt = Date()
    private var address = ""
    private var size: (w: Int, h: Int) = (1280, 720)
    private var fps = 30
    private var streamingStartedAt: Date?
    private var downgraded = false
    private var userStopped = false
    private var firstTouchLogged = false

    // MARK: 日志（与 CarLink 同规格：时间戳、1200 行上限）

    private func append(_ line: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let stamp = DateFormatter.logFormatter.string(from: Date())
            self.logLines.append("[\(stamp)] \(line)")
            if self.logLines.count > 1200 { self.logLines.removeFirst(self.logLines.count - 1200) }
            self.noteHint(in: line)
        }
    }

    func clearLog() {
        DispatchQueue.main.async { [weak self] in self?.logLines.removeAll() }
    }

    /// 从日志里抓需要用户处理的情况：端口被占、本地网络权限。
    private func noteHint(in line: String) {
        if line.contains("无法监听") || line.contains("监听失败") {
            hint = "有端口没能监听：可能被别的 App 占用，关掉占用端口的 App 或重启手机再试"
        } else if line.contains("本地网络") {
            hint = "本地网络权限没开：去 设置 → CabinPlay → 本地网络 打开后重启本页"
        }
    }

    // MARK: 启动 / 停止

    func start(carIP: String, width: Int, height: Int, fps: Int) {
        guard !running else { return }
        guard !CarLinkCore.shared.running else {
            status = "CarLink 正在运行：两边不能同时开，先停止 CarLink"
            append("CarLife：检测到 CarLink 在跑，拒绝启动（两套输出必须互斥）")
            return
        }
        address = carIP.trimmingCharacters(in: .whitespacesAndNewlines)
        size = effectiveStartSize(selectedW: width, selectedH: height)
        self.fps = fps
        userStopped = false
        downgraded = false
        firstTouchLogged = false
        pathWasReady = false
        startedAt = Date()
        streamingStartedAt = nil
        peerConnected = false
        streaming = false
        pausedByCar = false
        hint = nil
        keepAliveActive = false
        CarPlayAudio.carPlaysAudio = false
        OutputCoordinator.startingCarLife = true
        OutputCoordinator.carLifeActive = true
        wire()
        decoder.reset()
        local.start(width: size.w, height: size.h, fps: fps)
        output.start(targetAddress: address.isEmpty ? nil : address, width: size.w, height: size.h, fps: fps)
        OutputCoordinator.startingCarLife = false
        startMonitor()
        running = true
        listening = true
        status = address.isEmpty
            ? "正在启动：本机 CarPlay + CarLife 监听（靠 UDP 发现车机）"
            : "正在启动：本机 CarPlay + CarLife 监听（只通知车机 \(address)）"
        if !bluetoothAudioLikely() {
            hint = "蓝牙可能没连：声音会从手机扬声器出，先在系统蓝牙里连上车机"
        }
    }

    func stop() {
        userStopped = true
        stopEverything(status: "已停止")
        append("CarLife：已停止")
    }

    private func stopEverything(status newStatus: String) {
        output.stop()
        local.stop()
        pip?.stop()
        pip = nil
        monitor?.cancel()
        monitor = nil
        decoder.reset()
        OutputCoordinator.startingCarLife = false
        OutputCoordinator.carLifeActive = false
        DispatchQueue.main.async { [weak self] in
            self?.running = false
            self?.listening = false
            self?.peerConnected = false
            self?.streaming = false
            self?.pausedByCar = false
            self?.networkReady = false
            self?.keepAliveActive = false
            self?.status = newStatus
        }
    }

    // MARK: 接线

    private func wire() {
        guard !wired else { return }
        wired = true
        local.onLog = { [weak self] line in self?.append(line) }
        local.onPreviewConfig = { [weak self] record, codec in
            self?.decoder.configure(codec: codec == .h265 ? 2 : 1, config: record)
        }
        local.onPreviewFrame = { [weak self] data, codec in
            guard let self else { return }
            // 主路径：原样发给车机；旁路：喂本机解码器，只为画中画保活。
            self.output.append(data, codec: codec)
            self.decoder.append(data, ptsNanos: UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000))
        }
        output.onLog = { [weak self] line in self?.append(line) }
        output.onState = { [weak self] line in
            guard let self else { return }
            DispatchQueue.main.async { self?.status = line }
            if line.contains("暂停了画面") {
                DispatchQueue.main.async { self?.pausedByCar = true }
            }
            if line.contains("已断开"), self.streamingStartedAt != nil, !self.userStopped {
                self.downgradeIfNeeded()
            }
        }
        output.onPeer = { [weak self] peer in
            DispatchQueue.main.async { self?.peerConnected = true }
            self?.append("CarLife：车机已连上（\(peer)）")
        }
        output.onStreaming = { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                self.streaming = true
                self.streamingStartedAt = Date()
            }
            self.rememberProvenSize()
        }
        output.onTouches = { [weak self] points in
            guard let self else { return }
            if !self.firstTouchLogged, let first = points.first {
                self.firstTouchLogged = true
                self.append("CarLife：首触控 (\(String(format: "%.3f", first.x)), \(String(format: "%.3f", first.y)))（按声明的画面 0…1 归一化）")
            }
            self.local.touchesFromCarLife(points)
        }
        output.onControl = { [weak self] control in
            self?.local.pressRemote(control)
        }
        output.onKeyframeRequest = { [weak self] reason in
            self?.local.previewNeedsKeyFrame(reason: "CarLife：\(reason)")
        }
        decoder.onLog = { [weak self] line in self?.append(line) }
        decoder.onKeyframeNeeded = { [weak self] reason in
            self?.local.previewNeedsKeyFrame(reason: reason)
        }
        decoder.onFirstFrameEnqueued = { [weak self] in
            guard let self else { return }
            // 静音音频保活只有一条腿：本机 会话在首帧进显示层时自己
            // 拉起（与 CarLink 完全同一条），这里只把状态同步给页面
            // 的步骤卡。原来这里另起一份保活，两份静音播放器同时转，
            // 纯多余（验收时查出，已删）。
            self.local.previewDidDisplayFirstFrame()
            DispatchQueue.main.async { self.keepAliveActive = self.local.keepAliveActive }
            self.startPictureInPicture()
        }
    }

    // MARK: 画中画保活腿

    private func startPictureInPicture() {
        if pip == nil {
            let controller = CarPlayPictureInPicture(surface: decoder)
            controller.onLog = { [weak self] line in self?.append(line) }
            pip = controller
        }
        guard let pip else { return }
        pip.setAutomatic(true)
        _ = pip.start()
        append("CarLife：画中画保活已请求")
    }

    /// 页面把前后台变化转进来（与 CarLink 主页同款联动：切后台时推
    /// 一把让画中画自动吊起，回到前台收尾）。原来缺这一环，画中画
    /// 备好了也未必弹得出来。
    func sceneBecameInactive() { pip?.awaitAutomaticStart() }
    func sceneReturnedToForeground() { pip?.returnedToForeground() }

    // MARK: 网络变化（切网后重建监听）

    private func startMonitor() {
        monitor?.cancel()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let wifi = path.usesInterfaceType(.wifi) && path.status == .satisfied
            DispatchQueue.main.async { self.networkReady = wifi }
            guard self.running else { return }
            if !wifi {
                if self.pathWasReady {
                    self.pathWasReady = false
                    self.append("CarLife：网络断了（Wi-Fi 不可用），等网络回来再重建监听")
                }
                return
            }
            // 只在「从断到通」时才重建：监测刚启动会先报一次当前状态、
            // 运行中 Wi-Fi 参数微调也会反复回调，那些都不该把监听推倒
            // 重来（原来每次回调都重建，启动时平白多重建一遍，运行中
            // 网络一抖还可能把正连着的车机掀一下）。
            let recovering = !self.pathWasReady
            self.pathWasReady = true
            guard recovering, Date().timeIntervalSince(self.startedAt) > 3 else { return }
            // 切网后旧监听绑在旧地址上，重建一遍并重新宣告。
            self.append("CarLife：网络恢复（Wi-Fi），重建监听与通知")
            self.output.start(targetAddress: self.address.isEmpty ? nil : self.address,
                              width: self.size.w, height: self.size.h, fps: self.fps)
        }
        monitor.start(queue: DispatchQueue(label: "CabinPlay.carLife.network"))
        self.monitor = monitor
    }

    // MARK: 尺寸记忆与降档

    private var provenKey: String {
        "cabinplay.carLifeProvenSize.\(address.isEmpty ? "default" : address)"
    }

    private func rememberProvenSize() {
        UserDefaults.standard.set("\(size.w)x\(size.h)", forKey: provenKey)
    }

    /// 尺寸记忆的读法（原来只存不读，等于没做）：页面换过档位就清掉
    /// 记忆、按所选档重新试；没换档且存着更低的「跑通尺寸」（上次降
    /// 档降下来的），直接按跑通的起，不再白白失败一次。所选档比记忆
    /// 还低时按所选档（低的更稳妥）。
    private func effectiveStartSize(selectedW: Int, selectedH: Int) -> (w: Int, h: Int) {
        let defaults = UserDefaults.standard
        let scope = address.isEmpty ? "default" : address
        let selectedKey = "cabinplay.carLifeSelectedSize.\(scope)"
        let selected = "\(selectedW)x\(selectedH)"
        if defaults.string(forKey: selectedKey) != selected {
            defaults.set(selected, forKey: selectedKey)
            defaults.removeObject(forKey: provenKey)
            return (selectedW, selectedH)
        }
        if let proven = defaults.string(forKey: provenKey) {
            let parts = proven.split(separator: "x").compactMap { Int($0) }
            if parts.count == 2, parts[0] * parts[1] < selectedW * selectedH {
                append("CarLife：这台车上次跑通的是 \(proven)，这次直接按这个尺寸起")
                return (parts[0], parts[1])
            }
        }
        return (selectedW, selectedH)
    }

    /// 车机刚连上就断（20 秒内），按 1080p → 720p → 480p 降一档重试一次。
    private func downgradeIfNeeded() {
        guard !dowgraded, let startedAt = streamingStartedAt,
              Date().timeIntervalSince(startedAt) < 20 else { return }
        downgraded = true
        let next: (Int, Int)
        switch size {
        case (1920, 1080): next = (1280, 720)
        case (1280, 720): next = (854, 480)
        default: return
        }
        append("CarLife：车机连上很快就断了，按降档梯子从 \(size.w)×\(size.h) 降到 \(next.0)×\(next.1) 重开一次")
        size = next
        streamingStartedAt = nil
        DispatchQueue.main.async { [weak self] in
            self?.streaming = false
            self?.peerConnected = false
        }
        // 重启本机 会话要罩上「正在启动 CarLife」：互斥守卫分不清这是
        // CarLife 自己在重启，不罩就会以「CarLife 正在运行」把它拦下，
        // 降档反而把会话杀了（验收 5fac2ae 时查出的硬伤）。
        OutputCoordinator.startingCarLife = true
        local.stop()
        local.start(width: next.0, height: next.1, fps: fps)
        OutputCoordinator.startingCarLife = false
        output.start(targetAddress: address.isEmpty ? nil : address, width: next.0, height: next.1, fps: fps)
    }

    /// 蓝牙音频有没有连着（只读当前音频路由，不做任何切换）。
    private func bluetoothAudioLikely() -> Bool {
        AudioOutputPolicy.routeSummary.contains("Bluetooth")
    }
}
