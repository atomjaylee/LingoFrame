import Foundation
import Testing
@testable import DesignSystem

private let server = URL(string: "https://drive.example:443/emby")!

@Test func headersOnlyGoToTheRegisteredServer() {
    var authorization = ImageAuthorization()
    authorization.setHeaders(["X-Emby-Token": "t"], forServer: server)
    #expect(authorization.headers(for: URL(string: "https://drive.example/Items/1/Images/Primary")!) == ["X-Emby-Token": "t"])
    #expect(authorization.headers(for: URL(string: "https://image.tmdb.org/t/p/w500/a.jpg")!).isEmpty)
    #expect(authorization.headers(for: URL(string: "https://drive.example:8443/a.jpg")!).isEmpty)
    #expect(authorization.headers(for: URL(string: "http://drive.example/a.jpg")!).isEmpty)

    authorization.setHeaders(nil, forServer: server)
    #expect(authorization.headers(for: server).isEmpty)
}

@Test func crossOriginRedirectDropsCredentials() {
    var request = URLRequest(url: URL(string: "https://cdn.example/a.jpg")!)
    request.setValue("t", forHTTPHeaderField: "X-Emby-Token")
    let stripped = ImageAuthorization.redirect(request, from: server, removing: ["X-Emby-Token"])
    #expect(stripped.value(forHTTPHeaderField: "X-Emby-Token") == nil)

    request.url = URL(string: "https://drive.example/other.jpg")!
    let kept = ImageAuthorization.redirect(request, from: server, removing: ["X-Emby-Token"])
    #expect(kept.value(forHTTPHeaderField: "X-Emby-Token") == "t")
}
