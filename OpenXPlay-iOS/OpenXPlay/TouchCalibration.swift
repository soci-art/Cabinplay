// SPDX-FileCopyrightText: 2026 OpenXPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// 触控按车校准（描边法）：协议只报车机屏与画面区的尺寸、不报画面区
// 的位置，居中假设对画面不居中的车必然偏（UNI-V 左侧留着车机自己
// 的边栏、画面贴右，就是实测偏的来源）。校准让用户在车机屏上依次
// 点画面四条边的中段，四点的原始坐标直接给出画面区在触控面上的真
// 实矩形；四点全在边的中段、离四个角远远的，不会碰到右下角车机自
// 己的退出按钮。校验不用再点（正中央靠眼睛估、不准）：改程序自检
// ——矩形合法（左<右、上<下、宽高够大）且矩形宽高比与车机声明的
// videoDisplay 比例偏差在约 15% 内，不过就提示重校。
//
// 结果按车机 deviceId 存 UserDefaults；有校准的车，核心 UIBC 换算
// 用校准矩形替代居中模型；没有的车保持居中模型。车主本人的 UNI-V
// （deviceId 50C3A2E75160）内置一条预置：来源是车主实测照片（画面
// 贴右边缘、上下满幅）＋车机声明 screen 1920×720、videoDisplay
// 1800×720 推算——left=(1920−1800)/1920、right=1、top=0、bottom=1。
// 预置只对这一台车生效，绝不推广成所有车的默认；用户手动校准可
// 以覆盖预置。

import SwiftUI

enum TouchCalibrationStore {
    struct Rect: Equatable {
        var left: Double
        var right: Double
        var top: Double
        var bottom: Double
    }

    /// 车主本人的 UNI-V 预置（就这一台车，来源见文件头注释）。
    static let presetDeviceID = "50C3A2E75160"
    static let presetRect = Rect(left: 120.0 / 1920.0, right: 1.0, top: 0.0, bottom: 1.0)

    private static func key(for deviceId: String) -> String {
        "cabinplay.touchCalibration.\(deviceId)"
    }

    static func manualRect(for deviceId: String) -> Rect? {
        guard let values = UserDefaults.standard.array(forKey: key(for: deviceId)) as? [Double],
              values.count == 4 else { return nil }
        return Rect(left: values[0], right: values[1], top: values[2], bottom: values[3])
    }

    static func saveManualRect(_ rect: Rect, for deviceId: String) {
        UserDefaults.standard.set([rect.left, rect.right, rect.top, rect.bottom],
                                  forKey: key(for: deviceId))
    }

    static func clearManualRect(for deviceId: String) {
        UserDefaults.standard.removeObject(forKey: key(for: deviceId))
    }

    /// 生效校准：手动校准优先，其次预置（仅命中那一台车），都没有
    /// 为 nil（核心走居中模型）。
    static func effectiveRect(for deviceId: String) -> (rect: Rect, isPreset: Bool)? {
        if let manual = manualRect(for: deviceId) { return (manual, false) }
        if deviceId == presetDeviceID { return (presetRect, true) }
        return nil
    }

    static func hasAnyCalibration(for deviceId: String) -> Bool {
        effectiveRect(for: deviceId) != nil
    }
}

/// 校准捕获总线：核心的捕获回调（ContentView 接线）把原始坐标送到
/// 这里，校准界面在进行时挂上自己的处理函数，结束就摘掉。
final class TouchCaptureBus {
    static let shared = TouchCaptureBus()
    var handler: ((Double, Double) -> Void)?
    private init() {}
}

/// 描边校准界面（手机端分步指引，用户在车机屏上点）。需要在车机正
/// 出画时做：触控经 CarLink 回传，捕获模式下只记录不转发。
struct TouchCalibrationView: View {
    let deviceId: String?
    /// 打开这一页时 CarLink 是否正在出画（触控链活着才能校准）。
    let sessionPlaying: Bool
    var onLog: ((String) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var step = 0            // 0 说明，1..4 四条边，5 完成，6 自检没过
    @State private var edges: [Double?] = [nil, nil, nil, nil]   // 左/右/上/下
    @State private var failReason = ""
    @State private var lastAcceptedAt = Date.distantPast
    @State private var justAccepted = false

    private let stepTitles = ["画面最左边的边缘", "画面最右边的边缘", "画面最上边的边缘", "画面最下边的边缘"]
    private let stepHints = [
        "在车机屏上点 CarPlay 画面最左边的那条边，点在边的中间高度，别贴角",
        "点画面最右边的那条边，同样点中间高度——点的是右边中间，不是右下角（那儿是车机的退出按钮，别碰）",
        "点画面最上边的那条边，点在上边的中间位置",
        "点画面最下边的那条边，点在下边的中间位置",
    ]

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                switch step {
                case 0:
                    intro
                case 1...4:
                    edgeStep(step)
                case 5:
                    done
                default:
                    failed
                }
                Spacer()
            }
            .padding()
            .background(Color.pageBackground)
            .navigationTitle("校准车机触控")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { endCapture(); dismiss() }
                }
            }
        }
        .onDisappear { endCapture() }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("车机屏上的画面位置每台车不一样，触控要对准，先花半分钟把画面四条边点一遍。")
                .font(.body)
            Text("做法：接下来按提示，在车机屏上依次点画面左、右、上、下四条边的中间。点的都是边的中段，离四个角远远的，不会碰到车机自己的按钮。点错了可以重来。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let deviceId, let effective = TouchCalibrationStore.effectiveRect(for: deviceId) {
                Text(effective.isPreset
                     ? "这台车已有一份内置的预置校准在用。重新校准后以你这次点的为准。"
                     : "这台车已经校准过一次。重新校准会覆盖上次的结果。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if sessionPlaying {
                Button {
                    startCalibration()
                } label: {
                    Text("开始校准").frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.sunsetAccent)
            } else {
                Text("现在车机还没出画，点下去也记不到。先回驾驶舱连上车机、等画面出来，再回来校准。")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.orange)
            }
            if let deviceId, TouchCalibrationStore.manualRect(for: deviceId) != nil {
                Button("清掉这次手动校准", role: .destructive) {
                    TouchCalibrationStore.clearManualRect(for: deviceId)
                    CarLinkCore.shared.applyTouchCalibration(forDeviceId: deviceId)
                    onLog?("触控校准：已清掉这台车的手动校准（\(deviceId)）")
                    dismiss()
                }
                .font(.footnote)
            }
        }
    }

    private func edgeStep(_ current: Int) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("第 \(current) 步，共 4 步")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("点" + stepTitles[current - 1])
                .font(.title3.weight(.bold))
            Text(stepHints[current - 1])
                .font(.footnote)
                .foregroundStyle(.secondary)
            if justAccepted {
                Label("记下了，继续下一步", systemImage: "checkmark.circle.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.green)
            } else {
                Text("在车机屏上点完，这边会自动记下并跳到下一步")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button("这一步重点") {
                edges[current - 1] = nil
                justAccepted = false
            }
            .font(.footnote)
            Button("取消校准", role: .cancel) {
                endCapture()
                step = 0
            }
            .font(.footnote)
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("校准完成", systemImage: "checkmark.circle.fill")
                .font(.title3.weight(.bold))
                .foregroundStyle(.green)
            Text("回到车机屏上点几个图标试试，点得准就成了；不准就回来重新校准一次。")
                .font(.body)
            Button("好，去试试") { dismiss() }
                .buttonStyle(.borderedProminent)
                .tint(Color.sunsetAccent)
        }
    }

    private var failed: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("这组点可能有点偏", systemImage: "exclamationmark.triangle.fill")
                .font(.title3.weight(.bold))
                .foregroundStyle(.orange)
            Text(failReason)
                .font(.body)
            Button("重新校准一次") {
                edges = [nil, nil, nil, nil]
                step = 1
                CarLinkCore.shared.setTouchCapture(true)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.sunsetAccent)
            Button("先退出，用回原来的换算") {
                endCapture()
                dismiss()
            }
            .font(.footnote)
        }
    }

    // MARK: 流程

    private func startCalibration() {
        guard deviceId != nil else { return }
        edges = [nil, nil, nil, nil]
        step = 1
        TouchCaptureBus.shared.handler = { x, y in
            acceptTap(x: x, y: y)
        }
        CarLinkCore.shared.setTouchCapture(true)
        onLog?("触控校准：开始描边校准（左/右/上/下四条边中段），捕获已开启，期间触控只记录不转发")
    }

    private func endCapture() {
        TouchCaptureBus.shared.handler = nil
        CarLinkCore.shared.setTouchCapture(false)
    }

    /// 收一个捕获到的原始坐标（触控面归一化）。防抖：一秒内的连点
    /// 只算第一下（一回点在车机侧会连发好几个包）。
    private func acceptTap(x: Double, y: Double) {
        guard (1...4).contains(step) else { return }
        let now = Date()
        guard now.timeIntervalSince(lastAcceptedAt) >= 1.0 else { return }
        lastAcceptedAt = now
        switch step {
        case 1: edges[0] = x
        case 2: edges[1] = x
        case 3: edges[2] = y
        case 4: edges[3] = y
        default: return
        }
        onLog?(String(format: "触控校准：第 %d 步（%@）记下原始坐标 x=%.4f y=%.4f", step, stepTitles[step - 1], x, y))
        justAccepted = true
        let finishedStep = step
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard step == finishedStep else { return }
            justAccepted = false
            if finishedStep < 4 {
                step = finishedStep + 1
            } else {
                finishCalibration()
            }
        }
    }

    /// 四条边齐了：程序自检（不靠人眼估中央点）——矩形合法＋宽高比
    /// 与车机声明的 videoDisplay 比例偏差在约 15% 内（几何从核心读，
    /// 读不到就跳过比例这一项）。过了才落盘生效。
    private func finishCalibration() {
        endCapture()
        guard let deviceId,
              let left = edges[0], let right = edges[1],
              let top = edges[2], let bottom = edges[3] else {
            failReason = "四条边没有点全，重新来一次。"
            step = 6
            return
        }
        if !(left < right) {
            failReason = "左右两边点反了或者点在了同一处：左边记下的位置不在右边左边。重新校准一次，左、右分开点。"
            step = 6
            return
        }
        if !(top < bottom) {
            failReason = "上下两边点反了或者点在了同一处：上边记下的位置不在下边上边。重新校准一次，上、下分开点。"
            step = 6
            return
        }
        if right - left < 0.3 || bottom - top < 0.3 {
            failReason = "点出的画面范围太小了，不像整个画面——多半是某条边点到了画面里面。重新校准一次，四下都点在画面真正的边上。"
            step = 6
            return
        }
        if let geometry = CarLinkCore.shared.touchGeometry(),
           let surface = geometry.surface, let visible = geometry.visible,
           surface.1 > 0, visible.1 > 0 {
            let rectAspect = (right - left) * Double(surface.0) / ((bottom - top) * Double(surface.1))
            let displayAspect = Double(visible.0) / Double(visible.1)
            let deviation = abs(rectAspect / displayAspect - 1)
            onLog?(String(format: "触控校准自检：矩形宽高比 %.3f，车机声明画面区宽高比 %.3f，偏差 %.1f%%（15%% 内算过）", rectAspect, displayAspect, deviation * 100))
            if deviation > 0.15 {
                failReason = "点出的画面形状和车机报的画面区形状对不上（偏差超过 15%），多半是某条边点偏了。重新校准一次，每下都点在边的正中间。"
                step = 6
                return
            }
        } else {
            onLog?("触控校准自检：核心还没报车机几何，宽高比这一项跳过（矩形合法性已过）")
        }
        let rect = TouchCalibrationStore.Rect(left: left, right: right, top: top, bottom: bottom)
        TouchCalibrationStore.saveManualRect(rect, for: deviceId)
        CarLinkCore.shared.applyTouchCalibration(forDeviceId: deviceId)
        onLog?(String(format: "触控校准：描边完成并已生效（车 %@）left=%.4f right=%.4f top=%.4f bottom=%.4f", deviceId, left, right, top, bottom))
        step = 5
    }
}
