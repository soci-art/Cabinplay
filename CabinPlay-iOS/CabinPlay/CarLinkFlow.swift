// SPDX-FileCopyrightText: 2026 CabinPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// CarLink 候选试序状态机。
//
// 这一块原来是 ContentView 里的 7 个 @State + 6 个方法：候选下标、同候选
// 重试次数、单次看门狗、整轮预算、命中/放弃判定，全都散在视图里，任何
// 一次界面刷新都可能碰到这些字段。现在收进这个类：
//
//   begin(candidates:localIP:)  —— 开一轮试序
//   noteHit()                   —— 走到协商/出画，当前候选就是车机
//   noteSessionEnded()          —— 没命中就结束，按失败处理
//   noteError(_:)               —— 核心报错的最近一条，失败时带上
//   cancel()                    —— 用户断开/重来
//
// 视图只负责两件事：onAttempt 里「怎么启一次连接」，onAbandon 里「放弃后
// 怎么办（降档重开还是停在这一档）」。

import Foundation

final class CarLinkFlow {

    enum Outcome {
        case started
        case failed(String)
        /// 本机地址失效：换候选没用，整轮中止（不算候选失败）。
        case localAddressInvalid(String)
    }

    struct Config {
        var maxAttemptsPerCandidate = 4
        var retryGap: TimeInterval = 2.0
        var attemptTimeout: TimeInterval = 8.0
        var budget: TimeInterval = 30.0
    }

    let config = Config()

    // 对外只读（界面显示/守卫用）
    private(set) var candidates: [String] = []
    private(set) var candidateIndex = 0
    private(set) var attemptsOnCandidate = 0
    private(set) var isActive = false
    private(set) var lastError = ""

    private var localIP = ""
    private var deadline: Date?
    private var settled = true
    private var hit = false
    private var retryWork: DispatchWorkItem?
    private var watchdogWork: DispatchWorkItem?

    var onLog: ((String) -> Void)?
    var onDetail: ((String) -> Void)?
    /// 真正启一次连接，返回结果由视图判定（它知道尺寸、身份、配对码）。
    var onAttempt: ((_ carIP: String, _ localIP: String) -> Outcome)?
    var onStop: (() -> Void)?
    /// 命中：这个候选就是车机地址。
    var onHit: ((_ carIP: String) -> Void)?
    /// 整轮放弃（预算用完 / 候选试满）。
    var onAbandon: ((_ reason: String, _ tried: [String]) -> Void)?
    /// 本机地址失效，整轮中止（不降档、不重试）。
    var onLocalInvalid: ((_ carIP: String, _ detail: String) -> Void)?

    var currentCandidate: String? {
        candidates.indices.contains(candidateIndex) ? candidates[candidateIndex] : nil
    }

    func begin(candidates: [String], localIP: String) {
        self.candidates = candidates
        self.localIP = localIP
        candidateIndex = 0
        attemptsOnCandidate = 0
        deadline = Date().addingTimeInterval(config.budget)
        isActive = true
        hit = false
        settled = true
        lastError = ""
        cancelPendingWork()
        onLog?("CarLink 候选试序开始：\(candidates.joined(separator: " → "))——逐个用真连接试（同候选被拒先原地重试，间隔 \(Int(config.retryGap)) 秒、最多 \(config.maxAttemptsPerCandidate) 次；含切换总预算 \(Int(config.budget)) 秒）")
        runAttempt()
    }

    func noteError(_ line: String) {
        lastError = line
    }

    /// 状态走到协商/出画：当前候选就是车机地址，试序结束。
    func noteHit() {
        guard isActive, !hit else { return }
        hit = true
        settled = true
        isActive = false
        cancelPendingWork()
        guard let carIP = currentCandidate else { return }
        onLog?("CarLink 候选 \(carIP) 命中——车机地址定为 \(carIP)")
        onHit?(carIP)
    }

    /// 会话在命中前就结束：按失败处理，错误文本用最近一条核心报错。
    func noteSessionEnded() {
        guard isActive, !hit, settled else { return }
        settleFailure(reason: lastError.isEmpty ? "会话刚启动就结束（没走到协商）" : lastError)
    }

    func cancel() {
        isActive = false
        settled = true
        cancelPendingWork()
    }

    // MARK: - 内部

    private func runAttempt() {
        guard isActive, !hit else { return }
        if let deadline, Date() > deadline {
            abandon(reason: "\(Int(config.budget)) 秒重试预算用完")
            return
        }
        guard let carIP = currentCandidate else { return }
        attemptsOnCandidate += 1
        settled = false
        lastError = ""
        onDetail?("车机 \(carIP) · 本机 \(localIP) · 连接中（候选 \(candidateIndex + 1)/\(candidates.count) 第 \(attemptsOnCandidate) 次）")
        onLog?("CarLink 真连接试候选 \(carIP)（候选 \(candidateIndex + 1)/\(candidates.count)，本候选第 \(attemptsOnCandidate)/\(config.maxAttemptsPerCandidate) 次）")
        switch onAttempt?(carIP, localIP) ?? .failed("没有连接实现") {
        case .started:
            armWatchdog(carIP: carIP)
        case .failed(let reason):
            settleFailure(reason: reason)
        case .localAddressInvalid(let detail):
            isActive = false
            settled = true
            cancelPendingWork()
            onLocalInvalid?(carIP, detail)
        }
    }

    /// 单次尝试看门狗：迟迟走不到协商、也不结束，就停掉算失败，
    /// 别把整轮预算耗在一次干等上。先置 settled 再停 core——停的过程
    /// 中 core 可能同步回 .ended，回调看到 settled 就不会重复判。
    private func armWatchdog(carIP: String) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isActive, !self.hit, !self.settled else { return }
            self.settled = true
            self.watchdogWork = nil
            self.onLog?("CarLink 候选 \(carIP) 本次尝试 \(Int(self.config.attemptTimeout)) 秒没走到协商，停掉算失败")
            self.onStop?()
            self.decideFailure(reason: "\(Int(self.config.attemptTimeout)) 秒没走到协商（超时）")
        }
        watchdogWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + config.attemptTimeout, execute: work)
    }

    private func settleFailure(reason: String) {
        guard isActive, !hit, !settled else { return }
        settled = true
        watchdogWork?.cancel()
        watchdogWork = nil
        decideFailure(reason: reason)
    }

    /// 同候选先原地重试，用满再换下一个；候选与预算都用完才整轮放弃。
    private func decideFailure(reason: String) {
        guard let candidate = currentCandidate else { return }
        onLog?("CarLink 候选 \(candidate) 第 \(attemptsOnCandidate) 次没成：\(reason)")
        if let deadline, Date() > deadline {
            abandon(reason: "\(Int(config.budget)) 秒重试预算用完")
            return
        }
        if attemptsOnCandidate < config.maxAttemptsPerCandidate {
            onLog?("CarLink \(Int(config.retryGap)) 秒后原地重试候选 \(candidate)（车机鉴权口可能刚被占/还没重开）")
            schedule(after: config.retryGap) { [weak self] in self?.runAttempt() }
        } else if candidateIndex + 1 < candidates.count {
            let next = candidates[candidateIndex + 1]
            onLog?("CarLink 候选 \(candidate) 重试 \(config.maxAttemptsPerCandidate) 次都没成，换下一个候选 \(next)")
            candidateIndex += 1
            attemptsOnCandidate = 0
            schedule(after: 1.0) { [weak self] in self?.runAttempt() }
        } else {
            abandon(reason: "所有候选都试满了")
        }
    }

    private func abandon(reason: String) {
        guard isActive else { return }
        isActive = false
        settled = true
        cancelPendingWork()
        onAbandon?(reason, candidates)
    }

    private func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) {
        retryWork?.cancel()
        let work = DispatchWorkItem(block: action)
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelPendingWork() {
        retryWork?.cancel()
        retryWork = nil
        watchdogWork?.cancel()
        watchdogWork = nil
    }
}
