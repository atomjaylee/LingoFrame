import Foundation
import Observation
import TMDBKit

/// 首页推荐的一部作品。片名用英文原名、配合年份在 TMDB 上搜索，避免写死编号出错。
struct CatalogEntry: Identifiable, Hashable, Sendable {
    let id: String
    let type: TMDBMediaType
    let title: String
    let year: Int
    /// CEFR 难度：A2 入门、B1 进阶、B2 高阶、C1 精通。
    let level: String
    /// 为什么适合学英语，一句话。
    let reason: String
    /// 是否放进首页大图轮播。
    let featured: Bool

    init(_ id: String, _ type: TMDBMediaType, _ title: String, _ year: Int, _ level: String, _ reason: String,
         featured: Bool = false) {
        self.id = id
        self.type = type
        self.title = title
        self.year = year
        self.level = level
        self.reason = reason
        self.featured = featured
    }
}

struct CatalogGroup: Identifiable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let entries: [CatalogEntry]
}

/// 适合学英语的剧集和电影，按难度分组。以后可以换成从服务器下发的列表。
enum LearningCatalog {
    static let groups: [CatalogGroup] = [
        CatalogGroup(id: "a2", title: "入门 · 日常对话", subtitle: "语速慢、句子短、场景生活化", entries: [
            CatalogEntry("friends", .tv, "Friends", 1994, "A2", "日常口语最丰富，人物和场景反复出现，词汇复现率高", featured: true),
            CatalogEntry("modern-family", .tv, "Modern Family", 2009, "A2", "家庭场景，采访式独白语速慢，适合跟读"),
            CatalogEntry("young-sheldon", .tv, "Young Sheldon", 2017, "A2", "旁白清晰，句子完整"),
            CatalogEntry("paddington", .movie, "Paddington", 2014, "A2", "标准英式发音，节奏舒缓", featured: true),
            CatalogEntry("toy-story", .movie, "Toy Story", 1995, "A2", "动画配音咬字清楚"),
            CatalogEntry("finding-nemo", .movie, "Finding Nemo", 2003, "A2", "对白简单，情节好懂"),
        ]),
        CatalogGroup(id: "b1", title: "进阶 · 职场与生活", subtitle: "常用工作表达，语速正常", entries: [
            CatalogEntry("the-office", .tv, "The Office", 2005, "B1", "伪纪录片拍法，大量真实的办公室口语", featured: true),
            CatalogEntry("ted-lasso", .tv, "Ted Lasso", 2020, "B1", "美式和英式口音同框对比", featured: true),
            CatalogEntry("brooklyn-nine-nine", .tv, "Brooklyn Nine-Nine", 2013, "B1", "节奏轻快，俚语和梗多"),
            CatalogEntry("parks-and-recreation", .tv, "Parks and Recreation", 2009, "B1", "日常工作沟通"),
            CatalogEntry("the-devil-wears-prada", .movie, "The Devil Wears Prada", 2006, "B1", "时尚职场词汇"),
            CatalogEntry("the-intern", .movie, "The Intern", 2015, "B1", "职场礼貌用语"),
        ]),
        CatalogGroup(id: "b2", title: "高阶 · 快语速与专业词汇", subtitle: "信息密度高，适合练听力反应", entries: [
            CatalogEntry("suits", .tv, "Suits", 2011, "B2", "律师对话，语速快、用词正式"),
            CatalogEntry("the-big-bang-theory", .tv, "The Big Bang Theory", 2007, "B2", "科学词汇和快速对白"),
            CatalogEntry("gilmore-girls", .tv, "Gilmore Girls", 2000, "B2", "出了名的语速快"),
            CatalogEntry("the-social-network", .movie, "The Social Network", 2010, "B2", "密集的快节奏对白"),
            CatalogEntry("the-martian", .movie, "The Martian", 2015, "B2", "科技词汇，独白多"),
            CatalogEntry("notting-hill", .movie, "Notting Hill", 1999, "B2", "英美口音对照的轻喜剧"),
        ]),
        CatalogGroup(id: "c1", title: "英式英语", subtitle: "口音地道，表达更正式", entries: [
            CatalogEntry("sherlock", .tv, "Sherlock", 2010, "C1", "英式发音，推理对白信息量大", featured: true),
            CatalogEntry("the-crown", .tv, "The Crown", 2016, "C1", "正式、典雅的英式表达"),
            CatalogEntry("downton-abbey", .tv, "Downton Abbey", 2010, "C1", "贵族和仆人两种口音"),
            CatalogEntry("the-kings-speech", .movie, "The King's Speech", 2010, "C1", "一部关于发音本身的电影"),
        ]),
    ]

    static var allEntries: [CatalogEntry] { groups.flatMap(\.entries) }
}

/// 推荐列表在 TMDB 上的数据：按片名搜索得到编号，再取详情（海报、背景、Logo、简介）。结果有 7 天磁盘缓存。
@MainActor
@Observable
final class RecommendationStore {
    private(set) var titles: [String: TMDBTitle] = [:]
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    @ObservationIgnored private var loadedClient: ObjectIdentifier?

    func reset() {
        titles = [:]
        errorMessage = nil
        loadedClient = nil
    }

    func load(using tmdb: TMDBClient) async {
        guard loadedClient != ObjectIdentifier(tmdb) else { return }
        loadedClient = ObjectIdentifier(tmdb)
        isLoading = true
        defer { isLoading = false }
        var firstError: Error?
        await withTaskGroup(of: (String, Result<TMDBTitle?, Error>).self) { group in
            for entry in LearningCatalog.allEntries {
                group.addTask {
                    do {
                        guard let ref = try await tmdb.resolve(entry.type, title: entry.title, year: entry.year) else {
                            return (entry.id, .success(nil))
                        }
                        return (entry.id, .success(try await tmdb.details(ref)))
                    } catch {
                        return (entry.id, .failure(error))
                    }
                }
            }
            for await (id, result) in group {
                switch result {
                case .success(let title): titles[id] = title
                case .failure(let error): firstError = firstError ?? error
                }
            }
        }
        errorMessage = titles.isEmpty ? firstError?.localizedDescription : nil
        if titles.isEmpty { loadedClient = nil }
    }

    func entry(for ref: TMDBRef) -> CatalogEntry? {
        guard let id = titles.first(where: { $0.value.ref == ref })?.key else { return nil }
        return LearningCatalog.allEntries.first { $0.id == id }
    }
}
