import Foundation
import XCTest
@testable import Sherry

/// 2.2.6 回归：17:49 全局「暂无歌词」后的证据化加固。
///
/// 诊断结论（四分片一致）：2.2.5 没有一行代码能解释全局黑掉 —— 拒收门、
/// 取词/缓存、diff/UI 全部无罪；最可能的解释是瞬时全源失败 + 5 分钟负缓存
/// 连锁，以及抓取时 song.duration 未就绪导致酷狗只返回短版碎片。
/// 本文件锁住 2.2.6 的六处修复（F1–F6），探针数值取自 2026-11-16 实测
/// （/tmp/sherry-226-probe/SUMMARY.md）与 2.2.4 探针留档值。
/// 注意：CI 单测不跑真实网络 —— 三源正文用探针文档代替，断言的是
/// 门 → 三角测量 → 缓存 → 读取这条链路本身，以及失败分类/负缓存决策
/// 这些纯函数；网络层行为由日志分类（歌词结果：分类=…）在真机上验证。
final class SherryLyricsRecoveryTests: XCTestCase {

    private var tempDir: URL!
    private var tempCache: SherryLyricsCache!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sherry-recovery-test-\(UUID().uuidString)")
        tempCache = SherryLyricsCache(directory: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        tempCache = nil
        super.tearDown()
    }

    // MARK: - 探针文档构造

    private func song(name: String, artist: String, duration: TimeInterval) -> Song {
        Song(id: abs(name.hashValue) % 1_000_000 + 1, name: name, artists: artist,
             album: "", coverURL: nil, duration: duration, source: .kugou)
    }

    /// 行时间直接构造的文档（门/三角测量用，行文本 "行i" 保证跨源同名行可配对）。
    private func timedDoc(source: SherryLyricDocument.Source, count: Int, last: Double,
                          durationMs: Int?) -> SherryLyricDocument {
        guard count > 1 else {
            return SherryLyricDocument(source: source, timing: .synced,
                                       lines: [LyricLine(time: last, text: "行0")],
                                       title: "测试", artists: ["测试歌手"], album: nil,
                                       durationMs: durationMs, rawLRC: "", rawKRC: nil)
        }
        let lines = (0..<count).map { i in
            LyricLine(time: last * Double(i) / Double(count - 1), text: "行\(i)")
        }
        return SherryLyricDocument(source: source, timing: .synced, lines: lines,
                                   title: "测试", artists: ["测试歌手"], album: nil,
                                   durationMs: durationMs, rawLRC: "", rawKRC: nil)
    }

    /// 从 LRC 文本解析的文档（缓存往返用，rawLRC 必须能重新解析出同样的行）。
    /// 首行从 1.0s 起（避开解析器对 0 时刻行的任何特殊处理），末行精确等于 last。
    private func lrcDoc(source: SherryLyricDocument.Source, count: Int, last: Double,
                        durationMs: Int?, title: String, artist: String) -> SherryLyricDocument {
        let text = (0..<count).map { i in
            let t = count > 1 ? 1.0 + (last - 1.0) * Double(i) / Double(count - 1) : last
            return String(format: "[%02d:%05.2f]行%d", Int(t / 60),
                          t.truncatingRemainder(dividingBy: 60), i)
        }.joined(separator: "\n")
        let lines = LyricParser.parse(text)
        XCTAssertEqual(lines.count, count, "LRC 文本应解析出 \(count) 行")
        return SherryLyricDocument(source: source, timing: .synced, lines: lines,
                                   title: title, artists: [artist], album: nil,
                                   durationMs: durationMs, rawLRC: text, rawKRC: nil)
    }

    // MARK: - F6：健康歌端到端（门 → 三角测量 → 缓存 → 读取），错版仍拒收

    func testHealthyLyricsPassGateTriangulationCacheAndRead() {
        // 探针（2026-11-16）：小幸运三源文档，音频 264s。
        let kugou = timedDoc(source: .kugou, count: 44, last: 239.4, durationMs: 263_862)
        let kuwo = timedDoc(source: .kuwo, count: 44, last: 239.413, durationMs: 263_000)
        let lrclib = timedDoc(source: .lrclib, count: 45, last: 250.63, durationMs: 265_000)
        for doc in [kugou, kuwo, lrclib] {
            XCTAssertNil(SherryLyricsMatcher.rejectionReason(for: doc, audioDurationMs: 264_000),
                         "\(doc.source) 健康文档必须过门")
        }
        let result = SherryLyricsMatcher.triangulate(documents: [kugou, kuwo, lrclib],
                                                     audioDurationMs: 264_000)
        XCTAssertFalse(result.chosen.lines.isEmpty, "三角测量必须选出非空文档")
        XCTAssertEqual(result.chosen.lines.count, 45, "三源首选是 LRCLIB（覆盖率最高），平移与否都不丢行")
        let ratio = SherryLyricsMatcher.coverageRatio(of: result.chosen, audioDurationMs: 264_000)
        XCTAssertNotNil(ratio)
        XCTAssertTrue((ratio ?? 0) >= 0.75 && (ratio ?? 0) <= 1.20, "选用文档覆盖率必须在门内，实际 \(ratio ?? -1)")

        // 其余健康歌同样过门（2.2.4 探针 + 11-16 实测）：
        // 稻香 189.483/223s、海阔天空 257.498/320s、晴天 262.182/269s。
        XCTAssertNil(SherryLyricsMatcher.rejectionReason(
            for: timedDoc(source: .kugou, count: 48, last: 189.483, durationMs: 222_563),
            audioDurationMs: 223_000))
        XCTAssertNil(SherryLyricsMatcher.rejectionReason(
            for: timedDoc(source: .kugou, count: 49, last: 257.498, durationMs: 322_000),
            audioDurationMs: 320_000))
        XCTAssertNil(SherryLyricsMatcher.rejectionReason(
            for: timedDoc(source: .kugou, count: 52, last: 262.182, durationMs: 265_072),
            audioDurationMs: 269_000))

        // 错版仍诚实拒收（门没有被放宽）：消愁酷狗短版 151.24/294s、
        // 慌啥子嘛 165.09/260s。
        XCTAssertNotNil(SherryLyricsMatcher.rejectionReason(
            for: timedDoc(source: .kugou, count: 33, last: 151.24, durationMs: 179_382),
            audioDurationMs: 294_000), "消愁 179s 短版必须拒收")
        XCTAssertNotNil(SherryLyricsMatcher.rejectionReason(
            for: timedDoc(source: .kugou, count: 58, last: 165.09, durationMs: 189_000),
            audioDurationMs: 260_000), "慌啥子嘛 189s 版必须拒收")
    }

    func testHealthyLyricsCacheRoundTrip() {
        // 三源时间接近（无离群者）时三角测量不动首选：酷狗 44 行/239.4s。
        let kugou = timedDoc(source: .kugou, count: 44, last: 239.4, durationMs: 263_862)
        let kuwo = timedDoc(source: .kuwo, count: 44, last: 239.413, durationMs: 263_000)
        let lrclib = timedDoc(source: .lrclib, count: 44, last: 239.8, durationMs: 265_000)
        let result = SherryLyricsMatcher.triangulate(documents: [kugou, kuwo, lrclib],
                                                     audioDurationMs: 264_000)
        XCTAssertEqual(result.chosen.source, .kugou, "共识内不动，源优先级酷狗第一")
        XCTAssertNil(result.outlier)
        XCTAssertNil(result.appliedOffsetSeconds)

        // 缓存往返：存入三角测量选出的文档（LRC 文本版），再读出来必须一样。
        let doc = lrcDoc(source: .kugou, count: 44, last: 239.4, durationMs: 263_862,
                         title: "小幸运", artist: "田馥甄")
        let song = self.song(name: "小幸运", artist: "田馥甄", duration: 264)
        let key = SherryLyricsService.cacheKey(for: song)
        tempCache.store(document: doc, key: key, identityKey: song.identityKey)
        let readBack = SherryLyricsService.cachedLinesSync(for: song, cache: tempCache)
        XCTAssertEqual(readBack?.count, 44, "缓存读回的行数必须与存入一致")
        XCTAssertEqual(readBack?.last?.time ?? -1, 239.4, accuracy: 0.05)
        XCTAssertEqual(readBack?.first?.text, "行0")
    }

    // MARK: - F1：网络全失败不写负缓存（分类 + 决策矩阵）

    func testOutcomeClassificationMatrix() {
        XCTAssertEqual(SherryLyricsService.classifyOutcome(hasSurvivors: true, sawCandidate: false, sawDocument: false), .selected)
        XCTAssertEqual(SherryLyricsService.classifyOutcome(hasSurvivors: false, sawCandidate: false, sawDocument: false), .networkFailure)
        XCTAssertEqual(SherryLyricsService.classifyOutcome(hasSurvivors: false, sawCandidate: true, sawDocument: false), .noCandidates)
        XCTAssertEqual(SherryLyricsService.classifyOutcome(hasSurvivors: false, sawCandidate: true, sawDocument: true), .gateRejectedAll)
    }

    func testNetworkTotalFailureWritesNoNegativeCache() {
        // 一个候选都没拿到 = 全源网络层失败：不写负缓存，下次播放直接重抓。
        XCTAssertEqual(SherryLyricsService.negativeCacheDecision(outcome: .networkFailure, hasKeptPositiveEntry: false), .skip)
        XCTAssertEqual(SherryLyricsService.negativeCacheDecision(outcome: .networkFailure, hasKeptPositiveEntry: true), .skip)
        // 候选已取到但被拒收/无正文：才写 5 分钟暂存负缓存。
        XCTAssertEqual(SherryLyricsService.negativeCacheDecision(outcome: .gateRejectedAll, hasKeptPositiveEntry: false), .transient)
        XCTAssertEqual(SherryLyricsService.negativeCacheDecision(outcome: .noCandidates, hasKeptPositiveEntry: false), .transient)
        // F3：复检保留的旧正缓存还在时，负缓存绝不能覆盖它。
        XCTAssertEqual(SherryLyricsService.negativeCacheDecision(outcome: .gateRejectedAll, hasKeptPositiveEntry: true), .skip)
        XCTAssertEqual(SherryLyricsService.negativeCacheDecision(outcome: .noCandidates, hasKeptPositiveEntry: true), .skip)
    }

    // MARK: - F2：酷狗碎片全拒后，酷我/LRCLIB 仍能顶上；时长未知不传假时长

    func testKugouFragmentsFallThroughToKuwoAndLrclib() async {
        // 消愁：酷狗 10 个候选全是 160–179s 短版（探针），全部被拒收；
        // 酷我 Live 293s 与 LRCLIB 294s 必须顶上（后者余量最薄 77.0%）。
        let service = SherryLyricsService.shared
        let song = self.song(name: "消愁", artist: "毛不易", duration: 294)
        let fragments = [
            timedDoc(source: .kugou, count: 33, last: 151.24, durationMs: 179_382),
            timedDoc(source: .kugou, count: 33, last: 151.24, durationMs: 179_382),
            timedDoc(source: .kugou, count: 26, last: 146.6, durationMs: 179_049),
        ]
        for fragment in fragments {
            let kept = await service.gated(fragment, song: song, durationMs: 294_000)
            XCTAssertNil(kept, "酷狗短版碎片必须被拒收，且只丢该候选、不中断后续源")
        }
        let kuwo = timedDoc(source: .kuwo, count: 68, last: 245.13, durationMs: 293_000)
        XCTAssertNotNil(await service.gated(kuwo, song: song, durationMs: 294_000),
                        "酷我 293s Live 版必须顶上")
        let lrclib = timedDoc(source: .lrclib, count: 41, last: 226.47, durationMs: 294_000)
        XCTAssertNotNil(await service.gated(lrclib, song: song, durationMs: 294_000),
                        "LRCLIB 294s 版必须顶上（覆盖率 77.0%，余量最薄）")
    }

    func testSearchAttemptsCarryNoBogusDurationWhenUnknown() {
        // 时长未知时：所有尝试都不带 duration 参数（不拿 0/假值去搜）。
        let unknown = SherryKugouLyrics.searchAttempts(title: "小幸运", artists: ["田馥甄"], durationMs: nil)
        XCTAssertEqual(unknown.count, 4)
        XCTAssertTrue(unknown.allSatisfy { $0.duration == nil }, "时长未知时任何尝试都不带 duration")
        // 时长已知时：前两次尝试带时长（酷狗排名由 duration 决定），后两次不带。
        let known = SherryKugouLyrics.searchAttempts(title: "小幸运", artists: ["田馥甄"], durationMs: 264_000)
        XCTAssertEqual(known.count, 4)
        XCTAssertEqual(known[0].keyword, "小幸运 田馥甄")
        XCTAssertEqual(known[0].duration, 264_000)
        XCTAssertEqual(known[1].duration, 264_000)
        XCTAssertNil(known[2].duration)
        XCTAssertNil(known[3].duration)
    }

    // MARK: - F3：缓存复检不过时，旧条目保留、不得删除

    func testCacheRecheckKeepsOldEntry() {
        // 同一缓存键（5s 时长桶）：258s 与 260s 同属 52 桶；末行 194s 的歌词
        // 在 258s 时覆盖率 75.2%（存得进），在 260s 时 74.6%（复检不过，
        // 模拟元数据时长轻微漂移）。旧实现删条目 + 重抓失败 = 好歌词没了。
        let song258 = self.song(name: "测试", artist: "测试歌手", duration: 258)
        let song260 = self.song(name: "测试", artist: "测试歌手", duration: 260)
        let key258 = SherryLyricsService.cacheKey(for: song258)
        let key260 = SherryLyricsService.cacheKey(for: song260)
        XCTAssertEqual(key258, key260, "258s 与 260s 必须同属一个缓存键，否则复检路径测不到")
        let doc = lrcDoc(source: .kugou, count: 50, last: 194, durationMs: 258_000,
                         title: "测试", artist: "测试歌手")
        tempCache.store(document: doc, key: key258, identityKey: song258.identityKey)

        let result = SherryLyricsService.cachedLinesSync(for: song260, cache: tempCache)
        XCTAssertNil(result, "复检不过应返回 nil、走重抓，而不是返回错版歌词")
        XCTAssertNotNil(tempCache.lookup(key: key260), "旧条目必须保留，等重抓成功后再替换")
    }
}

/// 2.2.6 F4：PlayerManager 级 seek 测试 —— 旧的 8 例只直调同步引擎，
/// 绕过了 PlayerManager 的 pendingSeekTarget 门控，所以 2.2.5 的卡住窗口
/// 在 CI 里不可见。player 为 nil 时 AVPlayer completion 永不回调，
/// 故直接驱动抽出的 completeSeek（与真实 completion 同一入口）。
final class SherryLyricsSeekManagerTests: XCTestCase {

    private func managerWithSong(duration: TimeInterval = 200) -> (PlayerManager, Song) {
        let manager = PlayerManager()
        let song = Song(id: 9001, name: "测试", artists: "测试歌手", album: "",
                        coverURL: nil, duration: duration, source: .kugou)
        manager.queue = [song]
        manager.currentIndex = 0
        return (manager, song)
    }

    func testSeekCompletionClearsPendingTargetWhenFinishedIsFalse() {
        let (manager, song) = managerWithSong()
        manager.seek(to: 120)
        XCTAssertEqual(manager.pendingSeekTarget ?? -1, 120, "seek 发出后标志位应置位")
        // 2.2.5 的 bug：completion 里 guard finished else { return }，
        // finished == false 时标志位永远不清，观察者一直跳过喂入。
        manager.completeSeek(finished: false, revision: manager.seekRevision,
                             seekSongKey: song.identityKey, clamped: 120)
        XCTAssertNil(manager.pendingSeekTarget, "finished == false 的最新一笔 seek 也必须放开标志位")
    }

    func testSeekCompletionFinishedReanchorsEngine() {
        let (manager, song) = managerWithSong()
        manager.seek(to: 120)
        manager.completeSeek(finished: true, revision: manager.seekRevision,
                             seekSongKey: song.identityKey, clamped: 120)
        XCTAssertNil(manager.pendingSeekTarget)
        XCTAssertEqual(manager.lyricsSyncEngine.extrapolatedPosition(at: Date()), 120, accuracy: 0.5)
    }

    func testSeekCompletionSupersededByNewerSeekDoesNotClearNewTarget() {
        let (manager, song) = managerWithSong()
        manager.seek(to: 120)
        let oldRevision = manager.seekRevision
        manager.seek(to: 90)
        XCTAssertEqual(manager.pendingSeekTarget ?? -1, 90, "新 seek 应覆盖旧目标")
        // 旧 completion（finished == false，被新 seek 顶掉）不得误清新目标。
        manager.completeSeek(finished: false, revision: oldRevision,
                             seekSongKey: song.identityKey, clamped: 120)
        XCTAssertEqual(manager.pendingSeekTarget ?? -1, 90, "旧 completion 不得误清新目标")
        // 新 completion 落点：清标志位 + 重锚到 90。
        manager.completeSeek(finished: true, revision: manager.seekRevision,
                             seekSongKey: song.identityKey, clamped: 90)
        XCTAssertNil(manager.pendingSeekTarget)
        XCTAssertEqual(manager.lyricsSyncEngine.extrapolatedPosition(at: Date()), 90, accuracy: 0.5)
    }

    func testSeekCompletionAfterSongChangeDoesNothing() {
        let (manager, song) = managerWithSong()
        manager.seek(to: 120)
        let revision = manager.seekRevision
        // 切歌后旧 completion 不得动新歌的状态：revision/song guard 挡住，
        // 标志位保持原值（真机上切歌由 loadCurrent 统一清零）。
        manager.queue = [Song(id: 9002, name: "另一首", artists: "测试歌手", album: "",
                              coverURL: nil, duration: 200, source: .kugou)]
        manager.currentIndex = 0
        manager.completeSeek(finished: true, revision: revision,
                             seekSongKey: song.identityKey, clamped: 120)
        XCTAssertEqual(manager.pendingSeekTarget ?? -1, 120, "切歌后旧 completion 的 guard 应挡住，不得清标志位/重锚")
    }
}
