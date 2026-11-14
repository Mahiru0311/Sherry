import Foundation

/// 歌词侧外推时钟：锚点 + 外推，0.25s 滴答 + 行切换边界滴答。
///
/// 机制参考 LyricsIsland (MIT) 的 SyncEngine，按 Sherry 的模型改写。
/// AVPlayer 的 0.05s 观察者继续负责进度条 UI；歌词高亮读这里。
/// 调用约定：所有方法都在主线程调用（观察者队列 .main、Timer 主 RunLoop、
/// setLyrics 走 MainActor.run / SwiftUI .task），因此不加 @MainActor
/// 隔离，避免观察者闭包里的同步调用被隔离挡住。
final class SherryLyricsSyncEngine {
    /// 2 秒内的偏差当作采样抖动，不重锚。
    static let seekThresholdSeconds = 2.0
    /// 常规滴答间隔。
    static let tickInterval: TimeInterval = 0.25

    /// 外推位置（秒，不含用户偏移；偏移在读取端 LyricTiming.effectiveProgress 里加）。
    var onTick: ((Double) -> Void)?

    private(set) var lines: [LyricLine] = []
    private var anchorPosition: Double = 0
    private var anchorDate: Date = Date()
    private var anchorIsPlaying = false
    private var anchorDuration: Double = 0
    private var hasAnchor = false
    private var timer: Timer?
    private var boundaryTask: Task<Void, Never>?

    /// 换歌时重置：旧锚点、旧歌词、旧定时器全部丢弃。
    func reset() {
        lines = []
        hasAnchor = false
        anchorIsPlaying = false
        stopTicking()
    }

    func setLyrics(_ lines: [LyricLine]) {
        self.lines = lines
        tick()
    }

    /// 采用一次新的播放器位置报告（由 0.05s 观察者调用）。
    func apply(position: Double, isPlaying: Bool, duration: Double) {
        if hasAnchor, anchorIsPlaying == isPlaying, isPlaying {
            let expected = extrapolatedPosition(at: Date())
            if abs(expected - position) <= Self.seekThresholdSeconds {
                return // 抖动范围内：保留更平滑的旧锚点
            }
        }
        anchorPosition = position
        anchorDate = Date()
        anchorIsPlaying = isPlaying
        anchorDuration = duration
        hasAnchor = true
        tick()
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
        if anchorIsPlaying, let nextSwitch = nextLineSwitch(after: pos) {
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

    /// 播放中外推，暂停/无锚点时冻结在锚点位置。
    func extrapolatedPosition(at date: Date) -> Double {
        guard hasAnchor else { return 0 }
        guard anchorIsPlaying else { return anchorPosition }
        let elapsed = date.timeIntervalSince(anchorDate)
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
