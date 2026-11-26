import Foundation
import Darwin
import Security

struct ReceiverConfiguration {
    var name = "CarWithin"
    var address: String
    var ssid: String
    var password: String
    var port: UInt16 = 7000
    var width = 1280
    var height = 720
    var maxFPS = 60
    var videoCodec: VideoCodec = .h264
    var wifiChannel: UInt8 = 36
    var audioEnabled = true
    var rightHandDrive = false
    let deviceID: String
    /// Physical width declared to the iPhone; larger values fit more (smaller) icons per page.
    var widthPhysicalMM = CarPlayInfo.defaultWidthPhysicalMM
    /// Square PNG (≤ 192 px) for the car button on the CarPlay home screen; nil hides it.
    var oemIconPNG: Data?
    var oemIconLabel = "CarWithin"

    /// Choices for "CarPlay 图标大小", as declared screen widths (CabinPlay offers the same four).
    static let iconSizes: [(title: String, widthMM: Int)] = [(CWL("大"), 125), (CWL("默认"), 200), (CWL("较小"), 250), (CWL("最小"), 300)]

    /// CarPlay day/night appearance. Raw values are persisted.
    enum Appearance: Int, CaseIterable {
        case system = 0, light = 1, dark = 2
        var title: String { [CWL("跟随系统"), CWL("白天"), CWL("夜间")][rawValue] }
    }

    struct Resolution { let label: String; let width: Int; let height: Int }
    /// Offered display sizes, landscape. Index order matches the settings control.
    static let resolutions = [
        Resolution(label: "480P", width: 800, height: 480),
        Resolution(label: "720P", width: 1280, height: 720),
        Resolution(label: "1080P", width: 1920, height: 1080),
        Resolution(label: "2K", width: 2560, height: 1440),
        Resolution(label: "4K", width: 3840, height: 2160)
    ]
    static let defaultResolutionIndex = 1

    struct AspectRatio {
        let width: Int
        let height: Int
        var title: String { "\(width):\(height)" }
    }
    static let aspectRatios = [
        AspectRatio(width: 16, height: 9), .init(width: 16, height: 10),
        .init(width: 4, height: 3), .init(width: 3, height: 2), .init(width: 1, height: 1),
        .init(width: 21, height: 9), .init(width: 32, height: 9),
        .init(width: 3, height: 1), .init(width: 4, height: 1),
        .init(width: 3, height: 4), .init(width: 9, height: 16), .init(width: 9, height: 19),
        .init(width: 9, height: 20), .init(width: 1, height: 3), .init(width: 1, height: 4)
    ]

    /// Treat the resolution tier as a pixel budget. Align both edges for video encoding.
    static func fixedDisplaySize(area: Int, ratio: AspectRatio, maxWidth: Int, maxHeight: Int) -> (Int, Int) {
        let aspect = min(max(Double(ratio.width) / Double(ratio.height), 320 / Double(maxHeight)),
                         Double(maxWidth) / 320)
        let height = max(320, 320 / aspect, min(Double(maxHeight), Double(maxWidth) / aspect,
                                               (Double(area) / aspect).squareRoot()))
        return (min(maxWidth, max(320, Int(height * aspect / 2) * 2)),
                min(maxHeight, max(320, Int(height / 2) * 2)))
    }

    static func wifiIPv4Address() -> String? {
        localIPv4Addresses(interface: "en0").first
    }

    static func localIPv4Addresses(interface: String? = nil) -> [String] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { freeifaddrs(first) }
        var result: [String] = []
        var current = first
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            let name = String(cString: entry.pointee.ifa_name)
            guard interface == nil || interface == name,
                  let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  entry.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  entry.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let value = String(cString: host)
                if interface != nil && (value.hasPrefix("169.254.") || value.hasPrefix("0.")) { continue }
                if name == "en0" { result.insert(value, at: 0) }
                else { result.append(value) }
            }
        }
        return result
    }

    static func persistentDeviceID() -> String {
        if let existing = UserDefaults.standard.string(forKey: "receiverDeviceID") { return existing }
        let value = makeDeviceID()
        UserDefaults.standard.set(value, forKey: "receiverDeviceID")
        return value
    }

    /// 生成一个新 deviceID（口径与 persistentDeviceID 首次生成完全一致：
    /// 6 字节随机数、置本地管理位、MAC 格式字符串）。
    private static func makeDeviceID() -> String {
        var random = [UInt8](repeating: 0, count: 6)
        _ = SecRandomCopyBytes(kSecRandomDefault, random.count, &random)
        random[0] = (random[0] | 2) & 0xfe
        return random.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// 轮换 deviceID：生成新值覆写存量，下次会话启动时现取即生效。系统
    /// 是按 deviceID 给这台「车」记账的（传输注册/iAP2 识别/StartSession
    /// 都报它），会话记录楔住后换一个新值等于换了台新车——正是去设置
    /// 里「忽略这辆车」达到的效果。必须在会话完全停止后调用：配置在
    /// 会话启动时现取（LocalCarPlaySession.beginStart），运行中换不会
    /// 生效、还会让同一会话前后身份不一致。配对凭据在 Keychain 独立
    /// 一层，不受影响，pair-verify 照常走。
    @discardableResult
    static func rotatePersistentDeviceID() -> String {
        let value = makeDeviceID()
        UserDefaults.standard.set(value, forKey: "receiverDeviceID")
        return value
    }

    func validate(requiresLocalAddress: Bool = true, requiresWiFiCredentials: Bool = true) throws {
        var parsed = in_addr()
        guard inet_pton(AF_INET, address, &parsed) == 1 else {
            throw ConfigurationError(CWL("请选择有效的 IPv4 地址。"))
        }
        if requiresLocalAddress && !Self.localIPv4Addresses().contains(address) {
            throw ConfigurationError(CWL("请选择属于本机当前网络连接的 IP 地址。"))
        }
        // Fixed presets or a size that follows the head unit: even, within 320…3840 per side and
        // at most 4K in area; the requested CarPlay frame rate is 30–60 in steps of 5.
        guard (320...3840).contains(width), (320...3840).contains(height), width % 2 == 0, height % 2 == 0,
              width * height <= 3840 * 2160,
              (30...60).contains(maxFPS), maxFPS % 5 == 0, (100...400).contains(widthPhysicalMM) else {
            throw ConfigurationError(CWL("请选择受支持的分辨率和帧率。"))
        }
        guard requiresWiFiCredentials else { return }
        guard !ssid.isEmpty, ssid.utf8.count <= 32 else {
            throw ConfigurationError(ssid.isEmpty ? CWL("启动前请输入 Wi-Fi 名称。") : CWL("Wi-Fi 名称不能超过 32 个 UTF-8 字节。"))
        }
        guard password.isEmpty || (8...63).contains(password.utf8.count) else {
            throw ConfigurationError(CWL("请输入 8–63 字节的 Wi-Fi 密码，开放网络则留空。"))
        }
    }
}

struct ConfigurationError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
