import Foundation
import os

public struct ClientIdentity: Hashable, Sendable {
    public var appName: String
    public var appVersion: String
    public var deviceName: String
    public var deviceID: String

    public init(appName: String, appVersion: String, deviceName: String, deviceID: String) {
        self.appName = appName
        self.appVersion = appVersion
        self.deviceName = deviceName
        self.deviceID = deviceID
    }

    public var userAgent: String { "\(appName)/\(appVersion) (macOS)" }

    func authorizationHeader(token: String?) -> String {
        // URLSession 会在非 ASCII 字符处截断请求头。电脑名常含弯引号或中文，
        // 一旦截断，后面的 Version 就不会发给 Emby，登录会报 appVersion 为空。
        func clean(_ value: String, fallback: String) -> String {
            let bytes = value.utf8.filter { (0x20...0x7E).contains($0) && $0 != 0x22 && $0 != 0x5C }
            let result = String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? ""
            return result.isEmpty ? fallback : result
        }
        var value = #"MediaBrowser Client="\#(clean(appName, fallback: "ELEnglish"))", Device="\#(clean(deviceName, fallback: "Mac"))", "#
            + #"DeviceId="\#(clean(deviceID, fallback: "unknown-device"))", Version="\#(clean(appVersion, fallback: "0"))""#
        if let token { value += #", Token="\#(clean(token, fallback: ""))""# }
        return value
    }
}

public enum EmbyError: Error, LocalizedError, Equatable {
    case invalidAddress
    case notAnEmbyServer
    case unauthorized
    case http(status: Int, message: String)
    case network(String)
    case decoding(String)
    case noPlayableSource
    case serverConversionUnavailable(container: String)

    public var errorDescription: String? {
        switch self {
        case .invalidAddress: "服务器地址格式不正确，例如：http://192.168.1.10:8096"
        case .notAnEmbyServer: "这个地址上没有找到 Emby 服务器"
        case .unauthorized: "用户名或密码错误，或者登录已过期"
        // 反向代理出错时返回的是整页 HTML，不显示给用户。
        case .http(let status, let message):
            "服务器返回错误 \(status)" + (message.isEmpty || message.contains("<") ? "" : "：\(message)")
        case .network(let message): "网络错误：\(message)"
        case .decoding(let message): "无法解析服务器返回的数据：\(message)"
        case .noPlayableSource: "服务器没有返回可播放的地址"
        case .serverConversionUnavailable(let container):
            "该视频是 \(container)，当前版本需要 Emby 转换后播放。请在 Emby 用户权限中开启“允许媒体转换”或“允许视频转码”"
        }
    }
}

enum EmbyCoding {
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .custom { keys in
            let raw = keys.last?.stringValue ?? ""
            return AnyKey(raw.prefix(1).lowercased() + raw.dropFirst())
        }
        return d
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .custom { keys in
            let raw = keys.last?.stringValue ?? ""
            return AnyKey(raw.prefix(1).uppercased() + raw.dropFirst())
        }
        return e
    }()

    struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

/// HTTP 层：拼地址、加认证头、把状态码映射成 EmbyError。令牌只放在请求头里，不进日志。
struct Transport: Sendable {
    let baseURL: URL
    let identity: ClientIdentity
    let token: String?
    let session: URLSession
    private static let log = Logger(subsystem: "app.elenglish", category: "emby")

    func url(_ path: String, _ query: [String: String?] = [:]) -> URL {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        let items = query.compactMap { k, v in v.map { URLQueryItem(name: k, value: $0) } }.sorted { $0.name < $1.name }
        components.queryItems = items.isEmpty ? nil : items
        return components.url!
    }

    func get<T: Decodable>(_ path: String, _ query: [String: String?] = [:], as: T.Type = T.self) async throws -> T {
        try await send(method: "GET", url: url(path, query), body: nil)
    }

    func post<T: Decodable>(_ path: String, _ query: [String: String?] = [:], body: (some Encodable)?,
                            as: T.Type = T.self) async throws -> T {
        try await send(method: "POST", url: url(path, query), body: body.map { try EmbyCoding.encoder.encode($0) })
    }

    func postIgnoringResult(_ path: String, _ query: [String: String?] = [:], body: (some Encodable)?) async throws {
        _ = try await raw(method: "POST", url: url(path, query), body: body.map { try EmbyCoding.encoder.encode($0) })
    }

    func delete(_ path: String, _ query: [String: String?] = [:]) async throws {
        _ = try await raw(method: "DELETE", url: url(path, query), body: nil)
    }

    private func send<T: Decodable>(method: String, url: URL, body: Data?) async throws -> T {
        let data = try await raw(method: method, url: url, body: body)
        do {
            return try EmbyCoding.decoder.decode(T.self, from: data)
        } catch {
            Self.log.error("解码失败 \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
            throw EmbyError.decoding(String(describing: T.self))
        }
    }

    func raw(method: String, url: URL, body: Data?) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue(identity.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(identity.authorizationHeader(token: token), forHTTPHeaderField: "X-Emby-Authorization")
        if let token { request.setValue(token, forHTTPHeaderField: "X-Emby-Token") }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        var data = Data()
        var response: URLResponse?
        var status = 0
        // 网关错误（502/503/504）和网络抖动多半是一瞬间的，自动重试两次再报错。
        for attempt in 0..<3 {
            if attempt > 0 { try await Task.sleep(for: .milliseconds(400 * attempt)) }
            do {
                (data, response) = try await (url.isPrivateNetwork ? Self.direct : session).data(for: request)
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    throw CancellationError()
                }
                if attempt == 2 {
                    throw EmbyError.network(error.localizedDescription)
                }
                continue
            }
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if ![502, 503, 504].contains(status) { break }
        }
        Self.log.debug("\(method, privacy: .public) \(url.path, privacy: .public) → \(status)")
        switch status {
        case 200..<300: return data
        case 401, 403: throw EmbyError.unauthorized
        default:
            let message = String(data: data.prefix(200), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            Self.log.error("\(method, privacy: .public) \(url.path, privacy: .public) → \(status)")
            throw EmbyError.http(status: status, message: message)
        }
    }
}

struct Empty: Codable {}

extension Transport {
    /// 局域网服务器不走系统代理：代理软件转发内网地址时偶尔返回 502，导致整页加载或播放失败。
    static let direct: URLSession = {
        let config = URLSessionConfiguration.default
        config.connectionProxyDictionary = [:]
        return URLSession(configuration: config)
    }()
}

extension URL {
    /// 地址是不是本机或局域网（127.x、10.x、172.16–31.x、192.168.x、169.254.x、.local、IPv6 本地）。
    public var isPrivateNetwork: Bool {
        guard let host = host()?.lowercased() else { return false }
        if host == "localhost" || host.hasSuffix(".local") { return true }
        if host.contains(":") { return host == "::1" || host.hasPrefix("fe80:") || host.hasPrefix("fd") || host.hasPrefix("fc") }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (10, _), (127, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        default: return false
        }
    }
}
