import AppKit
import ImageIO
import UniformTypeIdentifiers
import NativeBridge

/// Forwarding a photo, video or file: the core's forward call only carries text, so the original is
/// fetched (or read from its imported copy) and sent again through the normal attachment upload.
enum ForwardMedia {
    struct Source { let url: URL; let isPhoto: Bool; let name: String }

    static func source(_ message: MessageSnapshot) -> Source? {
        if let photo = MediaSource.photo(message) {
            return Source(url: photo, isPhoto: true, name: "photo")
        }
        if let raw = MediaPresentation.fileURL(message), let url = MediaSource.local(message) ?? safeWebURL(raw) {
            let name = (message.fileName ?? url.lastPathComponent).trimmingCharacters(in: .whitespacesAndNewlines)
            return Source(url: url, isPhoto: false, name: name.isEmpty ? url.lastPathComponent : name)
        }
        return nil
    }

    /// The photo's own caption; Zalo's placeholder labels are not repeated as text.
    static func caption(_ message: MessageSnapshot) -> String {
        let text = MediaPresentation.caption(message).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.hasPrefix("[") && text.hasSuffix("]") ? "" : text
    }

    /// Writes the attachment to a private temporary folder and hands back its path on the main actor.
    @MainActor static func prepare(_ source: Source, message: MessageSnapshot, completion: @escaping @MainActor (URL?) -> Void) {
        Task.detached(priority: .userInitiated) {
            let file = await write(source)
            await MainActor.run { completion(file) }
        }
    }

    private static func write(_ source: Source) async -> URL? {
        let data: Data
        if source.url.isFileURL {
            guard let local = try? Data(contentsOf: source.url, options: .mappedIfSafe) else { return nil }
            data = local
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.timeoutIntervalForRequest = 30
            let session = URLSession(configuration: config)
            defer { session.finishTasksAndInvalidate() }
            guard let (remote, response) = try? await session.data(from: source.url),
                  (response as? HTTPURLResponse)?.statusCode == 200, !remote.isEmpty, remote.count <= 50 * 1024 * 1024 else { return nil }
            data = remote
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zalolite-forward", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])) != nil else { return nil }
        let target: URL
        if source.isPhoto {
            // Zalo serves photos as JPEG XL, which the upload does not accept; re-encode at full size.
            target = folder.appendingPathComponent("photo.jpg")
            guard let image = CGImageSourceCreateWithData(data as CFData, nil),
                  let destination = CGImageDestinationCreateWithURL(target as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImageFromSource(destination, image, 0, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }
        } else {
            let name = source.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            target = folder.appendingPathComponent(name.isEmpty ? "file" : name)
            guard (try? data.write(to: target, options: .atomic)) != nil else { return nil }
        }
        // The upload reads the file soon after; nothing is kept once it has had time to finish.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 900) { try? FileManager.default.removeItem(at: folder) }
        return target
    }
}
