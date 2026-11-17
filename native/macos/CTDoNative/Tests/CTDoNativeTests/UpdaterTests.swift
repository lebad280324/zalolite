import XCTest
@testable import CTDoNative

final class UpdaterTests: XCTestCase {
    private func release(_ json: [String: Any], architecture: String = "arm64") -> UpdateRelease? {
        UpdateRelease(json: try! JSONSerialization.data(withJSONObject: json), architecture: architecture)
    }

    private func zip(_ name: String) -> [String: Any] {
        ["name": name, "size": 22_000_000, "browser_download_url": "https://github.com/lebad280324/zalolite/releases/download/v0.0.12/\(name)"]
    }

    private let assets: [[String: Any]] = [
        ["name": "SHA256SUMS.txt", "size": 286, "browser_download_url": "https://github.com/lebad280324/zalolite/releases/download/v0.0.11/SHA256SUMS.txt"],
        ["name": "Zalolite-0.0.11-macos-arm64.dmg", "size": 13_000_000, "browser_download_url": "https://github.com/lebad280324/zalolite/releases/download/v0.0.11/Zalolite-0.0.11-macos-arm64.dmg"],
        ["name": "Zalolite-0.0.11-macos-arm64.zip", "size": 12_000_000, "browser_download_url": "https://github.com/lebad280324/zalolite/releases/download/v0.0.11/Zalolite-0.0.11-macos-arm64.zip"],
    ]

    func testReadsLatestReleaseAndPicksTheAppleSiliconZip() throws {
        let value = try XCTUnwrap(release(["tag_name": "v0.0.11", "body": "- Sửa lỗi", "html_url": "https://github.com/lebad280324/zalolite/releases/tag/v0.0.11", "assets": assets]))
        XCTAssertEqual(value.version, "0.0.11")
        XCTAssertEqual(value.archiveName, "Zalolite-0.0.11-macos-arm64.zip")
        XCTAssertEqual(value.archiveSize, 12_000_000)
        XCTAssertEqual(value.checksums.lastPathComponent, "SHA256SUMS.txt")
    }

    func testRejectsDraftsPrereleasesOddTagsAndForeignHosts() {
        XCTAssertNil(release(["tag_name": "v0.0.11", "prerelease": true, "assets": assets]))
        XCTAssertNil(release(["tag_name": "v0.0.11", "draft": true, "assets": assets]))
        XCTAssertNil(release(["tag_name": "nightly", "assets": assets]))
        var foreign = assets
        foreign[2]["browser_download_url"] = "https://example.com/Zalolite-0.0.11-macos-arm64.zip"
        XCTAssertNil(release(["tag_name": "v0.0.11", "assets": foreign]))
        XCTAssertNil(release(["tag_name": "v0.0.11", "assets": Array(assets.dropFirst())]))
    }

    func testPrefersUniversalAndNeverPicksAnotherChipsZip() throws {
        let sums = assets[0]
        let universal = [sums, zip("Zalolite-0.0.12-macos-arm64.zip"), zip("Zalolite-0.0.12-macos-universal.zip")]
        for architecture in ["arm64", "x86_64"] {
            let value = try XCTUnwrap(release(["tag_name": "v0.0.12", "assets": universal], architecture: architecture))
            XCTAssertEqual(value.archiveName, "Zalolite-0.0.12-macos-universal.zip")
        }
        let appleOnly = [sums, zip("Zalolite-0.0.12-macos-arm64.zip")]
        XCTAssertNil(release(["tag_name": "v0.0.12", "assets": appleOnly], architecture: "x86_64"))
        let intel = try XCTUnwrap(release(["tag_name": "v0.0.12", "assets": [sums, zip("Zalolite-0.0.12-macos-x86_64.zip")]], architecture: "x86_64"))
        XCTAssertEqual(intel.archiveName, "Zalolite-0.0.12-macos-x86_64.zip")
    }

    func testComparesVersionsNumerically() {
        XCTAssertTrue(UpdateRelease.isNewer("0.0.10", than: "0.0.9"))
        XCTAssertTrue(UpdateRelease.isNewer("0.1", than: "0.0.99"))
        XCTAssertFalse(UpdateRelease.isNewer("0.0.10", than: "0.0.10"))
        XCTAssertFalse(UpdateRelease.isNewer("0.0.9", than: "0.0.10"))
    }

    func testFindsChecksumForTheExactFileOnly() {
        let hash = String(repeating: "a", count: 64)
        let listing = "\(String(repeating: "b", count: 64))  Zalolite-0.0.11-macos-arm64.dmg\n\(hash.uppercased())  Zalolite-0.0.11-macos-arm64.zip\n"
        XCTAssertEqual(UpdateRelease.checksum(for: "Zalolite-0.0.11-macos-arm64.zip", in: listing), hash)
        XCTAssertNil(UpdateRelease.checksum(for: "Zalolite.zip", in: listing))
        XCTAssertNil(UpdateRelease.checksum(for: "x.zip", in: "short  x.zip"))
    }
}
