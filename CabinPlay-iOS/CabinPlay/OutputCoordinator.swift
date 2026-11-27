// SPDX-FileCopyrightText: 2026 CabinPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// 输出仲裁：CarLink 与 CarLife 抢同一个本机 CarPlay 会话和同一个 RTSP
// 端口，同一时刻只能有一路在跑。CarLife 启动前置位、停止时清掉；CarLink
// 启动本机会话时据此拒绝，反方向由 CarLife 自己检查 CarLinkCore。

import Foundation

enum OutputCoordinator {
    /// CarLife 正在运行（已启动或正在启动）。
    static var carLifeActive = false
    /// CarLife 自己启动本机会话的这一刻放行，避免把自己挡在门外。
    static var startingCarLife = false
}
