import AppKit
import DesignSystem
import MediaServerKit
import SwiftUI

/// 添加资源库，照抄 Rex 的两步对话框：先选来源类型（目前只支持 Emby），再填写连接信息。
/// 「智能识别」可以直接粘贴一段包含地址、用户名、密码的文字，自动拆到各个输入框里。
/// 密码只用于登录，不会被保存；保存的是服务器发放的访问令牌。
struct AddServerDialog: View {
    @Binding var isPresented: Bool
    @State private var step = Step.pick

    private enum Step { case pick, emby }

    var body: some View {
        ZStack {
            Color.black.opacity(0.38)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }
            Group {
                switch step {
                case .pick: SourcePicker(close: close) { step = .emby }
                case .emby: EmbyConnectForm(close: close)
                }
            }
            .frame(width: 544)
            .background(RexChrome.sheet.color, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.16), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
            .transition(.scale(scale: 0.97).combined(with: .opacity))
        }
        .background {
            Button("取消", action: close).keyboardShortcut(.cancelAction).hidden()
        }
        #if DEBUG
        .onAppear { if UserDefaults.standard.string(forKey: "debugRoute") == "library:emby" { step = .emby } }
        #endif
    }

    private func close() { isPresented = false }
}

// MARK: - 第一步：选类型

private struct SourcePicker: View {
    let close: () -> Void
    let chooseEmby: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 43, height: 43)
                VStack(alignment: .leading, spacing: 2) {
                    Text("添加资源库").font(.system(size: 17, weight: .bold))
                    Text("添加后，推荐和详情里的作品会自动匹配到这里的片源。").font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.85))
                }
                Spacer()
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 13, weight: .bold)) }
                    .buttonStyle(.plain)
                    .frame(width: 32, height: 32)
                    .overlay(Circle().strokeBorder(.primary.opacity(0.22), lineWidth: 1))
                    .contentShape(Circle())
                    .accessibilityLabel("关闭")
            }
            .padding(.leading, 4)

            section("媒体服务器") {
                Button(action: chooseEmby) { tile("Emby") { EmbyMark(size: 58) } }.buttonStyle(.plain)
                tile("Jellyfin", soon: true) { symbol("triangle.fill", Color(red: 0.48, green: 0.43, blue: 0.84)) }
                tile("Plex", soon: true) {
                    Text("plex").font(.system(size: 19, weight: .heavy)).foregroundStyle(.white)
                        .frame(width: 58, height: 58).background(.black, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            section("文件系统") {
                tile("本地文件夹", soon: true) { symbol("folder.fill", .blue) }
                tile("SMB", soon: true) { symbol("server.rack", .blue) }
                tile("WebDAV", soon: true) { symbol("network", .blue) }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 24)
        .padding(.bottom, 30)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 17, weight: .semibold))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 16) { content() }
        }
        .padding(.top, 24)
    }

    private func tile<Icon: View>(_ name: String, soon: Bool = false, @ViewBuilder icon: () -> Icon) -> some View {
        VStack(spacing: 8) {
            icon().frame(width: 61, height: 61)
            Text(name).font(.system(size: 13, weight: .semibold))
            if soon { Text("即将支持").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).padding(.top, -6) }
        }
        .opacity(soon ? 0.38 : 1)
        .contentShape(Rectangle())
    }

    private func symbol(_ name: String, _ color: Color) -> some View {
        Image(systemName: name).font(.system(size: 30)).foregroundStyle(.white)
            .frame(width: 58, height: 58)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - 第二步：Emby 连接信息

private struct EmbyConnectForm: View {
    let close: () -> Void
    @Environment(AppModel.self) private var model

    @State private var pasted = ""
    @AppStorage("login.lastHost") private var host = ""
    @AppStorage("login.lastPort") private var port = ""
    @AppStorage("login.lastPath") private var path = ""
    @AppStorage("login.lastHTTPS") private var https = false
    @AppStorage("login.lastUser") private var username = ""
    @State private var password = ""
    @State private var showsPassword = false
    @State private var probed: (url: URL, info: ServerInfo)?
    @State private var probedAddress: String?
    @State private var isBusy = false
    @State private var message: (text: String, isError: Bool)?
    @FocusState private var focus: Field?

    private enum Field { case pasted, host, port, path, username, password }

    private var address: String {
        var a = (https ? "https://" : "http://") + host.trimmingCharacters(in: .whitespaces)
        if !port.isEmpty { a += ":" + port.trimmingCharacters(in: .whitespaces) }
        let p = path.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if !p.isEmpty { a += "/" + p }
        return a
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("添加 Emby 资源库").font(.system(size: 13, weight: .bold)).frame(maxWidth: .infinity)

            label("智能识别")
            ZStack(alignment: .bottomTrailing) {
                TextEditor(text: $pasted)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
                    .focused($focus, equals: .pasted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 8)
                    .overlay(alignment: .topLeading) {
                        if pasted.isEmpty {
                            Text("粘贴包含链接、用户名和密码的线路信息").font(.system(size: 14)).foregroundStyle(.tertiary)
                                .padding(.horizontal, 11).padding(.vertical, 8).allowsHitTesting(false)
                        }
                    }
                Button(pasted.isEmpty ? "粘贴并识别" : "识别") {
                    if pasted.isEmpty { pasted = NSPasteboard.general.string(forType: .string) ?? "" }
                    recognize()
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .bold))
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(.black.opacity(0.35), in: Capsule())
                .padding(10)
            }
            .frame(height: 110)
            .fieldChrome()

            label("连接地址")
            HStack(spacing: 0) {
                TextField("服务域名或 IP 地址", text: $host).focused($focus, equals: .host)
                    .onChange(of: host) { splitIfURL() }
                Text(":").foregroundStyle(.secondary).padding(.horizontal, 8)
                TextField("端口", text: $port).focused($focus, equals: .port).frame(width: 90)
                Text("/").foregroundStyle(.secondary).padding(.horizontal, 8)
                TextField("例如 emby", text: $path).focused($focus, equals: .path).frame(width: 100)
            }
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .padding(.horizontal, 11)
            .frame(height: 30)
            .fieldChrome()

            HStack {
                Text("开启 HTTPS").font(.system(size: 14, weight: .medium))
                Spacer()
                Toggle("开启 HTTPS", isOn: $https).labelsHidden().toggleStyle(.switch).tint(RexChrome.accentBlue.color)
            }
                .padding(.leading, 15).padding(.trailing, 14)
                .frame(height: 40)
                .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 1))
                .padding(.top, 12)

            label("用户名")
            TextField("用户名", text: $username)
                .textContentType(.username)
                .focused($focus, equals: .username)
                .onSubmit { focus = .password }
                .textFieldStyle(.plain).font(.system(size: 14))
                .padding(.horizontal, 11).frame(height: 30).fieldChrome()

            label("密码")
            HStack {
                Group {
                    if showsPassword { TextField("密码（可以为空）", text: $password) }
                    else { SecureField("密码（可以为空）", text: $password) }
                }
                .textContentType(.password)
                .focused($focus, equals: .password)
                .onSubmit(save)
                Button { showsPassword.toggle() } label: { Image(systemName: showsPassword ? "eye" : "eye.slash") }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showsPassword ? "隐藏密码" : "显示密码")
            }
            .textFieldStyle(.plain).font(.system(size: 14))
            .padding(.horizontal, 11).frame(height: 30).fieldChrome()

            HStack(spacing: 10) {
                Button("测试连通性", action: test).disabled(host.isEmpty || isBusy)
                if isBusy { ProgressView().controlSize(.small) }
                if let message {
                    HStack(spacing: 6) {
                        Circle().fill(message.isError ? Color.red : RexChrome.online.color).frame(width: 7, height: 7)
                        Text(message.text).lineLimit(2)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(message.isError ? Color.red : .secondary)
                }
            }
            .padding(.top, 14)
            .padding(.leading, 6)

            HStack(spacing: 10) {
                Spacer()
                Button("取消", action: close).frame(width: 80)
                Button("保存", action: save)
                    .buttonStyle(.borderedProminent)
                    .tint(RexChrome.accentBlue.color)
                    .keyboardShortcut(.defaultAction)
                    .disabled(host.isEmpty || username.isEmpty || isBusy)
            }
            .controlSize(.regular)
            .padding(.top, 40)
        }
        .padding(.horizontal, 22)
        .padding(.top, 16)
        .padding(.bottom, 22)
        .onAppear { focus = host.isEmpty ? .pasted : (username.isEmpty ? .username : .password) }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .bold)).padding(.leading, 2).padding(.top, 16).padding(.bottom, 7)
    }

    // MARK: 识别

    /// 从一段文字里找出地址、用户名和密码，比如：
    /// 「地址：https://emby.example.com:8920 用户名：atom 密码：123」。
    private func recognize() {
        let text = pasted
        func first(_ pattern: String) -> String? {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
            let r = m.numberOfRanges > 1 ? m.range(at: 1) : m.range
            return Range(r, in: text).map { String(text[$0]) }
        }
        if let url = first(#"(https?://[^\s，,；;"'<>]+)"#) {
            host = url
        } else if let hostPort = first(#"\b((?:\d{1,3}\.){3}\d{1,3}(?::\d{2,5})?|[a-z0-9.-]+\.[a-z]{2,}(?::\d{2,5})?)\b"#) {
            host = hostPort
        }
        splitIfURL()
        if let user = first(#"(?:用户名|账号|用户|user(?:name)?)\s*[:：=]\s*([^\s，,；;]+)"#) { username = user }
        if let pw = first(#"(?:密码|pass(?:word)?|pwd)\s*[:：=]\s*([^\s，,；;]+)"#) { password = pw }
        message = host.isEmpty ? ("没有找到服务器地址", true) : ("已识别，可以测试连通性", false)
    }

    /// 地址框里粘贴了完整链接时，拆成协议、主机、端口和路径。
    private func splitIfURL() {
        let raw = host.trimmingCharacters(in: .whitespaces)
        let candidate = raw.contains("://") ? raw : (raw.contains(":") || raw.contains("/") ? "http://" + raw : nil)
        guard let candidate, let url = URLComponents(string: candidate), let h = url.host, !h.isEmpty else { return }
        if raw.contains("://") { https = url.scheme == "https" }
        if let p = url.port { port = String(p) }
        let p = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !p.isEmpty { path = p }
        if host != h { host = h }
    }

    // MARK: 连接

    private func test() {
        run {
            let result = try await model.connector.probe(address)
            probed = result
            probedAddress = address
            let name = result.info.serverName ?? "Emby"
            message = ("连接成功 · \(name)" + (result.info.version.map { " v\($0)" } ?? ""), false)
        }
    }

    private func save() {
        guard !host.isEmpty, !username.isEmpty, !isBusy else { return }
        run {
            let server: (url: URL, info: ServerInfo)
            if probedAddress == address, let probed {
                server = probed
            } else {
                server = try await model.connector.probe(address)
            }
            let account = try await model.connector.login(serverURL: server.url, info: server.info,
                                                          username: username, password: password)
            password = ""
            await model.addServer(account)
            close()
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        isBusy = true
        message = nil
        Task {
            defer { isBusy = false }
            do { try await work() } catch { message = (error.localizedDescription, true) }
        }
    }
}

private extension View {
    /// 输入框外观：圆角 7，细描边，极淡的底色。
    func fieldChrome() -> some View {
        background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.primary.opacity(0.14), lineWidth: 1))
    }
}
