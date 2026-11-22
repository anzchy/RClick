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
            guard url.path == "/repos/anzchy/RClick/releases" else {
                Issue.record("Unexpected repository/stars request")
                throw URLError(.unsupportedURL)
            }
            return (Data(), HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        _ = await checker.checkForUpdate(currentVersion: "2.0.0")
        #expect(paths == ["/repos/anzchy/RClick/releases"])
    }
    private func checker(status: Int = 200, body: String) -> GitHubReleaseChecker {
        GitHubReleaseChecker(owner: "anzchy", repo: "RClick") { request in
            (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status,
                                             httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test(arguments: [404, 204])
    func noReleaseIsUpToDate(status: Int) async {
        let result = await checker(status: status, body: "").checkForUpdate(currentVersion: "2.0.0")
        guard case .upToDate = result else {
            Issue.record("No release must be up to date, without an error")
            return
        }
    }

    @Test(arguments: ["", "[]"])
    func emptyFeedIsUpToDate(body: String) async {
        let result = await checker(body: body).checkForUpdate(currentVersion: "2.0.0")
        guard case .upToDate = result else {
            Issue.record("Empty feed must be up to date, without an error")
            return
        }
    }

    private func release(_ version: String, draft: Bool = false, prerelease: Bool = false) -> String {
        """
        {"id":1,"tag_name":"v\(version)","name":"Release","body":"Notes",
         "draft":\(draft),"prerelease":\(prerelease),"published_at":"2026-11-21T00:00:00Z",
         "assets":[],"html_url":"https://github.com/anzchy/RClick/releases/tag/v\(version)"}
        """
    }

    @Test func olderReleaseIsUpToDate() async {
        let result = await checker(body: "[\(release("1.0.0"))]").checkForUpdate(currentVersion: "2.0.0")
        guard case .upToDate = result else { Issue.record("Older release offered as update"); return }
    }

    @Test func newerReleaseIsAvailable() async {
        let result = await checker(body: "[\(release("3.0.0"))]").checkForUpdate(currentVersion: "2.0.0")
        guard case .updateAvailable(let release) = result else { Issue.record("Newer release missing"); return }
        #expect(release.version == "3.0.0")
    }

    @Test func prereleaseOnlyFeedOffersNewerRelease() async {
        let result = await checker(body: "[\(release("3.0.0", prerelease: true))]")
            .checkForUpdate(currentVersion: "2.0.0")
        guard case .updateAvailable(let release) = result else {
            Issue.record("Newer prerelease missing"); return
        }
        #expect(release.version == "3.0.0")
        #expect(release.prerelease)
    }

    @Test func draftOnlyFeedIsUpToDate() async {
        let result = await checker(body: "[\(release("9.0.0", draft: true))]")
            .checkForUpdate(currentVersion: "2.0.0")
        guard case .upToDate = result else { Issue.record("Draft offered as update"); return }
    }

    @Test func highestVersionWinsRegardlessOfFeedOrder() async {
        let feed = "[\(release("3.0.0")),\(release("9.0.0", draft: true)),\(release("4.0.0", prerelease: true)),\(release("1.0.0"))]"
        let result = await checker(body: feed).checkForUpdate(currentVersion: "2.0.0")
        guard case .updateAvailable(let release) = result else { Issue.record("Highest release missing"); return }
        #expect(release.version == "4.0.0")
    }

    @Test func malformedFeedFails() async {
        let result = await checker(body: "{broken").checkForUpdate(currentVersion: "2.0.0")
        guard case .failed(let reason) = result else { Issue.record("Malformed feed reported success"); return }
        #expect(!reason.isEmpty)
    }

    @Test func serverFailureIsNotUpToDate() async {
        let result = await checker(status: 500, body: "").checkForUpdate(currentVersion: "2.0.0")
        guard case .failed = result else { Issue.record("Server failure reported success"); return }
    }

}
