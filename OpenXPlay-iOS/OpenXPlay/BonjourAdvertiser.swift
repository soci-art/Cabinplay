// SPDX-FileCopyrightText: 2026 OpenXPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// BonjourAdvertiser — publishes the receiver as an AirPlay accessory, the way
// the relay's linux_bonjour module does, so the iPhone's CarPlay stack can find
// it on the Wi-Fi the phone has joined.
//
// TXT records follow what Apple accessories publish. `features` advertises
// CarPlay-capable display/audio streams; `deviceid` must be the accessory MAC
// derived from the MFi certificate.

import Foundation

final class BonjourAdvertiser: NSObject, NetServiceDelegate {
    private var service: NetService?

    func start(deviceId: String, port: Int32, model: String = "CabinPlay") {
        stop()
        let txt: [String: Data] = [
            "deviceid": Data(deviceId.utf8),
            "features": Data("0x5A7FFFF7,0x1E".utf8),
            "model": Data(model.utf8),
            "srcvers": Data("950.7.1".utf8),
            "vv": Data("2".utf8),
            "flags": Data("0x4".utf8),
            "pk": Data("0".utf8),
            "pi": Data("b0e9f7d1-3d7a-4d3e-9a44-92c1e2b6c001".utf8),
            "manufacturer": Data("CabinPlay".utf8),
        ]
        let service = NetService(domain: "", type: "_airplay._tcp.", name: model, port: port)
        service.delegate = self
        service.setTXTRecord(NetService.data(fromTXTRecord: txt))
        service.publish()
        self.service = service
    }

    func stop() {
        service?.stop()
        service = nil
    }

    func netServiceDidPublish(_ sender: NetService) {
        CarPlayCore.shared.onLog?("Bonjour: 已广播 \(sender.name) :\(sender.port)")
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        CarPlayCore.shared.onLog?("Bonjour 广播失败: \(errorDict)")
    }
}
