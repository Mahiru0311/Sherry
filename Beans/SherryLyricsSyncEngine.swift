import Foundation

/// 歌词侧时钟：锚点 + 外推，0.25s 滴答 + 行切换边界滴答。
///
/// 机制参考 LyricsIsland (MIT) 的 SyncEngine，按 Sherry 的模型改写。
/// AVPlayer 的 0.05s 观察者继续负责进度条 UI；歌词高亮读这里。
/// 调用约定：所有方法都在主线程调用（观察者队列 .main、Timer 主 RunLoop、
/// setLyrics 走 MainActor.run / SwiftUI .task），因此不加 @MainActor
/// 隔离，避免观察者闭包里的同步调用被隔离挡住。
///
/// 2.2.1 修正（真机实测仍延迟的根因）：
/// - 旧版 apply() 在偏差 ≤2s 时直接 return，锚点在整首歌里几乎不更新，
///   外推全靠墙钟；音频一卡顿（waitingToPlayAtSpecifiedRate），墙钟继续走、
///   音频冻住，歌词就跑到音频前面，误差 <2s 时还永远不纠正。
/// - 新版：每次观察者回调都把最新播放器位置当作锚点（0.05s 观察者本身
///   就是音频时钟的汇报，不会累积漂移）；>2s 的跳变仍当作 seek 处理。
/// - 卡顿期间冻结：PlayerManager 在 timeControlStatus 变成
///   waitingToPlayAtSpecifiedRate 时调 setStalled(true)，外推停在锚点位置，
///   恢复后观察者回调重新锚定，不再“歌词先跑、播回来再跳回去”。
/// - 外推按播放倍速走（rate 由观察者传入；旧版恒按 1.0x，变速播放时整首错位）。
final class SherryLyricsSyncEngine {
    /// 超过这个偏差才当作 seek 跳变（立即重锚 + 立即滴答）。
    static let seekThresholdSeconds = 2.0
    /// 常规滴答间隔。
    static let tickInterval: TimeInterval = 0.25

    /// 外推位置（秒，不含用户偏移；偏移在读取端 LyricTiming.effectiveProgress 里加）。
    var onTick: ((Double) -> Void)?

    private(set) var lines: [LyricLine] = []
    private var anchorPosition: Double = 0
    private var anchorDate: Date = Date()
    private var anchorRate: Double = 1
    private var anchorIsPlaying = false
    private var anchorDuration: Double = 0
    private var hasAnchor = false
    /// 音频正在等数据（缓冲）：外推冻结在锚点位置。
    private var stalled = false
    private var timer: Timer?
    private var boundaryTask: Task<Void, Never>?

    /// 换歌时重置：旧锚点、旧歌词、旧定时器全部丢弃。
    func reset() {
        lines = []
        hasAnchor = false
        anchorIsPlaying = false
        stalled = false
        stopTicking()
    }

    func setLyrics(_ lines: [LyricLine]) {
        self.lines = lines
        tick()
    }

    /// 卡顿状态（由 PlayerManager 的 timeControlStatus 观察者驱动）：
    /// 置 true 时外推立即冻结在锚点位置；恢复后下一次观察者回调重锚。
    func setStalled(_ stalled: Bool) {
        guard stalled != self.stalled else { return }
        self.stalled = stalled
        if stalled { tick() }
    }

    /// 采用一次新的播放器位置报告（由 0.05s 观察者调用）。
    /// 每次回调都重锚：观察者报的就是音频时钟的真实位置，重锚不会引入
    /// 漂移，只会把墙钟外推的微小误差清掉；>2s 的跳变当作 seek，立即滴答。
    func apply(position: Double, isPlaying: Bool, duration: Double, rate: Double = 1) {
        let wasAnchored = hasAnchor
        let wasPlaying = anchorIsPlaying
        let jump: Bool
        if wasAnchored, wasPlaying == isPlaying, isPlaying {
            let expected = extrapolatedPosition(at: Date())
            jump = abs(expected - position) > Self.seekThresholdSeconds
        } else {
            jump = true
        }
        anchorPosition = position
        anchorDate = Date()
        anchorRate = rate > 0 ? rate : 1
        anchorIsPlaying = isPlaying
        anchorDuration = duration
        hasAnchor = true
        stalled = false
        if jump || !wasAnchored || wasPlaying != isPlaying {
            tick()
        }
    }

    func startTicking() {
        stopTicking()
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        tick()
    }

    func stopTicking() {
        timer?.invalidate()
        timer = nil
        boundaryTask?.cancel()
        boundaryTask = nil
    }

    func tick() {
        boundaryTask?.cancel()
        boundaryTask = nil
        guard hasAnchor else { return }
        let pos = extrapolatedPosition(at: Date())
        onTick?(pos)
        // 在下一行切换时刻本身再滴答一次，不等下一个 250ms 周期。
        if anchorIsPlaying, !stalled, let nextSwitch = nextLineSwitch(after: pos) {
            let delayMs = max(1, Int(((nextSwitch - pos) * 1000).rounded()))
            boundaryTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(delayMs))
                guard !Task.isCancelled else { return }
                // 边界滴答回到主线程再发（onTick 写 @Published 状态）。
                await MainActor.run { self?.tick() }
            }
        }
    }

    // MARK: - 纯函数（可单测）

    /// 播放中外推（按倍速），暂停 / 卡顿 / 无锚点时冻结在锚点位置。
    func extrapolatedPosition(at date: Date) -> Double {
        guard hasAnchor else { return 0 }
        guard anchorIsPlaying, !stalled else { return anchorPosition }
        let elapsed = date.timeIntervalSince(anchorDate) * anchorRate
        let pos = max(0, anchorPosition + elapsed)
        if anchorDuration > 0 { return min(pos, anchorDuration) }
        return pos
    }

    /// 二分查找当前行：最后一行 time ≤ position 的行；第一行之前返回 nil。
    static func lineIndex(forPosition pos: Double, in lines: [LyricLine]) -> Int? {
        guard let first = lines.first, pos >= first.time else { return nil }
        var lo = 0
        var hi = lines.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lines[mid].time <= pos {
                lo = mid
            } else {
                hi = mid - 1
            }
        }
        return lo
    }

    private func nextLineSwitch(after pos: Double) -> Double? {
        let current = Self.lineIndex(forPosition: pos, in: lines)
        let upcoming = (current ?? -1) + 1
        guard lines.indices.contains(upcoming) else { return nil }
        let start = lines[upcoming].time
        return start > pos ? start : nil
    }
}
