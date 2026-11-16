import Foundation
import XCTest
@testable import Sherry

/// 2.2.4 回归：时长/覆盖率拒收门、跨源固定偏移三角测量、finalize 停掉
/// 假逐字扫掠、同步引擎卡顿冻结。探针数值见 /tmp/sherry224-bulk：
/// 慌啥子嘛 189s 歌词 vs 260s 音频（覆盖率 63.5%）、消愁 18 行/87s
/// 片段 vs 294s 音频、健康歌覆盖率 ≥80.5%（海阔天空 257.5/320s）。
final class SherryLyricsGateTests: XCTestCase {

    // MARK: - 拒收门

    private func doc(lines: [LyricLine], source: SherryLyricDocument.Source = .kugou,
                     durationMs: Int? = nil) -> SherryLyricDocument {
        SherryLyricDocument(
            source: source, timing: .synced, lines: lines,
            title: "测试", artists: ["测试歌手"], album: nil,
            durationMs: durationMs, rawLRC: "", rawKRC: nil
        )
    }

    private func timedLines(count: Int, last: Double) -> [LyricLine] {
        guard count > 1 else { return [LyricLine(time: last, text: "末行")] }
        return (0..<count).map { i in
            LyricLine(time: last * Double(i) / Double(count - 1), text: "行\(i)")
        }
    }

    func testHuangShaZiMa189sLyricRejectedAgainst260sAudio() {
        // 探针：58 行、末行 165.09s，音频 260s，覆盖率 63.5% < 75%。
        let document = doc(lines: timedLines(count: 58, last: 165.09), durationMs: 189_000)
        let reason = SherryLyricsMatcher.rejectionReason(for: document, audioDurationMs: 260_000)
        XCTAssertNotNil(reason, "189s 版歌词配 260s 音频必须拒收")
        XCTAssertTrue(reason?.contains("覆盖率") ?? false, reason ?? "")
    }

    func testXiaoChouFragmentRejected() {
        // 探针：18 行、末行 87s 的副歌片段，音频 294s，覆盖率 29.6%。
        let document = doc(lines: timedLines(count: 18, last: 87), durationMs: 87_000)
        XCTAssertNotNil(SherryLyricsMatcher.rejectionReason(for: document, audioDurationMs: 294_000))
    }

    func testHealthySongsPassCoverageGate() {
        // 探针健康歌：海阔天空 257.498/320s、起风了 271.423/326s、稻香 189.483/223s。
        XCTAssertNil(SherryLyricsMatcher.rejectionReason(
            for: doc(lines: timedLines(count: 49, last: 257.498)), audioDurationMs: 320_000))
        XCTAssertNil(SherryLyricsMatcher.rejectionReason(
            for: doc(lines: timedLines(count: 72, last: 271.423)), audioDurationMs: 326_000))
        XCTAssertNil(SherryLyricsMatcher.rejectionReason(
            for: doc(lines: timedLines(count: 48, last: 189.483)), audioDurationMs: 223_000))
    }

    func testDurationErrorGateRejectsWrongVersionEvenWithGoodCoverage() {
        // 行时间本身够长（覆盖率 96%），但版本时长 189s vs 音频 260s 差 71s。
        let document = doc(lines: timedLines(count: 58, last: 250), durationMs: 189_000)
        XCTAssertNotNil(SherryLyricsMatcher.rejectionReason(for: document, audioDurationMs: 260_000))
    }

    func testDurationGateIsLenientForDifferentCuts() {
        // 稻香：203s 候选 vs 223s 音频（差 20s，< max(30s, 25%)），覆盖率也过关。
        let document = doc(lines: timedLines(count: 48, last: 189.483), durationMs: 203_000)
        XCTAssertNil(SherryLyricsMatcher.rejectionReason(for: document, audioDurationMs: 223_000))
    }

    func testUnknownDurationIsNotRejected() {
        // 酷狗候选 duration=0 / 缺失 = 未知，只靠覆盖率门判。
        let lines = timedLines(count: 49, last: 257.498)
        XCTAssertNil(SherryLyricsMatcher.rejectionReason(
            for: doc(lines: lines, durationMs: 0), audioDurationMs: 320_000))
        XCTAssertNil(SherryLyricsMatcher.rejectionReason(
            for: doc(lines: lines, durationMs: nil), audioDurationMs: 320_000))
    }

    func testLyricLongerThanAudioIsRejected() {
        XCTAssertNotNil(SherryLyricsMatcher.rejectionReason(
            for: doc(lines: timedLines(count: 40, last: 250)), audioDurationMs: 200_000))
    }

    func testTooFewLinesRejected() {
        XCTAssertNotNil(SherryLyricsMatcher.rejectionReason(
            for: doc(lines: timedLines(count: 3, last: 80)), audioDurationMs: 100_000))
    }

    // MARK: - 三角测量

    private func triangDoc(source: SherryLyricDocument.Source, times: [Double],
                           worded: Bool, extraLast: Double? = nil) -> SherryLyricDocument {
        let texts = ["第一行", "第二行", "第三行", "第四行", "第五行", "第六行"]
        var lines = zip(texts, times).map { text, time in
            LyricLine(time: time, text: text,
                      words: worded ? [LyricWord(text: text, start: time, duration: 1)] : nil)
        }
        if let extraLast {
            lines.append(LyricLine(time: extraLast, text: "尾声",
                                   words: worded ? [LyricWord(text: "尾声", start: extraLast, duration: 1)] : nil))
        }
        return SherryLyricDocument(
            source: source, timing: worded ? .wordSynced : .synced, lines: lines,
            title: "测试", artists: ["测试歌手"], album: nil,
            durationMs: nil, rawLRC: "", rawKRC: nil
        )
    }

    func testTriangulationXiaoXingYunPicksConsensusOverKuwoOutlier() {
        // 探针：酷我比酷狗≈LRCLIB 早 3.1s；酷我靠多一行尾声排到首选。
        let kuwo = triangDoc(source: .kuwo, times: [6.9, 16.9, 26.9, 36.9, 46.9, 56.9], worded: true, extraLast: 62)
        let kugou = triangDoc(source: .kugou, times: [10, 20, 30, 40, 50, 60], worded: true)
        let lrclib = triangDoc(source: .lrclib, times: [10, 20, 30, 40, 50, 60], worded: false)
        let result = SherryLyricsMatcher.triangulate(documents: [kuwo, kugou, lrclib], audioDurationMs: 100_000)
        XCTAssertEqual(result.chosen.source, .kugou)
        XCTAssertEqual(result.outlier?.source, .kuwo)
        XCTAssertNil(result.appliedOffsetSeconds, "共识源带逐字时直接换源，不平移")
    }

    func testTriangulationDaoXiangPicksConsensusOverKugouOutlier() {
        // 探针：酷狗 KRC 比酷我≈LRCLIB 早 4.2s；酷狗靠多一行尾声排到首选。
        let kugou = triangDoc(source: .kugou, times: [5.8, 15.8, 25.8, 35.8, 45.8, 55.8], worded: true, extraLast: 62)
        let kuwo = triangDoc(source: .kuwo, times: [10, 20, 30, 40, 50, 60], worded: true)
        let lrclib = triangDoc(source: .lrclib, times: [10, 20, 30, 40, 50, 60], worded: false)
        let result = SherryLyricsMatcher.triangulate(documents: [kugou, kuwo, lrclib], audioDurationMs: 100_000)
        XCTAssertEqual(result.chosen.source, .kuwo)
        XCTAssertEqual(result.outlier?.source, .kugou)
    }

    func testTriangulationShiftsWordedOutlierWhenConsensusIsLineLevelOnly() {
        // 共识源只有行级：保留离群者的逐字，整体平移 +3.1s。
        let kuwo = triangDoc(source: .kuwo, times: [6.9, 16.9, 26.9, 36.9, 46.9, 56.9], worded: true, extraLast: 62)
        let kugou = triangDoc(source: .kugou, times: [10, 20, 30, 40, 50, 60], worded: false)
        let lrclib = triangDoc(source: .lrclib, times: [10, 20, 30, 40, 50, 60], worded: false)
        let result = SherryLyricsMatcher.triangulate(documents: [kuwo, kugou, lrclib], audioDurationMs: 100_000)
        XCTAssertEqual(result.chosen.source, .kuwo)
        XCTAssertEqual(result.appliedOffsetSeconds ?? 0, 3.1, accuracy: 0.05)
        XCTAssertEqual(result.chosen.lines.first?.time ?? -1, 10.0, accuracy: 0.05)
        XCTAssertEqual(result.chosen.lines.first?.words?.first?.start ?? -1, 10.0, accuracy: 0.05)
        XCTAssertTrue(result.chosen.lines.first?.hasWordTimings ?? false, "逐字要保留")
    }

    func testTriangulationHealthySongsStayUnchanged() {
        // 探针：晴天源间偏移 ≤0.4s、海阔天空 ≤1.2s —— 共识内不动。
        let kugou = triangDoc(source: .kugou, times: [10, 20, 30, 40, 50, 60], worded: true)
        let kuwo = triangDoc(source: .kuwo, times: [10.4, 20.4, 30.4, 40.4, 50.4, 60.4], worded: true)
        let lrclib = triangDoc(source: .lrclib, times: [9.8, 19.8, 29.8, 39.8, 49.8, 59.8], worded: false)
        let result = SherryLyricsMatcher.triangulate(documents: [kugou, kuwo, lrclib], audioDurationMs: 100_000)
        XCTAssertEqual(result.chosen.source, .kugou)
        XCTAssertNil(result.outlier)
        XCTAssertNil(result.appliedOffsetSeconds)
    }

    func testTriangulationWithTwoSourcesCannotJudge() {
        // 只有两源时无法判断谁错：保守不动，首选照旧。
        let kuwo = triangDoc(source: .kuwo, times: [6.9, 16.9, 26.9, 36.9, 46.9, 56.9], worded: true, extraLast: 62)
        let kugou = triangDoc(source: .kugou, times: [10, 20, 30, 40, 50, 60], worded: true)
        let result = SherryLyricsMatcher.triangulate(documents: [kuwo, kugou], audioDurationMs: 100_000)
        XCTAssertEqual(result.chosen.source, .kuwo)
        XCTAssertNil(result.outlier)
    }

    // MARK: - finalize：行级歌词不再合成假逐字

    func testFinalizeLineLevelHasNoSynthesizedWords() {
        let lines = LyricParser.parse("[00:01.00]你好世界\n[00:03.00]下一行")
        let finalized = SherryLyricsService.finalize(lines: lines, timing: .synced)
        XCTAssertTrue(finalized.allSatisfy { $0.words == nil })
        XCTAssertTrue(finalized.allSatisfy { !$0.synthesizedWords })
    }

    func testFinalizeKeepsRealWordTimings() {
        let krc = "[3000,1000]<0,400,0>你<400,600,0>好"
        let lines = LyricParser.parse("", wordRaw: krc, wordFormat: .kugouKRC)
        let finalized = SherryLyricsService.finalize(lines: lines, timing: .wordSynced)
        XCTAssertTrue(finalized.first?.hasWordTimings ?? false)
        XCTAssertEqual(finalized.first?.words?.first?.start ?? -1, 3.0, accuracy: 0.001)
    }

    // MARK: - 截图行：酷我词标记仍解析出有效逐字（2.2.3 防线保持）

    func testKuwoScreenshotLineParsesToValidWords() {
        // 截图像素：慌啥子嘛 0:54 行「别把所有压力自己背」，别 52.980/0.480 … 背 55.800/0.750。
        let raw = "[kuwo:073]\n[00:52.980]<4320,-4320>别<6180,-1380>把<6660,2340>所<7860,3540>有<9600,4200>压<9750,7050>力<14010,4290>自<15510,8490>己<20850,7350>背"
        let plain = raw.replacingOccurrences(
            of: #"<-?\d+,-?\d+(?:,-?\d+)?>"#, with: "", options: .regularExpression
        )
        let lines = LyricParser.parse(plain, wordRaw: raw, wordFormat: .kuwo)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.text, "别把所有压力自己背")
        XCTAssertEqual(lines.first?.words?.count, 9)
        XCTAssertEqual(lines.first?.words?.first?.start ?? -1, 52.98, accuracy: 0.01)
        XCTAssertEqual(lines.first?.words?.last?.start ?? -1, 55.80, accuracy: 0.01)
        XCTAssertTrue(lines.first?.words?.allSatisfy { $0.start >= 0 && $0.duration >= 0.001 } ?? false)
    }

    // MARK: - 同步引擎：卡顿冻结与定时器自愈

    func testStalledSurvivesFrozenObserverCallbacks() {
        let engine = SherryLyricsSyncEngine()
        engine.setLyrics([LyricLine(time: 0, text: "a"), LyricLine(time: 10, text: "b")])
        engine.apply(position: 10, isPlaying: true, duration: 100)
        engine.setStalled(true)
        // 缓冲期间观察者照常回调，但位置冻住：歌词必须继续冻在锚点。
        engine.apply(position: 10, isPlaying: true, duration: 100)
        engine.apply(position: 10, isPlaying: true, duration: 100)
        XCTAssertEqual(engine.extrapolatedPosition(at: Date().addingTimeInterval(2)), 10, accuracy: 0.05)
        engine.stopTicking()
    }

    func testStalledClearsWhenAudioAdvances() {
        let engine = SherryLyricsSyncEngine()
        engine.setLyrics([LyricLine(time: 0, text: "a"), LyricLine(time: 10, text: "b")])
        engine.apply(position: 10, isPlaying: true, duration: 100)
        engine.setStalled(true)
        engine.apply(position: 10.5, isPlaying: true, duration: 100)
        XCTAssertEqual(engine.extrapolatedPosition(at: Date().addingTimeInterval(1)), 11.5, accuracy: 0.3)
        engine.stopTicking()
    }

    func testApplyRestartsDeadTimerWhilePlaying() {
        let engine = SherryLyricsSyncEngine()
        engine.setLyrics([LyricLine(time: 0, text: "a"), LyricLine(time: 30, text: "b")])
        var tickCount = 0
        engine.onTick = { _ in tickCount += 1 }
        engine.apply(position: 5, isPlaying: true, duration: 100)
        let countAfterApply = tickCount
        XCTAssertGreaterThan(countAfterApply, 0, "跳变锚定应立即滴答一次")
        engine.stopTicking()
        // 定时器已死、播放中再来一次观察者回调：必须自愈重建，否则稳态停摆。
        // startTicking 本身会立即滴答一次，先记下这次，再等 0.6s 看定时器
        // 是否继续滴答（0.25s 间隔，0.6s 内应至少再滴答两次）。
        engine.apply(position: 6, isPlaying: true, duration: 100)
        let countAfterRestart = tickCount
        let expectation = expectation(description: "重建的定时器继续滴答")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if tickCount > countAfterRestart { expectation.fulfill() }
        }
        wait(for: [expectation], timeout: 2.0)
        engine.stopTicking()
    }
}
