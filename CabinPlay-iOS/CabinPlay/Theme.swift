// SPDX-FileCopyrightText: 2026 CabinPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// 落日驾驶舱主题：落日橙是唯一强调色；深色用纯黑底（OLED 真黑），
// 浅色用暖纸底。颜色集中在这里，页面不写死色值。

import SwiftUI
import UIKit

extension Color {
    /// 落日橙（唯一强调色）：深色 #FF9E57 / 浅色 #D9540D
    static let sunsetAccent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1.00, green: 0.62, blue: 0.34, alpha: 1)
            : UIColor(red: 0.85, green: 0.33, blue: 0.05, alpha: 1)
    })

    /// 页面底色：深色纯黑 #000000 / 浅色暖纸 #F7F3EF
    static let pageBackground = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.black
            : UIColor(red: 0.97, green: 0.95, blue: 0.94, alpha: 1)
    })

    /// 卡片底色：深色 #1C1712 / 浅色白
    static let cardBackground = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.11, green: 0.09, blue: 0.07, alpha: 1)
            : UIColor.white
    })

    /// 停止按钮的深红
    static let stopRed = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.55, green: 0.20, blue: 0.17, alpha: 1)
            : UIColor(red: 0.70, green: 0.22, blue: 0.18, alpha: 1)
    })
}

extension Font {
    static let heroState: Font = .title2.weight(.bold)
    static let cardTitle: Font = .headline
    static let bodyText: Font = .body
    static let monoCaption: Font = .caption.monospaced()
}

/// 触感反馈（出错/成功/点按），跟随系统设置，Reduce Motion 不受影响。
enum Haptics {
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}
