import DesignSystem
import SwiftUI
import TMDBKit
import Workspace

/// 设置窗口，照抄 Rex：左边分组菜单，右边系统风格的分组设置项。
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var page: Page = .appearance
    @State private var tmdbOK: Bool?

    enum Page: Hashable { case servers, tmdb, layout, appearance }

    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                row(.servers, "资源库", icon: "externaldrive") {
                    Text("\(model.servers.count) 个").foregroundStyle(.secondary)
                }
                row(.tmdb, "TMDB", icon: "film.stack") {
                    HStack(spacing: 4) {
                        Circle().fill(tmdbOK == false ? Color.red : model.tmdb == nil ? Color.secondary : Color.green).frame(width: 6, height: 6)
                        Text(tmdbOK == false ? "异常" : model.tmdb == nil ? "未配置" : "正常").foregroundStyle(.secondary)
                    }
                }
                Section("播放体验") {
                    row(.layout, "播放布局", icon: "rectangle.3.group") { EmptyView() }
                }
                Section("使用偏好") {
                    row(.appearance, "外观与交互", icon: "paintbrush.pointed") { EmptyView() }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(209)
        } detail: {
            Group {
                switch page {
                case .servers: AccountSettings()
                case .tmdb: TMDBSettings(status: $tmdbOK)
                case .layout: LayoutSettings()
                case .appearance: AppearanceSettings()
                }
            }
            .navigationTitle(title)
        }
        .frame(width: 820, height: 560)
    }

    private var title: String {
        switch page {
        case .servers: "资源库"
        case .tmdb: "数据与资源"
        case .layout: "播放布局"
        case .appearance: "外观与交互"
        }
    }

    private func row<Trailing: View>(_ page: Page, _ title: String, icon: String,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            trailing().font(.system(size: 11, weight: .medium))
        }
        .tag(page)
    }
}

private struct AppearanceSettings: View {
    @Environment(ThemeStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Form {
            Section("显示与启动") {
                Picker("外观模式", selection: $store.appearance) {
                    ForEach(ThemeAppearance.allCases, id: \.self) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// TMDB：首页推荐和详情页的海报、Logo、简介都从这里获取。
private struct TMDBSettings: View {
    @Binding var status: Bool?
    @Environment(AppModel.self) private var model
    @State private var token = ""
    @State private var apiBase = ""
    @State private var imageBase = ""
    @State private var testResult: String?
    @State private var isTesting = false

    var body: some View {
        Form {
            Section {
                LabeledContent("连接状态") {
                    HStack(spacing: 8) {
                        if isTesting { ProgressView().controlSize(.small) }
                        if let testResult {
                            Text(testResult).foregroundStyle(status == false ? Color.red : .secondary).lineLimit(1)
                        }
                        Button("测试连接") { test() }.disabled(isTesting)
                    }
                }
                LabeledContent("API 密钥") {
                    HStack {
                        SecureField("", text: $token, prompt: Text(model.hasCustomTMDBToken ? "已保存密钥" : "尚未配置"))
                            .frame(width: 200)
                        Button("保存") { model.tmdbToken = token; token = "" }.disabled(token.isEmpty)
                        if model.hasCustomTMDBToken {
                            Button("删除") { model.tmdbToken = "" }
                        }
                    }
                }
                LabeledContent("接口地址") {
                    TextField("", text: $apiBase).frame(width: 300).onSubmit(saveAddresses)
                }
                LabeledContent("图片地址") {
                    HStack {
                        TextField("", text: $imageBase).frame(width: 300).onSubmit(saveAddresses)
                    }
                }
                HStack {
                    Spacer()
                    Button("恢复默认地址") {
                        model.tmdbConfig = .default
                        load()
                    }
                    Button("保存地址") { saveAddresses() }
                }
            } header: {
                Text("TMDB")
            } footer: {
                Text("密钥可以在 themoviedb.org 的「设置 → API」免费申请，只保存在这台电脑上。国内网络直连 TMDB 经常失败，可以把两个地址换成可用的代理。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("语言") {
                Picker("简介与标题", selection: Binding(get: { model.tmdbConfig.language }, set: { lang in
                    model.tmdbConfig = TMDBConfig(apiBase: model.tmdbConfig.apiBase, imageBase: model.tmdbConfig.imageBase, language: lang)
                })) {
                    Text("简体中文").tag("zh-CN")
                    Text("繁體中文").tag("zh-TW")
                    Text("English").tag("en-US")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
    }

    private func load() {
        apiBase = model.tmdbConfig.apiBase.absoluteString
        imageBase = model.tmdbConfig.imageBase.absoluteString
    }

    private func saveAddresses() {
        guard let api = URL(string: apiBase.trimmingCharacters(in: .whitespaces)), api.host() != nil,
              let image = URL(string: imageBase.trimmingCharacters(in: .whitespaces)), image.host() != nil else {
            testResult = "地址格式不正确"
            return
        }
        model.tmdbConfig = TMDBConfig(apiBase: api, imageBase: image, language: model.tmdbConfig.language)
        testResult = "已保存"
    }

    private func test() {
        guard let tmdb = model.tmdb else { testResult = "还没有可用的密钥"; status = false; return }
        isTesting = true
        testResult = nil
        Task {
            defer { isTesting = false }
            do {
                let hits = try await tmdb.search(.tv, query: "Friends", year: 1994)
                testResult = hits.isEmpty ? "连接成功，但没有搜索结果" : "连接正常"
                status = true
            } catch {
                testResult = error.localizedDescription
                status = false
            }
        }
    }
}

private struct LayoutSettings: View {
    @Environment(LayoutStore.self) private var store

    var body: some View {
        Form {
            Section("布局预设") {
                ForEach(store.presets) { preset in
                    HStack {
                        Text(preset.name)
                        if preset.isBuiltin { Text("内置").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("应用") { store.apply(preset) }
                        if !preset.isBuiltin {
                            Button("删除", role: .destructive) { store.deletePreset(preset.id) }
                        }
                    }
                }
            }
            Section {
                Button("将当前布局存为预设") { store.saveCurrentAsPreset() }
                Button("恢复默认布局") { store.apply(LayoutStore.defaultPreset) }
            } footer: {
                Text("在播放窗口里可以拖动面板分隔条、右键面板标签移动位置，布局会自动保存。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AccountSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            if model.servers.isEmpty {
                Text("尚未添加 Emby 资源库").foregroundStyle(.secondary)
            } else {
                ForEach(model.servers) { server in
                    Section(server.name) {
                        LabeledContent("地址", value: server.account.serverURL.absoluteString)
                        LabeledContent("用户", value: server.account.userName)
                        Button("移除资源库", role: .destructive) { model.removeServer(server.id) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

#Preview("设置") {
    SettingsView()
        .appEnvironment(AppModel())
}
