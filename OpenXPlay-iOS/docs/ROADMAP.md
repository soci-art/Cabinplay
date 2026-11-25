# 路线图 / 待接的部分

按优先级排列，每一项都标了要改的文件。

## 1. 车机浏览器输出（决定能不能在车上看到）

- 目标：把 Swift 侧解出的 NAL 再推给车机浏览器，页面用 WebCodecs 解码，和 OpenXPlay-Stream 的网页接收端一致。
- WebCodecs 只在安全上下文可用，所以必须 HTTPS：
  - 生成自签 X.509（P-256，SAN 带本机 IP）→ `SecIdentity` → `NWListener` 的 `NWProtocolTLS`；
  - 或者退一步：把 `https://` 交给车机的 `Carlink`/`CarLife` 通道。
- 文件：新增 `OpenXPlay/ReceiverServer.swift`、`OpenXPlay/SelfSignedIdentity.swift`，页面资源放 `OpenXPlay/Resources/web/`。
- 推流协议：WebSocket 二进制帧，首帧发解码配置，后续发 Annex-B；触摸用 JSON 文本帧回传。

## 2. 触控回传（车机屏幕操作 CarPlay）

- Rust 侧已经有 `InputEvents`（`touch(screen, contacts)`），`CarPlayMediaEngine` 绑定会话后可用。
- 需要在 `oxp-ios` 里把当前 `CarPlayMediaEngine` 存下来，加 `oxp_touch(x, y, phase)` 导出函数，
  Swift 侧在网页上把触摸坐标归一化后调它。
- 文件：`src/OpenXPlay-Relay/rust/oxp-ios/src/lib.rs`、`OpenXPlay/ContentView.swift`。

## 3. 音频

- `IosMediaSink::on_audio_rtp` 已经把包送出来了，但还没有解码。
- 用 `AVAudioConverter` + `AVAudioEngine` 解 AAC-ELD / PCM；`on_audio_format` 里的 JSON 已带采样率和声道。
- 注意 `AVAudioSession` 要设 `.playback` + `.mixWithOthers`，并在 `Info.plist` 的 `UIBackgroundModes` 里保留 `audio`。

## 4. 配对持久化

- `oxp-ios` 现在把 AirPlay 配对身份存成 `airplay-identity.txt`（私钥/公钥/pairing id），
  配对表 `MemoryPairings` 只在内存里；重启后 iPhone 需要重新配对。
- 把 `PairingStore` 实现改成写文件（`identity` 目录旁边），或接到 Swift 的 Keychain。

## 5. CarPlay 会话的起点

- 现状：App 监听 7000 + Bonjour 广播，等手机自己的 CarPlay 栈连进来。
- 如果 iOS 不主动连本地配件，可选路径只有两条：
  1. 拿到 Apple 的配件授权（官方 App 走的路，闭源 + TestFlight 的原因）；
  2. 越狱设备上直接调私有 `AirPlayReceiverKit` / CarPlay 服务。
- 这两条都不在公开 API 范围内，代码层面能做的就是保证协议栈完全正确（本工程已经复用 relay 的同一套实现）。
