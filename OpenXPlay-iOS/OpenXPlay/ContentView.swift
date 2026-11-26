// SPDX-FileCopyrightText: 2026 OpenXPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// The app shell: import the MFi identity, start the receiver, show the
// decoded CarPlay surface and the protocol log.

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
    @State private var carLinkState = CarLinkCore.State.idle
    @State private var carLinkRunning = false
    @State private var audio = AudioPipeline()
    @State private var pip = PictureInPicture()
    @State private var pipReady = false

    private var core: CarPlayCore { .shared }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                VideoSurface(layer: decoder.layer)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                HStack {
                    Label(identity.hasIdentity ? "身份已就绪" : "缺少 MFi 身份",
                          systemImage: identity.hasIdentity ? "checkmark.seal.fill" : "exclamationmark.triangle")
                        .foregroundStyle(identity.hasIdentity ? .green : .orange)
                    Spacer()
                    Text(identity.deviceId).font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                }

                Button {
                    showingImporter = true
                } label: {
                    Label("导入 identity.pk8 和 certificate.p7b", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    running ? stop() : start()
                } label: {
                    Label(running ? "停止接收端" : "启动接收端",
                          systemImage: running ? "stop.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!identity.hasIdentity)

                Text(status).font(.footnote).foregroundStyle(.secondary)

                GroupBox("车机 CarLink 输出") {
                    VStack(spacing: 8) {
                        TextField("车机 IP（Carlink 网络里的地址）", text: $headUnitIP)
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.numbersAndPunctuation)
                        TextField("本机 IP（iPhone 在该网络的地址）", text: $localIP)
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.numbersAndPunctuation)
                        TextField("车机屏幕上的配对码", text: $pairingCode)
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.numberPad)
                        HStack {
                            Button(carLinkRunning ? "断开 CarLink" : "连接车机 CarLink") {
                                if carLinkRunning {
                                    stopCarLink()
                                } else {
                                    startCarLink()
                                }
                            }
                            .buttonStyle(.bordered)
                            Spacer()
                            Text(carLinkState.text).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                List(log.suffix(200), id: \.self) { line in
                    Text(line).font(.caption.monospaced())
                }
                .listStyle(.plain)
            }
            .padding()
            .navigationTitle("OpenXPlay 直连")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        if !pip.start() { appendLog("画中画不可用") }
                    } label: {
                        Image(systemName: "pip.enter")
                    }
                    .disabled(!pipReady)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("1280×720") { setSize(1280, 720) }
                        Button("1920×1080") { setSize(1920, 1080) }
                        Button("854×480") { setSize(854, 480) }
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                }
            }
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
                if localIP.isEmpty { localIP = LocalNetwork.ipv4Addresses().first ?? "" }
                pipReady = pip.setup(layer: decoder.layer)
            }
        }
    }

    @State private var targetSize: (Int, Int) = (1280, 720)

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
        }
        core.onTouch = { screen, x, y, pressed in
            appendLog("车机触摸 \(screen) (\(String(format: "%.3f", x)), \(String(format: "%.3f", y))) \(pressed ? "按下" : "抬起")")
        }
        carLinkRunning = core.start(headUnit: headUnitIP, local: localIP,
                                    pin: pairingCode, stateDir: clinkStateDirectory,
                                    width: 1280, height: 720)
        appendLog(carLinkRunning ? "CarLink 已启动，等待车机画面" : "CarLink 启动失败")
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
        core.onLog = { appendLog($0) }
        core.onState = { text in status = text }
        core.onVideoCodec = { kind, value in
            codec = value
            appendLog("视频流 \(kind) 编码 \(value == 2 ? "HEVC" : "H.264")")
        }
        core.onVideoConfig = { kind, data in
            decoder.configure(codec: codec, config: data)
            appendLog("解码配置 \(kind)：\(data.count) 字节")
        }
        core.onVideoFrame = { _, data, nanos in
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
            advertiser.start(deviceId: identity.deviceId, port: 7000)
            appendLog("接收端已启动，等待 iPhone 的 CarPlay 会话")
            UIApplication.shared.isIdleTimerDisabled = true
        } else {
            appendLog(core.lastError ?? "启动失败")
        }
    }

    private func stop() {
        core.stop()
        advertiser.stop()
        running = false
        status = "已停止"
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
