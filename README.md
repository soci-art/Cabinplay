# CabinPlay

**让原本不支持 CarPlay 的车机，也有机会使用无线 CarPlay。**

CabinPlay 是一个开源的 iOS 项目，探索通过软件方式，让 iPhone 与原本不支持 Apple CarPlay 的车机建立连接，并提供无线 CarPlay 使用体验。

传统方案往往需要额外购买 CarPlay 转换盒，或对车机进行破解、刷机和改装。CabinPlay 的目标是尽量减少这些额外条件：

- **无需额外 CarPlay 盒子**：目标是不依赖外置 CarPlay 转换硬件。
- **无需破解车机**：不以 Root、越狱车机或修改车机系统为前提。
- **无线连接**：通过 iPhone 与车机之间的无线连接流程完成通信。
- **开源实现**：客户端与底层组件代码开放，便于开发者研究和改进。

> **重要说明：** CabinPlay 并不保证所有原本不支持 CarPlay 的车机都能使用。实际兼容性取决于车机硬件、系统、无线网络能力及相关接口。请先确认目标车机是否满足项目当前实现所需的条件。

## 项目介绍

CabinPlay 希望提供一种不同于传统 CarPlay 盒子的实现思路：由 iPhone 端的软件负责设备发现、连接流程和数据通信，在兼容的车机环境中建立 CarPlay 连接。

项目目前包含 iOS 客户端、本机 CarPlay 会话相关实现，以及基于 Rust 的 CarLink 连接与流媒体组件。

## 功能与技术

| 模块 | 说明 |
| --- | --- |
| iOS 客户端 | 使用 Swift 和 SwiftUI 构建应用界面及连接流程 |
| 设备发现与配对 | 使用蓝牙相关能力发现车机并进行配对 |
| 网络连接 | 处理连接所需的网络信息与连接配置 |
| CarLink | 提供底层连接、视频流及交互数据通道 |
| 视频解码 | 使用 Apple VideoToolbox 处理视频帧 |
| 触控与按键 | 支持将触控或按键输入传递至连接端 |
| 音频处理 | 使用 AVFoundation 相关能力处理音频路由；具体能力受当前实现及设备环境限制 |
| 画中画 | 集成 iOS Picture in Picture 相关能力 |
| 诊断日志 | 提供连接过程及运行状态的诊断信息 |

具体功能是否可用，以当前代码实现和实际设备测试结果为准。

## 项目结构

```text
Cabinplay/
├── CabinPlay-iOS/       # iOS 客户端工程、资源、脚本和测试
├── src/
│   ├── CabinPlay-Relay/ # Relay 相关 Rust 组件
│   └── CabinPlay-Stream/# Stream / CarLink 相关 Rust 组件
├── identity/            # 项目身份相关文件
├── codemagic.yaml       # Codemagic 云构建配置
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

仓库提供 `codemagic.yaml` 构建配置，可用于在 Codemagic 环境中执行 iOS 构建流程。当前配置涉及 Rust 组件构建、Xcode 工程生成及 IPA 打包。

构建产物是否可以直接安装，取决于所使用的签名方式和设备配置。未签名或签名不匹配的 IPA 不能直接安装到普通 iOS 设备。

## 兼容性说明

CabinPlay 的目标是让更多原本没有 CarPlay 功能的车机能够尝试使用无线 CarPlay，但这并不代表所有车机都可以通过安装应用实现这一目标。

兼容性可能受到以下因素影响：

- 车机硬件与系统版本；
- 车机是否具备项目连接流程所需的蓝牙和网络能力；
- 车机对相关连接协议及数据通道的支持情况；
- iPhone 型号、iOS 版本及系统权限；
- Apple CarPlay 相关授权和系统限制。

**请勿仅凭“无需盒子、无需破解”的项目目标推断自己的车机一定兼容。** 建议先查阅项目代码、更新记录和实际测试反馈，再判断是否适用于自己的设备。

## 免责声明

- CabinPlay 是独立开源项目，与 Apple Inc. 没有隶属、合作或官方认可关系。
- Apple、CarPlay、iPhone 等名称和商标归其各自权利人所有。
- 本项目不提供对所有车型、车机或 iOS 版本的兼容性保证。
- 请遵守所在地法律法规、车辆制造商规定及相关软件许可要求。

## 许可证

仓库包含不同来源和许可条件的代码。请以各子目录中的 LICENSE、NOTICE 及文件头许可声明为准，不应将整个仓库视为单一许可证授权。

---

**CabinPlay — 不依赖 CarPlay 盒子，不以破解车机为前提，探索无线 CarPlay 的另一种实现方式。**
