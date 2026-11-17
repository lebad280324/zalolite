import Foundation
import AppKit
import CryptoKit

/// A published Zalolite build on GitHub Releases, reduced to what the updater needs.
struct UpdateRelease: Equatable {
    let version: String
    let notes: String
    let pageURL: URL?
    let archive: URL
    let archiveName: String
    let archiveSize: Int
    let checksums: URL

    /// Releases live on the project's own GitHub repository (not a Zalo host).
    static let repository = "lebad280324/zalolite"
    static let latestURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!

    /// Reads the `releases/latest` payload; nil when the release has no Apple Silicon ZIP or no checksum list.
    init?(json data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["draft"] as? Bool) != true, (root["prerelease"] as? Bool) != true,
              let tag = root["tag_name"] as? String, let version = Self.normalized(tag),
              let assets = root["assets"] as? [[String: Any]] else { return nil }
        func asset(_ match: (String) -> Bool) -> (String, URL, Int)? {
            for item in assets {
                guard let name = item["name"] as? String, match(name),
                      let link = (item["browser_download_url"] as? String).flatMap(URL.init(string:)),
                      Self.trusted(link) else { continue }
                return (name, link, item["size"] as? Int ?? 0)
            }
            return nil
        }
        guard let zip = asset({ $0.hasPrefix("Zalolite-") && $0.hasSuffix("-macos-arm64.zip") && !$0.contains("/") }),
              let sums = asset({ $0 == "SHA256SUMS.txt" }) else { return nil }
        self.version = version
        notes = (root["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        pageURL = (root["html_url"] as? String).flatMap(URL.init(string:))
        archiveName = zip.0; archive = zip.1; archiveSize = zip.2; checksums = sums.1
    }

    /// Download links must be HTTPS on github.com; GitHub then redirects to its own asset host.
    static func trusted(_ url: URL) -> Bool { url.scheme == "https" && url.host == "github.com" }

    /// "v0.0.11" → "0.0.11"; nil for tags that are not plain dotted numbers.
    static func normalized(_ tag: String) -> String? {
        let value = tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 4, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        return value
    }

    /// Numeric comparison of dotted versions ("0.0.10" is newer than "0.0.9").
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }, b = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Finds the lowercase SHA-256 for `name` in a `shasum -a 256` listing.
    static func checksum(for name: String, in listing: String) -> String? {
        for line in listing.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count == 2 else { continue }
            let file = fields[1].hasPrefix("*") ? String(fields[1].dropFirst()) : String(fields[1])
            let hash = fields[0].lowercased()
            if file == name, hash.count == 64, hash.allSatisfy(\.isHexDigit) { return hash }
        }
        return nil
    }
}

/// Checks GitHub Releases, downloads the ZIP, verifies it and swaps the app in place.
@MainActor final class SoftwareUpdater: NSObject, ObservableObject {
    static let shared = SoftwareUpdater()
    static let autoCheckKey = "nativeAutoCheckUpdates"
    private static let lastCheckKey = "nativeLastUpdateCheck"

    enum Phase: Equatable {
        case idle, checking, upToDate, available(UpdateRelease)
        case downloading(UpdateRelease, Double), installing(UpdateRelease)
        /// Downloaded and verified, but the app folder is not writable: the user moves it.
        case manual(UpdateRelease, URL)
        case failed(String)
    }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var lastCheck: Date? = UserDefaults.standard.object(forKey: lastCheckKey) as? Date
    private var task: Task<Void, Never>?

    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0" }
    var available: UpdateRelease? {
        switch phase { case .available(let release), .downloading(let release, _): return release; default: return nil }
    }
    var busy: Bool {
        switch phase { case .checking, .downloading, .installing: return true; default: return false }
    }

    /// Daily background check at launch, when enabled; demo windows never phone home.
    func checkIfDue() {
        guard !BackgroundMode.isDemo, UserDefaults.standard.object(forKey: Self.autoCheckKey) as? Bool ?? true else { return }
        if let lastCheck, Date().timeIntervalSince(lastCheck) < 24 * 3600 { return }
        check(quietly: true)
    }

    func check(quietly: Bool = false) {
        guard !busy else { return }
        if !quietly { phase = .checking }
        task = Task {
            do {
                var request = URLRequest(url: UpdateRelease.latestURL, timeoutInterval: 20)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("Zalolite-Updater", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else { throw UpdateError(status == 404 ? "Chưa có bản phát hành nào." : "GitHub trả về lỗi \(status).") }
                guard let release = UpdateRelease(json: data) else { throw UpdateError("Bản phát hành mới nhất chưa có gói cho Mac Apple Silicon.") }
                lastCheck = Date(); UserDefaults.standard.set(lastCheck, forKey: Self.lastCheckKey)
                phase = UpdateRelease.isNewer(release.version, than: currentVersion) ? .available(release) : .upToDate
            } catch is CancellationError {
                phase = .idle
            } catch {
                // A failed background check stays silent; a manual one explains itself.
                phase = quietly ? .idle : .failed(Self.message(error))
            }
        }
    }

    func cancel() { task?.cancel(); task = nil; phase = available.map { .available($0) } ?? .idle }

    func install(_ release: UpdateRelease) {
        guard !busy else { return }
        phase = .downloading(release, 0)
        task = Task {
            do {
                let work = FileManager.default.temporaryDirectory.appendingPathComponent("ZaloliteUpdate-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                let (listing, _) = try await URLSession.shared.data(from: release.checksums)
                guard let expected = UpdateRelease.checksum(for: release.archiveName, in: String(decoding: listing, as: UTF8.self)) else {
                    throw UpdateError("Không tìm thấy mã kiểm tra của gói cập nhật.")
                }
                let zip = try await Self.download(release.archive, to: work.appendingPathComponent(release.archiveName)) { value in
                    Task { @MainActor in
                        if case .downloading = SoftwareUpdater.shared.phase { SoftwareUpdater.shared.phase = .downloading(release, value) }
                    }
                }
                try Task.checkCancellation()
                phase = .installing(release)
                let app = try await Task.detached(priority: .userInitiated) {
                    try Self.verify(zip, sha256: expected)
                    return try Self.extract(zip, into: work, version: release.version)
                }.value
                let target = Bundle.main.bundleURL
                guard target.pathExtension == "app",
                      FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
                    phase = .manual(release, app)
                    NSWorkspace.shared.activateFileViewerSelecting([app])
                    return
                }
                try Self.relaunch(replacing: target, with: app, work: work)
            } catch is CancellationError {
                phase = .available(release)
            } catch {
                phase = .failed(Self.message(error))
            }
        }
    }

    // MARK: - Steps

    /// Streams the archive to disk off the main actor, reporting progress at most once per percent.
    nonisolated private static func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("Không tải được gói cập nhật.") }
        let total = max(response.expectedContentLength, 1)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var buffer = Data(); buffer.reserveCapacity(1 << 16)
        var written: Int64 = 0, reported = -1
        for try await byte in bytes {
            if buffer.isEmpty { try Task.checkCancellation() }
            buffer.append(byte)
            if buffer.count >= 1 << 16 {
                try handle.write(contentsOf: buffer); written += Int64(buffer.count); buffer.removeAll(keepingCapacity: true)
                let percent = Int(Double(written) / Double(total) * 100)
                if percent != reported { reported = percent; progress(min(Double(written) / Double(total), 1)) }
                guard written < 512 << 20 else { throw UpdateError("Gói cập nhật lớn bất thường.") }
            }
        }
        try handle.write(contentsOf: buffer)
        progress(1)
        return destination
    }

    nonisolated private static func verify(_ file: URL, sha256 expected: String) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == expected else { throw UpdateError("Gói tải về không khớp mã SHA-256. Đã hủy cài đặt.") }
    }

    /// Unpacks with `ditto` and checks the bundle identity, version and code signature before use.
    nonisolated private static func extract(_ zip: URL, into work: URL, version: String) throws -> URL {
        let folder = work.appendingPathComponent("unpacked", isDirectory: true)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, folder.path], failure: "Không giải nén được gói cập nhật.")
        let app = folder.appendingPathComponent("Zalolite.app", isDirectory: true)
        guard let info = Bundle(url: app)?.infoDictionary,
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info["CFBundleShortVersionString"] as? String == version else {
            throw UpdateError("Gói cập nhật không phải Zalolite \(version).")
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path], failure: "Chữ ký của gói cập nhật không hợp lệ.")
        return app
    }

    /// Hands the swap to a small script that waits for this process to quit, replaces the bundle
    /// (restoring the old one if the move fails) and opens the new version.
    private static func relaunch(replacing target: URL, with app: URL, work: URL) throws {
        let script = work.appendingPathComponent("install.sh")
        try """
        #!/bin/sh
        pid="$1"; target="$2"; new="$3"; backup="$4"
        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
        mv "$target" "$backup" || { open "$target"; exit 1; }
        if mv "$new" "$target"; then
          xattr -dr com.apple.quarantine "$target" 2>/dev/null
          rm -rf "$backup"
        else
          mv "$backup" "$target"
        fi
        open "$target"
        """.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), target.path, app.path,
                             work.appendingPathComponent("previous.app").path]
        try process.run()
        NSApp.terminate(nil)
    }

    nonisolated private static func run(_ tool: String, _ arguments: [String], failure: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError(failure) }
    }

    private static func message(_ error: Error) -> String {
        if let error = error as? UpdateError { return error.message }
        if (error as? URLError)?.code == .notConnectedToInternet { return "Không có kết nối mạng." }
        return "Không kiểm tra được bản cập nhật. Hãy thử lại sau."
    }
}

struct UpdateError: Error { let message: String; init(_ message: String) { self.message = message } }
