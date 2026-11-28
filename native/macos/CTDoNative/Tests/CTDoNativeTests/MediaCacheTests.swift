import AppKit
import ImageIO
import XCTest
@testable import CTDoNative

final class MediaCacheTests: XCTestCase {
    @MainActor
    func testImageCacheEvictsLeastRecentlyUsedImagesBeforeExceedingByteLimit() {
        let cache = ImageMemoryCache<Int>(byteLimit: 12, countLimit: 10)
        let image = NSImage(size: NSSize(width: 1, height: 1))
        cache.insert(image, for: 1, bytes: 5)
        cache.insert(image, for: 2, bytes: 5)
        XCTAssertNotNil(cache.image(for: 1))

        cache.insert(image, for: 3, bytes: 7)
        XCTAssertNil(cache.image(for: 2))
        XCTAssertNotNil(cache.image(for: 1))
        XCTAssertNotNil(cache.image(for: 3))
        XCTAssertEqual(cache.retainedBytes, 12)
    }

    @MainActor
    func testOversizedImagesAreDisplayedWithoutEnteringTheCache() {
        let cache = ImageMemoryCache<Int>(byteLimit: 12, countLimit: 10)
        let image = NSImage(size: NSSize(width: 1, height: 1))
        cache.insert(image, for: 1, bytes: 5)
        cache.insert(image, for: 2, bytes: 13)
        XCTAssertNil(cache.image(for: 2))
        XCTAssertNotNil(cache.image(for: 1))
        XCTAssertEqual(cache.retainedBytes, 5)
    }

    @MainActor
    func testInlinePhotosAndAvatarsUseSeparateDecodedSizes() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zalolite-photo-test-\(UUID().uuidString).jpg")
        try MediaMemoryBenchmark.photoFixture().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = PhotoCache()

        let photo = try await cache.image(url)
        let avatar = try await cache.image(url, size: .avatar)
        XCTAssertEqual(photo.size, NSSize(width: 720, height: 540))
        XCTAssertEqual(avatar.size, NSSize(width: 192, height: 144))
        XCTAssertTrue(photo === cache.cached(url))
        XCTAssertTrue(avatar === cache.cached(url, size: .avatar))
    }

    func testAnimatedImageCostAccountsForAllDecodedFrames() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 6,
                                              bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "com.compuserve.gif" as CFString, 3, nil))
        for frame in 0..<3 {
            context.setFillColor(CGColor(red: CGFloat(frame) / 3, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertEqual(AnimatedImageCache.estimatedBytes(of: data as Data), data.length + 8 * 6 * 4 * 3)
    }
}
