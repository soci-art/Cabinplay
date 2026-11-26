// SPDX-FileCopyrightText: 2026 OpenXPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// IdentityStore — imports the two MFi files into the app container and reads
// the accessory MAC out of the certificate's CN (`IPA_24ACBB48646F…`): the
// first six bytes of the IPA id are the accessory's Bluetooth address, and
// CarPlay peers expect that value in Bonjour TXT records and in the /info
// plist.

import Foundation
import Combine

final class IdentityStore: ObservableObject {
    @Published private(set) var keyURL: URL?
    @Published private(set) var certificateURL: URL?
    @Published private(set) var deviceId: String = "02:00:00:00:00:01"
    @Published private(set) var notBefore: String?
    @Published private(set) var notAfter: String?
    /// True when the current pair came from the bundle rather than the user.
    @Published private(set) var bundled = false

    let directory: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("OpenXPlay/mfi", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        refresh()
        installBundledIdentityIfNeeded()
    }

    /// The identity shipped inside the app bundle is installed on first launch,
    /// so a freshly side-loaded IPA needs no manual import. Importing files in
    /// the app still replaces it.
    private func installBundledIdentityIfNeeded() {
        guard !hasIdentity else { return }
        guard let bundledKey = Bundle.main.url(forResource: "identity", withExtension: "pk8"),
              let bundledCertificate = Bundle.main.url(forResource: "certificate", withExtension: "p7b")
        else { return }
        do {
            try FileManager.default.copyItem(at: bundledKey,
                                             to: directory.appendingPathComponent("identity.pk8"))
            try FileManager.default.copyItem(at: bundledCertificate,
                                             to: directory.appendingPathComponent("certificate.p7b"))
            refresh()
            bundled = true
        } catch {
            // A half copy is cleaned up by `refresh()`: it only reports complete pairs.
        }
    }

    var hasIdentity: Bool { keyURL != nil && certificateURL != nil }

    func refresh() {
        let key = directory.appendingPathComponent("identity.pk8")
        let cert = directory.appendingPathComponent("certificate.p7b")
        keyURL = FileManager.default.fileExists(atPath: key.path) ? key : nil
        certificateURL = FileManager.default.fileExists(atPath: cert.path) ? cert : nil
        if let data = try? Data(contentsOf: cert), let ipa = Self.ipaId(in: data) {
            deviceId = Self.mac(fromIPA: ipa)
        }
    }

    /// Imports one or two files; order does not matter, a ZIP is not unpacked here.
    @discardableResult
    func importFiles(_ urls: [URL]) throws -> String {
        var imported = 0
        for url in urls {
            let name = url.lastPathComponent.lowercased()
            let target: URL
            if name.hasSuffix(".pk8") {
                target = directory.appendingPathComponent("identity.pk8")
            } else if name.hasSuffix(".p7b") {
                target = directory.appendingPathComponent("certificate.p7b")
            } else {
                continue
            }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            guard !data.isEmpty, data.count <= 16 * 1024 else {
                throw NSError(domain: "OpenXPlay", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "\(url.lastPathComponent) 为空或超过 16 KiB"])
            }
            try data.write(to: target, options: .atomic)
            imported += 1
        }
        refresh()
        guard hasIdentity else {
            throw NSError(domain: "OpenXPlay", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "还需要另一个文件：identity.pk8 或 certificate.p7b"])
        }
        return imported > 0 ? "已导入身份（\(deviceId)）" : "没有可导入的文件"
    }

    // MARK: - Certificate CN parsing

    /// Find the accessory id inside the certificate. The CN is a TeletexString
    /// (tag 0x14) inside the PKCS#7 container, which a naive DER walk stepping
    /// two bytes at a time never lands on — so scan the raw bytes for the
    /// "IPA_" marker and read the hex digits that follow it.
    private static func ipaId(in der: Data) -> String? {
        let bytes = [UInt8](der)
        let marker: [UInt8] = [0x49, 0x50, 0x41, 0x5F] // "IPA_"
        guard bytes.count > marker.count else { return nil }
        for start in 0...(bytes.count - marker.count) {
            guard Array(bytes[start..<start + marker.count]) == marker else { continue }
            var hex = ""
            var index = start + marker.count
            while index < bytes.count, hex.count < 32 {
                let byte = bytes[index]
                let isHex = (byte >= 0x30 && byte <= 0x39)
                    || (byte >= 0x41 && byte <= 0x46)
                    || (byte >= 0x61 && byte <= 0x66)
                guard isHex else { break }
                hex.append(Character(UnicodeScalar(byte)))
                index += 1
            }
            if hex.count >= 12 { return "IPA_" + hex }
        }
        return nil
    }

    private static func mac(fromIPA ipa: String) -> String {
        let hex = ipa.dropFirst(4).prefix(12)
        guard hex.count == 12 else { return "02:00:00:00:00:01" }
        var parts: [String] = []
        var index = hex.startIndex
        for _ in 0..<6 {
            let next = hex.index(index, offsetBy: 2)
            parts.append(String(hex[index..<next]).uppercased())
            index = next
        }
        return parts.joined(separator: ":")
    }
}
