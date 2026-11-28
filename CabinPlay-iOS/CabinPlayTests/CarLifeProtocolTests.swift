// SPDX-FileCopyrightText: 2026 CabinPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// CarLife 协议层的离线自检：没有车机时，至少把帧头拼装/拆包与 protobuf
// 读写这两件最容易「看起来很对、实际一字节错」的事测住。

import XCTest
@testable import CabinPlay

final class CarLifeProtocolTests: XCTestCase {

    func testCommandChannelRoundTrip() throws {
        let message = CarLifeMessage(channel: 1, id: 65_540, payload: Data([0x0A, 0x03, 0x41, 0x42, 0x43]))
        var buffer = try CarLifeFraming.encode(message)
        let parsed = try CarLifeFraming.take(from: &buffer, channel: 1)
        XCTAssertEqual(parsed?.id, 65_540)
        XCTAssertEqual(parsed?.channel, 1)
        XCTAssertEqual(parsed?.payload, message.payload)
        XCTAssertTrue(buffer.isEmpty, "整帧应全部消费")
    }

    func testVideoChannelRoundTripKeepsLongPayload() throws {
        let payload = Data((0..<3000).map { UInt8($0 % 251) })
        let message = CarLifeMessage(channel: 2, id: 131_073, payload: payload)
        var buffer = try CarLifeFraming.encode(message)
        let parsed = try CarLifeFraming.take(from: &buffer, channel: 2)
        XCTAssertEqual(parsed?.id, 131_073)
        XCTAssertEqual(parsed?.payload.count, payload.count)
        XCTAssertTrue(buffer.isEmpty)
    }

    func testIncompleteFrameIsLeftInBuffer() throws {
        let message = CarLifeMessage(channel: 1, id: 65_611, payload: Data(repeating: 7, count: 64))
        let full = try CarLifeFraming.encode(message)
        var buffer = full.prefix(full.count - 10)
        XCTAssertNil(try CarLifeFraming.take(from: &buffer, channel: 1), "缺字节时不应产出半帧")
        XCTAssertEqual(buffer.count, full.count - 10, "缺字节时必须原样留在缓冲里等下一批")
    }

    func testProtoRoundTrip() throws {
        let writer = CarLifeProtoWriter().text(1, "Android").number(2, 4).text(4, "CabinPlay")
        let parsed = try CarLifeProto(parsing: writer.data)
        XCTAssertEqual(parsed.text(1), "Android")
        XCTAssertEqual(parsed.number(2), 4)
        XCTAssertEqual(parsed.text(4), "CabinPlay")
    }
}
