# CabinPlay

**让原本不支持 Apple CarPlay 的车机，也能通过 iPhone 使用 CarLife 或 CarLink 连接方案。**

CabinPlay 是一个开源 iOS 项目，目标是让 iPhone 与具备相应接收能力的车机建立无线连接，为原本没有原生 CarPlay 的车机提供另一种使用车载互联功能的方式。

与传统方案相比，CabinPlay 希望尽量减少额外硬件和车机改装：

- **支持 CarLife 输出**：通过无线网络与车机 CarLife 接收端建立连接。
- **支持 CarLink 输出**：通过设备发现、配对和无线网络连接车机 CarLink 服务。
- **无需额外 CarPlay 盒子**：目标是不依赖外置 CarPlay 转换盒。
- **无需破解车机**：不以 Root、越狱车机或修改车机系统为前提。
- **开源实现**：iOS 客户端及相关底层组件开放，便于开发者研究和改进。

> **兼容性说明：** 支持 CarLife 和 CarLink 两种连接方式，不代表所有车机都能使用。车机需要具备对应的 CarLife 或 CarLink 接收端能力，并满足网络、协议及系统环境要求。实际效果以设备测试为准。

## 项目介绍

CabinPlay 在 iPhone 端实现连接、会话和媒体输出流程，并提供两种面向车机的连接方式：

| 连接方式 | 工作方式 | 说明 |
| --- | --- | --- |
| **CarLife** | iPhone 启动无线 CarLife 输出服务，车机通过 Wi-Fi 连接 | 支持车机发现，也可以填写车机 IP 地址进行定向连接 |
| **CarLink** | iPhone 发现并配对车机，再通过 Wi-Fi 连接 CarLink 服务 | 支持配对认证、媒体输出以及车机触控等交互 |

两种输出模式分别管理连接和会话，**不能同时运行**。请根据车机实际支持的协议选择对应模式。

## 功能与技术

| 模块 | 说明 |
| --- | --- |
| iOS 客户端 | 使用 Swift 和 SwiftUI 构建应用界面、连接流程及状态管理 |
| CarLife | 无线发现、连接监听、协议认证、视频输出及触控交互 |
| CarLink | 蓝牙设备发现与配对、Wi-Fi 连接、PIN/信任管理及媒体输出 |
| 视频处理 | 使用 VideoToolbox 等系统能力处理视频帧 |
| 触控与按键 | 将车机侧输入事件传递至 iPhone 会话 |
| 音频 | 按连接模式和设备能力处理音频输出；CarLife 音频可通过 iPhone 的蓝牙音频链路输出 |
| 画中画与保活 | 集成 iOS 画中画及会话保活相关逻辑 |
| 诊断日志 | 分别记录 CarLife、CarLink 的连接状态、错误和运行信息 |

具体功能和可用性以当前代码实现、iOS 系统限制及实际车机测试结果为准。

## 项目结构

```text
Cabinplay/
├── CabinPlay-iOS/       # iOS 客户端工程、资源、脚本和测试
├── src/
│   ├── CabinPlay-Relay/ # Relay 及相关 Rust 组件
│   └── CabinPlay-Stream/# CarLink / Stream 相关 Rust 组件
├── identity/            # 项目身份相关文件
├── .github/workflows/  # GitHub Actions 工作流
├── codemagic.yaml       # Codemagic 云构建配置（如使用）
└── README.md
```

## 开发环境

构建 iOS 客户端通常需要：

- macOS
- Xcode
- Swift 工具链
- Rust 工具链及 iOS 编译目标
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

具体版本要求请以工程配置和构建脚本为准。

## 本地构建

以下为项目当前构建脚本对应的基本流程：

1. 安装并配置 Xcode、Rust 和 XcodeGen。
2. 进入 iOS 工程目录。
3. 添加 iOS 设备构建目标并执行 Rust 构建脚本。
4. 生成 Xcode 工程并使用 Xcode 编译。

示例：

```bash
cd CabinPlay-iOS

rustup target add aarch64-apple-ios
./scripts/build-rust-ios.sh

xcodegen generate
```

随后使用 Xcode 打开生成的工程，选择合适的签名配置和目标设备进行构建。

> 构建脚本、依赖和工程配置可能随项目更新而变化。如果构建失败，请优先检查脚本输出、Xcode 版本、Rust target 以及签名配置。

## 云端构建

仓库包含 GitHub Actions 工作流配置，可用于执行 iOS 构建和 IPA 打包。请以工作流文件中的触发条件、签名配置和产物设置为准。

构建产物能否安装，取决于 IPA 的签名方式和设备配置。未签名或签名不匹配的 IPA 不能直接安装到普通 iOS 设备。

## 使用前须知

- 先确认车机支持 **CarLife** 还是 **CarLink** 接收方式，再选择 CabinPlay 中对应的连接模式。
- iPhone 与车机需要满足对应模式的网络连接要求；部分模式还需要先完成蓝牙发现或配对。
- CarLife 和 CarLink 是两套独立的输出流程，不能同时启动。
- 首次连接或连接失败时，请查看应用内对应模式的诊断日志，并确认车机端已进入相应的连接/接收界面。

## 兼容性说明

CabinPlay 并不是把任意车机变成通用 CarPlay 接收器。是否能够使用，取决于：

- 车机是否具备可用的 CarLife 或 CarLink 接收端；
- 车机系统、网络和协议实现是否与 CabinPlay 当前版本兼容；
- iPhone 型号、iOS 版本及系统权限；
- 车机与手机之间的 Wi-Fi、蓝牙连接环境；
- 相关协议、授权和系统限制。

**请勿仅凭车机支持 CarLife 或 CarLink 就推断一定能够连接。** 建议先查阅项目更新记录和实际测试反馈。

## 免责声明

- CabinPlay 是独立开源项目，与 Apple、CarLife 或相关车机厂商没有隶属、合作或官方认可关系。
- Apple、CarPlay、CarLife、CarLink、iPhone 等名称和商标归其各自权利人所有。
- 本项目不保证兼容所有车型、车机或 iOS 版本。
- 请遵守所在地法律法规、车辆制造商规定及相关软件许可要求。驾驶过程中请勿操作手机或车机。

## 许可证

仓库包含不同来源和许可条件的代码。请以各子目录中的 LICENSE、NOTICE 及文件头许可声明为准，不应将整个仓库视为单一许可证授权。

---

**CabinPlay — 同时探索 CarLife 与 CarLink 无线连接，让更多车机有机会接入 iPhone。**
