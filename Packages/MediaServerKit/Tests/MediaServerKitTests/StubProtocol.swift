import Foundation
import Synchronization

/// 拦截 URLSession 请求的测试桩。按主机名区分处理函数，测试可以并行运行互不干扰。
final class StubProtocol: URLProtocol {
    struct Response: Sendable {
        var status: Int
        var body: Data
        static func json(_ s: String, status: Int = 200) -> Response { Response(status: status, body: Data(s.utf8)) }
    }

    typealias Handler = @Sendable (URLRequest, Data?) -> Response
    private static let handlers = Mutex<[String: Handler]>([:])

    static func session(host: String, handler: @escaping Handler) -> URLSession {
        handlers.withLock { $0[host] = handler }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host() ?? ""
        guard let handler = Self.handlers.withLock({ $0[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read)
        let response = handler(request, body)
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: nil,
                                   headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}
