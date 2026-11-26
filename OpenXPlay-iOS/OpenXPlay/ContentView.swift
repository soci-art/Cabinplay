// SPDX-FileCopyrightText: 2026 OpenXPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// The app shell: three tabs （驾驶舱 / 日志 / 设置）, with all receiver,
// CarLink, decoder and identity state held here and passed down.

import SwiftUI
import UniformTypeIdentifiers
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

struct VideoSurface: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        layer.frame = view.bounds
    }
}

struct ContentView: View {
    @StateObject private var identity = IdentityStore()
    @StateObject private var bleProbe = BleProbe()
    @State private var decoder = VideoDecoder()
    @State private var advertiser = BonjourAdvertiser()
    @State private var log: [String] = []
    @State private var running = false
    @State private var showingImporter = false
    @State private var status = "未启动"
    @State private var codec: UInt32 = 1
    @State private var headUnitIP = "192.168.49.1"
    @State private var localIP = ""
    @State private var pairingCode = ""
    @State private var blePin = ""
    @State private var carLinkState = CarLinkCore.State.idle
    @State private var carLinkRunning = false
    @State private var audio = AudioPipeline()
    @State private var pip = PictureInPicture()
    @State private var pipReady = false

    // New shell state
    @State private var tab = 0
    @State private var phoneConnected = false
    @State private var hasVideo = false
    @State private var receiverError: String?
    @State private var startedAt: Date?
    @State private var targetSize: (Int, Int) = (1280, 720)
    @State private var didAutoDetect = false

    private var core: CarPlayCore { .shared }

    private var heroState: String {
        if carLinkState == .playing && phoneConnected { return "正在车上显示" }
        if phoneConnected { return "已连接，画面传输中" }
        if running { return "等待 iPhone 连接" }
        return "未启动"
    }

    private var heroDetail: String {
        if let receiverError { return receiverError }
        if running { return status }
        return "启动后，在这台 iPhone 的 CarPlay 里选择本机"
    }

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                DashboardView(
                    identity: identity,
                    heroState: heroState,
                    heroDetail: heroDetail,
                    receiverError: receiverError,
                    running: running,
                    phoneConnected: phoneConnected,
                    hasVideo: hasVideo,
                    startedAt: startedAt,
                    videoLayer: decoder.layer,
                    pipReady: pipReady,
                    carLinkState: carLinkState,
                    carLinkRunning: carLinkRunning,
                    headUnitIP: headUnitIP,
                    bleScanning: bleProbe.scanning,
                    bleSummary: bleProbe.lastFoundSummary ?? "还没发现车机——在车里打开车机的 CarLink，再点开始探测",
                    bleFound: bleProbe.foundDeviceId != nil,
                    blePhaseText: bleProbe.flowPhaseText,
                    headUnitIPField: $headUnitIP,
                    localIPField: $localIP,
                    pairingCodeField: $pairingCode,
                    blePinField: $blePin,
                    onToggleReceiver: { running ? stop() : start() },
                    onPiP: {
                        if !pip.start() { appendLog("画中画不可用") }
                    },
                    onSelectSize: { setSize($0, $1) },
                    onConnectCarLink: { startCarLink() },
                    onDisconnectCarLink: { stopCarLink() },
                    onToggleBleProbe: { bleProbe.toggle() },
                    onConnectBle: { bleProbe.connectWithPin(blePin) },
                    onImportIdentity: { showingImporter = true },
                    onOpenSettings: { tab = 2 }
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
                    identity: identity,
                    selectedSize: targetSize,
                    onSelectSize: { setSize($0, $1) },
                    onImportIdentity: { showingImporter = true }
                )
                .navigationTitle("设置")
            }
            .tabItem { Label("设置", systemImage: "gearshape") }
            .tag(2)
        }
        .tint(.sunsetAccent)
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [.data, .item],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                do { appendLog(try identity.importFiles(urls)) }
                catch { appendLog("导入失败：\(error.localizedDescription)") }
            case .failure(let error):
                appendLog("导入失败：\(error.localizedDescription)")
            }
        }
        .onAppear {
            bleProbe.onLog = { appendLog($0) }
            bleProbe.onServerInfo = { handleUCarServerInfo($0) }
            if localIP.isEmpty { localIP = LocalNetwork.ipv4Addresses().first ?? "" }
            pipReady = pip.setup(layer: decoder.layer)
            autoDetectCarLink()
        }
    }

    private var clinkStateDirectory: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("OpenXPlay/clink", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    private func startCarLink() {
        if localIP.isEmpty {
            localIP = LocalNetwork.ipv4Addresses().first ?? ""
        }
        let core = CarLinkCore.shared
        core.onLog = { appendLog($0) }
        core.onState = { state in
            carLinkState = state
            carLinkRunning = (state != .idle && state != .ended)
            if state == .playing {
                UserDefaults.standard.set(headUnitIP, forKey: "oxp.lastHeadUnitIP")
                if !pairingCode.isEmpty {
                    UserDefaults.standard.set(pairingCode, forKey: "oxp.lastPin")
                }
                // UCar 流程：鉴权成功后经 BLE …103 回告本机地址（失败不影响判定）。
                bleProbe.writeClientAddress(localIP: localIP)
            }
        }
        core.onTouch = { screen, x, y, pressed in
            appendLog("车机触摸 \(screen) (\(String(format: "%.3f", x)), \(String(format: "%.3f", y))) \(pressed ? "按下" : "抬起")")
        }
        carLinkRunning = core.start(headUnit: headUnitIP, local: localIP,
                                    pin: pairingCode, stateDir: clinkStateDirectory,
                                    width: 1280, height: 720)
        appendLog(carLinkRunning ? "CarLink 已启动，等待车机画面" : "CarLink 启动失败")
    }

    /// 配对过的车机会在状态目录里留下 peer-*.key。
    private var hasPairedBefore: Bool {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: clinkStateDirectory)) ?? []
        return files.contains { $0.hasPrefix("peer-") && $0.hasSuffix(".key") }
    }

    /// 打开 App 时自动探车机：探到就填好地址；配对过的直接自动连上。
    private func autoDetectCarLink() {
        guard !didAutoDetect, !carLinkRunning else { return }
        didAutoDetect = true
        let lastUsed = UserDefaults.standard.string(forKey: "oxp.lastHeadUnitIP")
        let candidates = HeadUnitProbe.candidates(localIPs: LocalNetwork.ipv4Addresses(),
                                                  lastUsed: lastUsed)
        HeadUnitProbe.probeFirst(candidates: candidates) { found in
            guard let found, !carLinkRunning else { return }
            headUnitIP = found
            appendLog("已自动找到车机 \(found)")
            if hasPairedBefore {
                if pairingCode.isEmpty {
                    pairingCode = UserDefaults.standard.string(forKey: "oxp.lastPin") ?? ""
                }
                startCarLink()
            }
        }
    }

    /// UCar 阶段A：BLE 拿到 ServerInfo 后——先裸探一次 57209，再把地址和
    /// 刚输的配对码交给既有 CarLink 客户端走它自己的鉴权流程。
    private func handleUCarServerInfo(_ info: UCarServerInfo) {
        guard let ip = info.ipAddress, !ip.isEmpty else { return }
        if localIP.isEmpty {
            localIP = LocalNetwork.ipv4Addresses().first ?? ""
        }
        appendLog("UCar 连接：拿到车机地址 \(ip)（热点「\(info.ssid ?? "?")」），本机地址 \(localIP.isEmpty ? "未知" : localIP)，先裸连一次 \(ip):57209 探测")
        DispatchQueue.global(qos: .userInitiated).async {
            let probe = HeadUnitProbe.probeOnce(ip, port: HeadUnitProbe.carLinkAuthPort)
            DispatchQueue.main.async {
                if probe.ok {
                    appendLog("UCar 连接：裸 TCP 探测 \(ip):57209 —— 通（\(probe.detail)），车机的鉴权端口已经亮起来了")
                } else {
                    appendLog("UCar 连接：裸 TCP 探测 \(ip):57209 —— 不通（\(probe.detail)）。先确认手机连的是车机热点「\(info.ssid ?? "?")」；接着仍让 CarLink 客户端自己试一次，看它走到哪一步")
                }
                headUnitIP = ip
                pairingCode = blePin
                startCarLink()
            }
        }
    }

    private func stopCarLink() {
        CarLinkCore.shared.stop()
        carLinkRunning = false
        carLinkState = .idle
        appendLog("CarLink 已断开")
    }

    private func setSize(_ width: Int, _ height: Int) {
        targetSize = (width, height)
        appendLog("输出尺寸将使用 \(width)×\(height)")
    }

    private func start() {
        decoder.reset()
        phoneConnected = false
        hasVideo = false
        receiverError = nil
        core.onLog = { appendLog($0) }
        core.onState = { text in status = text }
        core.onVideoCodec = { kind, value in
            codec = value
            appendLog("视频流 \(kind) 编码 \(value == 2 ? "HEVC" : "H.264")")
        }
        core.onVideoConfig = { kind, data in
            phoneConnected = true
            decoder.configure(codec: codec, config: data)
            appendLog("解码配置 \(kind)：\(data.count) 字节")
        }
        core.onVideoFrame = { _, data, nanos in
            if !hasVideo { hasVideo = true }
            if !phoneConnected { phoneConnected = true }
            decoder.append(data, ptsNanos: nanos)
        }
        core.onAudioFormat = { data in
            audio.configure(formatJSON: data)
        }
        core.onAudioRtp = { data in
            audio.push(rtp: data)
        }

        let started = core.start(identityDirectory: identity.directory,
                                 deviceId: identity.deviceId,
                                 btMac: identity.deviceId,
                                 width: UInt32(targetSize.0),
                                 height: UInt32(targetSize.1),
                                 fps: 30,
                                 port: 7000)
        running = started
        if started {
            startedAt = Date()
            advertiser.start(deviceId: identity.deviceId, port: 7000)
            appendLog("接收端已启动，等待 iPhone 的 CarPlay 会话")
            UIApplication.shared.isIdleTimerDisabled = true
        } else {
            receiverError = core.lastError ?? "启动失败"
            Haptics.error()
            appendLog(core.lastError ?? "启动失败")
        }
    }

    private func stop() {
        core.stop()
        advertiser.stop()
        running = false
        phoneConnected = false
        hasVideo = false
        startedAt = nil
        status = "已停止"
    }

    private func appendLog(_ line: String) {
        if line.contains("device-info") && !phoneConnected {
            phoneConnected = true
            Haptics.success()
        }
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
