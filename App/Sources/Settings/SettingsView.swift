import AppKit
import DesignSystem
import Foundation
import SwiftUI
import TMDBKit

/// 设置只保留实际可调整的偏好；连接细节默认收起，资源库由主窗口管理。
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(ThemeStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var showsAdvanced = false
    @State private var token = ""
    @State private var apiBase = ""
    @State private var imageBase = ""
    @State private var isChecking = false
    @State private var connectionOK: Bool?
    @State private var connectionNote: String?
    @State private var advancedNote: String?
    @State private var advancedNoteIsError = false

    var body: some View {
        @Bindable var store = store
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                settingsSection("外观", icon: "paintbrush.pointed") {
                    HStack {
                        Text("外观模式")
                        Spacer(minLength: 20)
                        Picker("外观模式", selection: $store.appearance) {
                            Text("跟随系统").tag(ThemeAppearance.system)
                            Text("浅色").tag(ThemeAppearance.light)
                            Text("深色").tag(ThemeAppearance.dark)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 280)
                    }
                }
                settingsSection("影视资料", icon: "photo.on.rectangle.angled") {
                    connectionRow
                    if let connectionNote {
                        Text(connectionNote)
                            .font(.system(size: 12))
                            .foregroundStyle(connectionOK == false ? theme.colors.danger.color : theme.colors.inkMuted.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Divider()
                    HStack {
                        Text("片名与简介语言")
                        Spacer(minLength: 20)
                        Picker("片名与简介语言", selection: Binding(
                            get: { model.tmdbConfig.language },
                            set: { language in
                                var config = model.tmdbConfig
                                config.language = language
                                model.tmdbConfig = config
                                resetConnectionStatus()
                            }
                        )) {
                            Text("简体中文").tag("zh-CN")
                            Text("繁體中文").tag("zh-TW")
                            Text("English").tag("en-US")
                        }
                        .labelsHidden()
                        .frame(width: 160)
                        .disabled(isChecking)
                    }
                    Divider()
                    DisclosureGroup("高级连接设置", isExpanded: $showsAdvanced) {
                        advancedSettings.padding(.top, 14)
                    }
                }
                HStack {
                    Text("ELEnglish")
                    Spacer()
                    Text("版本 \(AppModel.appVersion)")
                }
                .font(.system(size: 12))
                .foregroundStyle(theme.colors.inkMuted.color)
            }
            .padding(28)
        }
        .font(.system(size: 13))
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("设置")
        .frame(width: 640, height: 540)
        .onAppear(perform: loadAddresses)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("设置").font(.system(size: 24, weight: .semibold))
                Text("外观偏好与影视资料")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.colors.inkMuted.color)
            }
        }
    }

    private func settingsSection<Content: View>(_ title: String, icon: String,
                                               @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 14, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .rexCard()
        }
    }

    private var connectionRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("资料服务")
                Text("TMDB · 提供海报、简介和演员资料")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.colors.inkMuted.color)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                if isChecking {
                    ProgressView().controlSize(.mini)
                } else {
                    Circle().fill(connectionColor).frame(width: 6, height: 6)
                }
                Text(connectionStatus).font(.system(size: 12))
            }
            .foregroundStyle(theme.colors.inkMuted.color)
            Button(model.tmdb == nil ? "配置服务" : "检查连接") {
                if model.tmdb == nil { showsAdvanced = true }
                else { checkConnection() }
            }
            .clickablePointer()
            .disabled(isChecking)
        }
    }

    private var connectionStatus: String {
        if isChecking { return "检查中" }
        if let connectionOK { return connectionOK ? "连接正常" : "连接失败" }
        return model.tmdb == nil ? "未配置" : "已配置"
    }

    private var connectionColor: Color {
        guard let connectionOK else { return theme.colors.inkMuted.color }
        return connectionOK ? theme.colors.success.color : theme.colors.danger.color
    }

    private var advancedSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("仅在需要更换资料服务密钥或连接地址时调整。")
                .font(.system(size: 12))
                .foregroundStyle(theme.colors.inkMuted.color)
            LabeledContent("访问密钥") {
                HStack(spacing: 8) {
                    SecureField(model.hasCustomTMDBToken ? "已保存密钥" : "填写访问密钥", text: $token)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("访问密钥")
                        .onSubmit(saveToken)
                    Button("保存密钥", action: saveToken)
                        .clickablePointer()
                        .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            Text("密钥只保存在这台 Mac。")
                .font(.system(size: 12))
                .foregroundStyle(theme.colors.inkMuted.color)
            LabeledContent("资料接口") {
                TextField("https://api.themoviedb.org/3", text: Binding(
                    get: { apiBase },
                    set: { apiBase = $0; advancedNote = nil }
                ))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("资料接口地址")
                    .onSubmit(saveAddresses)
            }
            LabeledContent("图片地址") {
                TextField("https://image.tmdb.org/t/p", text: Binding(
                    get: { imageBase },
                    set: { imageBase = $0; advancedNote = nil }
                ))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("图片服务地址")
                    .onSubmit(saveAddresses)
            }
            HStack(spacing: 10) {
                if model.hasCustomTMDBToken {
                    Button("移除密钥", role: .destructive) {
                        model.tmdbToken = ""
                        resetConnectionStatus()
                        advancedNote = "已移除访问密钥"
                        advancedNoteIsError = false
                    }
                    .clickablePointer()
                }
                Spacer(minLength: 8)
                Button("恢复默认地址") {
                    model.tmdbConfig = TMDBConfig(language: model.tmdbConfig.language)
                    loadAddresses()
                    resetConnectionStatus()
                    advancedNote = "已恢复默认地址"
                    advancedNoteIsError = false
                }
                .clickablePointer()
                Button("保存地址", action: saveAddresses).clickablePointer()
            }
            .controlSize(.small)
            if let advancedNote {
                Text(advancedNote)
                    .font(.system(size: 12))
                    .foregroundStyle(advancedNoteIsError ? theme.colors.danger.color : theme.colors.inkMuted.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(isChecking)
    }

    private func loadAddresses() {
        apiBase = model.tmdbConfig.apiBase.absoluteString
        imageBase = model.tmdbConfig.imageBase.absoluteString
    }

    private func resetConnectionStatus() {
        connectionOK = nil
        connectionNote = nil
    }

    private func saveToken() {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.tmdbToken = trimmed
        token = ""
        resetConnectionStatus()
        advancedNote = "访问密钥已保存"
        advancedNoteIsError = false
    }

    private func saveAddresses() {
        guard let api = URL(string: apiBase.trimmingCharacters(in: .whitespaces)), api.host() != nil,
              let image = URL(string: imageBase.trimmingCharacters(in: .whitespaces)), image.host() != nil else {
            advancedNote = "地址格式不正确，请填写完整网址。"
            advancedNoteIsError = true
            return
        }
        model.tmdbConfig = TMDBConfig(apiBase: api, imageBase: image, language: model.tmdbConfig.language)
        resetConnectionStatus()
        advancedNote = "连接地址已保存"
        advancedNoteIsError = false
    }

    private func checkConnection() {
        let token = model.tmdbToken
        let config = model.tmdbConfig
        isChecking = true
        connectionNote = nil
        Task {
            defer { isChecking = false }
            // 检查连接必须实际请求服务，不能把已有资料缓存当作连接成功。
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let client = TMDBClient(token: token, config: config, session: session, cacheDirectory: nil)
            do {
                let hits = try await client.search(.tv, query: "Friends", year: 1994)
                connectionOK = true
                connectionNote = hits.isEmpty ? "连接成功，暂未查到测试资料。" : nil
            } catch {
                connectionOK = false
                connectionNote = error.localizedDescription
            }
        }
    }
}

#Preview("设置") {
    SettingsView()
        .appEnvironment(AppModel())
}
