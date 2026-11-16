import SwiftUI

// MARK: - 版本更新日志（设置页与首次更新弹窗使用）

struct VersionLog: Identifiable {
    let id: String
    let version: String
    let title: String
    let notices: [String]
    let features: [String]
    let fixes: [String]
    let imageURL: URL?
    let textColorHex: String?

    init(id: String, version: String, title: String, notices: [String] = [], features: [String], fixes: [String], imageURL: URL? = nil, textColorHex: String? = nil) {
        self.id = id
        self.version = version
        self.title = title
        self.notices = notices
        self.features = features
        self.fixes = fixes
        self.imageURL = imageURL
        self.textColorHex = textColorHex
    }
}

enum ChangelogStore {
    static let lastSeenKey = "co.lastSeenVersion"

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    static var lastSeenVersion: String {
        UserDefaults.standard.string(forKey: lastSeenKey) ?? ""
    }

    static func markSeen() {
        UserDefaults.standard.set(currentVersion, forKey: lastSeenKey)
        UserDefaults.standard.synchronize()
    }

    static var shouldShowWhatsNew: Bool {
        lastSeenVersion != currentVersion
    }

    static var latest: VersionLog? { logs.first }

    /// 更新日志仅显示内置历史记录（酷狗专版不做更新检查）。
    static func fetchRemoteLatest() async -> VersionLog? { nil }

    static func fetchRemoteHistory() async -> [VersionLog] { [] }

    static let logs: [VersionLog] = [
        VersionLog(
            id: "2.2.5",
            version: "2.2.5",
            title: "拖动进度条后歌词不再掉同步",
            notices: [],
            features: [],
            fixes: [
                "拖动进度条/点按进度条/锁屏拖动后，歌词立即跳到新位置，不再停在拖动前的行",
                "暂停时拖动进度条，高亮同样立即跳到新行",
                "没歌词的歌拖动后仍显示无歌词，不硬凑歌词",
            ]
        ),
        VersionLog(
            id: "2.2.4",
            version: "2.2.4",
            title: "歌词错版拒收 + 跨源偏移校正 + 引擎防冻",
            notices: [
                "慌啥子嘛这类“歌词是 189s 版、音频是 260s”的歌不再放错版歌词，改为显示暂无歌词。",
            ],
            features: [
                "多源歌词互相校对：一个源整体快/慢几秒时，自动换用另外两个源一致的版本。",
            ],
            fixes: [
                "歌词按覆盖率与版本时长拒收错版/片段歌词（慌啥子嘛、消愁不再错词）",
                "行级歌词不再合成假逐字扫掠，没有逐字时间就干净地按行显示",
                "修复缓冲时歌词跑到音频前面的问题，暂停后重试不再冻住歌词与进度条",
                "拖动歌词列表时歌词时钟不再停摆",
            ]
        ),
        VersionLog(
            id: "2.2.3",
            version: "2.2.3",
            title: "歌词标签泄漏修复 + 瘦身 + ABR 音质恢复",
            notices: [
                "修复歌词页出现 <3780,-3780> 原始词标记的问题（酷我缓存重载路径）。",
                "降档后网络恢复时，音质会自动回到原来那一档。",
            ],
            features: [
                "主播放页 ··· 菜单新增“实际音质”显示",
                "弹窗玻璃、切歌飞出、Folia 逐词等动效统一为弹簧",
            ],
            fixes: [
                "修复酷我歌词缓存重载后逐字标签原样进渲染的问题",
                "修复 ABR 降档后永远停在低档的问题",
                "删除幽灵音质档 higher/master 与一批死代码、死字符串",
            ]
        ),
        VersionLog(
            id: "2.2.2",
            version: "2.2.2",
            title: "歌词覆盖修复：三分之二的歌恢复有词",
            notices: [
                "酷狗搜索恢复“歌名+歌手”优先：裸歌名对一半歌返回 0 候选，是 2.2.1 仍大量无词的根因。",
                "新增酷我跨源兜底：酷狗和 LRCLIB 都拿不到时自动换源找词。",
            ],
            features: [
                "歌词链路：酷狗 → 酷狗备用端点 → 酷我 → LRCLIB，逐源兜底",
                "繁简标题、Live/DJ/伴奏等无括号后缀的歌也能匹配到歌词",
            ],
            fixes: [
                "修复 2.2.1 删掉“歌名 歌手”搜索导致的歌词回归",
                "修复 krctype==2 的候选被误判为无 KRC 的问题",
                "修复旧版 24 小时负缓存跨版本残留、一堆歌一整天没歌词的问题",
                "修复匹配否决写 24 小时负缓存、预取失败写负缓存、重试清不掉旧条目的问题",
                "修复标题不对的候选挤掉真正匹配候选的问题",
            ]
        ),
        VersionLog(
            id: "2.2.1",
            version: "2.2.1",
            title: "歌词延迟与无歌词修复 + 动画现代化",
            notices: [
                "歌词时钟改按音频时钟重锚，卡顿期间冻结，不再越跑越偏。",
                "搜索限流不再让歌一整天没歌词：暂时失败只拦 5 分钟。",
            ],
            features: [
                "无歌词时显示加载中 / 暂无歌词 + “重新加载歌词”按钮",
                "动画改现代弹簧手感：Folia 换行、歌词滚动、开关类交互",
            ],
            fixes: [
                "修复音频卡顿时歌词按墙钟继续走、误差小于 2 秒永远不纠正的问题",
                "修复带 Live/DJ/伴奏后缀的歌在酷狗和 LRCLIB 两边都拿不到歌词的问题",
                "修复搜索被限流后写 24 小时负缓存、一堆歌一整天没歌词的问题",
            ]
        ),
        VersionLog(
            id: "2.2.0",
            version: "2.2.0",
            title: "歌词系统重建 + 播放引擎升级",
            notices: [
                "歌词系统整体重写：匿名酷狗链 → LRCLIB 兜底，候选按标题/歌手/时长校验，不再拿错 DJ 版、live、伴奏；行级歌词无逐字时合成逐字扫掠。",
                "下一首歌词与音频地址一起预取；酷狗 429 熔断冷却；播放中途失败先断点续播一次。",
            ],
            features: [
                "歌词不同步的根因已修：搜索/下载/解码/选择全程记日志，失败不再静默",
                "磁盘歌词缓存 30 天，查不到的 24 小时内不再重复请求",
                "歌词时钟锚点 + 外推，行切换不再拖到下一个刷新周期",
                "瘦身：删除无引用文档与死代码，截图体积大幅缩小",
            ],
            fixes: [
                "修复匿名歌词链无校验拿错版本的问题（DJ 版、live、伴奏不再被当成原版）",
                "修复歌词失败静默、无重试、每次播放重复请求的问题",
            ]
        ),
        VersionLog(
            id: "2.1.0",
            version: "2.1.0",
            title: "酷狗专版重制：歌词同步 v2",
            notices: [
                "本次更新基于 Co 2.0.3（酷狗专版）重制；旧 1.7.0 是基于 Beans 底构建的错误版本，请重新安装。",
                "Bundle ID 已改为 com.kugou.kugou1002：新安装不会继承旧版的设置、收藏与登录，请先用设置里的备份导出再恢复。"
            ],
            features: [
                "歌词与音频地址并行预取，打开即有歌词",
                "酷狗 KRC 逐字高亮（主歌词、黑胶歌词、Folia 舞台）",
                "歌词版本不对时自动重取更匹配的版本（LRCLIB / 酷狗重搜）",
                "本首歌单独歌词偏移（±0.1s 微调）",
                "歌词滚动跟随更快（0.15s），跳行或 seek 后直接定位",
                "全新暖橙色图标，应用改名 Sherry"
            ],
            fixes: [
                "修复 1.7.0 缺少全部 Co 定制的问题（捐赠入口、酷狗专版逻辑等）"
            ]
        ),
        VersionLog(
            id: "1.8.1",
            version: "1.8.1",
            title: "动态壁纸与听歌统计优化",
            features: [
                "新增 Star Nest、Dot Orbit、Dots 与 Grain Gradient 壁纸",
                "Grain Gradient 按静态壁纸处理，支持颜色、缩放和对比度调节",
                "我的界面仅保留听歌时长显示"
            ],
            fixes: [
                "听歌时长改为按实际播放中的经过时间计算，暂停、缓冲和切歌间隙不再计入",
                "修复拖动进度、循环播放或反复测试同一首歌导致听歌时长异常增加的问题"
            ]
        ),
        VersionLog(
            id: "1.8",
            version: "1.8",
            title: "专辑浏览体验优化",
            features: [
                "新增“该歌手的其他专辑”加载预览动效",
                "继续复用专辑与封面缓存，减少重复加载时的空白闪烁"
            ],
            fixes: [
                "修复详情页封面缓存刷新时短暂发白的问题",
                "修复排行榜作者头像刷新时短暂消失的问题"
            ]
        ),
        VersionLog(
            id: "1.7.01",
            version: "1.7.01",
            title: "流畅性与稳定性优化",
            notices: [
                "重点：本次优化高刷新渲染、列表滚动和更新说明加载体验。"
            ],
            features: [
                "优化封面加载中的扫光渲染，减少列表快速滚动时的主线程负担",
                "高刷新率请求覆盖主界面、弹窗与全屏播放器",
                "设置底部补充完整运行环境信息"
            ],
            fixes: [
                "修复更新后首次打开更新说明短暂显示旧版 1.6.7 内容的问题",
                "修复自定义视频头像在覆盖更新后可能丢失的问题"
            ]
        ),
        VersionLog(
            id: "1.6.7",
            version: "1.6.7",
            title: "主页、播放器与缓存体验优化",
            notices: [
                "建议更新时卸载后重新安装，不要覆盖安装，否则可能出现部分问题。",
                "不是最新版请不要反馈问题，旧版本不再维护。",
                "本软件不提供下载服务，请支持官方网易云音乐、QQ 音乐和酷狗音乐平台。"
            ],
            features: [
                "新增“新碟上架”和“歌手”板块",
                "新增歌单搜索，并将歌单广场独立为单独页面",
                "“我的”入口移至右上角，支持自定义昵称和头像",
                "新增灵动岛与控制中心显示开关",
                "新增多项缓存机制，提升加载速度和使用体验",
                "优化底部栏动画，适配 Apple Music 风格的自动收缩效果",
                "Apple Music 风格主页新增磨砂背景",
                "账号入口移至设置页面",
                "修改默认强调色",
                "优化音源播放与切歌速度",
                "更新底部栏图标样式",
                "移除歌单液态容器"
            ],
            fixes: [
                "修复低版本系统无法调节进度条的问题",
                "修复歌词与音乐进度不同步的问题",
                "修复自定义排序后重新打开应用失效的问题"
            ]
        ),
        VersionLog(
            id: "1.6.6",
            version: "1.6.6",
            title: "歌单广场与播放体验优化",
            features: [
                "新增网易云和 QQ 音乐歌单广场搜索功能",
                "优化歌曲封面缓存",
                "优化歌词滑动后不返回当前播放位置的问题",
                "优化整体流畅性，低系统表现以实际测试为准",
                "优化网易云私人漫游问题，遇到问题可使用心动模式",
                "简化搜索界面，移除均衡器注释",
                "更换酷狗音乐歌单广场接口",
                "整体以优化和问题修复为主"
            ],
            fixes: [
                "修复 QQ 音乐本身有会员但无法播放的问题",
                "修复 iOS 26 以下系统无法返回的问题"
            ]
        ),
        VersionLog(
            id: "1.6.5.1",
            version: "1.6.5.1",
            title: "音源与歌单体验修复",
            features: [
                "修复歌单页播放器无法返回的问题",
                "删除内置音源功能和填写密钥（可从密钥后台复制链接导入）",
                "持续优化 QQ 音源问题",
                "增加歌单、主页和排行榜缓存，减少重复加载"
            ],
            fixes: [
                "软件不提供任何下载服务，不会导入音源的可在群里反馈"
            ]
        ),
        VersionLog(
            id: "1.6.5",
            version: "1.6.5",
            title: "音源播放修复",
            features: [
                "新增网易云免费音源"
            ],
            fixes: [
                "修复 QQ 音乐音源不能播放的问题",
                "修复自定义导入音源不能播放的问题"
            ]
        ),
    ]
}

// MARK: - 更新说明弹窗

struct WhatsNewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var remoteLog: VersionLog?
    @State private var isLoading = true

    var body: some View {
        CoNavigationStack {
            ZStack {
                GlassBackdrop(customColor: ThemeStore.shared.backgroundSyncAll ? ThemeStore.shared.customBackground : nil)
                ScrollView {
                    if let log = remoteLog {
                        VersionLogCard(log: log)
                            .padding(16)
                    } else if isLoading {
                        ProgressView()
                            .tint(Color.coAmber)
                            .frame(maxWidth: .infinity, minHeight: 160)
                    } else if let log = ChangelogStore.latest {
                        VersionLogCard(log: log)
                            .padding(16)
                    }
                }
                .coScrollIndicatorsHidden()
            }
            .navigationTitle("更新说明")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("开始使用") {
                        ChangelogStore.markSeen()
                        dismiss()
                    }
                    .font(CoFont.appFont(14, .semibold))
                    .foregroundStyle(Color.coAmber)
                }
            }
        }
        .modifier(CoSheetModifier(detents: [.medium, .large]))
        .task {
            remoteLog = await ChangelogStore.fetchRemoteLatest()
            isLoading = false
        }
        .onDisappear {
            ChangelogStore.markSeen()
        }
    }
}

struct ChangelogListView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var remoteLogs: [VersionLog] = []
    @State private var isLoading = true

    var body: some View {
        let remoteVersions = Set(remoteLogs.map(\.version))
        CoNavigationStack {
            ZStack {
                GlassBackdrop(customColor: ThemeStore.shared.backgroundSyncAll ? ThemeStore.shared.customBackground : nil)
                ScrollView {
                    if isLoading {
                        ProgressView()
                            .tint(Color.coAmber)
                            .frame(maxWidth: .infinity, minHeight: 160)
                    } else {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(remoteLogs) { log in
                                VersionLogCard(log: log)
                            }
                            ForEach(ChangelogStore.logs.filter { log in
                                !remoteVersions.contains(log.version)
                            }) { log in
                                VersionLogCard(log: log)
                            }
                        }
                        .padding(16)
                    }
                }
                .coScrollIndicatorsHidden()
            }
            .navigationTitle("更新日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .modifier(CoSheetModifier(detents: [.medium, .large]))
        .task {
            remoteLogs = await ChangelogStore.fetchRemoteHistory()
            isLoading = false
        }
    }
}

private struct VersionLogCard: View {
    let log: VersionLog

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("v\(log.version)")
                    .font(CoFont.appFont(16, .bold))
                    .foregroundStyle(Color.coAmber)
                Text(log.title)
                    .font(CoFont.appFont(14, .semibold))
                    .foregroundStyle(textColor)
            }
            if let imageURL = log.imageURL {
                AsyncImage(url: imageURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit()
                    } else if phase.error != nil {
                        EmptyView()
                    } else {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 80)
                    }
                }
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            if !log.notices.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(log.notices, id: \.self) { notice in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.top, 1)
                            Text(notice)
                                .font(CoFont.appFont(13, .semibold))
                                .foregroundStyle(.white)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    LinearGradient(
                        colors: [Color.orange, Color.red.opacity(0.88)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
            }
            if !log.features.isEmpty {
                logSection(title: "新增功能", icon: "plus.circle.fill", items: log.features)
            }
            if !log.fixes.isEmpty {
                Divider().overlay(Color.coComment.opacity(0.15))
                logSection(title: "问题修复", icon: "checkmark.circle.fill", items: log.fixes)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            CoGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .coCardShadow(radius: 9, y: 3)
    }

    private func logSection(title: String, icon: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringKey(title))
                .font(CoFont.appFont(14, .bold))
                .foregroundStyle(Color.coAmber)
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.coAmber)
                        .padding(.top, 2)
                    Text(LocalizedStringKey(item))
                        .font(CoFont.appFont(13))
                        .foregroundStyle(textColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var textColor: Color {
        if let raw = log.textColorHex, let color = Color(hex: raw) { return color }
        return Color.coLabel
    }
}
