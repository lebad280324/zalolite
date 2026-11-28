import AppKit
import Darwin
import ImageIO
import XCTest
@testable import CTDoNative

final class MediaMemoryBenchmark: XCTestCase {
    @MainActor
    func testLongThumbnailSession() async throws {
        guard ProcessInfo.processInfo.environment["CTDOZLITE_MEDIA_MEMORY_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt-in synthetic media memory benchmark")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zalolite-media-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try Self.photoFixture()
        let urls = try (0..<240).map { index in
            let url = directory.appendingPathComponent("photo-\(index).jpg")
            try fixture.write(to: url)
            return url
        }
        let cache = PhotoCache()
        let preview = try XCTUnwrap(CGContext(data: nil, width: 560, height: 420,
                                              bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let initialFootprint = try Self.footprint()
        var footprints: [UInt64] = []
        var times: [Double] = []
        for (index, url) in urls.enumerated() {
            let start = DispatchTime.now().uptimeNanoseconds
            let thumbnail = try await cache.image(url)
            let bitmap = try XCTUnwrap(thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil))
            preview.draw(bitmap, in: CGRect(x: 0, y: 0, width: 560, height: 420))
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            if (index + 1) % 80 == 0 { footprints.append(try Self.footprint()) }
        }
        let cached = urls.compactMap { cache.cached($0) }
        let retainedPixels = cached.reduce(0) { $0 + Int($1.size.width * $1.size.height) }
        times.sort()
        func percentile(_ fraction: Double) -> Double {
            times[min(times.count - 1, Int(Double(times.count) * fraction))]
        }
        let report: [String: Any] = [
            "task": "inline_photo_history",
            "iterations": times.count,
            "min_ms": times[0], "avg_ms": times.reduce(0, +) / Double(times.count),
            "p50_ms": percentile(0.50), "p95_ms": percentile(0.95), "p99_ms": percentile(0.99),
            "initial_footprint_bytes": initialFootprint,
            "footprint_bytes_after_each_80": footprints,
            "cached_images": cached.count,
            "cached_pixels": retainedPixels
        ]
        let json = try JSONSerialization.data(withJSONObject: report, options: .sortedKeys)
        print("MEDIA_MEMORY_BENCHMARK " + String(decoding: json, as: UTF8.self))
    }

    static func photoFixture() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1600, height: 1200,
                                              bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1600, height: 1200))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private static func footprint() throws -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        // The kernel fills the task_vm_info_data_t buffer through the integer pointer expected by task_info.
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw POSIXError(.EIO) }
        return info.phys_footprint
    }
}
