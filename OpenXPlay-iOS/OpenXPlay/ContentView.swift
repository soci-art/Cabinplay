// SPDX-FileCopyrightText: 2026 OpenXPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// The app shell: three tabs （驾驶舱 / 日志 / 设置）.
// 主线：本机 CarPlay 会话（LocalCarPlaySession）出帧 → 蓝牙 UCar 配对 →
// CarLink（clink）把帧送上车机、把车机触摸/按键回送本机会话。

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
    @StateObject private var bleProbe = BleProbe()
    @StateObject private var localSession = LocalCarPlaySession()
    @State private var decoder = VideoDecoder()
    @State private var log: [String] = []
    @State private var tab = 0
    @State private var hasVideo = false
    @State private var headUnitIP = "192.168.49.1"
    @State private var localIP = ""
    @State private var pairingCode = ""
    @State private var blePin = ""
    @State private var wifiSSID = LocalCarPlaySession.savedSSID
    @State private var wifiPassword = LocalCarPlaySession.savedPassword
    @State private var carLinkState = CarLinkCore.State.idle
    @State private var carLinkRunning = false
    @State private var targetSize: (Int, Int) = (1280, 720)
    @State private var didAutoDetect = false

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                DashboardView(
                    localPhaseText: localSession.phase.text,
                    localPhaseFailed: localSession.phase.isFailed,
                    localRunning: localSession.isRunning,
                    localStreaming: localSession.phase == .streaming,
                    hasVideo: hasVideo,
                    videoLayer: decoder.layer,
                    carLinkState: carLinkState,
                    carLinkRunning: carLinkRunning,
                    headUnitIP: headUnitIP,
                    bleScanning: bleProbe.scanning,
                    bleSummary: bleProbe.lastFoundSummary ?? "还没发现车机——在车里打开车机的 CarLink，再点开始探测",
                    bleFound: bleProbe.foundDeviceId != nil,
                    bleHasToken: bleProbe.hasStoredToken,
                    blePhaseText: bleStageText,
                    headUnitIPField: $headUnitIP,
                    localIPField: $localIP,
                    pairingCodeField: $pairingCode,
                    blePinField: $blePin,
                    wifiSSIDField: $wifiSSID,
                    wifiPasswordField: $wifiPassword,
                    onToggleLocalSession: { localSession.isRunning ? stopLocalSession() : startLocalSession() },
                    onSelectSize: { setSize($0, $1) },
                    onConnectCarLink: { startCarLink() },
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
            localSession.onPreviewFrame = { data, _ in
                if !hasVideo { hasVideo = true }
                decoder.append(data, ptsNanos: UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000))
            }
            if localIP.isEmpty { localIP = LocalNetwork.ipv4Addresses().first ?? "" }
            autoDetectCarLink()
        }
        .onChange(of: wifiSSID) { _, newValue in
            LocalCarPlaySession.savedSSID = newValue
        }
        .onChange(of: wifiPassword) { _, newValue in
            LocalCarPlaySession.savedPassword = newValue
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

    // MARK: CarLink（clink）

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
            // 帧桥：进入出画才推帧（补配置+请求关键帧），离开即停推。
            localSession.carLinkPlayingChanged(state == .playing)
        }
        core.onTouch = { _, x, y, pressed in
            localSession.touchesFromCarLink(pressed: pressed, x: x, y: y)
        }
        core.onKey = { code, down in
            localSession.keyFromCarLink(code: code, down: down)
        }
        carLinkRunning = core.start(headUnit: headUnitIP, local: localIP,
                                    pin: pairingCode, stateDir: clinkStateDirectory,
                                    width: UInt32(targetSize.0), height: UInt32(targetSize.1),
                                    deviceID: BleProbe.persistentPhoneId(),
                                    model: BleProbe.deviceMarketName())
        appendLog(carLinkRunning ? "CarLink 已启动，等待车机画面" : "CarLink 启动失败")
    }

    private func stopCarLink() {
        CarLinkCore.shared.stop()
        carLinkRunning = false
        carLinkState = .idle
        localSession.carLinkPlayingChanged(false)
        appendLog("CarLink 已断开")
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

    /// UCar：BLE 拿到 ServerInfo 后——存下车机热点凭据（本机 CarPlay 用），
    /// 裸探一次 57209，再把地址和配对码交给 CarLink 客户端走鉴权流程。
    private func handleUCarServerInfo(_ info: UCarServerInfo) {
        guard let ip = info.ipAddress, !ip.isEmpty else { return }
        if localIP.isEmpty {
            localIP = LocalNetwork.ipv4Addresses().first ?? ""
        }
        if let ssid = info.ssid, !ssid.isEmpty {
            wifiSSID = ssid
            LocalCarPlaySession.savedSSID = ssid
            if let psk = info.psk {
                wifiPassword = psk
                LocalCarPlaySession.savedPassword = psk
            }
            appendLog("UCar 连接：车机热点「\(ssid)」的凭据已存下，本机 CarPlay 启动时用它告诉系统走哪个网络")
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
                if blePin.isEmpty {
                    appendLog("UCar 连接：本轮是令牌免码连接，TCP 鉴权走已存配对（QUICK）；要是车机不认，会报需要配对码，到时输码再连一次")
                }
                startCarLink()
            }
        }
    }

    private func appendLog(_ line: String) {
        let stamp = DateFormatter.logFormatter.string(from: Date())
        log.append("[\(stamp)] \(line)")
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }
}
