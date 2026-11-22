import Foundation
import Testing

@testable import RClick

@MainActor
struct UpdateCheckerTests {
    @Test func updateCheckNeverRequestsStars() async {
        var paths: [String] = []
        let checker = GitHubReleaseChecker(owner: "anzchy", repo: "RClick") { request in
            let url = request.url!
            paths.append(url.path)
            guard url.path == "/repos/anzchy/RClick/releases/latest" else {
                Issue.record("Unexpected repository/stars request")
                throw URLError(.unsupportedURL)
            }
            return (Data(), HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        _ = await checker.checkForUpdate(currentVersion: "2.0.0")
        #expect(paths == ["/repos/anzchy/RClick/releases/latest"])
    }
}
