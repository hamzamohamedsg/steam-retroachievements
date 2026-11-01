import Foundation
import Testing
@testable import RACore

private func reply(_ tag: String, status: Int = 200) -> FakeTransport {
    FakeTransport { _ in (Data(#"{"tag_name":"\#(tag)","html_url":"https://github.com/o/r/releases/tag/\#(tag)"}"#.utf8), status) }
}

@Test func comparesVersionsNumerically() {
    #expect(UpdateChecker.isNewer("v0.1.10", than: "0.1.9"))
    #expect(UpdateChecker.isNewer("1.0", than: "0.9.9"))
    #expect(!UpdateChecker.isNewer("v0.1.4", than: "0.1.4"))
    #expect(!UpdateChecker.isNewer("v0.1.3", than: "0.1.4"))
    #expect(!UpdateChecker.isNewer("nightly", than: "0.1.4"))
}

@Test func reportsOnlyNewerReleases() async {
    let newer = await UpdateChecker.newerRelease(current: "0.1.4", transport: reply("v0.2.0"))
    #expect(newer?.version == "0.2.0")
    #expect(newer?.page.absoluteString == "https://github.com/o/r/releases/tag/v0.2.0")
    #expect(await UpdateChecker.newerRelease(current: "0.1.4", transport: reply("v0.1.4")) == nil)
    #expect(await UpdateChecker.newerRelease(current: "0.1.4", transport: reply("v0.2.0", status: 403)) == nil)
}

@Test func versionMatchesInfoPlist() throws {
    let plist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/Info.plist")
    let dict = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any]
    #expect(dict?["CFBundleShortVersionString"] as? String == UpdateChecker.currentVersion)
}
