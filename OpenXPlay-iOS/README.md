# OpenXPlay iOS（iPhone 直连）源码

给 iPhone 直连用的可自建 App 源码：SwiftUI 外壳 + OpenXPlay 自己的 CarPlay 协议核心（Rust）。
你要的是源码自己构建，这里就是完整工程；`identity/` 里的两个 MFi 文件直接能用。

> 官方 TestFlight 版 App 不开源，且据它的兼容说明，iOS 18+ 才在本机跑 CarPlay。
> 本工程走的是同一套公开协议：App 在 iPhone 上做接收端，手机加入车机/路由器的 Wi-Fi 后，
> 手机自己的 CarPlay 栈连到 App 监听的 7000 端口，MFi 认证用你导入的证书和私钥。

---

## 1. 组成

| 路径 | 内容 |
| --- | --- |
| `OpenXPlay/` | SwiftUI App：身份导入、启动/停止、VideoToolbox 解码显示、Bonjour 广播、日志 |
| `../src/OpenXPlay-Relay/rust/carplay-airplay` | AirPlay / CarPlay 会话、配对、MFi SAP、加密、HID（OpenXPlay 原样代码） |
| `../src/OpenXPlay-Relay/rust/carplay-iap2` | iAP2 链路、MFi 认证（PKCS#8 + PKCS#7 校验就在这里） |
| `../src/OpenXPlay-Relay/rust/oxp-ios` | 新增：iOS 宿主（`server.rs` 由 `linux_air_play_server.rs` 移植）+ C ABI |
| `../src/OpenXPlay-Stream/rust/oxp-clink` | CarLink 协议（原样），车机端 Carlink 应用就是它对接的 |
| `../src/OpenXPlay-Stream/rust/oxp-clink-ios` | 新增：CarLink 客户端 + C ABI（PIN/信任库/回调/帧推送） |
| `../src/OpenXPlay-Stream/rust` | 工作区依赖（oxp-core / oxp-wire），构建时 Cargo 需要 |
| `scripts/build-rust-ios.sh` | 交叉编译 aarch64-apple-ios，产出 `liboxp_ios.a` + `oxp_ios.h` |
| `project.yml` | XcodeGen 工程定义（生成 `.xcodeproj`） |

数据流：

```
iPhone CarPlay 栈 ──TCP:7000(Bonjour 发现)──▶ oxp-ios(Rust)
                                             ├─ MFi 认证（identity.pk8 / certificate.p7b）
                                             ├─ 解密/拆包 → Annex-B NAL + 解码配置
                                             └─ C 回调 ──▶ Swift VideoToolbox ──▶ AVSampleBufferDisplayLayer
```

## 2. 构建（在 Mac 上）

```sh
# 1) Rust 工具链
curl https://sh.rustup.rs -sSf | sh
rustup target add aarch64-apple-ios

# 2) 编译接收端核心（在 OpenXPlay-iOS 目录）
./scripts/build-rust-ios.sh          # 真机
./scripts/build-rust-ios.sh sim      # 模拟器（可选）

# 3) 生成并打开工程
brew install xcodegen
xcodegen generate
open OpenXPlay.xcodeproj
```

Xcode 里选你的 iPhone，Team 选自己的开发者账号，Bundle Identifier 改成唯一的（默认 `org.openxplay.receiver`），Run。
首次运行允许「本地网络」权限，否则 Bonjour 广播和 7000 端口都不通。

## 3. 使用

**身份已经打包进 App 了**：`OpenXPlay/Resources/identity.pk8` 和 `certificate.p7b` 会在首次启动时
自动复制到 App 容器，装完打开就能点启动，不需要手动导入。

1. 首次启动先允许「本地网络」（拒绝的话 Bonjour 和 7000 端口都不通）。
2. 身份状态行应显示绿色「身份已就绪」和证书里推出来的 MAC（`IPA_24ACBB…` → `24:AC:BB:48:46:6F`）。
3. iPhone 加入车机热点或路由器（不能用这台 iPhone 自己的个人热点）。
4. 点「启动接收端」，日志出现 `tcp-accepted` / `device-info` 就说明手机连上来了。
5. 想换一份身份：仍可用「导入 identity.pk8 和 certificate.p7b」覆盖内置的那一对。

> 内置的好处是拿到 IPA 的人不用再找证书；代价是 IPA 本身就带着私钥，别把装好的包发给别人。
> 要发给别人用，删掉 `OpenXPlay/Resources/` 里两个文件重新打包，再让对方在 App 里导入。

## 4. CarLink 输出的实现方式

- 方向是「我们去连车机」：iPhone 以 Wi-Fi 客户端加入车机的 Carlink 网络，连车机上的 CarLink 服务，
  用配对码完成认证，然后推 H.264、收 UIBC 触摸。全程公开 API（`NWConnection`/BSD socket，无需特殊权限）。
- 协议用 `oxp-clink`（和中继同一个实现），iOS 侧只加了 `oxp-clink-ios` 的 C ABI。
- 帧的来源是 CarPlay 接收端：`IosMediaSink` 收到 Annex-B 后，同时调 `clink_push_config` / `clink_push_frame`。
- 触摸：车机 `OutputHost::control(ControlEvent::Touch)` → Swift 回调 → `oxp_touch()` → `CarPlayMediaEngine::touch`。
- CarLife 在 iOS 上做不了：它需要 USB 配件模式（手机当 USB device），iOS 没有这个能力；
  官方 App 的 CarLife 支持也是经 CarPlay 转的，不是真的模拟 CarLife 设备。

## 5. 已知边界（务必看）

- **CarPlay 会话能不能起来，取决于 iOS 是否允许本机配件连接。** 官方 App 用 TestFlight 分发、不开源，
  很可能带 Apple 私有授权；本工程用的是公开协议栈，能做的都做了，但这一步没有授权就由系统决定。
  日志停在 `tcp-accepted` 之前，说明手机的 CarPlay 栈没有连过来，不是协议实现的问题。
- **车机浏览器输出还没接进这个 App。** 官方 App 是把画面再转给车机的浏览器/CarLink；这一步需要
  HTTPS（WebCodecs 只在安全上下文可用）和一条 WebSocket 推送，属于下一版（见 `docs/ROADMAP.md`）。
- **触控回传还没做。** `InputEvents` 在 Rust 侧已可用，Swift 侧要把它接到 CarPlay 会话上才能用车机屏幕操作。
- **音频**当前只把格式和 RTP 包回调出来，没有解码播放；接 AVAudioEngine 即可。
- 接收端只监听、不主动发起；如果车机和你这台 iPhone 不在同一网段，什么都不会发生。

## 6. 许可

Rust 部分沿用 OpenXPlay-Relay 的 AGPL-3.0（`carplay-airplay` / `carplay-iap2` 为 GPL-3.0，
`oxp-ios` 为 AGPL-3.0），修改和分发时保留 `Powered by OpenXPlay.` 与上游链接。
Swift 外壳同样 AGPL-3.0。
