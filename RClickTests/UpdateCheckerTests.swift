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
    @Test func defaultManagerUsesForkReleaseSource() async {
        #expect(UpdateSource.owner == "anzchy")
        #expect(UpdateSource.repo == "RClick")
        var urls: [String] = []
        let manager = UpdateManager(currentVersion: "2.0.0") { request in
            urls.append(request.url!.absoluteString)
            return (Data("[]".utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
                                                     httpVersion: nil, headerFields: nil)!)
        }
        await manager.checkForUpdates()
        #expect(urls == ["https://api.github.com/repos/anzchy/RClick/releases?per_page=10"])
        #expect(manager.isUpToDate)
        #expect(manager.updateError == nil)
        #expect(manager.showUpdateSheet)
    }

    @Test func managerRefreshAndAboutCheckNeverRequestStarsEvenWhenClientFails() async {
        var urls: [String] = []
        let manager = UpdateManager(currentVersion: "2.0.0") { request in
            urls.append(request.url!.absoluteString)
            throw URLError(.notConnectedToInternet)
        }
        // Normal refresh and the forced check used by the About button.
        // About has no load task or other network-loading lifecycle path.
        await manager.checkForUpdates()
        #expect(manager.updateError != nil)
        #expect(!manager.isChecking)
        await manager.checkForUpdates(force: true)
        #expect(manager.updateError != nil)
        #expect(!manager.isChecking)
        #expect(!manager.isUpToDate)
        #expect(manager.availableUpdate == nil)
        #expect(urls == [
            "https://api.github.com/repos/anzchy/RClick/releases?per_page=10",
            "https://api.github.com/repos/anzchy/RClick/releases?per_page=10"
        ])
    }

    @Test(arguments: [404, 204])
    func managerWithNoReleaseShowsUpToDateWithoutError(status: Int) async {
        let manager = UpdateManager(currentVersion: "2.0.0") { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: status,
                                     httpVersion: nil, headerFields: nil)!)
        }
        await manager.checkForUpdates(force: true)
        #expect(manager.isUpToDate)
        #expect(manager.updateError == nil)
        #expect(manager.availableUpdate == nil)
        #expect(manager.showUpdateSheet)
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

    @Test func olderReleaseWithNullTitleAndNotesDoesNotBlockNewerRelease() async {
        let older = release("1.0.0")
            .replacingOccurrences(of: "\"name\":\"Release\"", with: "\"name\":null")
            .replacingOccurrences(of: "\"body\":\"Notes\"", with: "\"body\":null")
        let result = await checker(body: "[\(older),\(release("3.0.0"))]")
            .checkForUpdate(currentVersion: "2.0.0")
        guard case .updateAvailable(let release) = result else {
            Issue.record("Nullable older release blocked newer update"); return
        }
        #expect(release.version == "3.0.0")
    }

    @Test func newestReleaseWithNullNotesIsAvailable() async {
        let newest = release("3.0.0")
            .replacingOccurrences(of: "\"body\":\"Notes\"", with: "\"body\":null")
        let result = await checker(body: "[\(newest),\(release("1.0.0"))]")
            .checkForUpdate(currentVersion: "2.0.0")
        guard case .updateAvailable(let release) = result else {
            Issue.record("Newest update with null notes missing"); return
        }
        #expect(release.version == "3.0.0")
    }

    @Test(arguments: ["42", "null"])
    func nonStringReleaseTagFails(tag: String) async {
        let invalid = release("3.0.0").replacingOccurrences(of: "\"v3.0.0\"", with: tag)
        let result = await checker(body: "[\(invalid)]").checkForUpdate(currentVersion: "2.0.0")
        guard case .failed(let reason) = result else {
            Issue.record("Malformed release shape reported success"); return
        }
        #expect(!reason.isEmpty)
    }

    @Test func wrongTopLevelShapeFails() async {
        let result = await checker(body: release("3.0.0")).checkForUpdate(currentVersion: "2.0.0")
        guard case .failed = result else { Issue.record("Object feed reported success"); return }
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
