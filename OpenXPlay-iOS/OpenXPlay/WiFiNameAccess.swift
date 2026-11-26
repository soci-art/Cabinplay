// SPDX-FileCopyrightText: 2026 OpenXPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// WiFiNameAccess — 读「当前 Wi-Fi 叫什么名字」要过的系统关卡。
//
// iOS 把当前 SSID 锁在定位授权后面：没有 When In Use 授权时，
// CNCopyCurrentNetworkInfo 与 NEHotspotNetwork.fetchCurrent 都只回
// 空（2026-11-26 真机实证：用户在家单独点启动 CarPlay，状态栏
// Wi-Fi 明明连着，SSID 来源链第 2 步却读不到名字、其余来源又都为
// 空，最终按设计拒启）。CarWithin 原版同样是靠定位授权后
// fetchCurrent 读名。本类只做两件事：查/要定位授权、拿到授权后
// fetchCurrent 读名。权限只用来读 Wi-Fi 名，不取位置、不记录、
// 不上传。

import Foundation
import CoreLocation
import NetworkExtension

final class WiFiNameAccess: NSObject, CLLocationManagerDelegate {
    static let shared = WiFiNameAccess()

    private let manager = CLLocationManager()
    private var pendingCompletions: [((CLAuthorizationStatus) -> Void)] = []

    private override init() {
        super.init()
        manager.delegate = self
    }

    static var authorizationStatus: CLAuthorizationStatus {
        CLLocationManager().authorizationStatus
    }

    /// 授权状态的大白话（设置页展示用）。
    static var authorizationStatusText: String {
        switch authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            return "已允许（能自动读 Wi-Fi 名）"
        case .notDetermined:
            return "还没问过（启动 CarPlay 时会弹框问）"
        case .denied:
            return "被拒绝（读不到 Wi-Fi 名）"
        case .restricted:
            return "被系统限制（读不到 Wi-Fi 名）"
        @unknown default:
            return "未知状态"
        }
    }

    /// 请求 When In Use 授权（仅状态为未决定时调用才会弹系统框）。
    /// 结果经 delegate 回到主线程回调。
    func requestAuthorization(completion: @escaping (CLAuthorizationStatus) -> Void) {
        DispatchQueue.main.async {
            let status = self.manager.authorizationStatus
            guard status == .notDetermined else {
                completion(status)
                return
            }
            self.pendingCompletions.append(completion)
            self.manager.requestWhenInUseAuthorization()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        // 设 delegate 时系统会先回一次当前状态；未决定不算结果，继续等。
        guard status != .notDetermined, !pendingCompletions.isEmpty else { return }
        let completions = pendingCompletions
        pendingCompletions.removeAll()
        for completion in completions { completion(status) }
    }

    /// 拿到授权后读当前 Wi-Fi 名。读不到回调 nil。主线程回调。
    static func fetchCurrentSSID(completion: @escaping (String?) -> Void) {
        NEHotspotNetwork.fetchCurrent { network in
            let ssid = network?.ssid
            DispatchQueue.main.async {
                completion((ssid?.isEmpty == false) ? ssid : nil)
            }
        }
    }
}
