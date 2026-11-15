import Foundation
import XCTest
@testable import Sherry

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

    func testWordTimingTagsNeverReachRenderedText() {
        // 2.2.2 真机复现：酷我 lrcx 行 "[01:19.050]<3780,-3780>慌<5610,-1410>啥…"
        // 经缓存重载走纯 LRC 路径时，标签原样进了渲染。
        let tagged = "[01:19.050]<3780,-3780>慌<5610,-1410>啥<4860,3240>子<12060,-3060>嘛"
        let lines = LyricParser.parse(tagged)

        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.text, "慌啥子嘛")
        XCTAssertFalse(lines.first?.text.contains("<") ?? true)
        XCTAssertFalse(lines.first?.text.contains(">") ?? true)
    }

    func testKRCWordMarkersAcceptNegativeTimings() {
        // 负时长是合法编码（和/差变换的中间值），解析时钳制，不丢整行。
        let krc = "[79050,5000]<3780,-3780,0>慌<5610,-1410,0>啥"
        let line = LyricParser.parse("", wordRaw: krc, wordFormat: .kugouKRC).first

        XCTAssertEqual(line?.text, "慌啥")
        XCTAssertNotNil(line?.words)
        XCTAssertTrue(line?.words?.allSatisfy { $0.start >= 0 && $0.duration >= 0.001 } ?? false)
    }

    func testKuwoCacheRoundTripKeepsWordsAndCleanText() {
        // 2.2.3 缓存形状：lrc 去标签、krc 存带标签原文；重载走 kuwo 分支。
        let raw = "[kuwo:073]\n[01:19.050]<3780,-3780>慌<5610,-1410>啥"
        let plain = raw.replacingOccurrences(
            of: #"<-?\d+,-?\d+(?:,-?\d+)?>"#, with: "", options: .regularExpression
        )
        let cache = SherryLyricsCache(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true))
        let document = SherryLyricDocument(
            source: .kuwo, timing: .wordSynced,
            lines: LyricParser.parse(plain, wordRaw: raw, wordFormat: .kuwo),
            title: "慌啥子嘛", artists: ["赵本山"], album: nil, durationMs: 260_000,
            rawLRC: plain, rawKRC: raw
        )
        let key = SherryLyricsCache.key(trackSignature: "test-kuwo-roundtrip")
        cache.store(document: document, key: key)
        guard let hit = cache.lookup(key: key) else {
            return XCTFail("缓存未命中")
        }
        let lines = SherryLyricsService.parseCached(lrc: hit.lrc, krc: hit.krc, source: hit.source)

        XCTAssertEqual(lines.first?.text, "慌啥")
        XCTAssertFalse(lines.first?.text.contains("<") ?? true)
        XCTAssertFalse(lines.first?.text.contains(">") ?? true)
        XCTAssertTrue(lines.first?.hasWordTimings ?? false)
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
