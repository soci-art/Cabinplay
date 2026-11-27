// SPDX-FileCopyrightText: 2026 CabinPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// BleProbe — 蓝牙探针 + UCar 连接前段（阶段A）。
// 依据 ICCOA/UCar 的 BLE 规格（对小米 CarWith 客户端的逆向，BLE-SPEC.md）：
// 车机先用 BLE 广播自报家门（服务数据 00000001/00000002），手机据此
// 识别车机并做 GATT 连接。本模块先做探针的事：扫描并解析广播、连上
// GATT、把服务/特征属性全部记进日志、订阅 …102 通知。
// 阶段A 在此基础上补上连接流程：用户输车机屏显的 6 位配对码后，把
// ClientInfo（明文 JSON）写到 …101，等车机经 …102 回 ServerInfo
// （热点信息 + 车机地址）；拿到地址后回调上层去探 57209 并启动既有
// CarLink 客户端；鉴权成功后经 …103 回告手机局域网地址。

import Foundation
import Combine
import CoreBluetooth
import UIKit

/// 车机经 …102 下发的 ServerInfo（字段见 BLE-SPEC §4.2）。
struct UCarServerInfo {
    var ssid: String?
    var psk: String?
    var mac: String?
    var freq: Int?
    var authentication: String?
    var ipAddress: String?
}

final class BleProbe: NSObject, ObservableObject {
    @Published private(set) var scanning = false
    /// 最近一次发现的车机摘要（车机名 · deviceId · 版本），给驾驶舱卡片用。
    @Published private(set) var lastFoundSummary: String?
    /// 发现的车机信息（输码连接的前置条件）。
    @Published private(set) var foundDeviceId: String?
    @Published private(set) var foundVersionCode: Int?
    /// 连接流程阶段（UI 显示用）。
    @Published private(set) var flowPhaseText = "未开始"

    var onLog: ((String) -> Void)?
    /// 收到 ServerInfo 后回调（主线程）。不要求带 ipAddress——组网与
    /// 车机地址推导在上层（UCarNetworkJoiner + ContentView）完成。
    var onServerInfo: ((UCarServerInfo) -> Void)?

    private var central: CBCentralManager?
    private var wantScanning = false
    /// 已记录过的广播（deviceId+序号）去重，避免同一条广播刷屏。
    private var seenAdv = Set<String>()
    /// 正在连接/已连接的车机（同一时间只探一台）。
    private var target: CBPeripheral?
    /// 最近发现的车机（连接按钮用；与 target 可能是同一台）。
    private var foundPeripheral: CBPeripheral?
    private var foundName: String?
    /// 每台设备上次发起连接的时间，避免连不上时反复猛连。
    private var lastConnectAttempt: [UUID: Date] = [:]

    // MARK: 连接流程状态

    private enum FlowPhase {
        case idle, found, connecting, writingClientInfo, waitingServerInfo, gotServerInfo, failed(String)
    }
    private var flowPhase: FlowPhase = .idle {
        didSet { flowPhaseText = Self.text(for: flowPhase) }
    }
    private static func text(for phase: FlowPhase) -> String {
        switch phase {
        case .idle: return "未开始"
        case .found: return "已发现车机，可输配对码连接"
        case .connecting: return "正在连车机蓝牙…"
        case .writingClientInfo: return "正在写 ClientInfo…"
        case .waitingServerInfo: return "已写 ClientInfo，等车机回 ServerInfo…"
        case .gotServerInfo: return "已拿到 ServerInfo，正在入网并走 TCP 鉴权"
        case .failed(let reason): return "连接流程失败：\(reason)"
        }
    }

    /// 连接流程是否正在跑（防重复触发）：凭据已就位且阶段在连接/写
    /// ClientInfo/等 ServerInfo/已拿到 ServerInfo 之一。失败（.failed）
    /// 不算在跑——允许用户改码重试；断线处理会把凭据清掉让重连走干净路径。
    private var flowInProgress: Bool {
        guard flowCredential != nil else { return false }
        switch flowPhase {
        case .connecting, .writingClientInfo, .waitingServerInfo, .gotServerInfo:
            return true
        case .idle, .found, .failed:
            return false
        }
    }

    /// 用户点「连接车机」时暂存的配对码；服务就绪后据此写 ClientInfo。
    private var pendingPin: String?
    /// 本轮写进 ClientInfo 的凭据：输码连接时就是配对码，免码重连时是已存令牌。
    private var flowCredential: String?
    /// 本轮是不是在用令牌免码连接。
    private var flowUsesToken = false
    /// 本轮走的是「已存配对免码」路径（凭据留空、鉴权靠本机信任记录）。
    /// 上层据此在失败时把输码框重新亮出来。
    private(set) var flowUsesPairedRecord = false
    /// ClientInfo 的 type 候选链（CarWith 口径）：车机版本码 ≥1002 时 [1002, 1001]，否则 [1001]。
    private var clientInfoTypes: [Int] = []
    /// 写 …101 失败后是否已按 CarWith 口径同值重写过一次（只重写一次）。
    private var clientInfoWriteRetried = false
    private var clientInfoTypeIndex = 0
    /// 本轮是否已完整走到 ServerInfo（断线自动重连的判定依据）。
    private var sessionEstablished = false
    /// 断线后已自动重连的次数（每轮手动连接清零，最多自动重连 1 次）。
    private var autoReconnectAttempts = 0
    /// 正在等自动重连的车机 deviceId（重新扫到它就自动用令牌连）。
    private var autoReconnectDeviceId: String?
    /// 当前发现的车机有没有已存的重连令牌（连接按钮免输码用）。
    @Published private(set) var hasStoredToken = false
    /// 当前发现的车机有没有本机存下的配对信任记录（核心 peer 密钥文件）。
    /// 车机从没给这台手机发过重连令牌（实测 ServerInfo 的 authentication
    /// 恒为「无」），免码与否以这份本机记录为准。
    @Published private(set) var hasPairedRecord = false
    private var clientInfoWritten = false
    private var serverInfoSubscribed = false
    /// 已调用 setNotifyValue(true) 请求 …102 通知。有的车机不回订阅确认回调，
    /// 写 ClientInfo 不能只等回调确认，这个标记也要算数。
    private var serverInfoNotifyRequested = false
    /// 点连接后数秒还没写出 ClientInfo 时打诊断日志的看门狗。
    private var writeWatchdog: DispatchWorkItem?
    /// 看门狗自动重连（每轮连接最多一次）：5 秒蓝牙还没连上时取消
    /// 当前尝试重连一次。取消会引来 didFailToConnect/didDisconnect
    /// 回调、把流程误判失败——shield 标记让那一次回调被吞掉。
    private var watchdogReconnectUsed = false
    private var watchdogReconnectShield = false
    private var charClientInfo: CBCharacteristic?
    private var charServerInfoRef: CBCharacteristic?
    private var charClientAddr: CBCharacteristic?
    private var serverInfoTimeout: DispatchWorkItem?
    /// 最近一次收到的 ServerInfo（…103 回告等后续步骤用）。
    private(set) var lastServerInfo: UCarServerInfo?

    private static let svcDataA = CBUUID(string: "00000001-0000-1000-8000-00805F9B34FB")
    private static let svcDataB = CBUUID(string: "00000002-0000-1000-8000-00805F9B34FB")
    private static let gattService = CBUUID(string: "2abcc850-9935-4f8a-ba84-123456789100")
    private static let charClientInfo = CBUUID(string: "2abcc850-9935-4f8a-ba84-123456789101")
    private static let charServerInfo = CBUUID(string: "2abcc850-9935-4f8a-ba84-123456789102")
    private static let charClientAddr = CBUUID(string: "2abcc850-9935-4f8a-ba84-123456789103")
    private static let charClientInfoAuth = CBUUID(string: "2abcc850-9935-4f8a-ba84-123456789104")
    private static let char201 = CBUUID(string: "2abcc850-9935-4f8a-ba84-123456789201")
    private static let char202 = CBUUID(string: "2abcc850-9935-4f8a-ba84-123456789202")
    /// 出现在广播服务列表里时，疑似另一类设备/盒子的标记（UCar 路径会排除它）。
    private static let otherStackMarker = CBUUID(string: "C62857AA-6CA1-4AC4-8842-3CA71AEF6765")

    func toggle() {
        scanning || wantScanning ? stop() : start()
    }

    func start() {
        wantScanning = true
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        }
        if let central, central.state == .poweredOn {
            beginScan()
        } else {
            log("蓝牙探针：正在等蓝牙可用…")
        }
    }

    func stop() {
        wantScanning = false
        sessionEstablished = false
        autoReconnectDeviceId = nil
        central?.stopScan()
        if let target {
            central?.cancelPeripheralConnection(target)
            self.target = nil
        }
        scanning = false
        resetFlow(clearFound: true)
        log("蓝牙探针：已停止")
    }

    private func resetFlow(clearFound: Bool) {
        serverInfoTimeout?.cancel()
        serverInfoTimeout = nil
        pendingPin = nil
        flowCredential = nil
        flowUsesToken = false
        clientInfoTypes = []
        clientInfoTypeIndex = 0
        clientInfoWriteRetried = false
        lastServerInfo = nil
        clientInfoWritten = false
        serverInfoSubscribed = false
        charClientInfo = nil
        charServerInfoRef = nil
        charClientAddr = nil
        if clearFound {
            foundPeripheral = nil
            foundName = nil
            foundDeviceId = nil
            foundVersionCode = nil
            flowPhase = .idle
        }
    }

    private func beginScan() {
        guard let central, central.state == .poweredOn, !scanning else { return }
        seenAdv.removeAll()
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        scanning = true
        log("蓝牙探针：开始扫描车机广播（找 ICCOA/UCar 车机）")
    }

    private func log(_ line: String) {
        onLog?(line)
    }

    // MARK: 广播解析（服务数据 A/B，布局见 BLE 规格 §1.2/§1.3）

    private struct AdvInfo {
        var name: String?
        var deviceId: String?
        var versionText: String?
        var versionCode: Int?
        var serialHex: String?
        var summaryKey: String
        /// 解析出的日志行，由调用方在「这条广播是新的一轮」时才真正写进日志，避免重复广播刷屏。
        var detailLines: [String] = []
    }

    private func parseAdvertisement(_ advertisementData: [String: Any]) -> AdvInfo? {
        let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data]
        let dataA = serviceData?[Self.svcDataA]
        let dataB = serviceData?[Self.svcDataB]
        let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let hasGattService = serviceUUIDs.contains(Self.gattService)

        guard dataA != nil || dataB != nil || hasGattService else { return nil }

        var info = AdvInfo(summaryKey: "")

        // 车机名：服务数据 B 前 16 字节 UTF-8（截断可能切坏多字节字符，宽容解码）。
        if let dataB, dataB.count >= 16 {
            let raw = String(decoding: dataB.prefix(16), as: UTF8.self)
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            if !name.isEmpty { info.name = name }
        } else if let dataB {
            info.detailLines.append("蓝牙探针：服务数据 B 只有 \(dataB.count) 字节（正常应 ≥16），原文 \(hex(dataB))")
        }

        if let dataA {
            if dataA.count >= 15 {
                let major = Int(dataA[0])
                let minor = Int(dataA[1])
                info.versionText = "\(major).\(minor)"
                info.versionCode = major * 1000 + minor
                info.serialHex = String(format: "%02X", dataA[2])
                info.deviceId = hex(dataA[3..<9])
                let seg1 = hex(dataA[9..<11])
                let seg2 = hex(dataA[11..<13])
                let custom = hex(dataA[13..<15])
                var extra = "未命名段 \(seg1)+\(seg2) custom \(custom)"
                if dataA.count >= 16 {
                    extra += " RSSI门槛 \(Int8(bitPattern: dataA[15]))"
                }
                if dataA.count >= 18 {
                    let directed = (Int(dataA[16]) << 8) | Int(dataA[17])
                    extra += directed == 0 ? " 定向目标 0（普通广播）" : " 定向目标 \(directed)（在喊某台已配对手机）"
                }
                info.summaryKey = (info.deviceId ?? "") + "-" + (info.serialHex ?? "")
                info.detailLines.append("蓝牙探针：发现车机广播 名称「\(info.name ?? "未知")」 deviceId \(info.deviceId ?? "?") 版本 \(info.versionText ?? "?")（码 \(info.versionCode ?? -1)） 序号 \(info.serialHex ?? "?") \(extra)")
            } else {
                info.summaryKey = "shortA-" + hex(dataA)
                info.detailLines.append("蓝牙探针：服务数据 A 只有 \(dataA.count) 字节（正常应 ≥15），原文 \(hex(dataA))")
            }
        }
        if serviceUUIDs.contains(Self.otherStackMarker) {
            info.detailLines.append("蓝牙探针：这条广播带 C62857AA 标记，疑似另一类设备/盒子，UCar 流程会排除它")
        }
        if hasGattService {
            info.detailLines.append("蓝牙探针：广播服务列表含 UCar GATT 服务 2abcc850-…-123456789100")
        }
        return info
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined()
    }

    private func tryConnect(_ peripheral: CBPeripheral) {
        guard target == nil else { return }
        if let last = lastConnectAttempt[peripheral.identifier],
           Date().timeIntervalSince(last) < 10 { return }
        lastConnectAttempt[peripheral.identifier] = Date()
        target = peripheral
        peripheral.delegate = self
        log("蓝牙探针：正在连这台车机的蓝牙（只读特征，不发数据）…")
        central?.connect(peripheral, options: nil)
    }

    private func describeProperties(_ properties: CBCharacteristicProperties) -> String {
        var parts: [String] = []
        if properties.contains(.broadcast) { parts.append("broadcast") }
        if properties.contains(.read) { parts.append("read") }
        if properties.contains(.writeWithoutResponse) { parts.append("writeWithoutResponse") }
        if properties.contains(.write) { parts.append("write") }
        if properties.contains(.notify) { parts.append("notify") }
        if properties.contains(.indicate) { parts.append("indicate") }
        if properties.contains(.authenticatedSignedWrites) { parts.append("authenticatedSignedWrites") }
        if properties.contains(.extendedProperties) { parts.append("extendedProperties") }
        if properties.contains(.notifyEncryptionRequired) { parts.append("notifyEncryptionRequired") }
        if properties.contains(.indicateEncryptionRequired) { parts.append("indicateEncryptionRequired") }
        return parts.isEmpty ? "无" : parts.joined(separator: "/")
    }

    private func charLabel(_ uuid: CBUUID) -> String {
        switch uuid {
        case Self.charClientInfo: return "ClientInfo（手机写）"
        case Self.charServerInfo: return "ServerInfo（车机通知）"
        case Self.charClientAddr: return "客户端地址（手机写）"
        case Self.charClientInfoAuth: return "ClientInfo_auth（用途未明）"
        case Self.char201, Self.char202: return "未命名特征（用途未明）"
        default: return ""
        }
    }

    // MARK: - 连接流程（阶段A）

    /// 连接按钮入口：输了 6 位码走输码连接；没输码但存有这台车机的令牌，走免码重连。
    func connect(pin: String) {
        let trimmed = pin.trimmingCharacters(in: .whitespaces)
        if trimmed.count == 6 {
            connectWithPin(trimmed)
        } else if hasStoredToken {
            connectWithToken()
        } else if hasPairedRecord {
            connectWithPairedRecord()
        } else if trimmed.isEmpty {
            log("UCar 连接：先输车机屏幕上的 6 位配对码再连（这台车机还没有配对过）")
        } else {
            log("UCar 连接：配对码要是 6 位，现在是 \(trimmed.count) 位，先输对再连")
        }
    }

    /// 用户在卡片上输好配对码点「连接车机」后调用。
    func connectWithPin(_ pin: String) {
        let trimmed = pin.trimmingCharacters(in: .whitespaces)
        guard trimmed.count == 6 else {
            log("UCar 连接：配对码要是 6 位，现在是 \(trimmed.count) 位，先输对再连")
            return
        }
        guard let peripheral = foundPeripheral ?? target else {
            log("UCar 连接：还没发现车机，先点「开始探测」，等卡片显示发现车机再连")
            return
        }
        pendingPin = trimmed
        flowCredential = trimmed
        flowUsesToken = false
        flowUsesPairedRecord = false
        autoReconnectAttempts = 0
        autoReconnectDeviceId = nil
        beginFlow(peripheral: peripheral, credentialDescription: "配对码 **\(trimmed.suffix(2))")
    }

    /// 用已存的 authentication 令牌免码重连（BLE-SPEC §4.4 的 type=2 路径：
    /// 令牌原样填进 pinCodeOrAuthentication，TCP 侧随之走 QUICK）。
    func connectWithToken() {
        guard let deviceId = foundDeviceId, let token = storedToken(for: deviceId) else {
            log("UCar 连接：这台车机没有存下的重连令牌，还是输配对码连一次")
            return
        }
        guard let peripheral = foundPeripheral ?? target else {
            log("UCar 连接：还没发现车机，先点「开始探测」，等卡片显示发现车机再连")
            return
        }
        pendingPin = nil
        flowCredential = token
        flowUsesToken = true
        flowUsesPairedRecord = false
        log("UCar 连接：用已存令牌免码重连（令牌共 \(token.count) 位，已打码）")
        beginFlow(peripheral: peripheral, credentialDescription: "已存令牌免码")
    }

    /// 用本机存下的配对信任记录免码连接：凭据留空，TCP 鉴权时核心读到
    /// 已存的 peer 密钥就走已配对通道、不问码。车机要是把手机忘了、临时
    /// 改口要码，这轮会失败，上层会把输码框重新亮出来让用户输一次。
    func connectWithPairedRecord() {
        guard let deviceId = foundDeviceId, pairedRecordExists(for: deviceId) else {
            log("UCar 连接：这台车机还没有配对记录，还是输配对码连一次")
            return
        }
        guard let peripheral = foundPeripheral ?? target else {
            log("UCar 连接：还没发现车机，先点「开始探测」，等卡片显示发现车机再连")
            return
        }
        pendingPin = nil
        flowCredential = ""
        flowUsesToken = false
        flowUsesPairedRecord = true
        log("UCar 连接：这台车机配对过，用已存配对免码连接")
        beginFlow(peripheral: peripheral, credentialDescription: "已存配对免码")
    }

    /// 这台车机有没有本机存下的配对信任记录：核心配对成功后把 peer 密钥
    /// 存进 CabinPlay/clink 状态目录（peer-<deviceId>.key），与核心鉴权时
    /// 读的是同一份。目录口径与 ContentView 的 clinkStateDirectory 一致。
    func pairedRecordExists(for deviceId: String) -> Bool {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let path = base.appendingPathComponent("CabinPlay/clink/peer-\(deviceId).key").path
        return FileManager.default.fileExists(atPath: path)
    }

    /// 已存的重连令牌（ServerInfo 的 authentication，按车机 deviceId 落盘）。
    func storedToken(for deviceId: String) -> String? {
        let token = UserDefaults.standard.string(forKey: "ucar.authToken.\(deviceId)")
        return (token?.isEmpty == false) ? token : nil
    }

    /// 凭据与 type 候选链就位后，真正跑连接流程（输码/令牌共用）。
    private func beginFlow(peripheral: CBPeripheral, credentialDescription: String) {
        // 防重复触发（13:50 实测教训）：入网等待期间用户又点了一次「连接
        // 车机」，beginFlow 重入把 clientInfoWritten/阶段全部重置，还对着
        // 已到手的 ServerInfo 反复试写 ClientInfo，日志刷出一串误导性的
        // 「条件未齐」。流程在跑时直接忽略，不重入、不重置状态机。
        if flowInProgress {
            log("UCar 连接：连接流程已在进行中（当前阶段：\(flowPhaseText)），忽略这次重复触发——不重入、不重置，等这一轮走完或失败再连")
            return
        }
        clientInfoWritten = false
        clientInfoWriteRetried = false
        watchdogReconnectUsed = false
        watchdogReconnectShield = false
        // type 候选链（CarWith y8/h.java M() 口径）：type 是手机声明的协议代际，
        // 只可能取 1002 或 1001——车机广播版本码 ≥1002 先发 1002，无响应回落 1001；
        // 版本码不到 1002 就只发 1001。绝不发广播码原值或 1003（取值域外，车机会整包丢弃）。
        clientInfoTypes = (foundVersionCode ?? 0) >= 1002 ? [1002, 1001] : [1001]
        let chain = clientInfoTypes
        clientInfoTypeIndex = 0
        flowPhase = .connecting
        log("UCar 连接：开始连接流程，车机 deviceId \(foundDeviceId ?? "?")，\(credentialDescription)；ClientInfo 的 type 候选链 \(chain.map { String($0) }.joined(separator: " → "))（CarWith 口径：只发 1002/1001，10 秒无响应往后换）")
        let readyNow = peripheral.state == .connected && charClientInfo != nil
            && (serverInfoSubscribed || serverInfoNotifyRequested)
        log("UCar 连接：点连接时状态——蓝牙 \(peripheral.state == .connected ? "已连" : "未连（state=\(peripheral.state.rawValue)）")，…101 特征 \(charClientInfo != nil ? "已发现" : "未发现")，…102 订阅 \(serverInfoSubscribed ? "已确认" : (serverInfoNotifyRequested ? "已请求未确认" : "未订阅"))；\(readyNow ? "条件已齐，立即写 ClientInfo" : "等蓝牙连上/特征发现/订阅就绪后写")")
        startWriteWatchdog()
        // 连接流程开始后停扫描省电，但 GATT 连接保持。
        central?.stopScan()
        scanning = false
        if peripheral.state == .connected {
            if charClientInfo != nil {
                maybeWriteClientInfo()
            } else {
                peripheral.discoverServices(nil)
            }
        } else {
            if target !== peripheral {
                target = peripheral
                peripheral.delegate = self
            }
            lastConnectAttempt[peripheral.identifier] = Date()
            log("UCar 连接：正在连车机蓝牙…")
            central?.connect(peripheral, options: nil)
        }
    }

    /// 点连接后启动：数秒内还没写出 ClientInfo，就打一行状态说明卡在哪一步，
    /// 并顺手再试一次写（防止某个回调丢了流程静默卡住）。若卡的这一步
    /// 是「蓝牙根本没连上」（1742 日志 B–E 轮：state 恒为 1、连接尝试
    /// 僵在半路），先取消当前尝试、自动重连一次（每轮最多一次），再
    /// 给一轮看门狗；重连后还不行就按原流程收尾。
    private func startWriteWatchdog() {
        writeWatchdog?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.flowCredential != nil, !self.clientInfoWritten else { return }
            if case .failed = self.flowPhase { return }
            if case .gotServerInfo = self.flowPhase { return }
            if !self.watchdogReconnectUsed,
               let peripheral = self.target ?? self.foundPeripheral,
               peripheral.state != .connected, let central = self.central {
                self.watchdogReconnectUsed = true
                self.watchdogReconnectShield = true
                self.log("UCar 连接：看门狗——点连接后 5 秒蓝牙还没连上（state=\(peripheral.state.rawValue)），取消当前连接尝试、自动重连一次")
                central.cancelPeripheralConnection(peripheral)
                self.target = peripheral
                peripheral.delegate = self
                self.lastConnectAttempt[peripheral.identifier] = Date()
                central.connect(peripheral, options: nil)
                self.startWriteWatchdog()
                return
            }
            let stateText: String
            if let t = self.target {
                stateText = "蓝牙 state=\(t.state.rawValue)"
            } else {
                stateText = "还没有目标车机（target 为空）"
            }
            self.log("UCar 连接：看门狗——点连接后 5 秒还没写出 ClientInfo。当前状态：\(stateText)，…101 特征 \(self.charClientInfo != nil ? "已发现" : "未发现")，…102 订阅 \(self.serverInfoSubscribed ? "已确认" : (self.serverInfoNotifyRequested ? "已请求未确认" : "未订阅"))，阶段 \(self.flowPhaseText)。再试一次写")
            self.maybeWriteClientInfo()
        }
        writeWatchdog = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: item)
    }

    /// 服务发现完成、…102 订阅就绪（已确认或已请求）且用户已输码时，写 ClientInfo。
    private func maybeWriteClientInfo() {
        guard let credential = flowCredential else { return }
        if clientInfoWritten { return }
        // ServerInfo 已到手：ClientInfo 这一环已经完成，不需要再写。
        // 13:50 的「条件未齐」就是从这儿来的：旧 guard 把 lastServerInfo
        // 混在总条件里，失败诊断又没覆盖这一项，只剩兜底的「条件未齐」，
        // 看着像条件没凑齐、其实是流程早已越过这一步。现在逐项自报。
        if lastServerInfo != nil {
            log("UCar 连接：ServerInfo 已经到手，ClientInfo 不用再写（这一步早已完成，不是条件没齐）")
            return
        }
        guard let char = charClientInfo else {
            log("UCar 连接：这次没写成 ClientInfo——…101（ClientInfo）特征还没发现，等后续回调再试")
            return
        }
        guard let peripheral = target else {
            log("UCar 连接：这次没写成 ClientInfo——没有目标车机（target 为空），等后续回调再试")
            return
        }
        guard peripheral.state == .connected else {
            log("UCar 连接：这次没写成 ClientInfo——蓝牙还没连上（state=\(peripheral.state.rawValue)），等后续回调再试")
            return
        }
        guard serverInfoSubscribed || serverInfoNotifyRequested else {
            log("UCar 连接：等 …102 订阅就绪后再写 ClientInfo")
            return
        }
        if !serverInfoSubscribed {
            log("UCar 连接：按「先写 ClientInfo、订阅请求紧随其后」的顺序写（不等 …102 订阅确认，避免 CCCD 确认把写入堵死）")
        }
        clientInfoWritten = true
        writeWatchdog?.cancel()
        writeWatchdog = nil
        flowPhase = .writingClientInfo

        let fields = buildClientInfo(credential: credential)
        let masked = fields.maskedJSON
        log("UCar 连接：准备写 ClientInfo 到 …101（PIN 已打码）：\(masked)")
        for note in fields.notes { log(note) }
        guard let data = fields.jsonData else {
            flowPhase = .failed("ClientInfo 拼 JSON 失败")
            log("UCar 连接：ClientInfo 序列化失败，写不出去")
            return
        }
        if data.count > peripheral.maximumWriteValueLength(for: .withResponse) {
            log("UCar 连接：注意 ClientInfo 有 \(data.count) 字节，超过单次可写长度 \(peripheral.maximumWriteValueLength(for: .withResponse))，写可能失败")
        }
        peripheral.writeValue(data, for: char, type: .withResponse)
        log("UCar 连接：…101 写请求已发出（withResponse），等写回执——回执到了才算真写到了车机")
        flowPhase = .waitingServerInfo
        startServerInfoTimeout()
    }

    private func startServerInfoTimeout() {
        serverInfoTimeout?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.flowCredential != nil else { return }
            if case .gotServerInfo = self.flowPhase { return }
            // type 回落链：当前 type 等了 10 秒没等到 ServerInfo，换下一个候选重写。
            // 每档只等 10 秒，是为了整条链赶在车机约 30 秒的会话看门狗清连接之前走完。
            if self.clientInfoTypeIndex + 1 < self.clientInfoTypes.count {
                self.clientInfoTypeIndex += 1
                let next = self.clientInfoTypes[self.clientInfoTypeIndex]
                self.log("UCar 连接：type=\(self.clientInfoTypes[self.clientInfoTypeIndex - 1]) 写完 10 秒没等到 ServerInfo，自动换 type=\(next) 重写 ClientInfo（候选 \(self.clientInfoTypeIndex + 1)/\(self.clientInfoTypes.count)）")
                self.clientInfoWritten = false
                self.flowPhase = .writingClientInfo
                self.maybeWriteClientInfo()
                return
            }
            self.flowPhase = .failed("等 ServerInfo 超时")
            self.log("UCar 连接：type 候选链 \(self.clientInfoTypes.map { String($0) }.joined(separator: "/")) 全部试完都没等到 …102 的 ServerInfo——可能配对码不对、车机没认，或车机要先在屏幕上确认。把车机屏幕情况和这份日志一起发回来看")
        }
        serverInfoTimeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: item)
    }

    /// 组装 ClientInfo（字段依据 BLE-SPEC §4.1）。credential 是配对码或已存令牌。
    private func buildClientInfo(credential: String) -> (jsonData: Data?, maskedJSON: String, notes: [String]) {
        var notes: [String] = []

        // id：本地持久化的 6 字符随机 ID。
        let phoneId = Self.persistentPhoneId()
        // name/model：机型市场名（如 iPhone 14 Pro Max）。
        let marketName = Self.deviceMarketName()
        // mac：iOS 取不到 Wi-Fi MAC，用本地生成并持久化的随机 MAC 替代。
        let (mac, macGenerated) = Self.persistentSubstituteMac()
        if macGenerated {
            notes.append("UCar 连接：iOS 取不到本机 Wi-Fi MAC，ClientInfo 的 mac 用本地生成的随机地址 \(mac) 代替（已存下，以后都用这个）")
        } else {
            notes.append("UCar 连接：ClientInfo 的 mac 用此前生成的替代地址 \(mac)（iOS 取不到真 MAC）")
        }
        // type：候选链当前值（CarWith 口径只发 1002/1001，见 beginFlow 的链构造）。
        let typeValue = clientInfoTypes.indices.contains(clientInfoTypeIndex)
            ? clientInfoTypes[clientInfoTypeIndex]
            : (((foundVersionCode ?? 0) >= 1002) ? 1002 : 1001)
        notes.append("UCar 连接：ClientInfo 的 type 填 \(typeValue)（候选链第 \(clientInfoTypeIndex + 1)/\(max(clientInfoTypes.count, 1)) 个；CarWith 口径只发 1002/1001——车机版本码 ≥1002 先 1002、无响应回落 1001）")
        if flowUsesToken {
            notes.append("UCar 连接：本轮用已存令牌免码连接，pinCodeOrAuthentication 填的是令牌（共 \(credential.count) 位）")
        }
        // manufactures：照安卓样本填 Xiaomi，最大化车机接受概率。
        notes.append("UCar 连接：ClientInfo 的 manufactures 照样本填 \"Xiaomi\"（不是真厂商名，是为了让车机按样本路径走）")
        // band：CarWith 口径——手机支持 5 GHz 即填 1（iPhone 全系支持）。
        let band = 1
        // channel：CarWith L() 按当前 Wi-Fi 频率换算信道；iOS 没有取当前 Wi-Fi
        // 频率/信道的公开接口，算不出时按 L() 的回落规则：band=1 → 36，band≠1 → 1。
        // L() 的取值域里没有 0，绝不填 0（非法值可能被车机整包丢弃）。
        let channel = band == 1 ? 36 : 1
        notes.append("UCar 连接：ClientInfo 的 channel 填 \(channel)（iOS 取不到当前 Wi-Fi 信道，按 CarWith L() 回落口径 band=1→36；绝不填 0）")

        // 键序照 CarWith K() 的插入顺序拼（id, name, model, pinCodeOrAuthentication,
        // band, mac, type, manufactures, channel）：标准 JSON 解析与键序无关，
        // 但车机固件的解析健壮性未经证实，照原样对齐、去掉这个变量。
        let data = Self.clientInfoJSON(id: phoneId, name: marketName, model: marketName,
                                       credential: credential, band: band, mac: mac,
                                       type: typeValue, channel: channel)
        let masked = Self.clientInfoJSON(id: phoneId, name: marketName, model: marketName,
                                         credential: "**" + String(credential.suffix(2)), band: band,
                                         mac: mac, type: typeValue, channel: channel)
            .flatMap { String(data: $0, encoding: .utf8) } ?? "(拼不出来)"
        return (data, masked, notes)
    }

    /// 按 CarWith K() 的插入顺序拼 ClientInfo JSON。
    private static func clientInfoJSON(id: String, name: String, model: String,
                                       credential: String, band: Int, mac: String,
                                       type: Int, channel: Int) -> Data? {
        let text = "{\"id\":\(jsonEscaped(id)),\"name\":\(jsonEscaped(name)),\"model\":\(jsonEscaped(model)),\"pinCodeOrAuthentication\":\(jsonEscaped(credential)),\"band\":\(band),\"mac\":\(jsonEscaped(mac)),\"type\":\(type),\"manufactures\":\"Xiaomi\",\"channel\":\(channel)}"
        return text.data(using: .utf8)
    }

    /// 单个字符串的 JSON 转义（借 JSONSerialization 处理引号与控制字符）。
    private static func jsonEscaped(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
              let text = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return text
    }

    /// 鉴权成功后经 …103 回告手机局域网地址（BLE-SPEC §4.3）。失败只记日志。
    func writeClientAddress(localIP: String) {
        // 没走过 BLE 连接流程（比如用的是老 CarLink 页直连）时静默跳过。
        guard flowCredential != nil || lastServerInfo != nil else { return }
        guard !localIP.isEmpty else {
            log("UCar 连接：拿不到本机局域网 IP，跳过写 …103 回告地址")
            return
        }
        guard let char = charClientAddr, let peripheral = target, peripheral.state == .connected else {
            log("UCar 连接：蓝牙连接不在或没找到 …103 特征，跳过回告地址（不影响主流程判定）")
            return
        }
        let dict: [String: Any] = ["ip": localIP, "port": ""]
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) else {
            log("UCar 连接：…103 回告地址拼 JSON 失败，跳过")
            return
        }
        log("UCar 连接：经 …103 回告本机地址 \(localIP)")
        peripheral.writeValue(data, for: char, type: .withResponse)
    }

    private func handleServerInfo(data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            log("UCar 连接：…102 发来的不是 JSON 对象，原文：\(text)")
            return
        }
        var info = UCarServerInfo()
        // ServerInfo 里带车名（如「长安UNI-V」）：蓝牙广播那边不一定报
        // 名字（实测有「未知」的轮次），这里再落一次盘，给「汽车」格
        // 选车标用（VehicleIcons）。
        if let carName = dict["name"] as? String, !carName.isEmpty {
            UserDefaults.standard.set(carName, forKey: "cabinplay.lastCarName")
        }
        info.ssid = dict["ssid"] as? String
        info.psk = dict["psk"] as? String
        info.mac = dict["mac"] as? String
        info.freq = (dict["freq"] as? NSNumber)?.intValue
        info.authentication = dict["authentication"] as? String
        info.ipAddress = dict["ipAddress"] as? String
        lastServerInfo = info

        serverInfoTimeout?.cancel()
        serverInfoTimeout = nil
        flowPhase = .gotServerInfo
        sessionEstablished = true

        log("UCar 连接：收到 ServerInfo——ssid「\(info.ssid ?? "?")」 psk \(info.psk.map { "共 \($0.count) 位（已打码）" } ?? "无") mac \(info.mac ?? "?") freq \(info.freq.map { String($0) } ?? "?") authentication \(info.authentication != nil ? "有（重连令牌，已存）" : "无") ipAddress \(info.ipAddress ?? "无")")
        if let auth = info.authentication, let deviceId = foundDeviceId {
            UserDefaults.standard.set(auth, forKey: "ucar.authToken.\(deviceId)")
            hasStoredToken = true
        }
        // 不再等 ipAddress：CarWith 实证安卓根本不用这个字段（只打日志），
        // 车机 IP 来自组网结果（组主地址）。本车 ServerInfo 就没这个字段，
        // 在这儿停住等于永远走不下去（13:24 实测卡死点）。拿到 ssid/psk
        // 就回调上层走组网步；ipAddress 有就带上，上层优先采用。
        if info.ipAddress?.isEmpty != false {
            log("UCar 连接：ServerInfo 没有 ipAddress（常态，安卓也不用它）——车机地址等入网后取组主地址，上层继续走组网")
        }
        if flowCredential != nil {
            onServerInfo?(info)
        } else {
            log("UCar 连接：这条 ServerInfo 不是本轮输码流程触发的，只记录不往下走")
        }
    }

    // MARK: 持久化小工具

    static func persistentPhoneId() -> String {
        let key = "ucar.phoneId"
        if let saved = UserDefaults.standard.string(forKey: key), saved.count == 6 {
            return saved
        }
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let generated = String((0..<6).map { _ in alphabet.randomElement()! })
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }

    private static func persistentSubstituteMac() -> (mac: String, generated: Bool) {
        let key = "ucar.substituteMac"
        if let saved = UserDefaults.standard.string(forKey: key), !saved.isEmpty {
            return (saved, false)
        }
        var bytes = (0..<6).map { _ in UInt8.random(in: 0...255) }
        bytes[0] = (bytes[0] & 0xFE) | 0x02 // 本地管理、单播
        let mac = bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
        UserDefaults.standard.set(mac, forKey: key)
        return (mac, true)
    }

    /// 机型市场名：取硬件标识（如 iPhone15,3）映射成市场名，未知就用标识本身。
    static func deviceMarketName() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let identifier = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        let names: [String: String] = [
            "iPhone13,2": "iPhone 12", "iPhone13,3": "iPhone 12 Pro",
            "iPhone13,4": "iPhone 12 Pro Max", "iPhone13,1": "iPhone 12 mini",
            "iPhone14,5": "iPhone 13", "iPhone14,4": "iPhone 13 mini",
            "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max",
            "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus",
            "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
            "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus",
            "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
            "iPhone16,3": "iPhone 16", "iPhone16,4": "iPhone 16 Plus",
            "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus",
            "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max",
            "iPhone17,5": "iPhone 16e",
            "iPhone18,1": "iPhone 17 Pro", "iPhone18,2": "iPhone 17 Pro Max",
            "iPhone18,3": "iPhone 17",
        ]
        return names[identifier] ?? identifier
    }
}

// MARK: - CBCentralManagerDelegate

extension BleProbe: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if wantScanning { beginScan() }
        case .poweredOff:
            scanning = false
            log("蓝牙探针：蓝牙没打开，请先打开蓝牙")
        case .unauthorized:
            scanning = false
            log("蓝牙探针：没有蓝牙权限，请在系统设置里允许 CabinPlay 用蓝牙")
        case .unsupported:
            scanning = false
            log("蓝牙探针：这台设备不支持蓝牙低功耗")
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard var info = parseAdvertisement(advertisementData) else { return }
        if info.summaryKey.isEmpty {
            info.summaryKey = "periph-" + peripheral.identifier.uuidString
        }
        let isNew = seenAdv.insert(info.summaryKey).inserted
        if isNew {
            for line in info.detailLines { log(line) }
            log("蓝牙探针：广播信号强度 RSSI \(RSSI.intValue)")
            if let deviceId = info.deviceId {
                lastFoundSummary = "\(info.name ?? "未知车机") · deviceId \(deviceId) · 版本 \(info.versionText ?? "?")"
                foundDeviceId = deviceId
                foundVersionCode = info.versionCode
                foundName = info.name
                // 车名落盘:本机 CarPlay 选「汽车」格图标时按这个名字认品牌
                // (VehicleIcons),不连车单独启动时就用上次这台车的名字。
                if let carName = info.name, !carName.isEmpty {
                    UserDefaults.standard.set(carName, forKey: "cabinplay.lastCarName")
                }
                foundPeripheral = peripheral
                hasStoredToken = storedToken(for: deviceId) != nil
                hasPairedRecord = pairedRecordExists(for: deviceId)
                if hasStoredToken {
                    log("蓝牙探针：这台车机存有重连令牌，可免输配对码直接点「连接车机」")
                } else if hasPairedRecord {
                    log("蓝牙探针：这台车机配对过（本机存有配对记录），可免输配对码直接点「连接车机」")
                }
                if flowCredential == nil, case .idle = flowPhase {
                    flowPhase = .found
                }
                // 断线自动重连：重新扫到同一台车机就用令牌自动连回去。
                if autoReconnectDeviceId == deviceId, flowCredential == nil {
                    autoReconnectDeviceId = nil
                    log("UCar 连接：自动重连——重新发现车机 \(deviceId)，用已存令牌免码连接")
                    connectWithToken()
                    return
                }
            }
        }
        // 连接流程进行中（已停扫描）时不再自动发起只读连接。
        if flowCredential == nil {
            tryConnect(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        // iOS 没有手动请求 MTU 的接口，系统自动协商；这里记下实际最大可写长度。
        let maxWrite = peripheral.maximumWriteValueLength(for: .withResponse)
        log("蓝牙探针：蓝牙已连上，系统协商的最大可写长度 \(maxWrite) 字节，开始读服务和特征")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        // 看门狗重连主动取消的那次尝试会引来这个回调：不是真失败，
        // 吞掉，别把正在重连的流程判死。
        if watchdogReconnectShield {
            watchdogReconnectShield = false
            log("UCar 连接：看门狗重连——旧尝试的取消回调已忽略，新连接尝试已在路上")
            return
        }
        log("蓝牙探针：蓝牙连接失败：\(error?.localizedDescription ?? "未知错误")")
        if flowCredential != nil {
            flowPhase = .failed("蓝牙连接失败")
        }
        if target === peripheral { target = nil }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        if watchdogReconnectShield {
            watchdogReconnectShield = false
            log("UCar 连接：看门狗重连——旧尝试的取消回调已忽略，新连接尝试已在路上")
            return
        }
        log("蓝牙探针：蓝牙已断开\(error.map { "：\($0.localizedDescription)" } ?? "")")
        if target === peripheral { target = nil }
        if flowCredential != nil {
            switch flowPhase {
            case .gotServerInfo:
                log("UCar 连接：蓝牙在拿到 ServerInfo 后断开（主流程已往下走，TCP 那边继续看）")
                // 完整会话已建立过又断开：用令牌自动重连一次（重新扫到车机时触发）。
                if sessionEstablished, autoReconnectAttempts < 1,
                   let deviceId = foundDeviceId, storedToken(for: deviceId) != nil {
                    autoReconnectAttempts += 1
                    autoReconnectDeviceId = deviceId
                    flowCredential = nil
                    flowUsesToken = false
                    pendingPin = nil
                    log("UCar 连接：已安排自动重连（第 \(autoReconnectAttempts) 次）——重新开始扫描，扫到车机 \(deviceId) 就用令牌免码连回")
                    start()
                } else {
                    // 没安排自动重连（本车 ServerInfo 不带令牌，是常态）：
                    // 把流程复位到可重试状态，下次点「连接车机」走干净的
                    // 新一轮；否则阶段停在 gotServerInfo、防重入守卫会把
                    // 之后每次点按都当重复触发忽略掉。已到手的 ServerInfo
                    // 与上层入网流程不受影响（lastServerInfo 保留）。
                    flowCredential = nil
                    flowUsesToken = false
                    pendingPin = nil
                    flowPhase = .found
                    log("UCar 连接：本轮蓝牙流程就此收尾（无令牌可自动重连）——再点「连接车机」会重新走一轮新的；上层入网/CarLink 不受影响")
                }
            case .failed:
                break
            default:
                serverInfoTimeout?.cancel()
                serverInfoTimeout = nil
                flowPhase = .failed("蓝牙中途断开")
                log("UCar 连接：蓝牙在流程中途断开了——车机可能在等 ClientInfo 超时或主动清会话，重新点「开始探测」再连一次")
            }
        }
        charClientInfo = nil
        charServerInfoRef = nil
        charClientAddr = nil
        serverInfoSubscribed = false
        serverInfoNotifyRequested = false
        writeWatchdog?.cancel()
        writeWatchdog = nil
        clientInfoWritten = false
        clientInfoWriteRetried = false
    }
}

// MARK: - CBPeripheralDelegate

extension BleProbe: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            log("蓝牙探针：读服务失败：\(error.localizedDescription)")
            return
        }
        for service in peripheral.services ?? [] {
            let label = service.uuid == Self.gattService ? "（UCar 服务）" : ""
            log("蓝牙探针：服务 \(service.uuid.uuidString)\(label)")
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let error {
            log("蓝牙探针：读特征失败（服务 \(service.uuid.uuidString)）：\(error.localizedDescription)")
            return
        }
        var pendingNotifyChar: CBCharacteristic?
        for char in service.characteristics ?? [] {
            let label = charLabel(char.uuid)
            log("蓝牙探针：特征 \(char.uuid.uuidString) 属性 \(describeProperties(char.properties))\(label.isEmpty ? "" : " — \(label)")")
            switch char.uuid {
            case Self.charClientInfo: charClientInfo = char
            case Self.charServerInfo: charServerInfoRef = char
            case Self.charClientAddr: charClientAddr = char
            default: break
            }
            if char.uuid == Self.charServerInfo {
                if char.properties.contains(.notify) {
                    // 先只登记「待订阅」，setNotifyValue 押后到 ClientInfo 写出之后再发：
                    // iOS 的 setNotifyValue 是一次真实的 CCCD 写、要等车机确认，CoreBluetooth
                    // 对同一外设又是串行排队——先发订阅会把后面的 ClientInfo 写堵在队列里
                    // （13:08 实测：写回执与订阅确认双双缺席，车机 30 秒清连接）。
                    // CarWith 在安卓上订阅只是本地开关、写紧随其后；iOS 上靠
                    // 「写在前、订阅紧随其后」对齐同一时序。
                    serverInfoNotifyRequested = true
                    pendingNotifyChar = char
                } else {
                    log("蓝牙探针：…102 没有 notify 属性，订不了通知")
                }
            }
        }
        // 用户已输码在等连接时，特征一发现齐就先写 ClientInfo（写排在订阅前面），
        // 不依赖订阅确认回调（本车机从不回那个回调，等它会静默卡住）。
        if flowCredential != nil {
            maybeWriteClientInfo()
        }
        if let pendingNotifyChar {
            peripheral.setNotifyValue(true, for: pendingNotifyChar)
            log("蓝牙探针：已发出 …102 订阅请求（排在 ClientInfo 写入之后发出），等车机发 ServerInfo")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            log("蓝牙探针：订阅通知失败（\(characteristic.uuid.uuidString)）：\(error.localizedDescription)")
            if flowCredential != nil, characteristic.uuid == Self.charServerInfo {
                log("UCar 连接：流程进行中 …102 订阅回调报错，订阅没确认；已请求过通知的话写 ClientInfo 不等这个确认")
                maybeWriteClientInfo()
            }
        } else {
            log("蓝牙探针：通知状态 \(characteristic.uuid.uuidString) 现在是 \(characteristic.isNotifying ? "已开启" : "已关闭")")
            if characteristic.uuid == Self.charServerInfo {
                serverInfoSubscribed = characteristic.isNotifying
                if flowCredential != nil {
                    log("UCar 连接：流程进行中收到 …102 订阅回调，isNotifying=\(characteristic.isNotifying)，据此试着写 ClientInfo")
                }
                if characteristic.isNotifying {
                    maybeWriteClientInfo()
                }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        switch characteristic.uuid {
        case Self.charClientInfo:
            if let error {
                if !clientInfoWriteRetried {
                    // CarWith 口径：写回调失败时同值重写一次，再失败才判死。
                    clientInfoWriteRetried = true
                    clientInfoWritten = false
                    log("UCar 连接：写 …101（ClientInfo）失败：\(error.localizedDescription)；按 CarWith 口径同值重写一次")
                    maybeWriteClientInfo()
                } else {
                    flowPhase = .failed("写 ClientInfo 失败")
                    log("UCar 连接：写 …101（ClientInfo）重写仍失败：\(error.localizedDescription)")
                }
            } else {
                log("UCar 连接：ClientInfo 已写入 …101（写回执已回，车机确认收到），等车机回 ServerInfo（最长等 10 秒）")
            }
        case Self.charClientAddr:
            if let error {
                log("UCar 连接：写 …103 回告地址失败（不影响主流程）：\(error.localizedDescription)")
            } else {
                log("UCar 连接：…103 回告地址写入成功，BLE 阶段收尾完成")
            }
        default:
            if let error {
                log("蓝牙探针：写 \(characteristic.uuid.uuidString) 失败：\(error.localizedDescription)")
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            log("蓝牙探针：收到数据但读错（\(characteristic.uuid.uuidString)）：\(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value else { return }
        let text = String(decoding: data, as: UTF8.self)
        if characteristic.uuid == Self.charServerInfo,
           let object = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let prettyText = String(data: pretty, encoding: .utf8) {
            log("蓝牙探针：收到 …102 通知（JSON，\(data.count) 字节）：\(prettyText)")
        } else {
            log("蓝牙探针：收到 \(characteristic.uuid.uuidString) 数据 \(data.count) 字节：\(text)")
        }
        if data.count <= 512 {
            log("蓝牙探针：数据原文（十六进制）：\(hex(data))")
        }
        if characteristic.uuid == Self.charServerInfo {
            handleServerInfo(data: data)
        }
    }
}
