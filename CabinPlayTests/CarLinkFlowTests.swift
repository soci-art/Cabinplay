// SPDX-FileCopyrightText: 2026 CabinPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// CarLinkFlow 纯逻辑测试：候选顺序、同候选重试、命中收手、本机地址失效
// 中止。时间参数全部压到毫秒级，跑起来不到一秒。

import XCTest
@testable import CabinPlay

final class CarLinkFlowTests: XCTestCase {

    private func fastConfig(attempts: Int = 1) -> CarLinkFlow.Config {
        CarLinkFlow.Config(maxAttemptsPerCandidate: attempts,
                           retryGap: 0.02,
                           attemptTimeout: 0.05,
                           budget: 0.5)
    }

    /// 候选依次试完、无一命中 → 整轮放弃，tried 就是全部候选。
    func testWalksAllCandidatesThenAbandons() {
        let flow = CarLinkFlow()
        flow.config = fastConfig(attempts: 1)
        var attempted: [String] = []
        var abandoned: (reason: String, tried: [String])?

        flow.onAttempt = { ip, _ in
            attempted.append(ip)
            return .failed("被拒")
        }
        let done = expectation(description: "abandon")
        flow.onAbandon = { reason, tried in
            abandoned = (reason, tried)
            done.fulfill()
        }
        flow.begin(candidates: ["10.0.0.1", "10.0.0.2"], localIP: "10.0.0.9")

        wait(for: [done], timeout: 2)
        XCTAssertEqual(attempted, ["10.0.0.1", "10.0.0.2"])
        XCTAssertEqual(abandoned?.tried, ["10.0.0.1", "10.0.0.2"])
    }

    /// 同候选先原地重试到上限，再换下一个候选。
    func testRetriesSameCandidateBeforeSwitching() {
        let flow = CarLinkFlow()
        flow.config = fastConfig(attempts: 2)
        var attempted: [String] = []
        flow.onAttempt = { ip, _ in
            attempted.append(ip)
            return .failed("被拒")
        }
        let done = expectation(description: "abandon")
        flow.onAbandon = { _, _ in done.fulfill() }
        flow.begin(candidates: ["10.0.0.1", "10.0.0.2"], localIP: "10.0.0.9")

        wait(for: [done], timeout: 3)
        XCTAssertEqual(attempted, ["10.0.0.1", "10.0.0.1", "10.0.0.2", "10.0.0.2"])
    }

    /// 走到协商/出画就收手：不再重试、不再换候选。
    func testHitStopsTheWalk() {
        let flow = CarLinkFlow()
        flow.config = fastConfig(attempts: 3)
        var attempted = 0
        var hits: [String] = []
        flow.onAttempt = { _, _ in
            attempted += 1
            return .started
        }
        flow.onHit = { ip in hits.append(ip) }
        flow.begin(candidates: ["10.0.0.1", "10.0.0.2"], localIP: "10.0.0.9")

        flow.noteHit()
        XCTAssertFalse(flow.isActive)
        XCTAssertEqual(hits, ["10.0.0.1"])

        // 看门狗到点也不该再判失败（settled 已置位）。
        let settle = expectation(description: "no retry")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settle.fulfill() }
        wait(for: [settle], timeout: 1)
        XCTAssertEqual(attempted, 1)
    }

    /// 本机地址失效：整轮中止，不降档、不再试候选。
    func testLocalAddressInvalidAborts() {
        let flow = CarLinkFlow()
        flow.config = fastConfig(attempts: 2)
        var attempted = 0
        var invalid: String?
        var abandoned = false
        flow.onAttempt = { _, _ in
            attempted += 1
            return .localAddressInvalid("本机地址失效")
        }
        flow.onLocalInvalid = { _, detail in invalid = detail }
        flow.onAbandon = { _, _ in abandoned = true }
        flow.begin(candidates: ["10.0.0.1", "10.0.0.2"], localIP: "10.0.0.9")

        XCTAssertFalse(flow.isActive)
        XCTAssertEqual(attempted, 1)
        XCTAssertEqual(invalid, "本机地址失效")
        XCTAssertFalse(abandoned)
    }

    /// 会话在命中前结束：按失败重试，不会卡在「活跃但不动」。
    func testSessionEndedCountsAsFailure() {
        let flow = CarLinkFlow()
        flow.config = fastConfig(attempts: 2)
        var attempted = 0
        flow.onAttempt = { _, _ in
            attempted += 1
            return .started
        }
        flow.begin(candidates: ["10.0.0.1"], localIP: "10.0.0.9")
        flow.noteSessionEnded()

        let settle = expectation(description: "retry")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { settle.fulfill() }
        wait(for: [settle], timeout: 1)
        XCTAssertEqual(attempted, 2)
    }
}
