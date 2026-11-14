import XCTest
@testable import Beans

final class LyricParserTests: XCTestCase {
    func testDecodedKRCParsesRelativeWordOffsets() {
        let krc = "[3000,1000]<0,400,0>你<400,600,0>好"
        let line = LyricParser.parse("", wordRaw: krc, wordFormat: .kugouKRC).first

        XCTAssertEqual(line?.text, "你好")
        XCTAssertEqual(line?.words?.first?.start ?? -1, 3.0, accuracy: 0.001)
        XCTAssertEqual(line?.words?.dropFirst().first?.start ?? -1, 3.4, accuracy: 0.001)
    }

    func testQishuiKRCUsesTheKugouWordTimelineFormat() {
        let krc = "[290,1530]<0,330,0>我<330,420,0>听"
        let line = LyricParser.parse(krc, wordRaw: krc, wordFormat: .kugouKRC).first

        XCTAssertEqual(line?.text, "我听")
        XCTAssertEqual(line?.time ?? -1, 0.29, accuracy: 0.001)
        XCTAssertEqual(line?.words?.first?.start ?? -1, 0.29, accuracy: 0.001)
    }

    func testPlainLRCKeepsLineFallback() {
        let lines = LyricParser.parse("[00:01.00]plain line\n[00:03.00]next")

        XCTAssertEqual(lines.count, 2)
        XCTAssertNil(lines.first?.words)
    }

    func testKaraokeOpacityInterpolates() {
        let word = LyricWord(text: "歌", start: 10, duration: 2)

        XCTAssertEqual(LyricKaraokeTiming.opacity(for: word, at: 9), 0.28, accuracy: 0.001)
        XCTAssertEqual(LyricKaraokeTiming.opacity(for: word, at: 11), 0.64, accuracy: 0.001)
        XCTAssertEqual(LyricKaraokeTiming.opacity(for: word, at: 12), 1.0, accuracy: 0.001)
    }

    func testSynthesizedWordsSweepEightyEightPercentOfWindow() {
        // 两行行级歌词：第一行 1s→3s（窗口 2s），扫掠应占 1.76s。
        let lines = LyricParser.parse("[00:01.00]你好世界\n[00:03.00]下一行")
        let swept = LyricParser.withSynthesizedWords(lines)

        XCTAssertEqual(swept.count, 2)
        XCTAssertTrue(swept[0].synthesizedWords)
        XCTAssertEqual(swept[0].words?.map(\.text), ["你", "好", "世", "界"])
        XCTAssertEqual(swept[0].words?.first?.start ?? -1, 1.0, accuracy: 0.001)
        let lastEnd = (swept[0].words?.last?.start ?? 0) + (swept[0].words?.last?.duration ?? 0)
        XCTAssertEqual(lastEnd, 1.0 + 2.0 * 0.88, accuracy: 0.001)
        // 末行无下一行：窗口回退为 4s。
        XCTAssertTrue(swept[1].synthesizedWords)
    }
}
