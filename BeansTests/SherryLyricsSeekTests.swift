import Foundation
import XCTest
@testable import Sherry

/// 2.2.5 回归：拖动进度条后歌词掉同步（真机 2.2.4：从头播跟得上，
/// 拖动进度条往前跳之后歌词就掉同步）。
///
/// 修复（与诊断 sherry-225-diagnosis.md 对应）：
/// - Rank 2：seek(to:) 同步重锚引擎 + player?.seek 落点 completion 再锚一次
///   （旧目标被新 seek 覆盖时 completion 不生效）；seekPrecisely 落点后同样重锚；
///   落点前观察者不把旧时间喂给引擎（否则同步锚点 50ms 内就被拉回去）。
/// - Rank 1：Apple Music 布局 seekRevision 处理器不再向过期行号 scrollTo，
///   只置 pendingSeekJump，滚动只由重锚后的 currentIndex 变化驱动（与黑胶布局同款）。
/// - Rank 3：stalled 锁存的两条解冻路（显式 setStalled(false) / moved）都要通。
///
/// 引擎层可直接单测；视图层 Rank 1 断言需要 ViewInspector 一类 SwiftUI
/// 测试依赖，仓库没有引入，故此处不做视图层测试（见 testSeek* 的行号断言
/// 覆盖“重锚后行号正确”这一半；滚动本身由 currentIndex 驱动已是既有逻辑）。
final class SherryLyricsSeekTests: XCTestCase {

    private var engine: SherryLyricsSyncEngine!
    private var ticks: [Double] = []

    /// 17 行、每 10s 一行（0…160），音频时长 200s。
    private var lines: [LyricLine] {
        (0...16).map { LyricLine(time: Double($0 * 10), text: "行\($0)") }
    }

    override func setUp() {
        super.setUp()
        engine = SherryLyricsSyncEngine()
        ticks = []
        engine.onTick = { [weak self] pos in self?.ticks.append(pos) }
    }

    override func tearDown() {
        engine.stopTicking()
        engine = nil
        super.tearDown()
    }

    private func assertTickedNear(_ target: Double, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(ticks.contains { abs($0 - target) < 0.5 },
                      "应立即滴答到 \(target) 附近，实际滴答：\(ticks)", file: file, line: line)
    }

    // MARK: - §9-1 前向大跳（播放中，含落点前缓冲冻结）

    func testSeekForwardBigJumpWhilePlaying() {
        engine.setLyrics(lines)
        engine.apply(position: 54, isPlaying: true, duration: 200)
        ticks.removeAll()
        // 落点前缓冲：位置不动，歌词必须继续冻在拖动前锚点。
        engine.setStalled(true)
        engine.apply(position: 54, isPlaying: true, duration: 200)
        engine.apply(position: 54, isPlaying: true, duration: 200)
        XCTAssertEqual(engine.extrapolatedPosition(at: Date()), 54, accuracy: 0.05)
        // 落点：跳变必须立即重锚 + 立即滴答，不等 0.25s 定时器。
        engine.apply(position: 150, isPlaying: true, duration: 200)
        XCTAssertEqual(engine.extrapolatedPosition(at: Date()), 150, accuracy: 0.5)
        assertTickedNear(150)
        XCTAssertEqual(SherryLyricsSyncEngine.lineIndex(forPosition: 150, in: lines), 15)
    }

    // MARK: - §9-2 后向跳（播放中）

    func testSeekBackwardJumpWhilePlaying() {
        engine.setLyrics(lines)
        engine.apply(position: 150, isPlaying: true, duration: 200)
        ticks.removeAll()
        engine.apply(position: 30, isPlaying: true, duration: 200)
        XCTAssertEqual(engine.extrapolatedPosition(at: Date()), 30, accuracy: 0.5)
        assertTickedNear(30)
        XCTAssertEqual(SherryLyricsSyncEngine.lineIndex(forPosition: 30, in: lines), 3)
    }

    // MARK: - §9-3 小跳（<2s 阈值，无立即跳变滴答，但锚点已更新）

    func testSeekSmallJumpUpdatesAnchorWithoutImmediateJumpTick() {
        engine.setLyrics(lines)
        engine.apply(position: 54, isPlaying: true, duration: 200)
        ticks.removeAll()
        engine.apply(position: 55.5, isPlaying: true, duration: 200)
        XCTAssertEqual(engine.extrapolatedPosition(at: Date()), 55.5, accuracy: 0.5)
        // 250ms 内定时器必须从新锚点外推发出 ≥55.5 的位置。
        let expectation = expectation(description: "定时器从新锚点继续滴答")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { expectation.fulfill() }
        wait(for: [expectation], timeout: 2.0)
        XCTAssertTrue(ticks.contains { $0 >= 55.4 }, "小跳后定时器应从 55.5 外推，实际滴答：\(ticks)")
    }

    // MARK: - §9-4 暂停中 seek

    func testSeekWhilePausedJumpsImmediately() {
        engine.setLyrics(lines)
        engine.apply(position: 54, isPlaying: true, duration: 200)
        engine.apply(position: 54, isPlaying: false, duration: 200)
        ticks.removeAll()
        // 暂停着拖动：高亮应立即跳到新行，不等恢复播放。
        engine.apply(position: 120, isPlaying: false, duration: 200)
        assertTickedNear(120)
        XCTAssertEqual(engine.extrapolatedPosition(at: Date()), 120, accuracy: 0.5)
        XCTAssertEqual(SherryLyricsSyncEngine.lineIndex(forPosition: 120, in: lines), 12)
        // 恢复播放：定时器已停（模拟 pausePlayback 的 stopTicking）时必须重建并继续滴答。
        engine.stopTicking()
        ticks.removeAll()
        engine.apply(position: 120, isPlaying: true, duration: 200)
        let expectation = expectation(description: "恢复播放后定时器继续滴答")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { expectation.fulfill() }
        wait(for: [expectation], timeout: 2.0)
        XCTAssertTrue((ticks.max() ?? 0) >= 120.2, "恢复播放后应继续从 120 外推滴答，实际滴答：\(ticks)")
    }

    // MARK: - §9-5 缓冲中 seek（落点慢）：两条解冻路都要通

    func testSeekDuringBufferingUnfreezesOnExplicitUnstall() {
        engine.setLyrics(lines)
        engine.apply(position: 54, isPlaying: true, duration: 200)
        engine.setStalled(true)
        engine.apply(position: 54, isPlaying: true, duration: 200)
        engine.apply(position: 54, isPlaying: true, duration: 200)
        XCTAssertEqual(engine.extrapolatedPosition(at: Date().addingTimeInterval(2)), 54, accuracy: 0.05)
        // 数据到了：status 回 playing 显式清 stalled + 观察者报新位置。
        engine.setStalled(false)
        ticks.removeAll()
        engine.apply(position: 150, isPlaying: true, duration: 200)
        XCTAssertEqual(engine.extrapolatedPosition(at: Date()), 150, accuracy: 0.5)
        assertTickedNear(150)
    }

    func testSeekDuringBufferingUnfreezesViaMovedWithoutExplicitUnstall() {
        engine.setLyrics(lines)
        engine.apply(position: 54, isPlaying: true, duration: 200)
        engine.setStalled(true)
        engine.apply(position: 54, isPlaying: true, duration: 200)
        ticks.removeAll()
        // 反向用例：不给 setStalled(false)，只给新位置 —— moved 路径
        // 同样必须解冻并立即发出新位置（2.2.4 的 moved 解冻 + 2.2.5 的
        // 落点重锚缺一不可，否则缓冲后歌词永久冻在旧锚点）。
        engine.apply(position: 150, isPlaying: true, duration: 200)
        assertTickedNear(150)
        XCTAssertEqual(engine.extrapolatedPosition(at: Date().addingTimeInterval(1)), 151, accuracy: 0.3)
    }

    // MARK: - §9-6 连续拖动/多次 seek：旧目标不得残留

    func testConsecutiveSeeksOnlyLatestTargetSurvives() {
        engine.setLyrics(lines)
        engine.apply(position: 54, isPlaying: true, duration: 200)
        ticks.removeAll()
        // seek 120 发出但未落点：观察者仍报旧位置 54。
        engine.apply(position: 54, isPlaying: true, duration: 200)
        engine.apply(position: 54, isPlaying: true, duration: 200)
        // 改目标 90，仍未落点。
        engine.apply(position: 54, isPlaying: true, duration: 200)
        // 落在 90：最终锚点必须是 90，120 不得残留。
        engine.apply(position: 90, isPlaying: true, duration: 200)
        XCTAssertEqual(engine.extrapolatedPosition(at: Date()), 90, accuracy: 0.5)
        assertTickedNear(90)
        XCTAssertFalse(ticks.contains { abs($0 - 120) < 0.5 }, "旧目标 120 不得出滴答，实际滴答：\(ticks)")
        XCTAssertEqual(SherryLyricsSyncEngine.lineIndex(forPosition: 90, in: lines), 9)
    }

    // MARK: - §9-8 无歌词 song 的 seek：保持诚实的无歌词态

    func testSeekWithNoLyricsKeepsNoLyricsState() {
        // 不设歌词（lines=[]）：seek 前后都不应凭空出现一行。
        engine.apply(position: 54, isPlaying: true, duration: 200)
        engine.apply(position: 150, isPlaying: true, duration: 200)
        XCTAssertTrue(engine.lines.isEmpty)
        XCTAssertNil(SherryLyricsSyncEngine.lineIndex(forPosition: 150, in: engine.lines))
        XCTAssertEqual(engine.extrapolatedPosition(at: Date()), 150, accuracy: 0.5)
    }
}
