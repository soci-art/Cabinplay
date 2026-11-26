// SPDX-FileCopyrightText: 2026 OpenXPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// BleProbe — 蓝牙探针（只探测，不走正式连接流程）。
// 依据 ICCOA/UCar 的 BLE 规格（对小米 CarWith 客户端的逆向）：
// 车机先用 BLE 广播自报家门（服务数据 00000001/00000002），手机据此
// 识别车机，再做 GATT 连接。本模块只做到：扫描并解析广播、连上
// GATT、把服务/特征属性全部记进日志、订阅 …102 通知并记录数据。
// 本轮不写 …101（不发 ClientInfo、不走 PIN、不触发组网）。

import Foundation
import Combine
import CoreBluetooth

final class BleProbe: NSObject, ObservableObject {
    @Published private(set) var scanning = false
    /// 最近一次发现的车机摘要（车机名 · deviceId · 版本），给驾驶舱卡片用。
    @Published private(set) var lastFoundSummary: String?

    var onLog: ((String) -> Void)?

    private var central: CBCentralManager?
    private var wantScanning = false
    /// 已记录过的广播（deviceId+序号）去重，避免同一条广播刷屏。
    private var seenAdv = Set<String>()
    /// 正在连接/已连接的车机（同一时间只探一台）。
    private var target: CBPeripheral?
    /// 每台设备上次发起连接的时间，避免连不上时反复猛连。
    private var lastConnectAttempt: [UUID: Date] = [:]

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
        central?.stopScan()
        if let target {
            central?.cancelPeripheralConnection(target)
            self.target = nil
        }
        scanning = false
        log("蓝牙探针：已停止")
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
        case Self.charClientInfo: return "ClientInfo（手机写，本轮不写）"
        case Self.charServerInfo: return "ServerInfo（车机通知）"
        case Self.charClientAddr: return "客户端地址（手机写，本轮不写）"
        case Self.charClientInfoAuth: return "ClientInfo_auth（用途未明）"
        case Self.char201, Self.char202: return "未命名特征（用途未明）"
        default: return ""
        }
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
            }
        }
        tryConnect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        // iOS 没有手动请求 MTU 的接口，系统自动协商；这里记下实际最大可写长度。
        let maxWrite = peripheral.maximumWriteValueLength(for: .withResponse)
        log("蓝牙探针：蓝牙已连上，系统协商的最大可写长度 \(maxWrite) 字节，开始读服务和特征")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        log("蓝牙探针：蓝牙连接失败：\(error?.localizedDescription ?? "未知错误")")
        if target === peripheral { target = nil }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        log("蓝牙探针：蓝牙已断开\(error.map { "：\($0.localizedDescription)" } ?? "")")
        if target === peripheral { target = nil }
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
        for char in service.characteristics ?? [] {
            let label = charLabel(char.uuid)
            log("蓝牙探针：特征 \(char.uuid.uuidString) 属性 \(describeProperties(char.properties))\(label.isEmpty ? "" : " — \(label)")")
            if char.uuid == Self.charServerInfo {
                if char.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: char)
                    log("蓝牙探针：已订阅 …102 通知，等车机发 ServerInfo")
                } else {
                    log("蓝牙探针：…102 没有 notify 属性，订不了通知")
                }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            log("蓝牙探针：订阅通知失败（\(characteristic.uuid.uuidString)）：\(error.localizedDescription)")
        } else {
            log("蓝牙探针：通知状态 \(characteristic.uuid.uuidString) 现在是 \(characteristic.isNotifying ? "已开启" : "已关闭")")
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
    }
}
